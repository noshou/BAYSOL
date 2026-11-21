# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDBZ5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDBZ5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDBZ5: NPr (monomer, 9.25 kDa); Enzyme I-Ntr (monomer, 28.35 kDa), measured at
# Rigaku BioSAXS-1000. Publication: Strickland M et al., "Structure of the
# NPr:EIN<sup>Ntr</sup> Complex: Mechanism for Specificity in Paralogous Phosphotransferase
# Systems." Structure 2016, DOI 10.1016/j.str.2016.10.007 (SASBDB metadata only; the paper
# was not consulted). Entry: https://www.sasbdb.org/data/SASDBZ5/.
#
# Instrument (SASBDB): wavelength 0.154 nm (hc/lambda = 8051 eV). Temperature: 27 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '10 mM Tris 150 mM NaCl 0.5 mM EDTA', pH 7.5. Paper not
# consulted (SASBDB metadata only). EDTA taken as the disodium salt (H2EDTA plus 2 Na+,
# flagged).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01813-0.6797 A-1, 460 rows, 0
# with sigma <= 0, 0 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 4.0.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header '5t1o-1.p Dro:0.000 Ra:1.800
# RGT:23.97 Vol: 50394. Chi^2: 1.248'; SASBDB chi2 1.25) against SASDBZ5_fit1_model1.pdb:
# single atomic model: 2641 heavy atoms, chain(s) AB, no hydrogens. The .fit has 4 columns
# (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header Chi^2
# equals the SASBDB value and the recomputation against the .dat (free scale) agrees.
# Recomputed 1.248. The depositor's fit covers q up to 0.501 A-1 while the curve extends to
# 0.680 A-1, so refChi2 is not like for like with the fitted range (no q cut is applied).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # wavelength 1.54 Å
const TEMPERATURE_C = 27.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 10 mM at pH 7.5, 27 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.160 M): 8.13 mM Cl- from the HCl titration
# (sigma 0.50 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "tris"),   # 10 mM Tris, +-2%
    # Cl- of the HCl titration to pH 7.5, 8.13 mM
    NonBiological(0.008128, 0.000504, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
    NonBiological(0.0005, 1e-05, "H2EDTA"),   # 0.5 mM EDTA, +-2%
    NonBiological(0.001, 2e-05, "sodium(1+)"),   # Na+ of disodium EDTA (assumed salt), 1 mM
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
    refChi2 = "CRYSOL 1.248",
    pdb = "SASDBZ5_fit1_model1.pdb",
    fit = "SASDBZ5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
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

# Builds the Seed that `runSasdbz5` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdbz5` below is the whole story).
function seedSasdbz5(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdbz5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdbz5(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdbz5(run)

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

    # `@__DIR__` (this SASDBZ5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
