using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

# =============================================================================
#                                *** CAUTION ***
# =============================================================================
# SASDX52 is the LEAST-documented case in this test family: no bundled paper
# PDF, no experimental_data/*.dat, no GNOM pddf. The ONLY fixture files are
# SASDX52_fit1.fit (the sole source of q/I/σ *and* the reference fit curve)
# and SASDX52_fit1_model1.pdb (an AlphaFold-monomer-derived, depositor-docked
# dimer model). All solution-condition metadata below comes from ONE of three
# tiers, marked explicitly at each declaration:
#
#   [SASBDB]    fetched from https://www.sasbdb.org/data/SASDX52/ via WebFetch
#               in this session -- NOT cross-checked against the underlying
#               paper (Rahman, Dalwani & Venkatesan 2025, Biochem Biophys Res
#               Commun 769:151960) because no PDF is bundled here. Treat as
#               provisional, SASBDB-page-sourced metadata, not paper-verified.
#   [DEFAULT]   this package's own default (a module-level constant of the owning module),
#               used because nothing case-specific was available.
#   [PLACEHOLDER] a best-effort, UNVERIFIED guess with no direct source at
#               all -- flagged loudly inline.
#
# This case needs more scrutiny before being trusted than any of its siblings.
# =============================================================================

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDX52")
const _PDB_PATH = joinpath(_FIXTURE_DIR, "SASDX52_fit1_model1.pdb")
const _FIT_PATH = joinpath(_FIXTURE_DIR, "SASDX52_fit1.fit")

# No experimental_data/*.dat bundled: SASDX52_fit1.fit is the only source of
# q/I/σ. 3 '#' header lines, 4 columns: q, exp_intensity, error, model_intensity.
# q is already in Å⁻¹ (SASBDB .fit outputs are Å⁻¹, unlike some raw .dat
# files which come in nm⁻¹ and need /10 -- no such conversion here).
raw = readdlm(_FIT_PATH; skipstart = 3)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# [SASBDB] WebFetch of https://www.sasbdb.org/data/SASDX52/ in this session
# returned (no bundled paper PDF to cross-verify against):
#
#   Protein:      Fatty acyl-CoA synthetase FadD5 (probable fatty-acid-CoA
#                 ligase), Mycobacterium tuberculosis (H37Rv); dimer;
#                 monomer MW ≈ 61.7 kDa (SASBDB's own figure; the
#                 sequence-derived MW computed below, ≈59.9 kDa, is used for
#                 the molarity conversion instead -- see FADD5_MW).
#   Buffer:       20 mM HEPES, 500 mM NaCl, 5 mM MgCl2, 1 mM
#                 beta-mercaptoethanol, pH 7.5
#   Conc.:        4.00 mg/ml, 20 successive 1 s frames
#   Temperature:  4 °C
#   Beamline:     Diamond Light Source B21, Eiger 4M, wavelength 0.09537 nm,
#                 sample-detector distance 3.72 m
#   Publication:  Rahman MA, Dalwani S, Venkatesan R (2025), "Structural
#                 enzymological studies of the long chain fatty acyl-CoA
#                 synthetase FadD5 from the mce1 operon of Mycobacterium
#                 tuberculosis", Biochem Biophys Res Commun 769:151960.

const PH, σ_PH = 7.5, PH_METER_SIGMA   # [SASBDB]; σ not stated by SASBDB

# [SASBDB] wavelength 0.09537 nm = 0.9537 Å => energy = hc/λ ≈ 13000.3 eV
# (hc = 12398.42 eV·Å).
const ENERGY_EV = HC_EV_ANGSTROM / 0.9537   # ≈ 13000.3 eV

# [SASBDB] 4°C.
const TEMPERATURE_C = 4.0

const DEBYE_T_K = 4.0 + 273.15   # 277.15 K

# [SASBDB] buffer-derived ionic strength: I = 1/2 Σ cᵢzᵢ².
#   500 mM NaCl:  1/2*(0.500*1² + 0.500*1²)          = 0.500
#   5 mM MgCl2:   1/2*(0.005*2² + 0.010*1²)          = 0.015
#   HEPES (zwitterionic near pH 7.5) and 1 mM BME (nonionic) contribute
#   negligibly and are omitted.
const IONIC_STRENGTH_M = 0.515

