using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDRW2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRW2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRW2: A solution structure analysis reveals a bent collagen triple helix in the
# complement activation recognition molecule mannan-binding lectin.
#
# Paper: Iqbal H, Fung KW, Gor J, et al., J Biol Chem (2023), DOI
# 10.1016/j.jbc.2022.102799. Open access (CC BY); PDF not in the
# repository, see test/fixtures/experiments/SASDRW2/README.txt (PMC
# PMC9898670). SASBDB entry: https://www.sasbdb.org/data/SASDRW2/
#
# Sample: (POG)10 (trimer, 3.933 kDa/chain); measured at up to 2.0
# mg/ml (Single concentration). Instrument: Diamond Light Source (X-ray
# synchrotron), wavelength 0.12 nm = 1.2 Å => energy = hc/λ ≈ 10332 eV
# (hc = 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "20 mM L-histidine, 138 mM NaCl, 2.7 mM KCL,", pH 6.0. Curve
# units: the SASBDB .dat is already in Å⁻¹. The reference fit files are read from
# the same folder; each run's comparison curve is the depositor's fit for that
# model. ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # ≈ 10332 eV, from the stated 0.12 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 20 mM L-histidine titrated
# with HCl -> Cl⁻ = C·0.636 (pK(22 °C) = 6.123). The pH is taken as set at room temperature
# (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature.
# pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.153 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "l-histidine"),   # 20 mM, ±2%
    NonBiological(0.138, 0.00276, "sodium chloride"),   # 138 mM, ±2%
    NonBiological(0.0027, 5.4e-05, "potassium chloride"),   # 2.7 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of L-histidine (see note above)
    NonBiological(0.012725, 0.001313, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    pdb = "SASDRW2_fit1_model1.pdb",
    fit = "SASDRW2_fit1.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "CRYSOL",
),   # D_max ≈ 94 Å; deposited χ² = 3.028
]

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdrw2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdrw2` below is the whole story (build the seed, then sample it).
function seed_sasdrw2(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdrw2(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdrw2(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdrw2(run)

    # The figures (terminal plots, pgfplots .tex, TSV) go before the report, so
    # that their time is in its timing section.
    fit_curve = try
        fc = _read_fit(joinpath(_FIXTURE_DIR, run.fit), run.fit_scale, run.fit_col)
        fc !== nothing && run.rescale ? _rescale_fit(fc, q_fit, I_fit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    references = BAYSOL.Reference[]
    if fit_curve !== nothing
        push!(
            references,
            BAYSOL.Reference(
                run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""),
                fit_curve...; q_max = Q_MAX_FIT,
            ),
        )
    end
    BAYSOL.results(
        result, (q_fit, I_fit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        form_factor_log = form_factor_log, n_atoms = n_atoms,
    )

    # `@__DIR__` (this SASDRW2/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
