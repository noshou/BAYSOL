using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, DEFAULT_TEMPERATURE_C
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDAC9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAC9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDAC9: Crystal structure of the Varkud satellite ribozyme (the catalytically
# inactive G638A construct, a dimer of 186 nt chains, 120.3 kDa).
#
# Paper: Suslov NB, DasGupta S, Huang H, et al., Nat Chem Biol (2015), DOI
# 10.1038/nchembio.1929. SASBDB entry: https://www.sasbdb.org/data/SASDAC9/ (the buffer,
# pH and instrument below are the SASBDB entry metadata; the paper was not consulted for
# them).
#
# Sample: 1.5-4.5 mg/ml series, extrapolated to infinite dilution. Instrument: Advanced
# Light Source 12.3.1 (SIBYLS) (X-ray synchrotron), Pilatus3 X 2M, wavelength 0.103 nm =
# 1.03 Å => energy = hc/λ ≈ 12038 eV (hc = 12398.42 eV·Å). SASBDB gives no temperature
# for this entry, so the package default (`DEFAULT_TEMPERATURE_C`, 25 °C) is used.
#
# Buffer as deposited: "10 mM Tris 25 mM KCl 5 mM MgCl2", pH 7.5. The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (q 0.21-3.24 nm⁻¹, 2 header lines, 4 trailer
# lines) and is converted to Å⁻¹ (÷10). The model is the 12092-atom crystal-structure
# dimer (chains A and B; 4026 hydrogens, a GDP ligand, 22 waters, 10 Mg²⁺, 10 K⁺ and 68
# MO6 atoms as HETATM). The depositor's fit is a FoXS profile with χ² = 680 (Chi = 26.08;
# the model describes the data poorly); the entry is kept on purpose as a stress test.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12038 eV, from the stated 0.103 nm
const TEMPERATURE_C = DEFAULT_TEMPERATURE_C   # none recorded in SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions. Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 10 mM Tris titrated with
# HCl -> Cl⁻ = C·0.846 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.048 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.025, 0.00025, "potassium chloride"),   # 25 mM, ±1%
    NonBiological(0.01, 0.0002, "tris"),   # 10 mM, ±2%
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.008462, 0.000441, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model already carries 4026 hydrogens; as for
# SASDWZ9 pdb2pqr is left to place its own. The model has two RNA chains that both carry
# the chain id A (the ions, water and MO6 are chain B): see the hand-off notes.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    ref_chi2 = "FoXS 680.3",
    pdb = "SASDAC9_fit2_model1.pdb",
    fit = "SASDAC9_fit2.dat",
    fit_scale = 1.0,
    fit_col = 3,
    rescale = false,
    software = "FoXS",
),   # VS ribozyme dimer with 4026 H and a GDP; deposited χ² = 680.3 (Chi = 26.08)
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

# Builds the Seed that `run_sasdac9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdac9` below is the whole story (build the seed, then sample it).
function seed_sasdac9(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdac9(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdac9(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdac9(run)

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

    # `@__DIR__` (this SASDAC9/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
