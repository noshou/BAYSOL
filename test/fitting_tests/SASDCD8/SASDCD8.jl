# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDCD8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCD8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDCD8: horse spleen apoferritin (WAXS), 24-mer, 476.3 kDa.
#
# NOT YET RUN: this entry was wired on 2026-11-19 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Sample: horse spleen apoferritin, 24 identical subunits (19.846 kDa each, 476.3 kDa),
# 15.8 mg/ml, one concentration; SASBDB cell temperature 20 °C (storage 10.2 °C). Buffer
# "tbs", pH 7.5: SASBDB gives NO concentrations. ASSUMPTION (flagged, not from this
# entry): 100 mM Tris, 100 mM NaCl, pH 7.5, taken from the buffer that the EMBL Hamburg
# group used for the standard proteins of its 2007 benchmark (J. Appl. Cryst. 2007, 40,
# s1, "100 mM Tris, 100 mM NaCl at pH 7.5 for most proteins"; the later P12 series is not
# documented). If the true buffer differs, the ionic strength is off by tens of mM; the
# electron density of the buffer shifts by about 0.001 e/Å³ per 100 mM salt.
#
# Instrument and conditions (SASBDB): EMBL beamline P12, PETRA III (DESY, Hamburg),
# Pilatus 2M, wavelength 0.062 nm = 0.62 Å, energy = hc/λ ≈ 19997 eV. The depositor is M.
# Petoukhov (EMBL Hamburg, "WAXS benchmark on standard proteins" series); SASBDB lists no
# publication for the series.
#
# Curve units: the SASBDB .dat says "angular-unit: nanometer" and is in nm⁻¹ (1830 points,
# q from 0.00869 to 1.793 Å⁻¹ after dividing by NM_INV_PER_ANGSTROM_INV), while the
# depositor's .fit is already in Å⁻¹ (its first q is 0.00869, the .dat's first value is 10
# times that). The depositor's fit covers the whole curve (the .fit has 1831 rows, q
# 0.00869 to 1.7929 Å⁻¹ except where noted), so refChi2 is like for like.
#
# No q cut: the rule of test/fitting_tests/README.md (a tail is cut only if its median I/σ
# is below 0.5 or 25 % of it is non-positive) is not met anywhere: the median I/σ of the
# top 20 % of the curve (q ≥ 1.437 Å⁻¹) is 14.7 and 1 % of those points have I ≤ 0. The
# curve is fitted whole; at q up to 1.8 Å⁻¹ the forward model needs a high
# spherical-harmonic order and, for a large assembly, many atoms (see the open points of
# the run).
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL 3.0 (fit1) against
# SASDCD8_fit1_model1.pdb (PDB 1IER, the 24-mer, chains A-X: 33 696 ATOM records, no
# HETATM, no hydrogens). The fit header reads Chi^2:****** (overflow, unreadable); the
# depositor's χ² used here is SASBDB's 274.778 (not recomputed). The header values Convex
# 0.000, Concave 2.000, Inner -7.80 show the CRYSOL parameters at or near their bounds, so
# the depositor's fit is poor and the comparison is a weak one. Caveats: the model is
# iron-free apoferritin while the sample may carry iron; the buffer is incomplete (above).
# OPEN: 33 696 heavy atoms (about 66 000 with hydrogens) is the largest structure of the
# suite; pdb2pqr and the forward model have not been run on it.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # qvals are in nm⁻¹; convert to Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # SASBDB (buffer "tbs", pH 7.5)
const ENERGY_EV     = HC_EV_ANGSTROM / 0.62   # see the instrument note above
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl: the pH is set with HCl, so the titrant counter-ion
# is Cl⁻ = C x (1 - f), f the deprotonated fraction (pK(Tris) and its temperature
# dependence from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902: 8.072, ΔH 47.45 kJ/mol, ΔCp -59 J/K/mol); pH taken as set at 22 ± 3
# °C (ASSUMPTION, the source gives no setting temperature), Davies-corrected at I ≈ 0.186
# M (0.1 M NaCl + Tris ions); Cl⁻ = 0.085807 M. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on C: 0.004523 M. The same recipe reproduces the
# repository's SASDGF3 and SASDVX4 values. The titrant (HCl) is assumed, as in the other
# Tris scripts.
const SOLUTES = Solute[
    NonBiological(0.1, 0.002, "tris"),   # 100 mM Tris-HCl, ±2%
    # Cl⁻ counter-ion of the HCl titration of Tris (see the note above)
    NonBiological(0.085807, 0.004523, "chloride"),
    NonBiological(0.1, 0.001, "sodium chloride"),   # 100 mM NaCl, ±1%
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
    refChi2 = "CRYSOL 274.778",
    pdb = "SASDCD8_fit1_model1.pdb",
    fit = "SASDCD8_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 274.778
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

# Builds the Seed that `runSasdcd8` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdcd8` below is the whole story (build the seed, then
# sample it).
function seedSasdcd8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdcd8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdcd8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdcd8(run)

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

    # `@__DIR__` (this SASDCD8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
