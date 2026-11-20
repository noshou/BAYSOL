# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXW3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXW3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXW3: transthyretin tetramer, 55.0 kDa (SEC-SWAXS, Taiwan Photon Source).
#
# NOT YET RUN: this entry was wired on 2026-11-19 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Sample: transthyretin tetramer (13.761 kDa per chain, 55.0 kDa), 5.0 mg/ml, in 20 mM
# Tris, 50 mM NaCl, pH 7.0 (SASBDB buffer and experiment text), measured at 26 °C. Paper
# (SASBDB): Shih O, Feng YC, Agrawal S, Liao KF, Yeh YQ, Chang JW, Yu TY, Jeng US, J.
# Appl. Cryst. 2025, DOI 10.1107/S1600576725004716 (not read; buffer, temperature and
# wavelength are SASBDB values).
#
# Instrument (SASBDB): National Synchrotron Radiation Research Center (NSRRC), Taiwan
# Photon Source beamline 13A, Eiger X 1M and X 9M detectors at 0.3 m and 2.5 m, wavelength
# 0.08265 nm = 0.8265 Å, energy = hc/λ ≈ 15000 eV.
#
# Curve units: the SASBDB .dat has no unit footer; its q values (0.008340 to 1.5525 Å⁻¹,
# 570 points) match the .fit and are in Å⁻¹, so there is no conversion (checkQAngstrom
# checks the range). The depositor's fit covers 0.008340-1.5479 Å⁻¹ (569 rows), i.e. the
# curve but its last point. No q cut: the median I/σ of the top 20 % of the curve (q ≥
# 1.034 Å⁻¹) is 9.6 and none of those points has I ≤ 0, so the rule of
# test/fitting_tests/README.md is not met; the curve is fitted whole.
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL 3.2.1 (fit1) against
# SASDXW3_fit1_model1.pdb (a Coot-built tetramer, chains A-D: 3940 ATOM records, 372 HOH,
# no other HETATM; no hydrogens). The loader drops the waters. The .fit header reads Dro
# 0.029, Rg 24.27, Vol 68865, Chi^2 6.112 (agrees with SASBDB); the depositor's χ² used
# here is 6.112.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# (qvals are already in Å⁻¹, no unit conversion)
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA   # SASBDB buffer field and experiment text
const ENERGY_EV     = HC_EV_ANGSTROM / 0.8265   # see the instrument note above
const TEMPERATURE_C = 26.0   # SASBDB cell and storage temperature

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl: the pH is set with HCl, so the titrant counter-ion
# is Cl⁻ = C x (1 - f), f the deprotonated fraction (pK(Tris) and its temperature
# dependence from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902: 8.072, ΔH 47.45 kJ/mol, ΔCp -59 J/K/mol); pH taken as set at 22 ± 3
# °C (ASSUMPTION, the source gives no setting temperature), Davies-corrected at I ≈ 0.069
# M (0.05 M NaCl + Tris ions); Cl⁻ = 0.018939 M. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK,
# 30 % of the Davies shift and ±2 % on C: 0.000512 M. The same recipe reproduces the
# repository's SASDGF3 and SASDVX4 values. The titrant (HCl) is assumed, as in the other
# Tris scripts.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris-HCl, ±2%
    # Cl⁻ counter-ion of the HCl titration of Tris (see the note above)
    NonBiological(0.018939, 0.000512, "chloride"),
    NonBiological(0.05, 0.0005, "sodium chloride"),   # 50 mM NaCl, ±1%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from the
# diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and bins the
# curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the hydrogens are built by pdb2pqr at PH (see the model note above).
const ADD_HYDROGENS = true

# Largest q fitted (Å⁻¹); Inf = the whole curve (see the q note in the header).
const Q_MAX_FIT = Inf

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 6.112",
    pdb = "SASDXW3_fit1_model1.pdb",
    fit = "SASDXW3_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 6.112
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

# Builds the Seed that `runSasdxw3` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdxw3` below is the whole story (build the seed, then
# sample it).
function seedSasdxw3(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxw3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdxw3(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxw3(run)

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
    )

    # `@__DIR__` (this SASDXW3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
