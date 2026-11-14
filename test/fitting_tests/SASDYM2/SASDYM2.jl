# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDYM2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDYM2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDYM2: Prothrombin recognition and conformational modulation by anti-thrombin
# anticoagulant aptamers (human prothrombin, 72.0 kDa, with the DNA aptamer NU172, 26 nt).
#
# Paper: Troisi R, Cangiano A, Cowieson N, et al., Mol Ther (2026), DOI
# 10.1016/j.ymthe.2026.07.042. Conditions below are from the SASBDB entry metadata
# (https://www.sasbdb.org/data/SASDYM2/), which has no experiment description; the paper
# itself was not consulted.
#
# Sample: up to 0.22 mg/ml, single concentration. Instrument: Diamond B21, wavelength
# recorded as 0.095 (nm) = 0.95 Å => energy = hc/λ ≈ 13051 eV (hc = 12398.42 eV·Å).
# Sample temperature: 20.0 °C (SASBDB cell temperature).
#
# Buffer as deposited: "10 mM Tris-HCl, 137 mM NaCl, 2.7 mM KCl, 5 mM CaCl2, 1% v/v
# glycerol,", pH 7.4. The deposited text ends with a comma, so a further component may be
# missing; none is guessed. Curve units: the SASBDB .dat is already in Å⁻¹ (3 header lines,
# 2567 rows). The reference fit is FoXS (3 `#` header lines, columns q, I_exp, σ, I_model).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - component after the comma ending the recipe: unknown; est. 0.002 to 0.015 % per mM

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.95   # ≈ 13051 eV, from the recorded 0.095 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed:
# 10 mM Tris titrated with HCl ->
# Cl⁻ = C·0.883 (pK(22 °C) = 8.156).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.164 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
# 1 % v/v glycerol = 0.1369 M (ρ = 1.261 g/mL, MW = 92.094 g/mol), ±5 % because it is a
# v/v -> molarity conversion (as SASDJ72).
const SOLUTES = Solute[
    NonBiological(0.137, 0.00137, "sodium chloride"),   # 137 mM, ±1%
    NonBiological(0.0027, 0.000027, "potassium chloride"),   # 2.7 mM, ±1%
    NonBiological(0.005, 0.00005, "calcium chloride"),   # 5 mM, ±1%
    NonBiological(0.01, 0.0002, "tris"),   # 10 mM Tris-HCl, ±2%
    NonBiological(0.1369, 0.006845, "glycerol"),   # 1 % v/v, ±5%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.008831, 0.000372, "chloride"),
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "component after the comma ending the recipe: unknown; est. 0.002 to 0.015 % per mM",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDYM2: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.340 Å⁻¹,
# but the 306 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.08 and 42 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.31 Å⁻¹) has a median I/σ of 0.09. The
# refChi2 covers the full range.
const Q_MAX_FIT = 0.3
# The depositor's FoXS χ² (0.286) is far below 1: the error bars are overestimated.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH
# Two chains (A prothrombin, E the NU172 aptamer, a G-quadruplex-forming DNA).

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "FoXS 0.286 (error bars overestimated)",
    pdb = "SASDYM2_fit1_model1.pdb",
    fit = "SASDYM2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),   # deposited χ² = 0.2864 (FoXS, model chain from MultiFoXS)
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdym2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdym2` below is the whole story (build the seed, then sample it).
function seedSasdym2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdym2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdym2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdym2(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

    # run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
    fitCurve = try
        fc = _readFit(joinpath(_FIXTURE_DIR, run.fit), run.fitScale, run.fitCol)
        fc !== nothing && run.rescale ? _rescaleFit(fc, qFit, iFit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    references = BAYSOL.Reference[]
    if fitCurve !== nothing
        push!(
            references,
            BAYSOL.Reference(
                run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""),
                fitCurve...; qMax = Q_MAX_FIT,
            ),
        )
    end
    BAYSOL.results(
        result, (qFit, iFit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        formFactorLog = formFactorLog, nAtoms = nAtoms,
        refChi2 = run.refChi2,
        runLog = true,
    )

    # `@__DIR__` (this SASDYM2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
