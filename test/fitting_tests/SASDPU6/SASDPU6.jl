using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDPU6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPU6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPU6: Structure of a 28.5 kDa duplex-embedded G-quadruplex system resolved
# to 7.4 Å resolution with cryo-EM.
#
# Paper: Monsen RC, Chua EYD, Hopkins JB, Chaires JB, Trent JO, Nucleic Acids Res (2023),
# DOI 10.1093/nar/gkad014. Conditions below are from the SASBDB entry metadata
# (https://www.sasbdb.org/data/SASDPU6/); the paper itself was not consulted.
#
# Sample: synthetic duplex-G4-duplex DNA (46 nt, 28.6 kDa) with a poly-dT surrogate
# complement loop; 6.6 mg/ml injected on an in-line SEC column (co-flow SEC-SAXS).
# Instrument: APS BioCAT 18ID, wavelength 0.1033 nm = 1.033 Å => energy = hc/λ ≈ 12002 eV
# (hc = 12398.42 eV·Å). Sample temperature: 25.0 °C (SASBDB cell temperature; SEC at 25 °C).
#
# Buffer as deposited (BPEK): "6 mM Na2HPO4, 2 mM NaH2PO4, 1 mM Na2EDTA, 185 mM KCl",
# pH 7.2. Curve units: the SASBDB .dat is already in Å⁻¹ (4 header lines, 1200 rows, then
# a free-text trailer that `_read_curve` skips). The reference fit (CRYSOL, from an AMBER
# MD model) is read from the same folder.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). The phosphate is given as the two salts' stated amounts and
# the pH (7.2) is the measured one (the Na2EDTA acidifies the 3:1 phosphate mix), so no
# titrant counter-ion is added. Na2EDTA is entered as the H2EDTA²⁻ table entry plus its two
# Na⁺ (at pH 7.2 HEDTA³⁻ dominates, a ~25 cm³/mol difference on 1 mM: negligible).
const SOLUTES = Solute[
    NonBiological(0.006, 0.00012, "disodium hydrogen phosphate"),   # 6 mM, ±2%
    NonBiological(0.002, 0.00004, "sodium dihydrogen phosphate"),   # 2 mM, ±2%
    NonBiological(0.001, 0.00002, "h2edta"),   # 1 mM Na2EDTA, anion part, ±2%
    NonBiological(0.002, 0.00004, "sodium(1+)"),   # Na⁺ of the Na2EDTA, ±2%
    NonBiological(0.185, 0.00185, "potassium chloride"),   # 185 mM, ±1%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH
# The model already carries 1055 hydrogens (AMBER MD); Pdb2pqr rebuilds them from the
# heavy atoms. All atoms have a blank chain id; the two K⁺ ions are residues named `K+`.

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    pdb = "SASDPU6_fit1_model1.pdb",
    fit = "SASDPU6_fit1.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "CRYSOL (AMBER MD model)",
),   # deposited χ² = 1.265 (CRYSOL, AMBER MD model)
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

# Builds the Seed that `run_sasdpu6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdpu6` below is the whole story (build the seed, then sample it).
function seed_sasdpu6(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdpu6(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdpu6(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdpu6(run)

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

    # `@__DIR__` (this SASDPU6/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
