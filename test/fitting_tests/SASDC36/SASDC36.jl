# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDC36")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDC36.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDC36: unnamed (monomer, 24.869 kDa), measured at EMBL P12. Publication: Reckel S
# et al., "Structural and functional dissection of the DH and PH domains of oncogenic
# Bcr-Abl tyrosine kinase." Nat Commun 2017, DOI 10.1038/s41467-017-02313-6 (SASBDB metadata
# only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDC36/.
#
# Instrument (SASBDB): wavelength 0.124 nm (hc/lambda = 9999 eV). Temperature: 20 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '25 mM Tris-HCl, 150 mM NaCl, 5% Glycerol, 1 mM DTT', pH
# 7.5. Paper not consulted (SASBDB metadata only). The glycerol percentage is taken as v/v
# (flagged).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.00252-0.4812 A-1, 1812 rows, 0
# with sigma <= 0, 10 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 3.2.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'nmr1.pdb Dro:0.000 Ra:1.800
# RGT:21.33 Vol: 31270. Chi^2: 1.469'; SASBDB chi2 1.47) against SASDC36_fit1_model1.pdb:
# model named nmr1.pdb in the header: 1744 heavy atoms, chain(s) A, no hydrogens. The .fit
# has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled.
# Header Chi^2 1.469 (SASBDB 1.47); recomputed 1.478.
#
# Model and depositor fit (fit2_model1): CRYSOL fit (header 'sreflex. Dro:0.005 Ra:1.780
# RGT:21.56 Vol: 31115. Chi^2: 1.001'; SASBDB chi2 1.0) against SASDC36_fit2_model1.pdb:
# SREFLEX model: 1744 heavy atoms, chain(s) A, no hydrogens. The .fit has 4 columns (q,
# I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header Chi^2 1.001
# (SASBDB 1.0); recomputed 1.014. The model is the SREFLEX-refined structure (a single
# atomic model).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl 25 mM at pH 7.5, 20 C (tris template: Clarke-Glew pK
# at the temperature, Davies activities at I = 0.172 M): 21.82 mM Cl- from the HCl titration
# (sigma 0.99 mM). Glycerol 5 % v/v: 0.05 x 1261 g/L / 92.094 g/mol = 0.6846 M, +-5 %. Every
# solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris-HCl, +-2%
    # Cl- of the HCl titration to pH 7.5, 21.82 mM
    NonBiological(0.021825, 0.000992, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
    NonBiological(0.6846, 0.0342, "glycerol"),   # 5 % v/v glycerol, 0.6846 M, +-5%
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, +-2%
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
        refChi2 = "CRYSOL 1.469",
        pdb = "SASDC36_fit1_model1.pdb",
        fit = "SASDC36_fit1.fit",
        fitScale = 1.0,
        fitCol = 4,
        rescale = false,
        software = "CRYSOL",
    ),
    (
        tag = "fit2_model1",
        refChi2 = "SREFLEX 1.001",
        pdb = "SASDC36_fit2_model1.pdb",
        fit = "SASDC36_fit2.fit",
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

# Builds the Seed that `runSasdc36` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdc36` below is the whole story).
function seedSasdc36(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdc36(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdc36(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdc36(run)

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

    # `@__DIR__` (this SASDC36/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
