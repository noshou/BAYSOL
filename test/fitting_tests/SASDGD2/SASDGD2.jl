# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDGD2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDGD2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDGD2 (fit1): human IBA57 (33.2 kDa, a monomer), an iron-sulfur cluster assembly
# factor, measured by SEC-SAXS at EMBL P12 (PETRA III). Publication: Nasta V. et al.,
# "Structural properties of [2Fe-2S] ISCA2-IBA57: a complex of the mitochondrial iron-sulfur
# cluster assembly machinery", Sci. Rep. 2019, 9, 18986, DOI 10.1038/s41598-019-55313-5
# (open access, Europe PMC full text read: the SAXS methods). Entry:
# https://www.sasbdb.org/data/SASDGD2/.
#
# Instrument (SASBDB): wavelength 0.124 nm (SASBDB; EMBL P12, hc/lambda = 9998 eV).
# Temperature: 20 °C, SASBDB cell temperature; the paper gives no temperature (flagged).
#
# Buffer: Buffer from the PAPER: the SEC-SAXS runs used 'a buffer consisting of 50 mM
# phosphate pH 7.0, 150 mM NaCl, 5 mM DTT and 3% (v/v) glycerol' (the ISCA2-IBA57 complex
# sample was measured in the same buffer without the glycerol being repeated). SASBDB lists
# 50 mM phosphate, 150 mM NaCl, 5 mM DTT and leaves out the 3 % (v/v) glycerol; the paper is
# the source of truth and the glycerol is included (flagged). The paper does not say which
# phosphate salt (sodium assumed, as in the other phosphate entries).
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1226-3.696 nm-1),
# converted to A-1 (divide by 10): q 0.01226-0.3696 A-1, 1296 rows, all sigma > 0, 14 with a
# non-positive intensity. No q cut: the median I/sigma above 0.3 A-1 is 2.3 and the README's
# noise-floor rule (median I/sigma below 0.5 and 25 % non-positive) is far from met.
#
# Model and depositor fit: fit1 is a CRYSOL fit (header '6qe3.pdb  Dro:0.018  Ra:1.800
# RGT:21.23  Vol: 44521.  Chi^2: 1.075') against SASDGD2_fit1_model1.pdb, the 1.75 A
# re-refinement of human IBA57 (PDB 6QE3, 'RE-REFINEMENT OF 6ESR'), one chain A: 4562 ATOM
# records of which 2214 are hydrogens (2348 heavy atoms), 245 HETATM HOH (dropped by the
# loader), 20 standard amino acids. The hydrogens are removed and re-placed by pdb2pqr at
# the pH (ADD_HYDROGENS), as for the other models that carry hydrogens. The .fit has four
# columns q (A-1), I_exp, sigma, I_fit on the data scale (first row q = 0.002 with zeros):
# the reference curve is column 4, not rescaled. The depositor's χ² is the header value,
# header Chi^2 1.075 = SASBDB 1.075 (refChi2 = CRYSOL 1.075).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Phosphate (50 mM, pH 7.0, 22 C): pK2 = 7.198 (Goldberg,
# Kishore & Lennen 2002, DOI 10.1063/1.1416902) with Davies activities at I = 0.261 M (0.15
# M NaCl plus the phosphate charges): H2PO4- 39.14 %, HPO4(2-) 60.86 %, so 19.57 mM NaH2PO4
# and 30.43 mM Na2HPO4 (sigma 2.8 mM on each: sigma_pH = 0.1 moves the fraction by 5.5 %,
# plus +-3 C, +-0.02 pK and +-2 % on C). The phosphate cation is Na+ (assumed; its salts
# carry it). Glycerol 3 % v/v: 0.03 L/L x 1261 g/L / 92.094 g/mol = 0.4108 M, +-5 %. Every
# solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.03043, 0.0028, "disodium hydrogen phosphate"),   # HPO4(2-), 30.43 mM
    NonBiological(0.01957, 0.0028, "sodium dihydrogen phosphate"),   # H2PO4(-), 19.57 mM
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
    # 3 % v/v glycerol (the paper says v/v), ±5%
    NonBiological(0.4108, 0.0205, "glycerol"),
    NonBiological(0.005, 0.0001, "dtt"),   # 5 mM DTT, ±2%
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
    refChi2 = "CRYSOL 1.075",
    pdb = "SASDGD2_fit1_model1.pdb",
    fit = "SASDGD2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 1.075
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

# Builds the Seed that `runSasdgd2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdgd2` below is the whole story (build the seed, then sample it).
function seedSasdgd2(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdgd2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdgd2(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdgd2(run)

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

    # `@__DIR__` (this SASDGD2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
