# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDDH9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDDH9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDDH9: CrPRK (dimer, 38.908 kDa), measured at BM29. Publication: Gurrieri L et
# al., "<i>Arabidopsis</i> and <i>Chlamydomonas</i> phosphoribulokinase crystal structures
# complete the redox structural proteome of the Calvin-Benson cycle." Proc Natl Acad Sci U S
# A 2019, DOI 10.1073/pnas.1820639116 (SASBDB metadata only; the paper was not consulted).
# Entry: https://www.sasbdb.org/data/SASDDH9/.
#
# Instrument (SASBDB): wavelength 0.099 nm (hc/lambda = 12524 eV). Temperature: 4 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: 'Tris-HCl 50 mM 150 mM KCl', pH 7.5, 4 C. Paper not
# consulted (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.1224-3.502 nm-1), converted to A-1 (divide by
# 10): q 0.01224-0.3502 A-1, 718 rows, 0 with sigma <= 0, 2 with a non-positive intensity.
# No q cut: the median I/sigma above 0.3 A-1 is 1.8.
#
# Model and depositor fit (fit1_model1): FoXS fit (header '6h7g.pdb Convex: 2.000 Concave:
# 2.000 Inner: -5.80 Chi^2: 0.889'; SASBDB chi2 1.222) against SASDDH9_fit1_model1.pdb:
# single atomic model: 5329 heavy atoms, chain(s) AB, no hydrogens, 31 water atoms (dropped
# by the loader), HETATM SO4 x10. The .fit has 4 columns (q, I_exp, sigma, I_fit); the
# reference curve is column 4, not rescaled. Header Chi^2 0.889 (recomputed 0.887); SASBDB
# lists 1.222, which the recomputation does not reproduce, so the header value is used.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # wavelength 0.99 Å
const TEMPERATURE_C = 4.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl 50 mM at pH 7.5, 4 C (tris template: Clarke-Glew pK
# at the temperature, Davies activities at I = 0.198 M): 47.80 mM Cl- from the HCl titration
# (sigma 1.20 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris-HCl, +-2%
    # Cl- of the HCl titration to pH 7.5, 47.80 mM
    NonBiological(0.047799, 0.001196, "chloride"),
    NonBiological(0.15, 0.003, "potassium chloride"),   # 150 mM KCl, +-2%
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
    refChi2 = "FoXS 0.889",
    pdb = "SASDDH9_fit1_model1.pdb",
    fit = "SASDDH9_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
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

# Builds the Seed that `runSasddh9` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasddh9` below is the whole story).
function seedSasddh9(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasddh9(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasddh9(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasddh9(run)

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

    # `@__DIR__` (this SASDDH9/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
