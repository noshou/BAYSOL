# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJL6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJL6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJL6: Rod domain of α-actinin-2 (rod-α-actinin-2, P35609, Homo sapiens, 56.132
# kDa x 2). Sarcomeric F-actin crosslinking protein α-actinin-2 (spectrin repeat rod
# domain, rod-α-actinin-2). Publication: Sponga A, Arolas JL, Schwarz TC, Jeffries CM,
# Rodriguez Chamorro A, Kostan J, Ghisleni A, Drepper F, Polyansky A, De Almeida Ribeiro
# E, Pedron M, Zawadzka-Kazimierczuk A, Mlynek G, Peterbauer T, Doto P, Schreiner C,
# Hollerl E, Mateos B, Geist L, Faulkner G, Kozminski W, Svergun DI, Warscheid B, Zagrovic
# B, Gautel M, Konrat R, Djinović-Carugo K, "Order from disorder in the sarcomere: FATZ
# forms a fuzzy but tight complex and phase-separated condensates with α-actinin.", Sci
# Adv (2021), DOI 10.1126/sciadv.abg7653 (the paper was NOT consulted, except where
# stated: every condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDJL6/.
#
# Instrument (SASBDB): PETRA III EMBL P12 (DESY; Hamburg, Germany), detector Pilatus 6M;
# wavelength 1.24 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of the rod domain of α-actinin-2 in 50 mM Tris-HCl 150 mM NaCl,
# pH 7.5 were collected on the EMBL P12 beam line at PETRA III (DESY, Hamburg, Germany)
# using a Pilatus 6M detector at a sample-detector distance of 3 m and at a wavelength of
# λ = 0.124 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). One solute
# concentration of 1.12 mg/ml was measured at 20°C. 28 ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "50 mM Tris-HCl 150 mM NaCl", pH 7.5.
# Counter-ion: setting the pH adds a titrant that the recipe does not list. 50 mM Tris
# (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I = 0.1929 M: the cationic
# (protonated) fraction is 0.8584, so Cl- = C x 0.8584 = 42.92 mM (sigma 2.26 mM: sigma_pH
# = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not
# stated; the ordinary choice, assumed). The pH is taken as set at room temperature (22
# +-3 C). Concentrations carry a 2 % sigma unless stated. Every solute below is in the
# bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (its footer says `angular-unit: nanometer`;
# the depositor's CRYSOL .fit ends at 0.444 A-1 = 4.441 nm-1): q 0.08078-4.441 nm-1 =
# 0.008078-0.4441 A-1, converted below. 1577 rows, 0 with sigma <= 0 (dropped by the fit
# subset), 125 with a non-positive intensity (`seedModel` drops the non-positive bins).
# No q cut: the README noise-floor rule (median I/sigma below 0.5 together with about a
# quarter of the points non-positive) is not met over any useful part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'rod.pdb Dro:0.015 Ra:1.400
# RGT:72.25 Vol:148076. Chi^2: 1.021', SASBDB chi2 1.021; recomputed from the .fit columns
# 2-4: chi2 1.021. Model SASDJL6_fit1_model1.pdb: 7860 ATOM records (heavy atoms), no
# HETATM, chains AB, no hydrogens; SASBDB model = PDB 1HCI (identical) (PDB (Protein Data
# Bank)). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 7860 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹ (the file's `angular-unit: nanometer`); convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
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
    refChi2 = "CRYSOL 1.021",
    pdb = "SASDJL6_fit1_model1.pdb",
    fit = "SASDJL6_fit1.fit",
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

# Builds the Seed that `runSasdjl6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjl6` below is the whole story (build the seed, then sample it).
function seedSasdjl6(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjl6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdjl6(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjl6(run)

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

    # `@__DIR__` (this SASDJL6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
