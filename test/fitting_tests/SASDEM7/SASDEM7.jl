# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDEM7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDEM7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDEM7_6I35_AB.pdb")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDEM7: human glycine decarboxylase (GLDC, the P-protein of the glycine
# cleavage system; UniProt P23378, residues 45-1020), a homodimer of 2 x 109.367 kDa =
# 218.7 kDa (SASBDB experimental MW 197 kDa), one concentration, 5.00 mg/ml, in "10 mM
# TRIS pH 7.5, 100 mM NaCl, 1 mM DTT, 100 mM glycine" (the enzyme's substrate). Entry
# title "Glycine decarboxylase (P-protein of glycine cleavage system)", sample name
# "Human glycine decarboxylase with glycine", measured 2017-11-12, released 2021-09-20,
# contributor B. Van Laer (ESRF). SASBDB lists NO publication for the entry. The same
# group deposited the crystal structures used here (PDB 6I33, 6I34, 6I35; "Structural
# insights in human glycine decarboxylase and comparison with the Neanderthal variant",
# B. Van Laer, U. Kapp, L. Signor, G. Leonard, C. Mueller-Dieckmann, "to be published"
# in the PDB headers). Conditions below are the SASBDB entry metadata
# (https://www.sasbdb.org/data/SASDEM7/ and its REST summary); no paper was consulted.
#
# Instrument (SASBDB): ESRF BM29 (Grenoble), Dectris Pilatus 1M, sample-detector
# distance 2.864 m, wavelength 0.099 nm = 0.99 Å (SASBDB `xray_energy` is null, so the
# energy is hc/λ ≈ 12524 eV), 10 successive 0.5 s frames, data normalized to the
# transmitted beam, radially averaged, solvent blank subtracted; cell and storage
# temperature 20 °C (the file trailer says 20.01 °C measured). Guinier (SASBDB): R_g
# 3.96 ± 0.01 nm, I(0) 138.06; Porod volume 315 nm³. The intensity unit is "arbitrary"
# (the scale is a free parameter of the fit).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.09 and s_max
# 4.934 nm⁻¹) with three text lines, 1032 rows of q, I, σ, and a trailer of text lines
# (all skipped by `_read_curve`), and is converted to Å⁻¹ (÷10). The curve ends at
# 0.4934 Å⁻¹.
#
# *** NO DEPOSITED FIT AND NO MODEL: SASBDB lists no fit, no model and no PDB link for
# *** SASDEM7. The structure is that of the crystal structure 6I35 (see below), the
# *** SASBDB entry's own sequence being the sequence of 6I33/6I35. There is NO
# *** reference curve and NO `ref_chi2` (`results` is called without `references`).
#
# Construct (SASBDB sequence, 984 residues): Met44 (initiating Met) + UniProt P23378
# residues 45-1020 (976 residues, the mature enzyme without the mitochondrial transit
# peptide, checked: the entry's residues 2-977 equal UniProt 45-1020 exactly) + Gly1021 and
# His1022-1027 (a C-terminal hexa-His tag after one Gly), 109.367 kDa. This is also the
# SEQRES of 6I33 and 6I35 (identical, checked residue by residue against the SASBDB
# sequence), so there is no construct mismatch in the sequence; the model lacks the
# residues that were not located (below), and the 984 vs 976 difference is only the
# initiating Met and the 7-residue tag.
#
# Which crystal structure (all by the SASBDB depositors' group, UniProt P23378):
#   - 6I34 (2.10 Å) is the NEANDERTHAL variant (Homo sapiens neanderthalensis, its own
#     sequence, not P23378), so it is not the sample's protein. Rejected.
#   - 6I33 (2.30 Å, human, PLP cofactor, dimer in the asymmetric unit, crystallized in
#     0.1 M HEPES pH 7, 6 % PEG 3350, 10 mM DTT): residues not located: chain A 44-48,
#     502-504, 790-793, 1006-1027; chain B 44-50, 634-641, 677-692, 721-722, 790-792,
#     1005-1027 (925 and 950 residues observed).
#   - 6I35 (2.00 Å, human, same crystallization conditions, tetramer = two dimers in the
#     asymmetric unit, REMARK 350 biomolecule 1 = chains A, B and biomolecule 2 = chains
#     C, D, both "DIMERIC, author determined and PISA"): the cofactor is bound as PLG,
#     N-glycine-(3-hydroxy-2-methyl-5-phosphonooxymethyl-pyridin-4-yl-methane), the
#     pyridoxyl-glycine 5'-monophosphate, i.e. PLP carrying the substrate glycine, a
#     stable analogue of the external aldimine. CHOSEN, for three reasons: (1) it is the
#     highest resolution, (2) it is the most complete (chain A lacks only 44-48,
#     502-505 and the tag from 1006; chain B only 44-50 and the tag from 1005: 953 and
#     954 residues observed of 984), and (3) it is the glycine-bound state, which is
#     presumably closer to the sample (100 mM glycine) than the glycine-free 6I33. The
#     difference to 6I33 in the scattering is small; this is a judgement, not a
#     measurement.
#
# Model file SASDEM7_6I35_AB.pdb (not a SASBDB file; made from files.rcsb.org/download/
# 6I35.pdb): a plain text selection of the ATOM records of chains A and B (7433 and
# 7442 atoms: residues 49-1005 of A and 51-1004 of B as located, heavy atoms, no
# hydrogens, no altlocs) and of the HETATM records of the residue PLG of chains A and B
# (20 atoms each, A1101 and B3003), chain A first, a TER after each chain, END; no
# REMARK/SEQRES/CRYST1 lines; coordinates and B-factors untouched (checked: the
# selected records equal those of 6I35). Left out of the selection: all waters (the
# loader drops them anyway), and the crystallization additives EDO (ethylene glycol),
# GOL (glycerol), PEG and BCT (bicarbonate) of those chains, which are not in the
# sample's buffer (the loader would otherwise keep them: `KEEP_LIGANDS`, owner decision
# 2026-11-11). The chains of 6I35 are A, B, C, D; the dimer extracted is the biological
# unit of REMARK 350 (biomolecule 1), not a crystal-contact pair. The PLG ligand is
# kept by the loader (known composition C10 H15 N2 O7 P; ligands get no hydrogens),
# part of the model as the enzyme's cofactor; its glycine is the substrate bound to the
# PLP, not the free glycine of the buffer (that one is a solute, below).
#
# The dimer has 14,915 heavy atoms (14,875 protein + 40 PLG); 953 + 954 of the 2 x 984
# residues are present, so the model lacks 61 residues (3.1 %: the initiating Met, the
# first residues up to 48/50, the tag and one internal loop), which makes the computed
# particle a little smaller than the sample's.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB: pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12524 eV, SASBDB wavelength 0.099 nm
const TEMPERATURE_C = 20.0                    # SASBDB cell temperature