# FadD5 sequence, read directly off SASDX52_fit1_model1.pdb chain A SEQRES
# (554 residues). 
const FADD5_SEQ =
    "MTAQLASHLTRALTLAQQQPYLARRQNWVNQLERHAMMQPDAPALRFVGNTMTWADLRRR" *
    "VAALAGALSGRGVGFGDRVMILMLNRTEFVESVLAANMIGAIAVPLNFRLTPTEIAVLVE" *
    "DCVAHVMLTEAALAPVAIGVRNIQPLLSVIVVAGGSSQDSVFGYEDLLNEAGDVHEPVDI" *
    "PNDSPALIMYTSGTTGRPKGAVLTHANLTGQAMTALYTSGANINSDVGFVGVPLFHIAGI" *
    "GNMLTGLLLGLPTVIYPLGAFDPGQLLDVLEAEKVTGIFLVPAQWQAVCTEQQARPRDLR" *
    "LRVLSWGAAPAPDALLRQMSATFPETQILAAFGQTEMSPVTCMLLGEDAIAKRGSVGRVI" *
    "PTVAARVVDQNMNDVPVGEVGEIVYRAPTLMSCYWNNPEATAEAFAGGWFHSGDLVRMDS" *
    "DGYVWVVDRKKDMIISGGENIYCAELENVLASHPDIAEVAVIGRADEKWGEVPIAVAAVT" *
    "NDDLRIEDLGEFLTDRLARYKHPKALEIVDALPRNPAGKVLKTELRLRYGACVNVERRSA" *
    "SAGFTERRENRQKL"

# Average mass from FADD5_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH) => ≈59.91 kDa, close to (but not identical to) SASBDB's
# own quoted 61.7 kDa monomer MW; the sequence-derived value is used for
# internal consistency with FADD5_SEQ.
const FADD5_MW = 59905.88   # g/mol

# [SASBDB] 4.00 mg/ml protein concentration / sequence-derived monomer MW.
const FADD5_CONC_MG_ML = 4.00
const FADD5_MOLARITY   = FADD5_CONC_MG_ML / FADD5_MW # ≈ 6.68e-5 M
const FADD5_MOLARITY_σ = MOLARITY_REL_SIGMA * FADD5_MOLARITY   # σ not stated by SASBDB

# Buffer components. All four species below were cross-checked against
# src/BulkElectronDensity/NonBiological/nonbio_lookup.json and found
# present (no MISSING FROM PMV LOOKUP entries for this case):
#   "sodium chloride"    -> "sodium chloride"
#   "magnesium chloride" -> "magnesium dichloride"
#   "hepes"               -> "2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonic acid"
#   "2-mercaptoethanol"   -> "2-mercaptoethanol"
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the
# deposited recipe does not list. Assumed: 20 mM HEPES titrated with NaOH -> Na⁺ = C·0.519
# (pK(22 °C) = 7.6). The pH is taken as set at room temperature (22 ± 3 °C), which fixes
# the counter-ion amount whatever the measurement temperature. pK(T) from Goldberg,
# Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902)
# pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.525 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the
# volume change of the buffer's own (de)protonation is not. Titrant: not stated; HCl for
# amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.500, 0.005, "sodium chloride"),    # 500 mM NaCl, ±1%
    NonBiological(0.020, 0.0004, "hepes"),              # 20 mM HEPES, ±2%
    NonBiological(0.005, 0.0001, "magnesium chloride"), # 5 mM MgCl2, ±2%
    # 1 mM BME, ±5% (small conc., degrades/evaporates)
    NonBiological(0.001, 0.00005, "2-mercaptoethanol"),
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.010382, 0.001346, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# Full q-range of the only data source (SASDX52_fit1.fit): q_max ≈ 0.16996.
# No additional high-q truncation is needed (the bundled .fit file is
# already restricted to the fitted range), but Q_MAX_FIT/fit_subset() are
# kept for consistency with the rest of this test family and as a guard
# against any I_exp ≤ 0 points.
const Q_MAX_FIT = 0.17

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdx52` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdx52` below is the whole story (build the seed, then sample it).
function seed_sasdx52(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdx52(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdx52(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdx52()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
ref = readdlm(_FIT_PATH; skipstart = 3)
reference = BAYSOL.Reference(
    "SASBDB fit1",
    Float64.(ref[:, 1]),
    Float64.(ref[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "0.70 (method unconfirmed)",
    run_log = true,
)

# `@__DIR__` (this SASDX52/ folder), not the caller's cwd.

BAYSOL.print_summary(result)
