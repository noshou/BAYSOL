using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDLP4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDLP4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDLP4: Protein quaternary structures in solution are a mixture of multiple forms
#
# Paper: Marciano S, Dey D, Listov D, et al., Chemical Science
# (2022), DOI 10.1039/D2SC02794A. Open access (CC BY); PDF not in the
# repository, see test/fixtures/experiments/SASDLP4/README.txt (PMC
# PMC9555727). SASBDB entry: https://www.sasbdb.org/data/SASDLP4/
#
# Sample: SodA (unknown, 23.0 kDa/chain); measured at up to 2.03 mg/ml (Single
# concentration). Instrument: PETRA III (X-ray synchrotron), wavelength 0.124 nm = 1.24 Å =>
# energy = hc/λ ≈ 9999 eV (hc = 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "50 mM HEPES", pH 7.4. Only the components with a
# partial-molar-volume entry and a stated concentration are modelled below; the
# measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
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

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, from the stated 0.124 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 50 mM HEPES titrated with
# NaOH -> Na⁺ = C·0.420 (pK(22 °C) = 7.6). The pH is taken as set at room temperature (22 ±
# 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.021 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.021027, 0.003115, "sodium(1+)"),
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
        pdb = "SASDLP4_fit1_model1.pdb",
        fit = "SASDLP4_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "OLIGOMER 3-state",
    ),   # D_max ≈ 53 Å; deposited χ² = 1.09
    (
        tag = "fit1_model2",
        pdb = "SASDLP4_fit1_model2.pdb",
        fit = "SASDLP4_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "OLIGOMER 3-state",
    ),   # D_max ≈ 74 Å; deposited χ² = 1.09
    (
        tag = "fit1_model3",
        pdb = "SASDLP4_fit1_model3.pdb",
        fit = "SASDLP4_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "OLIGOMER 3-state",
    ),   # D_max ≈ 113 Å; deposited χ² = 1.09
    (
        tag = "fit2_model1",
        pdb = "SASDLP4_fit2_model1.pdb",
        fit = "SASDLP4_fit2.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 74 Å; deposited χ² = 1.058
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

# Builds the Seed that `run_sasdlp4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdlp4` below is the whole story (build the seed, then sample it).
function seed_sasdlp4(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdlp4(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdlp4(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdlp4(run)

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

    # `@__DIR__` (this SASDLP4/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
