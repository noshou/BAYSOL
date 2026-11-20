# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJB2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJB2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJB2 (fit2): restriction endonuclease AgeI (R.AgeI, 30.5 kDa, a monomer in
# solution). Publication: Tamulaitiene G. et al., "Restriction endonuclease AgeI is a
# monomer which dimerizes to cleave DNA", Nucleic Acids Res. 2017, 45, 3547, DOI
# 10.1093/nar/gkw1310 (open access, Europe PMC full text read: the SAXS methods). Entry:
# https://www.sasbdb.org/data/SASDJB2/.
#
# Instrument (SASBDB): wavelength 0.124 nm (SASBDB; hc/lambda = 9998 eV). Temperature: 20
# °C, SASBDB cell temperature; the paper gives no SAXS temperature (flagged).
#
# Buffer: Buffer from the PAPER: before the SAXS experiment 'AgeI preparation was run
# through the Superdex200 16/600 column ... to exchange a buffer for SAXS measurements (10
# mM Tris-HCl, pH 7.5, 150 mM NaCl, 5 mM CaCl2)'. SASBDB lists the same recipe, so paper and
# SASBDB agree. Tris-HCl means HCl is the titrant.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.0291-3.514 nm-1),
# converted to A-1 (divide by 10): q 0.00291-0.3514 A-1, 1324 rows, all sigma > 0, 4 with a
# non-positive intensity. No upper q cut: the median I/sigma above 0.3 A-1 is 2.0 and the
# README's noise-floor rule is far from met. q gap (2026-11-19): the depositor's .fit has
# only the first point (0.00291 A-1) and then jumps to 0.02266 A-1, i.e. it left out the 74
# points in 0.0031-0.0224 A-1; `EXCLUDE_Q` leaves them out here too, so BAYSOL's χ² and the
# depositor's cover the same 1250 points (I_exp and sigma equal the .dat up to a constant
# factor, so the ratio is the same).
#
# Model and depositor fit: fit2 is a CRYSOL fit (header 'AgeI-IR5  Dro:0.022  Ra:1.800
# RGT:20.09  Vol: 39666.  Chi^2: 0.867') against SASDJB2_fit2_model1.pdb, the AgeI model of
# the paper (chain A, 2089 ATOM records, 20 standard amino acids, no hydrogens) plus 11
# HETATM HOH (dropped by the loader). The .fit has four columns but its I_exp and sigma
# columns are NOT on the .dat scale (first rows 44521, 13187; the .dat starts at 0.21), so
# the reference curve (column 4) is rescaled to the data (rescale = true), and the figure
# legend says so. The entry's fit1 (chi2 0.936) is an .fir file and is not used. The
# depositor's χ² is the header value, header Chi^2 0.867 = SASBDB 0.867 (refChi2 = CRYSOL
# 0.867).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 10 mM Tris-HCl at pH 7.5 (pK(22 C) = 8.157) with
# Davies activities at I = 0.1736 M (0.15 M NaCl, 5 mM CaCl2, the protonated Tris and its
# chloride): acid fraction 0.8576, so the Tris chloride = 0.01 x 0.8576 = 8.58 mM (sigma
# 0.43 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The pH
# is taken as set at room temperature (22 +-3 C), although the SAXS temperature is not
# stated. The CaCl2 chloride (10 mM) comes with the salt row. Every solute below is in the
# bundled tables.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "tris"),   # 10 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
    NonBiological(0.005, 0.0001, "calcium chloride"),   # 5 mM CaCl2, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.008576, 0.000425, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut (see the Source for the numbers): the README's noise-floor rule is not met over
# any useful part of the curve.
const Q_MAX_FIT = Inf

# q interval(s) the depositor's fit file skips (Å⁻¹, both ends included; Source note).
const EXCLUDE_Q = ((0.0031, 0.0224),)

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
    tag = "fit2_model1",
    refChi2 = "CRYSOL 0.867",
    pdb = "SASDJB2_fit2_model1.pdb",
    fit = "SASDJB2_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = true,
    software = "CRYSOL",
),   # deposited χ² = 0.867
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` and outside `EXCLUDE_Q`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(
        i ->
            qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0 &&
            !any(r -> r[1] ≤ qvals[i] ≤ r[2], EXCLUDE_Q),
        eachindex(qvals),
    )
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdjb2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjb2` below is the whole story (build the seed, then sample it).
function seedSasdjb2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjb2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdjb2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjb2(run)

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

    # `@__DIR__` (this SASDJB2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
