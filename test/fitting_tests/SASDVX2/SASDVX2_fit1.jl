using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVX2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVX2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVX2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVX2_fit1.fit")

# The .dat has 3 lines of header and 45 lines of processing history at the end, and the
# latter break `readdlm` (SASDVV4's has quote characters), so `_read_curve` (common.jl,
# numeric rows only) reads it: 2625 points.
qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
@assert length(qvals) == 2625

# qvals are in nm⁻¹ (0.0255-7.35); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDVX2 (sasbdb.org/data/SASDVX2/); paper: Mertinkus
# et al. 2024, J. Am. Chem. Soc., "Dissecting the Conformational Heterogeneity of
# Stem-Loop Substructures of the Fifth Element in the 5'-Untranslated Region of
# SARS-CoV-2", DOI 10.1021/jacs.4c08406 (PMID 39442924). The paper's methods text was not
# consulted.
#
#     25 mM potassium phosphate, 50 mM KCl, pH 6.2
#
# The SASBDB comment says the buffer was "also used with 10 mM Mg2+ or 10 mM Mg2+/5 mM
# GdnCl"; this curve is the "50_mM_KCl" sample (.dat header), so no Mg2+ is listed.
# Full-length stem-loop 5 RNA (48.3 kDa), 1.0 mg/mL, 10 °C (cell; storage 20 °C), EMBL P12
# (PETRA III), wavelength 0.124028 nm => energy = hc/λ ≈ 10 keV (hc = 12398.42 eV·Å).
# The model is a PyMOL-built all-atom RNA without hydrogens.

const PH, σ_PH = 6.2, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24028   # ≈ 9996 eV, from the stated 0.124028 nm
const TEMPERATURE_C = 10.0                       # 10 °C, SASBDB

# Buffer components. "25 mM potassium phosphate" is a mix of KH2PO4 and K2HPO4 at pH 6.2:
# the HPO4²⁻ fraction is 0.166 (pK2 from Goldberg, Kishore & Lennen 2002, J. Phys. Chem.
# Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at
# 22 °C (pH set at room temperature), Davies-corrected at I ≈ 0.083 M. σ combines σ_PH,
# ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C. Same treatment as the sodium
# phosphate of SASDWZ9.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    # 25 mM KPi, H2PO4⁻ part
    NonBiological(0.020851, 0.000999, "potassium dihydrogen phosphate"),
    # 25 mM KPi, HPO4²⁻ part
    NonBiological(0.004149, 0.000999, "dipotassium hydrogen phosphate"),
    NonBiological(0.050, 0.0005, "potassium chloride"),   # 50 mM KCl, ±1%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .dat runs to 0.73 Å⁻¹ (the .fit file to 0.50 Å⁻¹); the fit is cut at 0.3 Å⁻¹.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE, no PROPKA for a
# nucleic-acid-only file)
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`. (`seed_model`
bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(≤(Q_MAX_FIT), qvals)
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdvx2_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdvx2_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdvx2_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdvx2_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdvx2_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdvx2_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "Pepsi-SAXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "Pepsi-SAXS 6.974",
    run_log = true,
)

# `@__DIR__` (this SASDVX2/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
