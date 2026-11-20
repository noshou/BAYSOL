# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDBZ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDBZ2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDBZ2: FbaB (decamer, 38.056 kDa), measured at EMBL P12. Publication: Dadinova LA
# et al., "X-Ray Solution Scattering Study of Four Escherichia coli Enzymes Involved in
# Stationary-Phase Metabolism." PLoS One 2016, DOI 10.1371/journal.pone.0156105 (SASBDB
# metadata only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDBZ2/.
#
# Instrument (SASBDB): wavelength 0.12 nm (hc/lambda = 10332 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '50 mM Tris 10 mM NaCl' (additive '10 mM NaCl'), pH 7.5.
# Paper not consulted (SASBDB metadata only). LARGE: decamer, 24220 heavy atoms.
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.08465-3.234 nm-1), converted to A-1 (divide
# by 10): q 0.00847-0.3234 A-1, 1198 rows, 0 with sigma <= 0, 11 with a non-positive
# intensity. q cut (2026-11-19): 0.0187 <= q <= 0.2503 A-1, the range of the depositor's
# CRYSOL fit file (see below); the points outside it (to 0.3234 A-1, median I/sigma above
# 0.3 A-1 is 1.6) are left out so that BAYSOL's chi2 and the depositor's cover the same
# points.
#
# Model and depositor fit (fit2_model1): CRYSOL fit (header 'fba2.pdb Dro:0.000 Ra:1.400
# RGT:43.08 Vol:533162. Chi^2: 1.809'; SASBDB chi2 1.81) against SASDBZ2_fit2_model1.pdb:
# single atomic model: 24220 heavy atoms, chain(s) ABIJKPQWXZ, no hydrogens. The .fit has 4
# columns (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header
# Chi^2 1.809 (SASBDB 1.81); recomputed 1.846. fit2 of SASBDB (the model is named fba2.pdb
# in the header). The depositor's fit covers q 0.0187-0.2502 A-1 (881 points with data)
# while the curve covers 0.0085-0.3234 A-1; the fit uses the depositor's range (`Q_MIN_FIT`,
# `Q_MAX_FIT`), so refChi2 (same points and sigma; recomputed 1.805) is like for like.
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
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # wavelength 1.2 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 50 mM at pH 7.5, 10 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.056 M): 46.36 mM Cl- from the HCl titration
# (sigma 1.45 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, +-2%
    # Cl- of the HCl titration to pH 7.5, 46.36 mM
    NonBiological(0.046364, 0.001447, "chloride"),
    NonBiological(0.01, 0.0002, "sodium chloride"),   # 10 mM NaCl, +-2%
]

# q range of the depositor's fit file (first point with data 0.01873, last 0.25023 A-1).
const Q_MIN_FIT = 0.0187
const Q_MAX_FIT = 0.2503

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the
# file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    refChi2 = "CRYSOL 1.809",
    pdb = "SASDBZ2_fit2_model1.pdb",
    fit = "SASDBZ2_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `Q_MIN_FIT ≤ q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(
        i -> Q_MIN_FIT ≤ qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0,
        eachindex(qvals),
    )
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdbz2` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdbz2` below is the whole story).
function seedSasdbz2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdbz2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdbz2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdbz2(run)

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

    # `@__DIR__` (this SASDBZ2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