# Buffer as deposited (SASBDB buffer name): "10 mM TRIS pH 7.5, 100 mM NaCl, 1 mM DTT,
# 100 mM glycine"; nothing else. The measured macromolecule is deliberately NOT a solute
# (see BulkElectronDensity.Solute).
#
# Glycine, 100 mM: an amino-acid additive (the enzyme's substrate) that is a
# large co-solute at this concentration. At pH 7.5 it is the zwitterion (pK₁
# 2.35, pK₂ 9.78, so ~0.5 % is the anion), net charge 0, so the table's glycine
# row (C2H5NO2, partial molar volume 43.3 mL/mol) applies and it does not enter
# the ionic strength; the small anion fraction is not modelled. ±2 % on C.
#
# Counter-ion (ASSUMED, not stated): setting pH 7.5 adds a titrant that the recipe does not
# list. 10 mM Tris titrated with HCl -> Cl⁻ = C·f, f the protonated fraction
# 1/(1 + 10^(pH − pK)·γ₁), pK(22 °C) = 8.156, the pH taken as set at room temperature (22
# ± 3 °C), pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231,
# DOI 10.1063/1.1416902) as in SASDMJ9 and SASDMM3, γ₁ the Davies activity coefficient of a
# monovalent ion (A = 0.509) at the self-consistent ionic strength I = 0.1 + 0.01 f of THIS
# recipe (Na⁺ 0.1 M, Cl⁻ 0.1 M + C f, TrisH⁺ C f; I = 0.1085 M, γ₁ = 0.777): f = 0.8536,
# Cl⁻ = 8.536 mM. σ combines σ_PH (0.1), the temperature term (±3 °C, ±0.0855 pK),
# ±0.02 pK, 30 % of the Davies shift and ±2 % on C, in quadrature with central
# differences: 0.000431 (the same calculation gives 0.008587 ± 0.000424 for SASDMJ9 against
# the 0.008588 ± 0.000422 there, and 0.017209 ± 0.000844 for SASDMM3 against 0.017209 ±
# 0.000838). Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not, nor is the effect of 100 mM glycine on the pH. DTT (pK 9.2 and
# 10.1) is taken as neutral at pH 7.5. Titrant: HCl for amine bases.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.100, 0.001, "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.010, 0.0002, "tris"),             # 10 mM Tris, ±2%
    NonBiological(0.001, 0.00002, "dtt"),             # 1 mM DTT, ±2%
    NonBiological(0.100, 0.002, "glycine"),           # 100 mM glycine (zwitterion), ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.008536, 0.000431, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# ASSUMED: the curve reaches 0.4934 Å⁻¹, but the mean signal-to-noise per point is about
# 2.7 at 0.2-0.3 Å⁻¹, 2.1 at 0.3-0.4 and 1.0 at 0.4-0.5 (32 of 199 points non-positive
# there), so the fit is cut at 0.3 Å⁻¹ (no fit exists for this entry to follow); the model
# is large (about 15 thousand heavy atoms), which a larger cut would make costlier.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `run_sasdem7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdem7` below is the whole story (build the seed, then sample it).
function seed_sasdem7(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdem7(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdem7(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdem7()

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log. No depositor fit exists for this entry, so there
# is no `references` and no `ref_chi2` (see the header).
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res",
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    run_log = true,
)

# `@__DIR__` (this SASDEM7/ folder), not the caller's cwd.

BAYSOL.print_summary(result)
