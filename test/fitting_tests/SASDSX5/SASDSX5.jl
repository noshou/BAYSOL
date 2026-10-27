using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDSX5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSX5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDSX5: BCL7 proteins, novel subunits of the mammalian SWI/SNF complex, bind
# the nucleosome core particle (the entry is the free nucleosome core particle, NCP, of
# the study: Xenopus histone octamer + 145 bp Widom 601 DNA, 198.7 kDa).
#
# Paper: SASBDB records no publication and no DOI for this entry (the title above is
# the entry's own), so there is nothing to cite beyond the entry itself:
# https://www.sasbdb.org/data/SASDSX5/. The buffer, pH, temperature and instrument below
# are the SASBDB entry metadata.
#
# Sample: 0.5 mg/ml NCP, SEC-SAXS (Agilent Bio SEC-5 500 Å column at 15 °C). Instrument:
# SOLEIL SWING (X-ray synchrotron), Eiger 4M, wavelength 0.1 nm = 1.0 Å => energy = hc/λ
# ≈ 12398 eV (hc = 12398.42 eV·Å). Sample temperature: 15 °C (SASBDB cell temperature).
#
# Buffer as deposited: "20 mM Tris-HCl, 50 mM KCl, 1 mM DTT", pH 8.0. The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q 0.0041-0.5516 Å⁻¹, 4 header lines,
# 84 trailer lines; `_read_curve` keeps the numeric rows only); 276 of its 1205 points
# have a non-positive intensity (the high-q noise floor of a SEC-SAXS curve), which
# `seed_model` drops after binning. The model is the full nucleosome (13579 heavy
# atoms, chains A-J: eight histone chains and the two DNA strands I and J).
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the stated 0.1 nm
const TEMPERATURE_C = 15.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions. Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 20 mM Tris titrated with
# HCl -> Cl⁻ = C·0.639 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.063 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.05, 0.0005, "potassium chloride"),   # 50 mM, ±1%
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris-HCl, ±2%
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.012784, 0.001474, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has no hydrogens. It holds protein and DNA, so
# `seed_model` takes the mixed route (AMBER force field, PROPKA for the protein only).
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    ref_chi2 = "Pepsi-SAXS 1.28",
    pdb = "SASDSX5_fit1_model1.pdb",
    fit = "SASDSX5_fit1.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "Pepsi-SAXS",
),   # Xenopus histone octamer + 145 bp Widom 601 DNA; deposited χ² = 1.280
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

# Builds the Seed that `run_sasdsx5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdsx5` below is the whole story (build the seed, then sample it).
function seed_sasdsx5(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdsx5(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdsx5(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdsx5(run)

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

    # `@__DIR__` (this SASDSX5/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
