# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDE27")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDE27.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDE27: unnamed (monomer, 21.007 kDa), measured at Bruker Nanostar II.
# Publication: Thorn DC et al., "The structure and stability of the disulfide-linked
# γS-crystallin dimer provide insight into oxidation products associated with lens cataract
# formation." J Mol Biol 2018, DOI 10.1016/j.jmb.2018.12.005 (SASBDB metadata only; the
# paper was not consulted). Entry: https://www.sasbdb.org/data/SASDE27/.
#
# Instrument (SASBDB): wavelength 0.1541 nm (hc/lambda = 8046 eV). Temperature: 25 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM sodium phosphate', pH 7.0. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01280-0.3910 A-1, 533 rows, 0
# with sigma <= 0, 11 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 2.0.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header '2m3t-1.p Dro:0.003 Ra:1.800
# RGT:17.84 Vol: 27833. Chi^2: 1.425'; SASBDB chi2 1.425) against SASDE27_fit1_model1.pdb:
# single atomic model: 1473 heavy atoms, chain(s) A, 1394 hydrogens. The .fit has 3 columns
# (q, I_exp, I_fit); the reference curve is column 3, not rescaled. Header Chi^2 1.425 =
# SASBDB 1.425 (listed there as Chimera); recomputed 1.428.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.541   # wavelength 1.541 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Phosphate 20 mM at pH 7.0, 25 C (pK2 7.198, Davies at I =
# -0.030 M): HPO4(2-) 10.46 mM, H2PO4(-) 9.54 mM (sodium salts assumed). Every solute below
# is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.010462, 0.001229, "disodium hydrogen phosphate"),   # HPO4(2-), 10.46 mM
    NonBiological(0.009538, 0.001229, "sodium dihydrogen phosphate"),   # H2PO4(-), 9.54 mM
]

# No q cut: the README noise-floor rule is not met over any useful part of the curve.
const Q_MAX_FIT = Inf

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the
# file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.425",
    pdb = "SASDE27_fit1_model1.pdb",
    fit = "SASDE27_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
    rescale = false,
    software = "CRYSOL",
),
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

# Builds the Seed that `runSasde27` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasde27` below is the whole story).
function seedSasde27(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasde27(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasde27(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasde27(run)

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

    # `@__DIR__` (this SASDE27/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
