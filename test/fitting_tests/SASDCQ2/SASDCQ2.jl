using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDCQ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCQ2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDCQ2: 2017 publication guidelines for structural modelling of
# small-angle scattering data from biomolecules in solution: an update.
#
# Paper: Trewhella J, Duff AP, Durand D, et al., Acta Crystallogr D Struct
# Biol (2017), DOI 10.1107/S2059798317011597. Open access (CC BY); PDF not
# in the repository, see test/fixtures/experiments/SASDCQ2/README.txt (PMC
# PMC5586245). SASBDB entry: https://www.sasbdb.org/data/SASDCQ2/
#
# Sample: CaM (monomer, 16.706 kDa/chain); measured at up to 1.1 mg/ml (Other). Instrument:
# Australian Synchrotron (X-ray synchrotron), wavelength 0.10332 nm = 1.033 Å => energy =
# hc/λ ≈ 12000 eV (hc = 12398.42 eV·Å). Sample temperature: 22.0 °C (SASBDB record).
#
# Buffer as deposited: "25 mM MOPS, 250 mM NaCl, 50 mM KCl, 2 mM TCEP, 0.1%
# NaN3", pH 7.5. Only the components with a partial-molar-volume entry and
# a stated concentration are modelled below; the measured macromolecule is
# deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹. The reference fit files are read
# from the same folder; each run's comparison curve is the depositor's fit for that
# model. ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0332   # ≈ 12000 eV, from the stated 0.10332 nm
const TEMPERATURE_C = 22.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 25 mM MOPS titrated with
# NaOH -> Na⁺ = C·0.722 (pK(22 °C) = 7.222). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.333 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "mops"),   # 25 mM, ±2%
    NonBiological(0.25, 0.005, "sodium chloride"),   # 250 mM, ±2%
    NonBiological(0.05, 0.001, "potassium chloride"),   # 50 mM, ±2%
    NonBiological(0.002, 4e-05, "tcep"),   # 2 mM, ±2%
    NonBiological(0.01538224888, 0.0003076449777, "sodium azide"),   # 15.38 mM, ±2%
    # Na⁺ counter-ion from NaOH titration of MOPS (see note above)
    NonBiological(0.018041, 0.001391, "sodium(1+)"),
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
        tag = "fit2_model1",
        pdb = "SASDCQ2_fit2_model1.pdb",
        fit = "SASDCQ2_fit2.dat",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "MultiFoXS 1-state",
    ),   # D_max ≈ 69 Å; deposited χ² = 0.85
    (
        tag = "fit3_model1",
        pdb = "SASDCQ2_fit3_model1.pdb",
        fit = "SASDCQ2_fit3.dat",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "MultiFoXS 2-state",
    ),   # D_max ≈ 71 Å; deposited χ² = 0.79
    (
        tag = "fit3_model2",
        pdb = "SASDCQ2_fit3_model2.pdb",
        fit = "SASDCQ2_fit3.dat",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "MultiFoXS 2-state",
    ),   # D_max ≈ 60 Å; deposited χ² = 0.79
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

# Builds the Seed that `run_sasdcq2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdcq2` below is the whole story (build the seed, then sample it).
function seed_sasdcq2(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdcq2(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdcq2(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdcq2(run)

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

    # `@__DIR__` (this SASDCQ2/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
