# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDF42")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDF42_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDF42_fit1.fit")

# `experimental_data/` and `pddf/` are both empty for this entry
#
#     sExp iExp Err iFit // ChiExp =   1.45
#
# i.e. column 1 = q, column 2 =
# I_exp, column 3 = σ_exp, column 4 = the paper's own fitted/reference
# curve (χ² = 1.45 quoted in the header). Single header line, so
# `skipstart = 1`.
raw = readdlm(_FIT_PATH; skipstart = 1)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Johansson et al. 2020, Biochemistry 59:1410-1419 ("Identification
# of Binding Sites on Human Serum Albumin for Somapacitan, a Long-Acting
# Growth Hormone Derivative"), doi:10.1021/acs.biochem.0c00019.
#
# Table 2 ("SAXS Data") lists three SAXS entries; the third column,
# "HSA:somapacitan" (molar ratio 1:2, 6.3 mg/mL, MicroMax-007 HF (Rigaku),
# λ = 1.54187 Å, 20 °C, exposure 3600 s, Rg = 41 Å, Dmax = 139 Å, MW ≈ 113
# kDa theoretical), carries the SASDB accession code SASDF42.
#
# Buffer: the "HSA:Somapacitan Complex Formation Studied by SEC" paragraph
# describes this as a 1:2 HSA:somapacitan preparation (Figure 3a, "1:2
# molar ratio (gray)"), run on "a Superdex 200 10/300 GL column (GE
# Healthcare) equilibrated with a 100 mM MES, 140 mM sodium chloride, pH
# 6.5 buffer".
#
# X-ray source for this data set (Table 2, third column): MicroMax-007 HF
# (Rigaku) rotating anode, wavelength stated as 1.54187 Å (Cu Kα) =>
# energy = hc/λ ≈ 8043 eV (hc = 12398.42 eV·Å). Table 2 states the sample
# temperature explicitly as 20 °C.

const PH, σ_PH = 6.5, PH_METER_SIGMA

# ≈ 8043 eV, from the stated 1.54187 Å wavelength
const ENERGY_EV = HC_EV_ANGSTROM / 1.54187
# 20°C, Table 2 (SASBDB says 25 °C; the paper's explicit Table 2 value is used)
const TEMPERATURE_C    = 20.0
const IONIC_STRENGTH_M = 0.140             # 140 mM NaCl, matches the SEC/SAXS buffer above

# ---------------------------------------------------------------------------
#                        Sequences (read from the PDB itself)
# ---------------------------------------------------------------------------
#
# SASDF42_fit1_model1.pdb has no SEQRES records, so both sequences
# were read directly off its own ATOM/CA records (three-letter -> one-letter
# translation of each chain's residues, in residue-number order). The
# REMARKs at the top of the file ("Cond Sub Res ... Dist Pen", Euler-angle
# rotation, SASREF-style "Discog/Cross/Anisom/Center" penalty terms) match
# the paper's own description of this entry ("A rigid body refinement using
# a HSA model in complex with octadecanoic acid and two growth hormone
# molecules ... was applied [with] the ATSAS SASREF module [and] 15 Å
# distance constraints from residue 101 of growth hormone to residues 209
# (FA6) and 502 (FA5) of HSA").
#
# Chain A (residues 3-584, 582 residues modelled) is HSA: the extracted
# sequence lines up exactly with mature human serum albumin (UniProt
# P02768, residues 1-585) starting "DAHKSEV..." (chain A starts at residue
# 3 = "H", i.e. D1/A2 are simply not resolved in this model), missing only
# the very last residue (585, Leu). No bound fatty acid (octadecanoic
# acid) is present as HETATM in this file.
#
# Chains B and C (residues 2-190, 186 residues each, identical sequence) 
# are the two growth hormone (somapacitan) copies;
# both have an internal gap at residues 37-39 (a flexible loop not modelled
# in either copy). Chain B's sequence is used below as the representative
# growth-hormone sequence; its second copy (chain C) is folded into the
# solute molarity below (2x) rather than listed twice, since it is
# chemically the same dissolved species.
const HSA_SEQ =
    "HKSEVAHRFKDLGEENFKALVLIAFAQYLQQCPFEDHVKLVNEVTEFAKTCVADESAENC" *
    "DKSLHTLFGDKLCTVATLRETYGEMADCCAKQEPERNECFLQHKDDNPNLPRLVRPEVDV" *
    "MCTAFHDNEETFLKKYLYEIARRHPYFYAPELLFFAKRYKAAFTECCQAADKAACLLPKL" *
    "DELRDEGKASSAKQRLKCASLQKFGERAFKAWAVARLSQRFPKAEFAEVSKLVTDLTKVH" *
    "TECCHGDLLECADDRADLAKYICENQDSISSKLKECCEKPLLEKSHCIAEVENDEMPADL" *
    "PSLAADFVESKDVCKNYAEAKDVFLGMFLYEYARRHPDYSVVLLLRLAKTYETTLEKCCA" *
    "AADPHECYAKVFDEFKPLVEEPQNLIKQNCELFEQLGEYKFQNALLVRYTKKVPQVSTPT" *
    "LVEVSRNLGKVGSKCCKHPEAKRMPCAEDYLSVVLNQLCVLHEKTPVSDRVTKCCTESLV" *
    "NRRPCFSALEVDETYVPKEFNAETFTFHADICTLSEKERQIKKQTALVELVKHKPKATKE" *
    "QLKAVMDDFAAFVEKCCKADDKETCFAEEGKKLVAASQAALG"

const GH_SEQ =
    "PTIPLSRLFQNAMLRAHRLHQLAFDTYEEFEEAYIQKYSFLQAPQASLCFSESIPTPSNR" *
    "EQAQQKSNLQLLRISLLLIQSWLEPVGFLRSVFANSCVYGASDSDVYDLLKDLEEGIQTL" *
    "MGRLEDGSPRTGQAFKQTYAKFDANSHNDDALLKNYGLLYCFRKDMDKVETFLRIVQCRS" *
    "VEGSCG"

# Average masses from HSA_SEQ/GH_SEQ (ExPASy average residue masses + one
# water for the terminal H/OH), computed from the PDB-resolved sequences. 
# these are slightly smaller than the full mature-protein
# masses (HSA is missing 3 N-/C-terminal residues; growth hormone is
# missing 5 residues incl. the 37-39 loop), and the growth hormone mass
# in excludes somapacitan's non-protein modification (the
# tetrazole/linker/C18-diacid albumin-binding side chain of Figure 2d),
# since that side chain has no resolved coordinates in this rigid-body
# model. Both are therefore approximations, noted here rather than
# silently assumed exact.
const HSA_MW = 66172.88   # g/mol
const GH_MW  = 21221.05   # g/mol

# Table 2's "HSA:somapacitan" column: total protein concentration 6.3
# mg/mL at a 1:2 (HSA:somapacitan) molar ratio. Treating the dissolved
# material as "1 HSA + 2 GH per complex" with the masses above:
#
#   MW_complex = HSA_MW + 2*GH_MW ≈ 108.6 kDa  (paper's own theoretical
#     MW for this column is 113 kDa; the ~4% gap is attributable to the
#     GH_MW approximation above excluding somapacitan's small-molecule
#     modification and to the few unmodelled terminal/loop residues)
#   [complex] = 6.3 mg/mL / MW_complex ≈ 0.058 mM
#   [HSA]      = [complex]        (1 HSA per complex)
#   [GH]       = 2 * [complex]    (2 growth-hormone copies per complex)
const TOTAL_PROTEIN_CONC_MG_ML = 6.3
const _COMPLEX_MOLARITY        = TOTAL_PROTEIN_CONC_MG_ML / (HSA_MW + 2 * GH_MW)   # mol/L

const HSA_MOLARITY   = _COMPLEX_MOLARITY
const HSA_MOLARITY_σ = MOLARITY_REL_SIGMA * HSA_MOLARITY
const GH_MOLARITY    = 2 * _COMPLEX_MOLARITY
const GH_MOLARITY_σ  = MOLARITY_REL_SIGMA * GH_MOLARITY

# Buffer components Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 100 mM MES titrated with
# NaOH -> Na⁺ = C·0.682 (pK(22 °C) = 6.296). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.208 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.140, 0.0014, "sodium chloride"),   # 140 mM NaCl, ±1%
    NonBiological(0.100, 0.002, "mes"),                # 100 mM MES, ±2%
    # Na⁺ counter-ion from NaOH titration of MES (see note above)
    NonBiological(0.068195, 0.005764, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .fit file's own full q-range (≈0.008-0.5 Å⁻¹); no further truncation
# needed.
const Q_MAX_FIT = 0.5

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdf42` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdf42` below is the whole story (build the seed, then sample it).
function seed_sasdf42(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdf42(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdf42(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdf42()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "SASREF fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "2.10",
    run_log = true,
)

# `@__DIR__` (this SASDF42/ folder), not the caller's cwd.

BAYSOL.print_summary(result)
