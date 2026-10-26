using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDSW7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSW7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDSW7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDSW7_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 3)

# has 3 lines of headers, and 10 lines of trailer (merge information) at the end; need to
# skip. The third header line is long, so `readdlm` pads the file to 4 columns; only
# columns 1-3 of the 1388 data rows are used.
qvals = Float64.(raw[1:1388, 1])
I_exp = Float64.(raw[1:1388, 2])
σ_exp = Float64.(raw[1:1388, 3])

# q is already in Å⁻¹ (range 0.01125-0.882, SASBDB "1/A", APS 12-ID-B); no unit
# conversion is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDSW7/); paper: Escobar C, Petersen R,
# Tonelli M, Fan L, Henzler-Wildman K, Butcher S 2023, J. Mol. Biol. ("Solution structure of
# poly(UG) RNA"), DOI 10.1016/j.jmb.2023.168340.
#
#   Sample:   poly(GU) RNA, 12 GU repeats (GUGUGUGUGUGUGUGUGUGUGUGU, 24 nt, 7.834 kDa);
#             the curve is the concentration series 0.26, 1, 1.4 and 1.6 mg/mL
#             extrapolated to infinite dilution
#   Buffer:   "20 mM HEPES, 150 mM KCl", pH 7.0
#   Temp.:    22 °C ("Solute concentrations ... were measured at 22°C"; storage 4 °C)
#   Beamline: APS 12-ID-B, Eiger2 S, "wavelength of λ = 0.0932 nm" => 0.932 Å =>
#             energy = hc/λ ≈ 13303 eV
#   Model:    SASDSW7_fit1_model1.pdb, an XPLOR-NIH structure, chain A, 24 nucleotides
#             (G and U residue names) with 254 hydrogens (767 atoms); deposited with the
#             Pepsi-SAXS fit1 (χ² 2.688)

const PH, σ_PH = 7.0, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 0.932   # ≈ 13303 eV, from the stated 0.0932 nm
const TEMPERATURE_C = 22.0                     # 22 °C, SASBDB (measurement temperature)

# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM HEPES titrated with NaOH -> Na⁺ = C·0.2482 (pK(22 °C) = 7.601;
# ΔH 21.0 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.155 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.150, 0.0015, "potassium chloride"),   # 150 mM KCl, ±1%
    NonBiological(0.020, 0.0004, "hepes"),                 # 20 mM HEPES, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.004964, 0.000989, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.5: the data (and the Pepsi-SAXS fit) reach 0.88 Å⁻¹, far past the useful range of a
# 7.8 kDa RNA (10 non-positive points, a flat tail); 0.5 Å⁻¹ keeps the shape and the
# first minima and is the value used for the other nucleic-acid entries.
const Q_MAX_FIT = 0.5

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true although the XPLOR-NIH model already carries 254 hydrogens, as for
# SASDWZ9: Pdb2pqr rebuilds the hydrogens from the heavy atoms.
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

# Builds the Seed that `run_sasdsw7_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdsw7_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdsw7_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdsw7_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdsw7_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdsw7_fit1()

fit, divergence_rate, map_result, quantile_result = result

# The figures (terminal plots, pgfplots .tex, TSV) go before the report, so
# that their time is in its timing section.
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
)

# `@__DIR__` (this SASDSW7/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
