# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDHM8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDHM8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDHM8: Aquifex aeolicus McoA metaloxidase ∆328-352 evolved variant
# (2F4∆328-352) (2F4∆328-352, no UniProt, Aquifex aeolicus, 52.722 kDa x 1). Aquifex
# aeolicus McoA metaloxidase ∆328-352 evolved variant (2F4∆328-352). Publication: Brissos
# V, Borges P, Núñez-Franco R, Lucas M, Frazão C, Monza E, Masgrau L, Cordeiro T, Martins
# L, "Distal Mutations Shape Substrate-Binding Sites during Evolution of a Metallo-Oxidase
# into a Laccase", ACS Catalysis (2022), DOI 10.1021/acscatal.2c00336 (the paper was NOT
# consulted, except where stated: every condition below is the SASBDB entry metadata,
# flagged). Entry: https://www.sasbdb.org/data/SASDHM8/.
#
# Instrument (SASBDB): ESRF BM29 (Grenoble, France), detector Pilatus 1M; wavelength 0.99
# A (SASBDB wavelength field / experiment description); energy HC/lambda. Temperature: 20
# C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron SAXS data from
# solutions of Aquifex aeolicus McoA metaloxidase ∆328-352 evolved variant (2F4∆328-352)
# in 50 mM Tris-HCl, 150 mM NaCl, 2 mM TCEP, pH 7.5 were collected on the BM29 beam line
# at the ESRF (Grenoble, France) using a Pilatus 1M detector at a sample-detector distance
# of 2.9 m and at a wavelength of λ = 0.099 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is
# the scattering angle). In-line ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "50 mM Tris-HCl, 150 mM NaCl, 2 mM TCEP", pH
# 7.5. Counter-ion: setting the pH adds a titrant that the recipe does not list. 50 mM
# Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I = 0.1929 M: the cationic
# (protonated) fraction is 0.8584, so Cl- = C x 0.8584 = 42.92 mM (sigma 2.26 mM: sigma_pH
# = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not
# stated; the ordinary choice, assumed). The pH is taken as set at room temperature (22
# +-3 C). Concentrations carry a 2 % sigma unless stated. Every solute below is in the
# bundled tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.01105-0.496 A-1, 1027
# rows, 0 with sigma <= 0 (dropped by the fit subset), 10 with a non-positive intensity
# (`seedModel` drops the non-positive bins). No q cut: the README noise-floor rule (median
# I/sigma below 0.5 together with about a quarter of the points non-positive) is not met
# over any useful part of the curve.
#
# Model and depositor fit (fit2_model1): CRYSOL fit, header '2f4∆loop.pdb Dro:0.020
# Ra:1.800 RGT:22.05 Vol: 65057. Chi^2: 1.', SASBDB chi2 1.003; recomputed from the .fit
# columns 2-4: chi2 1.003. Model SASDHM8_fit2_model1.pdb: 5923 ATOM records (heavy atoms),
# HETATM groups CU x4 atoms (known components, kept by the loader), chains A, 1373
# deposited hydrogens (replaced by pdb2pqr); SASBDB model = PDB 6TTD (identical)
# (Rosetta). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 5927 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # wavelength 0.99 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 50 mM Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I =
# 0.1929 M: the cationic (protonated) fraction is 0.8584, so Cl- = C x 0.8584 = 42.92 mM
# (sigma 2.26 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris-HCl, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.0429187, 0.00225569, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
    NonBiological(0.002, 4e-05, "tcep"),   # 2 mM TCEP, ±2%
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
    tag = "fit2_model1",
    refChi2 = "CRYSOL 1.003",
    pdb = "SASDHM8_fit2_model1.pdb",
    fit = "SASDHM8_fit2.fit",
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

# Builds the Seed that `runSasdhm8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdhm8` below is the whole story (build the seed, then sample it).
function seedSasdhm8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdhm8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdhm8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdhm8(run)

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

    # `@__DIR__` (this SASDHM8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
