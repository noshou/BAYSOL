using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDBS6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDBS6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDBS6: Structural and biochemical analysis of Escherichia coli ObgE, a central
# regulator of bacterial persistence.
#
# Paper: Gkekas S, Singh RK, Shkumatov AV, et al., J Biol Chem (2017), DOI
# 10.1074/jbc.M116.761809.
# Open access (CC BY); PDF filed with the data:
# doi:10.1074/jbc.M116.761809 (PMC PMC5392579).
# SASBDB entry: https://www.sasbdb.org/data/SASDBS6/
#
# Sample: ObgE_FL (monomer, 44.441 kDa/chain) (Other). Instrument: SOLEIL
# (X-ray synchrotron), wavelength 0.103 nm = 1.03 Å => energy = hc/λ ≈ 12037
# eV (hc = 12398.42 eV·Å). Sample temperature: 10.0 °C (SASBDB record).
#
# Buffer as deposited: "20 mM Hepes , 300 mM NaCl, 250 mM imidazole, 5 mM
# MgCl2, 2 mM DTT", pH 7.5. Only the components with a partial-molar-volume
# entry and a stated concentration are modelled below; the measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
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
const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12037 eV, from the stated 0.103 nm
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds
# titrant counter-ions that the deposited recipe does not list. Assumed: 20 mM HEPES
# titrated with NaOH -> Na⁺ = C·0.520 (pK(22 °C) = 7.6); 250 mM imidazole titrated with
# HCl -> Cl⁻ = C·0.331 (pK(22 °C) = 7.058). The pH is taken as set at room temperature
# (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature.
# pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.408 M. σ
# combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the
# counter-ion is modelled; the volume change of the buffer's own (de)protonation is
# not. Titrant: Hepes/NaOH stated in the paper; imidazole assumed HCl.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM, ±2%
    NonBiological(0.3, 0.006, "sodium chloride"),   # 300 mM, ±2%
    NonBiological(0.25, 0.005, "imidazole"),   # 250 mM, ±2%
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM, ±2%
    NonBiological(0.002, 4e-05, "dtt"),   # 2 mM, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.010409, 0.001348, "sodium(1+)"),
    # Cl⁻ counter-ion from HCl titration of imidazole (see note above)
    NonBiological(0.082731, 0.016407, "chloride"),
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
        ref_chi2 = "EOM ensemble 11.3",
        pdb = "SASDBS6_fit2_model1.pdb",
        fit = "SASDBS6_fit2.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),   # D_max ≈ 141 Å; deposited χ² = 11.4
    (
        tag = "fit2_model2",
        ref_chi2 = "EOM ensemble 11.3",
        pdb = "SASDBS6_fit2_model2.pdb",
        fit = "SASDBS6_fit2.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),   # D_max ≈ 160 Å; deposited χ² = 11.4
    (
        tag = "fit2_model3",
        ref_chi2 = "EOM ensemble 11.3",
        pdb = "SASDBS6_fit2_model3.pdb",
        fit = "SASDBS6_fit2.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),   # D_max ≈ 151 Å; deposited χ² = 11.4
    (
        tag = "fit2_model4",
        ref_chi2 = "EOM ensemble 11.3",
        pdb = "SASDBS6_fit2_model4.pdb",
        fit = "SASDBS6_fit2.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),   # D_max ≈ 141 Å; deposited χ² = 11.4
    (
        tag = "fit2_model5",
        ref_chi2 = "EOM ensemble 11.3",
        pdb = "SASDBS6_fit2_model5.pdb",
        fit = "SASDBS6_fit2.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),   # D_max ≈ 108 Å; deposited χ² = 11.4
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

# Builds the Seed that `run_sasdbs6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdbs6` below is the whole story (build the seed, then sample it).
function seed_sasdbs6(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdbs6(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdbs6(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdbs6(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

    # run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
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
        ref_chi2 = run.ref_chi2,
        run_log = true,
    )

    # `@__DIR__` (this SASDBS6/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
