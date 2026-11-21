# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDHP7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDHP7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDHP7: Haloalkane dehalogenase variant DhaA115 -monomeric fraction (DhaA115 -
# monomeric, no UniProt, Rhodococcus rhodochrous, 34.404 kDa x 1). Haloalkane dehalogenase
# variant DhaA115 - monomeric fraction. Publication: Markova K, Chmelova K, Marques S,
# Carpentier P, Bednar D, Damborsky J, Marek M, "Decoding the intricate network of
# molecular interactions of a hyperstable engineered biocatalyst", Chemical Science
# (2020), DOI 10.1039/D0SC03367G. Entry: https://www.sasbdb.org/data/SASDHP7/. Sources
# (owner, 2026-11-18: paper first, SASBDB second): the paper's SAXS methods give the
# buffer recipe, pH and temperature, and they agree with the SASBDB fields, which are
# the second source: "Size exclusion buffer (41 mM K₂HPO₄, 9 mM KH₂PO₄, pH 7.5) was used
# for the blank measurement", data collected "at 293 K" (= 20 °C, as in SASBDB) with Cu
# Kα X-rays (1.54 Å, as in SASBDB). The sample-to-detector distance is 0.48 m in the
# paper (SASBDB 0.48).
#
# Instrument (SASBDB): CEITEC Rigaku BioSAXS-1000 (Brno, Czech Republic), detector Pilatus
# 100K; wavelength 1.54 A (SASBDB wavelength field / experiment description); energy
# HC/lambda. Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description:
# "SAXS data from solutions of haloalkane dehalogenase variant DhaA115 in 50 mM potassium
# phosphate buffer (41 mM K₂HPO₄, 9mM KH₂PO₄), pH 7.5 were collected using a Rigaku
# BioSAXS-1000 instrument at CEITEC (Brno, Czech Republic) equipped with a Pilatus 100K
# detector at a sample-detector distance of 0.5 m and at a wavelength of λ = 0.154 nm
# (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). Solute ...".
#
# Buffer (paper, confirmed by SASBDB): "50 mM potassium phosphate buffer (41 mM K₂HPO₄,
# 9 mM KH₂PO₄)", pH 7.5. The two salts are entered as stated, so no speciation is
# computed. The pH is taken as set at room temperature (22 +-3 C).
# Concentrations carry a 2 % sigma unless stated. Every solute below is in the bundled
# tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.03387-0.4001 A-1, 256
# rows, 0 with sigma <= 0 (dropped by the fit subset), 0 with a non-positive intensity
# (`seedModel` drops the non-positive bins). No q cut: the README noise-floor rule (median
# I/sigma below 0.5 together with about a quarter of the points non-positive) is not met
# over any useful part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'DhaA115- Dro:0.007 Ra:1.580
# RGT:18.33 Vol: 42798. Chi^2: 1.145', SASBDB chi2 1.145; recomputed from the .fit columns
# 2-4: chi2 1.145. Model SASDHP7_fit1_model1.pdb: 2425 ATOM records (heavy atoms), HETATM
# groups B3P x19 atoms, SCN x9 atoms (known components, kept by the loader), chains A, no
# hydrogens, 56 alternate-location atoms (the loader's altloc handling applies); SASBDB
# model = PDB 6SP5 (derived) (PDB (Protein Data Bank)). Depositor chi2 used as refChi2:
# SASBDB chi_square_value.
#
# Size: 2453 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # wavelength 1.54 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.041, 0.00082, "dipotassium hydrogen phosphate"),   # 41 mM K2HPO4, ±2%
    NonBiological(0.009, 0.00018, "potassium dihydrogen phosphate"),   # 9 mM KH2PO4, ±2%
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
    refChi2 = "CRYSOL 1.145",
    pdb = "SASDHP7_fit1_model1.pdb",
    fit = "SASDHP7_fit1.fit",
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

# Builds the Seed that `runSasdhp7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdhp7` below is the whole story (build the seed, then sample it).
function seedSasdhp7(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdhp7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdhp7(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdhp7(run)

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

    # `@__DIR__` (this SASDHP7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
