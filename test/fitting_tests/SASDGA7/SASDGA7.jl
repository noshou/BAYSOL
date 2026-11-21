# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDGA7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDGA7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDGA7 (fit1): the Trypanosoma brucei MORN1 construct tbMORNdelta6 (25.9 kDa per
# chain, a dimer), a MORN-repeat protein, measured at EMBL P12 (PETRA III). Publication:
# Sajko S. et al., "Structures of three MORN repeat proteins and a re-evaluation of the
# proposed lipid-binding properties of MORN repeats", PLoS ONE 2020, 15, e0242677, DOI
# 10.1371/journal.pone.0242677 (open access, Europe PMC full text read: purification and
# SAXS methods). Entry: https://www.sasbdb.org/data/SASDGA7/.
#
# Instrument (SASBDB): wavelength 0.124 nm (SASBDB; EMBL P12, hc/lambda = 9998 eV; the
# paper's P12 line says 1.2 A). Temperature: 20 °C, SASBDB cell temperature; the paper text
# read gives none (flagged).
#
# Buffer: Buffer from the PAPER: the proteins were dialysed against 'gel filtration buffer
# (20 mM Tris-HCl pH 8.5, 200 mM NaCl, 2% (w/v) glycerol, 0.5 mM DTT)'. SASBDB lists the
# same recipe, so paper and SASBDB agree (the other two MORN entries of that paper, SASDG97
# and SASDGB7, list 100 mM NaCl without glycerol, which the paper does not support, and are
# not used). Tris-HCl means HCl is the titrant.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.0796-3.052 nm-1),
# converted to A-1 (divide by 10): q 0.00796-0.3052 A-1, 1092 rows, all sigma > 0, 36 with a
# non-positive intensity. No q cut: the data end at 0.305 A-1 and the noise-floor rule is
# not met (only 20 points above 0.3 A-1).
#
# Model and depositor fit: fit1 is a CRYSOL fit (header 'd6_TbMOR  Dro:0.025  Ra:1.400
# RGT:42.77  Vol: 58741.  Chi^2: 1.160') against SASDGA7_fit1_model1.pdb, the tbMORNdelta6
# dimer (chains A, B with 1591 and 1583 ATOM records, 3174 in all, 20 standard amino acids,
# no hydrogens, no HETATM). The .fit has four columns q (A-1), I_exp, sigma, I_fit on the
# data scale (first row q = 0.002 with zeros): the reference curve is column 4, not
# rescaled. The .dat header reads 'chromixs' (a chromatography-mixture analysis run, c = 0).
# The depositor's χ² is the header value, header Chi^2 1.160 = SASBDB 1.16 (refChi2 = CRYSOL
# 1.160).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 20 mM Tris-HCl (pK(22 C) = 8.157) at pH 8.5 with
# Davies activities at I = 0.2076 M (0.2 M NaCl plus the Tris charges): the acid fraction is
# only 0.3783 at this high pH, so the Tris chloride = 0.02 x 0.3783 = 7.57 mM (sigma 1.51
# mM: sigma_pH = 0.1 moves the fraction by 0.0527 x 20 mM = 1.05 mM, plus +-3 C (-0.028
# pK/K), +-0.02 pK and the Davies shift). The pH is taken as set at room temperature (22 +-3
# C). Glycerol 2 % w/v = 20 g/L / 92.094 g/mol = 0.2172 M, +-5 %. Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.2, 0.004, "sodium chloride"),   # 200 mM NaCl, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.007566, 0.001506, "chloride"),
    # 2 % w/v glycerol (the paper says w/v), ±5%
    NonBiological(0.2172, 0.0109, "glycerol"),
    NonBiological(0.0005, 1e-05, "dtt"),   # 0.5 mM DTT, ±2%
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
    refChi2 = "CRYSOL 1.160",
    pdb = "SASDGA7_fit1_model1.pdb",
    fit = "SASDGA7_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 1.160
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

# Builds the Seed that `runSasdga7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdga7` below is the whole story (build the seed, then sample it).
function seedSasdga7(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdga7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdga7(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdga7(run)

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

    # `@__DIR__` (this SASDGA7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
