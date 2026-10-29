# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDZZ9")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDZZ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDZZ9_fit1.fit")

# `experimental_data/` and `pddf/` are both empty for this fixture.
raw = readdlm(_FIT_PATH; skipstart = 1)

qvals_all = Float64.(raw[:, 1])
I_all = Float64.(raw[:, 2])
σ_all = Float64.(raw[:, 3])
I_crysol_all = Float64.(raw[:, 4])

# Units: the file's header line ("RGT:23.93", i.e. Rg = 23.93 Å) is
# consistent with Dmax ≈ 3-4×Rg landing right on the coordinate-derived Dmax
# computed below (≈70.6 Å, 23.93*3 ≈ 71.8) only if q is already in Å⁻¹.
qvals = qvals_all
I_exp = I_all
σ_exp = σ_all

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: WebFetch of <https://www.sasbdb.org/data/SASDZZ9/>
#
#   Sample: "Chitooligosaccharide deacetylase (NodB) from the marine
#            bacterium Vibrio campbellii (VhCOD), native form"
#   Organism: Vibrio campbellii (strain ATCC BAA-1116)
#   Oligomeric state: monomer; UniProt A7MSF4 (residues 23-427); PDB 8YFP
#   Buffer: 20 mM Tris, 100 mM NaCl, pH 7.5
#   Temperature: 16°C; sample concentration: 4.00 mg/ml
#   Beamline: SLRI (Thailand) BL1.3W, wavelength 0.137 nm => energy =
#       hc/λ = 12398.42 eV·Å / 1.37 Å ≈ 9049.9 eV
#   Associated publication: Pongnan S, Robinson RC, Kamonsutthipaijit N,
#       Fukamizo T, Suginta W. Biophys Rep (N Y) 2026. PMID 42341985.
#   Models: two fits are given for this entry fit1 (rigid-body/crystal
#       PDB model, χ²≈34.5, this script) and fit2 (an ab initio DAMMIF/
#       DAMAVER dummy-atom bead model, χ²≈0.002).

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.37  # ≈ 9049.9 eV, from 0.137 nm wavelength
const TEMPERATURE_C = 16.0           # 16°C, SASBDB
# (only water's T-dependence is modelled)
const IONIC_STRENGTH_M = 0.100          # 100 mM NaCl, SASBDB's stated ~100 mM

# NodB sequence, SASDZZ9_fit1_model1.pdb chain A (the only
# protein chain present; residues 2-405, 404 residues).
const NODB_SEQ =
    "TAPKGTIYLTFDDGPINASIDVINVLNEQGVKGTFYFNAWHLDGIGDENEDRALEALKLA" *
    "LDTGHVVANHSYAHMVHNCVDEFGPTSGAECNATGDHQINAYQDPVYDASTFADNLVVFE" *
    "RYLPNINSYPNYFGEELARLPYTNGWRITKDFKADGLCATSDDLKPWEPGYVCDLDNPSN" *
    "SVKASIEVQNILANKGYQTHGWDVDWSPENWGIPMPANSLTEAEAFLGYVDAALNSCAPT" *
    "TINPINSKAHGFPCGTPLHADKVVVLTHEFLYEDGKRGMGATQNLPKLAKFLRIAKEAGY" *
    "VFDTIDNYTPVWQVGNAYAAGDYVTHSGTVYKAVTAHIAQQDWAPSSTSSLWTNADPATN" *
    "WTLNVSYEAGDVVTYQGLRYLVNVPHVSQADWTPNTQNTLFTAL"

# Average mass from NODB_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH); ≈44.36 kDa, close to SASBDB's stated 45 kDa.
const NODB_MW         = 44360.06   # g/mol
const NODB_CONC_MG_ML = 4.00
const NODB_MOLARITY   = NODB_CONC_MG_ML / NODB_MW   # ≈ 9.02e-5 M
const NODB_MOLARITY_σ = MOLARITY_REL_SIGMA * NODB_MOLARITY

# Buffer components. "sodium chloride" / "tris" both present verbatim in
# src/BulkElectronDensity/NonBiological/nonbio_lookup.json. Counter-ions (added
# 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.854 (pK(22 °C) =
# 8.156). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg,
# Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902)
# pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.117 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled;
# the volume change of the buffer's own (de)protonation is not. Titrant: not stated;
# HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.100, 0.001, "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.020, 0.0004, "tris"),              # 20 mM Tris, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017086, 0.000856, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# Q_MAX_FIT is set to just above the file's q_max (0.387528). The spherical-harmonic
# band limit lMax is not set here: `seed_model` takes it from the diameter of the
# scatterer cloud and the largest fitted q (ceil(q_max * D)), and bins the curve to
# the Shannon channels that diameter allows (see `rebin` there).
const Q_MAX_FIT = 0.39

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
The `σ_exp > 0` filter also drops this file's own leading q<0.0213
placeholder rows (I_exp = σ_exp = 0, no experimental coverage there).
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdzz9_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdzz9_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdzz9_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdzz9_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdzz9_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdzz9_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
reference = BAYSOL.Reference("CRYSOL fit1", qvals_all, I_crysol_all; q_max = Q_MAX_FIT)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "CRYSOL ≈ 34.5",
    run_log = true,
)

# `@__DIR__` (this SASDZZ9/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
