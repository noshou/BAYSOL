# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDMK9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMK9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMK9: Replicase polyprotein 1a (Nsp7, P0C6U8, Severe acute respiratory
# syndrome-related coronavirus, 9.268 kDa x 2); Replicase polyprotein 1a (Nsp8, P0C6U8,
# Severe acute respiratory syndrome-related coronavirus, 21.881 kDa x 1). Nonstructural
# Proteins 7 and 8 of Feline Coronavirus (complex 1:2). Publication: Xiao Y, Ma Q, Restle
# T, Shang W, Svergun D, Ponnusamy R, Sczakiel G, Hilgenfeld R, "Nonstructural Proteins 7
# and 8 of Feline Coronavirus Form a 2:1 Heterotrimer That Exhibits Primer-Independent RNA
# Polymerase Activity", Journal of Virology (2012), DOI 10.1128/JVI.06635-11 (the paper
# was NOT consulted, except where stated: every condition below is the SASBDB entry
# metadata, flagged). Entry: https://www.sasbdb.org/data/SASDMK9/.
#
# Instrument (SASBDB): DORIS III, DESY EMBL X33 (Hamburg, Germany), detector Pilatus 1M-W;
# wavelength 1.54 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: the 25 C DEFAULT (SASBDB gives no temperature for this entry; flagged).
# SASBDB experiment description: "".
#
# Buffer (SASBDB, NOT the paper; flagged): "10 mM Tris-HCl, 200 mM NaCl, 5 mM DTT", pH
# 7.5. Counter-ion: setting the pH adds a titrant that the recipe does not list. 10 mM
# Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I = 0.2086 M: the cationic
# (protonated) fraction is 0.8589, so Cl- = C x 0.8589 = 8.59 mM (sigma 0.45 mM: sigma_pH
# = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not
# stated; the ordinary choice, assumed). The pH is taken as set at room temperature (22
# +-3 C). Concentrations carry a 2 % sigma unless stated. Every solute below is in the
# bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.0671-6.024 nm-1),
# converted to A-1 (divide by 10): q 0.00671-0.6024 A-1, 2178 rows, 0 with sigma <= 0
# (dropped by the fit subset), 5 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'newtrime Dro:0.060 Ra:1.800
# RGE:29.12 RGT:30.21 Vol: 52229. Chi:', SASBDB chi2 1.731856; the .fit has no sigma
# column to recompute from. Model SASDMK9_fit1_model1.pdb: 2754 ATOM records (heavy
# atoms), no HETATM, chains ABC, no hydrogens; SASBDB model = PDB 3UB0 (identical) (PDB
# (Protein Data Bank)). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 2754 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # wavelength 1.54 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 10 mM Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I =
# 0.2086 M: the cationic (protonated) fraction is 0.8589, so Cl- = C x 0.8589 = 8.59 mM
# (sigma 0.45 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "tris"),   # 10 mM Tris-HCl, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.00858892, 0.0004499, "chloride"),
    NonBiological(0.2, 0.004, "sodium chloride"),   # 200 mM NaCl, ±2%
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
    refChi2 = "CRYSOL 1.73186",
    pdb = "SASDMK9_fit1_model1.pdb",
    fit = "SASDMK9_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
    rescale = true,
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

# Builds the Seed that `runSasdmk9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdmk9` below is the whole story (build the seed, then sample it).
function seedSasdmk9(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdmk9(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdmk9(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdmk9(run)

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

    # `@__DIR__` (this SASDMK9/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
