# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDCF8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCF8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDCF8: bovine serum albumin (WAXS), monomer, 66.2 kDa.
#
# NOT YET RUN: this entry was wired on 2026-11-19 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Sample: bovine serum albumin, monomer (66.246 kDa), 17.1 mg/ml (SASBDB; the .dat header
# says 8.55 mg/ml, the merged curve), SASBDB cell temperature 20 °C. The curve is a merge
# of a low-q and a high-q measurement (SASBDB experiment text). Buffer "Hepes", pH 7.5:
# SASBDB gives NO concentration. ASSUMPTION (flagged, not from this entry): 50 mM HEPES,
# pH 7.5, no salt, from the buffer the EMBL Hamburg group used for BSA in its 2007
# standard-protein benchmark (J. Appl. Cryst. 2007, 40, s1: "50 mM HEPES at pH 7.5 for
# BSA"; the P12 entry is not documented). Titrated with NaOH (assumed, as for the other
# HEPES scripts).
#
# Instrument and conditions (SASBDB): EMBL beamline P12, PETRA III (DESY, Hamburg),
# Pilatus 2M, wavelength 0.062 nm = 0.62 Å, energy = hc/λ ≈ 19997 eV. The depositor is M.
# Petoukhov (EMBL Hamburg, "WAXS benchmark on standard proteins" series); SASBDB lists no
# publication for the series.
#
# Curve units: the SASBDB .dat says "angular-unit: nanometer" and is in nm⁻¹ (1878 points,
# q from 0.01354 to 1.786 Å⁻¹ after dividing by NM_INV_PER_ANGSTROM_INV), while the
# depositor's .fit is already in Å⁻¹ (its first q is 0.01354, the .dat's first value is 10
# times that). The depositor's fit covers the whole curve (the .fit has 1879 rows, q
# 0.01354 to 1.7856 Å⁻¹ except where noted), so refChi2 is like for like.
#
# No q cut: the rule of test/fitting_tests/README.md (a tail is cut only if its median I/σ
# is below 0.5 or 25 % of it is non-positive) is not met anywhere: the median I/σ of the
# top 20 % of the curve (q ≥ 1.421 Å⁻¹) is 13.5 and 1 % of those points have I ≤ 0. The
# curve is fitted whole; at q up to 1.8 Å⁻¹ the forward model needs a high
# spherical-harmonic order and, for a large assembly, many atoms (see the open points of
# the run).
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL 3.0 (fit1) against
# SASDCF8_fit1_model1.pdb (PDB 3V03 chain A: 4385 ATOM records and 26 HETATM: 23 HOH, 3
# CA; one MODEL record). The loader reads the first model, drops the waters and keeps the
# three calcium ions as ligands. The .fit header: Convex 0.880, Concave 0.880, Inner
# -7.00, Chi^2 7.441 (agrees with SASBDB); the depositor's χ² used here is 7.441. Caveat:
# the buffer concentration is an assumption (above).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # qvals are in nm⁻¹; convert to Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # SASBDB (buffer "Hepes", pH 7.5)
const ENERGY_EV     = HC_EV_ANGSTROM / 0.62   # see the instrument note above
const TEMPERATURE_C = 20.0   # SASBDB cell and storage temperature

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES titrated with NaOH (ASSUMED, as for the other HEPES
# scripts of the suite): Na⁺ = C x f with f the anion fraction (pK(22 °C) = 7.600, pH
# taken as set at 22 ± 3 °C, Davies-corrected at I ≈ 0.036 M): f = 0.4796, Na⁺ = 0.023979
# M; σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C:
# 0.003347 M. The same recipe reproduces the repository's SASDDF7 value (0.02174 M for 50
# mM at pH 7.4 with 10 mM MgCl2).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM HEPES, ±2%
    # Na⁺ counter-ion of the NaOH titration of HEPES (see the note above)
    NonBiological(0.023979, 0.003347, "sodium(1+)"),
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
    refChi2 = "CRYSOL 7.441",
    pdb = "SASDCF8_fit1_model1.pdb",
    fit = "SASDCF8_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 7.441
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

# Builds the Seed that `runSasdcf8` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdcf8` below is the whole story (build the seed, then
# sample it).
function seedSasdcf8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdcf8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdcf8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdcf8(run)

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

    # `@__DIR__` (this SASDCF8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
