# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJG5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJG5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJG5 (fit1): the wild-type SARS-CoV-2 main protease (Mpro, 33.8 kDa per chain, a
# dimer), curve extrapolated to infinite dilution from four concentrations (1.2-9.6 mg/ml),
# measured with an in-house Rigaku BioSAXS-2000. Publication: Lee J. et al.,
# "Crystallographic structure of wild-type SARS-CoV-2 main protease acyl-enzyme intermediate
# with physiological C-terminal autoprocessing site", Nat. Commun. 2020, 11, 5877, DOI
# 10.1038/s41467-020-19662-4 (open access, Europe PMC full text read: Methods, 'BioSAXS').
# Entry: https://www.sasbdb.org/data/SASDJG5/.
#
# Instrument (SASBDB): wavelength 0.154 nm (SASBDB; the paper: in-house X-rays, 1.54 A, Cu
# K-alpha; hc/lambda = 8051 eV). Temperature: 6 °C, SASBDB cell temperature; the paper text
# read gives none for the SAXS (flagged).
#
# Buffer: Buffer from the PAPER: the background scattering subtracted was that 'of the
# dialysis buffer (50 mM Tris pH 7.4, 1 mM DTT, and 1 mM EDTA)'; SASBDB lists the same
# recipe. The paper does not say which EDTA salt or how the Tris was titrated (HCl assumed;
# EDTA taken as the disodium salt).
#
# Curve units: The SASBDB .dat is already in A-1 (angular_unit 1/A, q 0.01243-0.6044 A-1, no
# conversion), 723 rows, all sigma > 0, none non-positive. No q cut: the median I/sigma
# above 0.3 A-1 is 4.0. The depositor's fit stops at q = 0.500 A-1, so refChi2 is not like
# for like (the data to 0.604 A-1 are fitted here).
#
# Model and depositor fit: fit1 is a CRYSOL fit (header '6M03_dim  Dro:0.018  Ra:1.400
# RGT:26.16  Vol: 89551.  Chi^2: 2.158') against SASDJG5_fit1_model1.pdb, the Mpro dimer of
# PDB 6M03 (chains A, B, 2367 ATOM records each, 4734 in all, 20 standard amino acids, no
# hydrogens, no HETATM). The .fit has four columns q (A-1), I_exp, sigma, I_fit on the data
# scale (first row q = 0.002 with zeros): the reference curve is column 4, not rescaled. The
# depositor's χ² is the header value, header Chi^2 2.158 = SASBDB 2.158 (refChi2 = CRYSOL
# 2.158).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # wavelength 1.54 Å
const TEMPERATURE_C = 6.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 50 mM Tris (pK(22 C) = 8.157) titrated with HCl
# at pH 7.4, Davies activities at I = 0.0467 M (the protonated Tris and its chloride plus
# the EDTA salt): acid fraction 0.8737, so Cl- = 0.05 x 0.8737 = 43.69 mM (sigma 1.95 mM:
# sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is
# HCl (not stated; assumed). EDTA: the salt form is not stated; H2EDTA(2-) with 2 Na+ (the
# table's 'H2EDTA' row, as in other entries) is assumed at pH 7.4, so 2 mM Na+. The pH is
# taken as set at room temperature (22 +-3 C), although the sample was measured at 6 C (the
# Tris pH shifts by -0.03 per K; the sigma carries only +-3 C: open point). Every solute
# below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.043685, 0.00195, "chloride"),
    NonBiological(0.001, 2e-05, "H2EDTA"),   # 1 mM EDTA as H2EDTA(2-), ±2%
    # Na+ of the EDTA salt (2 x 1 mM, assumed disodium EDTA)
    NonBiological(0.002, 0.0001, "sodium(1+)"),
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, ±2%
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
    refChi2 = "CRYSOL 2.158",
    pdb = "SASDJG5_fit1_model1.pdb",
    fit = "SASDJG5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 2.158
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

# Builds the Seed that `runSasdjg5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjg5` below is the whole story (build the seed, then sample it).
function seedSasdjg5(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjg5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdjg5(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjg5(run)

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

    # `@__DIR__` (this SASDJG5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
