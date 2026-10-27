using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWZ9")
const _PDB_PATH = joinpath(_FIXTURE_DIR, "SASDWZ9_fit1_model1.pdb")
const _FIT_PATH = joinpath(_FIXTURE_DIR, "SASDWZ9_fit1.fit")

# `experimental_data/` and `pddf/` are both empty for this fixture (no
# standalone .dat and no GNOM .out were bundled).
raw = readdlm(_FIT_PATH; skipstart = 6)

qvals       = Float64.(raw[:, 1])
I_exp       = Float64.(raw[:, 2])
σ_exp       = Float64.(raw[:, 3])
I_pepsi_fit = Float64.(raw[:, 4])   # Pepsi-SAXS's own fitted curve, for the comparison plot

# q is already in Å⁻¹ here (range ≈ 0.0083-0.3501, the usual protein-SAXS
# scale) -- unlike SASDMJ9's SASBDB .dat export, no nm⁻¹ -> Å⁻¹ conversion
# is needed.

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Huang et al. 2026, ACS Omega 11:2614-2627 ("pH Sensitivity of the
# SERF1a Conformational Ensemble"), doi:10.1021/acsomega.5c07620,
# "Materials and Methods" / "Purification and Preparation of Samples" (the
# only Methods paragraph in the bundled main-text PDF; a separate
# Supporting Information PDF with further experimental detail is referenced
# but not bundled in this fixture).
#
# The paper states the final SEC running buffer used immediately before
# SAXS is "a size-exclusion column, Superdex 75 Increase 10/300 (Cytiva) in
# 20 mM NaPi (pH 6.0 or pH 6.8), 20 mM NaCl, and 0.02% NaN3." SASDWZ9 (vs.
# its sibling SASDWY9, the pH 6 dataset from the same paper) is the pH 6.8
# entry: confirmed both by the .fit file's own embedded Pepsi-SAXS command
# line (`S7_pH68_...`) and by the SASBDB metadata page for SASDWZ9
# (sasbdb.org/data/SASDWZ9/), which additionally gives the sample details
# the bundled main-text PDF itself doesn't state:
#
#     protein concentration: 15.00 mg/ml
#     buffer:                20 mM sodium phosphate, 20 mM NaCl, pH 6.8
#     temperature:            10°C
#     beamline:                TPS 13A, NSRRC (Hsinchu, Taiwan), Eiger X 9M
#     wavelength:              0.08266 nm = 0.8266 Å  => energy = hc/λ ≈ 15.0 keV
#
# consistent with TPS 13A's published nominal ~15 keV configuration
# (Shih et al. 2022, J. Appl. Crystallogr. 55:340-352, cited as ref. 62 in
# the paper for the beamline itself).

const PH, σ_PH = 6.8, PH_METER_SIGMA

# ≈ 15000 eV, from SASBDB's stated 0.08266 nm wavelength
const ENERGY_EV     = HC_EV_ANGSTROM / 0.8266
const TEMPERATURE_C = 10.0   # 10°C, SASBDB
# unused by the fit; derived from the old pKa2 = 7.2 split (see below)
const IONIC_STRENGTH_M = 0.0545

# SERF1a sequence, read directly off SASDWZ9_fit1_model1.pdb chain A
# (residues 1-62, all 62 residues modelled -- this is a single filtered
# NMR/TAiBP-CYANA conformer, MODEL 37 of the deposited ensemble, not a
# crystal structure). MW below is computed from this sequence and matches
# SASBDB's stated "7.3 kDa (monomer)" to within rounding.
const SERF1A_SEQ = "MARGNQRELARQKNMKKTQEISKGKRKEDSLTASQRKQRDSEIMQEKQKAANEKKSMQTREK"

# Average mass from SERF1A_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH).
const SERF1A_MW = 7336.37   # g/mol
# SASBDB metadata (not stated in the bundled main-text PDF)
const SERF1A_CONC_MG_ML = 15.00
const SERF1A_MOLARITY   = SERF1A_CONC_MG_ML / SERF1A_MW   # ≈ 2.045 mM
const SERF1A_MOLARITY_σ = MOLARITY_REL_SIGMA * SERF1A_MOLARITY   # σ not stated

# Buffer components.
#
# "20 mM NaPi" is not itself a single species: at pH 6.8 it is a mix of NaH2PO4 and
# Na2HPO4. The HPO4²⁻ fraction is 0.425: pK2 from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230
# J/K/mol) at 22 °C (pH set at room temperature), Davies-corrected at I ≈ 0.060 M, giving
# an effective pK2' ≈ 6.93. This replaces the earlier flat pKa2 = 7.2, which ignored ionic
# strength. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
#
# 0.02% NaN3 (w/v) = 0.2 g/L; MW(NaN3) = 65.01 g/mol => ≈ 3.08 mM.
#
# IONIC_STRENGTH_M above is I = ½Σ cᵢzᵢ² over all these species (Na⁺, Cl⁻,
# H2PO4⁻, HPO4²⁻ [z=-2, so it enters with weight 4], N3⁻) rather than just
# the 20 mM NaCl term (as the simpler SASDMJ9 buffer used), since the
# doubly-charged HPO4²⁻ fraction is a non-negligible contributor here:
#
#     Na⁺ total = 0.020 + 0.01431 + 2·0.00569 + 0.00308 ≈ 0.04877 M
#     I = ½·[0.04877·1 + 0.020·1 + 0.01431·1 + 0.00569·4 + 0.00308·1] ≈ 0.0545 M
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.020, 0.0002, "sodium chloride"),             # 20 mM NaCl, ±1%
    # 20 mM NaPi, H2PO4⁻ part
    NonBiological(0.011494, 0.001491, "sodium dihydrogen phosphate"),
    # 20 mM NaPi, HPO4²⁻ part
    NonBiological(0.008506, 0.001483, "disodium hydrogen phosphate"),
    NonBiological(0.003076, 0.0000615, "sodium azide"),                # 0.02% w/v NaN3, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.35   # the .fit file's own full q-range (≈0.0083-0.3501 Å⁻¹)

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true  # runs Pdb2pqr at PH; the NMR structure already carries
# modelled hydrogens, but Pdb2pqr recomputes pH-consistent
# protonation states from the heavy-atom positions regardless.

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdwz9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdwz9` below is the whole story (build the seed, then sample it).
function seed_sasdwz9(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdwz9(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdwz9(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdwz9()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
reference = BAYSOL.Reference("Pepsi-SAXS fit1", qvals, I_pepsi_fit; q_max = Q_MAX_FIT)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "Pepsi-SAXS 0.62",
    run_log = true,
)

# `@__DIR__` (this SASDWZ9/ folder), not the caller's cwd.

BAYSOL.print_summary(result)
