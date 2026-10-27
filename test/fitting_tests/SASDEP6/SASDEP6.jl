using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDEP6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDEP6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDEP6: Molecular Fingerprints for a Novel Enzyme Family in Actinobacteria with
# Glucosamine Kinase Activity.
#
# Paper: Manso JA, Nunes-Costa D, Macedo-Ribeiro S, et al., MBio (2019),
# DOI 10.1128/mBio.00239-19. Open access (CC BY, CC BY SA); PDF not in
# the repository, see test/fixtures/experiments/SASDEP6/README.txt (PMC
# PMC6520443). SASBDB entry: https://www.sasbdb.org/data/SASDEP6/
#
# Sample: Glucosamine kinase (monomer, 48.377 kDa/chain); measured at up to 5.0 mg/ml
# (Extrapolated to infinite dilution).
# Instrument: ESRF (X-ray synchrotron), wavelength 0.09919 nm = 0.9919 Å => energy = hc/λ ≈
# 12500 eV (hc = 12398.42 eV·Å). Sample temperature: 10.0 °C (SASBDB record).
#
# Buffer as deposited: "20 mM Tris-HCl, 150 mM NaCl, 10 mM MgCl2, 5 mM DTT, 0.2 M
# D-glucosamine, 1 mM ATP", pH 8.0. Only the components with a partial-molar-volume
# entry and a stated concentration are modelled below; the measured macromolecule
# is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# '0.2 M D-glucosamine' resolves in the PMV table ('d-glucosamine' -> 130.6
# ± 0.07 cm³/mol, Moses 2021, measured as the hydrochloride with the HCl
# counter-ion ignored; see BulkElectronDensity/README.md). If the
# depositors dissolved GlcN·HCl, up to 0.2 M Cl⁻ (plus the base used to
# reach pH 8.0) is also present but not modelled: the recipe is not stated.
#
# Curve units: the SASBDB .dat is in nm⁻¹ and is converted to Å⁻¹ (÷10). The
# reference fit files are read from the same folder; each run's comparison
# curve is the depositor's fit for that model.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9919   # ≈ 12500 eV, from the stated 0.09919 nm
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 20 mM Tris titrated with
# HCl -> Cl⁻ = C·0.657 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.196 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    NonBiological(0.01, 0.0002, "magnesium chloride"),   # 10 mM, ±2%
    NonBiological(0.005, 0.0001, "dtt"),   # 5 mM, ±2%
    NonBiological(0.001, 2e-05, "adenosine 5'-triphosphate disodium salt"),   # 1 mM, ±2%
    NonBiological(0.2, 0.004, "d-glucosamine"),   # 200 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.013143, 0.001457, "chloride"),
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
        ref_chi2 = "OLIGOMER 2-state 8.31 (w 0.59)",
        pdb = "SASDEP6_fit1_model1.pdb",
        fit = "SASDEP6_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "OLIGOMER 2-state",
    ),   # D_max ≈ 84 Å; deposited χ² = 8.31
    (
        tag = "fit1_model2",
        ref_chi2 = "OLIGOMER 2-state 8.31 (w 0.41)",
        pdb = "SASDEP6_fit1_model2.pdb",
        fit = "SASDEP6_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "OLIGOMER 2-state",
    ),   # D_max ≈ 81 Å; deposited χ² = 8.31
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

# Builds the Seed that `run_sasdep6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdep6` below is the whole story (build the seed, then sample it).
function seed_sasdep6(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdep6(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdep6(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdep6(run)

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

    # `@__DIR__` (this SASDEP6/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
