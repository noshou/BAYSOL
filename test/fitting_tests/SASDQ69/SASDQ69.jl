# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDQ69")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQ69.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQ69: a 28 bp double-stranded DNA (GGGGTTTTCGCCAGCTGGCGTTTTGGGG and its
# complement), 17.3 kDa, the 7-deazaguanine-modification paper's DNA substrate.
#
# Paper: Gedara SH, Wood E, Gustafson A, et al., Nucleic Acids Res (2023), DOI
# 10.1093/nar/gkad141 (PMID 36928176). Not bundled; the conditions below are SASBDB's
# entry metadata (https://www.sasbdb.org/data/SASDQ69/), which quotes the SAXS section.
#
# Buffer as deposited: "100 mM KCl, 50 mM Tris pH 7.0, 1 mM DTT". In-line SEC-SAXS at
# SIBYLS (beamline 12.3.1, ALS), Pilatus3 X 2M, wavelength 0.1 nm = 1.0 Å => energy =
# hc/λ ≈ 12398 eV (hc = 12398.42 eV·Å); 1 mg/ml injected, column and cell at 24.9 °C
# (SASBDB "cell temperature"). The measured DNA is deliberately NOT a solute (see
# BulkElectronDensity.Solute).
#
# The model is a GROMACS structure of the duplex (chains A and B, 1772 atoms, 630 of them
# hydrogens), so the nucleotide path of the pipeline (AMBER, no PROPKA) is exercised.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (46 REMARK header lines, then q, I, σ); it is
# a SEC-SAXS curve and 81 of its 849 points have I ≤ 0, which `seedModel` bins away.
# The comparison curve is the depositor's FoXS fit ("# SAXS profile" file, columns q,
# I_exp, σ, I_fit).

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.01-0.44, is checked below).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the stated 0.1 nm = 1.0 Å
const TEMPERATURE_C = 24.9   # SASBDB cell temperature (SEC at 24.9 °C)

# Buffer components (the measured DNA is deliberately NOT listed: ρₑ is the buffer's
# electron density). Counter-ion: setting the pH adds a titrant that the deposited recipe
# does not list. Assumed: 50 mM Tris titrated with HCl -> Cl⁻ = C·0.9496 (pK(22 °C) =
# 8.156). Same method as SASDMJ9.jl (pH set at 22 ± 3 °C; pK(T) from Goldberg, Kishore &
# Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; Davies correction
# at I ≈ 0.148 M; σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on
# C), which this calculation reproduces for SASDMJ9 (0.008588). Only the counter-ion is
# modelled. Titrant not stated; HCl for amine bases.
const SOLUTES = Solute[
    NonBiological(0.100, 0.001, "potassium chloride"),   # 100 mM KCl, ±1%
    NonBiological(0.050, 0.001, "tris"),                 # 50 mM Tris, ±2%
    NonBiological(0.001, 0.00002, "dtt"),                # 1 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.047481, 0.001219, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0104-0.4400 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.3 Å⁻¹ was used before, but the 277 points above 0.3
# Å⁻¹ (σ > 0) have a median I/σ of 0.66 and 28 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 0.66 ≥ 0.5; median I/σ 1.20 ≥ 1 in the
# lowest-q quarter (up to 0.33 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model's 630 GROMACS hydrogens are rebuilt by pdb2pqr.
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "FoXS 1.10",
    pdb = "SASDQ69_fit1_model1.pdb",
    fit = "SASDQ69_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),   # deposited χ² = 1.100 (FoXS)
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

# Builds the Seed that `runSasdq69` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdq69` below is the whole story (build the seed, then sample it).
function seedSasdq69(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdq69(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdq69(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdq69(run)

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

    # `@__DIR__` (this SASDQ69/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
