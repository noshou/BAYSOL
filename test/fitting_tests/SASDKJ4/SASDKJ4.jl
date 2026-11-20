# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDKJ4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDKJ4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDKJ4 (fit1): the SARS-CoV-2 nsp7+nsp8 complex (nsp7 9.2 kDa, nsp8 21.9 kDa;
# SASBDB experimental MW 58.7 kDa, a 2:2 heterotetramer by the model), 2.08 mg/ml, measured
# at EMBL P12 (PETRA III). Publication: Krichel B. et al., "Hallmarks of Alpha- and
# Betacoronavirus non-structural protein 7+8 complexes", Sci. Adv. 2021, 7, eabf1004, DOI
# 10.1126/sciadv.abf1004 (open access, Europe PMC full text read: Methods). Entry:
# https://www.sasbdb.org/data/SASDKJ4/.
#
# Instrument (SASBDB): wavelength 0.124 nm (SASBDB; EMBL P12, hc/lambda = 9998 eV).
# Temperature: 20 °C, SASBDB cell temperature; the paper text read gives none (flagged).
#
# Buffer: Buffer from the PAPER: 'To obtain a prepurified SARS-CoV-2 nsp7+8 complex for DLS
# and SAXS, ... the buffer was exchanged with a PD-10 desalting column equilibrated with 50
# mM tris (pH 8.0), 100 mM NaCl, 4 mM DTT, and 4 mM MgCl2 [size exclusion chromatography
# (SEC) buffer]'. SASBDB lists the same recipe (and the .dat header names a 'SEC_Buffer'),
# so paper and SASBDB agree. The paper does not say how the Tris was titrated (HCl assumed).
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1017-7.267 nm-1),
# converted to A-1 (divide by 10): q 0.01017-0.7267 A-1, 2589 rows, all sigma > 0, 128 (5 %)
# with a non-positive intensity. No q cut: the median I/sigma above 0.3 A-1 is 1.65; the
# README's rule (a) for a cut is first met only above 0.68 A-1, a sliver, so the fit is left
# uncut (open point: check the sampler health there). The depositor's fit stops at q = 0.500
# A-1, so refChi2 is not like for like (the data to 0.727 A-1 are fitted here).
#
# Model and depositor fit: fit1 is a CRYSOL fit (header 'T1.pdb  Dro:0.065  Ra:1.800
# RGT:34.71  Vol: 68657.  Chi^2: 1.306') against SASDKJ4_fit1_model1.pdb: four chains, K and
# L (567 and 575 ATOM records, the nsp7 pair) and O and P (1476 and 1479, the nsp8 pair),
# 4097 ATOM records in all, 20 standard amino acids, no hydrogens, no HETATM. Which chains
# are nsp7 or nsp8 is inferred from their size, not read from the file. The .fit has four
# columns q (A-1), I_exp, sigma, I_fit on the data scale (first row q = 0.002 with zeros):
# the reference curve is column 4, not rescaled. The depositor's χ² is the header value,
# header Chi^2 1.306 = SASBDB 1.306 (refChi2 = CRYSOL 1.306).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 50 mM Tris (pK(22 C) = 8.157) titrated with HCl
# at pH 8.0, Davies activities at I = 0.1447 M (0.1 M NaCl, 4 mM MgCl2 and the Tris
# charges): acid fraction 0.6531, so Cl- = 0.05 x 0.6531 = 32.66 mM (sigma 3.66 mM: sigma_pH
# = 0.1 moves the fraction by 0.0757 x 50 mM = 3.8 mM at this pH, which dominates; plus +-3
# C, +-0.02 pK and +-2 % on C). The titrant is HCl (not stated; assumed). The pH is taken as
# set at room temperature (22 +-3 C). The MgCl2 chloride (8 mM) comes with the salt row.
# Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM NaCl, ±2%
    NonBiological(0.004, 8e-05, "magnesium chloride"),   # 4 mM MgCl2, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.032656, 0.003663, "chloride"),
    NonBiological(0.004, 8e-05, "dtt"),   # 4 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut (see the Source for the numbers): the README's noise-floor rule is not met over
# any useful part of the curve.
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.306",
    pdb = "SASDKJ4_fit1_model1.pdb",
    fit = "SASDKJ4_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 1.306
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut: `Q_MAX_FIT` is infinite).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdkj4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdkj4` below is the whole story (build the seed, then sample it).
function seedSasdkj4(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdkj4(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdkj4(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdkj4(run)

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

    # `@__DIR__` (this SASDKJ4/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
