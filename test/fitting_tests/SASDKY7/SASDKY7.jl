# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDKY7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDKY7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDKY7: Alpha-L-fucosidase (Fuk2 wt, K0JCW6, Paenibacillus thiaminolyticus
# (Bacillus thiaminolyticus), 74.297 kDa x 4). α-L-Fucosidase isoenzyme 2 from
# Paenibacillus thiaminolyticus - wild type. Publication: Koval'ová T, Kovaľ T, Stránský
# J, Kolenko P, Dušková J, Švecová L, Vodičková P, Spiwok V, Benešová E, Lipovová P,
# Dohnálek J, "The first structure–function study of GH151 α‐ <scp>l</scp> ‐fucosidase
# uncovers new oligomerization pattern, active site complementation, and selective
# substrate specificity", The FEBS Journal (2022), DOI 10.1111/febs.16387 (the paper was
# NOT consulted, except where stated: every condition below is the SASBDB entry metadata,
# flagged). Entry: https://www.sasbdb.org/data/SASDKY7/.
#
# Instrument (SASBDB): Institute of Biotechnology, Czech Academy of Sciences/Centre of
# Molecular Structure Anton Paar SAXSpoint 2.0 (Vestec, Czech Republic), detector Eiger R
# 1M; wavelength 1.34 A (SASBDB wavelength field / experiment description); energy
# HC/lambda. Temperature: 15 C, SASBDB cell temperature. SASBDB experiment description:
# "SAXS data from solutions of wild-type α-L-Fucosidase isoenzyme 2 in 50 mM potassium
# phosphate, pH 7.4 were collected using an Anton Paar SAXSpoint 2.0 instrument (Institute
# of Biotechnology, Czech Academy of Sciences, Vestec, Czech Republic) equipped with an
# Eiger R 1M detector at a sample-detector distance of 0.8 m and at a wavelength of λ =
# 0.134 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "50 mM potassium phosphate", pH 7.4. Phosphate:
# 50 mM total potassium phosphate at pH 7.4 (pK2(22 C) = 7.205, Davies I = 0.1276 M): the
# HPO4(2-) fraction is 0.7755, so the mix is 38.78 mM of the dibasic and 11.22 mM of the
# monobasic salt (sigma 3.26 mM; the ratio is not stated, so it is the one that gives the
# stated pH, assumed). The pH is taken as set at room temperature (22 +-3 C).
# Concentrations carry a 2 % sigma unless stated. Every solute below is in the bundled
# tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1135-3.997 nm-1),
# converted to A-1 (divide by 10): q 0.01135-0.3997 A-1, 738 rows, 0 with sigma <= 0
# (dropped by the fit subset), 204 with a non-positive intensity (`seedModel` drops the
# non-positive bins). Q cut 0.2 A-1: above 0.20 A-1 the median I/sigma is 0.1 and 46-50 %
# of the points have I <= 0 (the README noise-floor rule); the depositor's fit range is
# stated below.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'Fuk2_6TV Dro:0.028 Ra:1.400
# RGT:46.07 Vol:344363. Chi^2: 1.032', SASBDB chi2 1.032; recomputed from the .fit columns
# 2-4: chi2 1.031. Model SASDKY7_fit1_model1.pdb: 20968 ATOM records (heavy atoms), HETATM
# groups CSO x28 atoms, ZN x4 atoms, GOL x72 atoms, SO4 x20 atoms (known components, kept
# by the loader), chains ABCD, no hydrogens, 72 alternate-location atoms (the loader's
# altloc handling applies); SASBDB model with no PDB link (Other). Depositor chi2 used as
# refChi2: SASBDB chi_square_value.
#
# Size: 22520 heavy atoms in the largest model (VERY LARGE: plan the run time).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # wavelength 1.34 Å
const TEMPERATURE_C = 15.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Phosphate: 50 mM total potassium phosphate at pH 7.4 (pK2(22
# C) = 7.205, Davies I = 0.1276 M): the HPO4(2-) fraction is 0.7755, so the mix is 38.78
# mM of the dibasic and 11.22 mM of the monobasic salt (sigma 3.26 mM; the ratio is not
# stated, so it is the one that gives the stated pH, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    # HPO4(2-) part (38.78 mM)
    NonBiological(0.0387754, 0.00326047, "dipotassium hydrogen phosphate"),
    # H2PO4(-) part (11.22 mM)
    NonBiological(0.0112246, 0.00326047, "potassium dihydrogen phosphate"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.2 Å⁻¹ (see the Source for the numbers).
const Q_MAX_FIT = 0.2

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
    refChi2 = "CRYSOL 1.032",
    pdb = "SASDKY7_fit1_model1.pdb",
    fit = "SASDKY7_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` and `q ≤ Q_MAX_FIT` (0.2 Å⁻¹).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdky7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdky7` below is the whole story (build the seed, then sample it).
function seedSasdky7(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdky7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdky7(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdky7(run)

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

    # `@__DIR__` (this SASDKY7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
