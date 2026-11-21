# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDMG8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMG8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMG8: Non-POU domain-containing octamer-binding protein (NONO, Q15233, Homo
# sapiens, 30.1 kDa x 1); Splicing factor, proline- and glutamine-rich (SFPQ-QM, P23246,
# Homo sapiens, 38.025 kDa x 1). Splicing factor, proline- and glutamine-rich-QM bound to
# Non-POU domain-containing octamer-binding protein: SFPQ(276-598)-QM / NONO(53-312)
# heterodimer. Publication: Huang J, Ringuet M, Whitten A, Caria S, Lim Y, Badhan R,
# Anggono V, Lee M, "Structural basis of the zinc-induced cytoplasmic aggregation of the
# RNA-binding protein SFPQ", Nucleic Acids Research (2020), DOI 10.1093/nar/gkaa076 (the
# paper was NOT consulted, except where stated: every condition below is the SASBDB entry
# metadata, flagged). Entry: https://www.sasbdb.org/data/SASDMG8/.
#
# Instrument (SASBDB): Australian Synchrotron SAXS/WAXS (Melbourne, Australia), detector
# Pilatus 1M; wavelength 1.033 A (SASBDB wavelength field / experiment description);
# energy HC/lambda. Temperature: 20 C, SASBDB cell temperature. SASBDB experiment
# description: "X-ray synchrotron radiation scattering data from solutions of human
# SFPQ(276-598)-QM/NONO(53-512) in 20 mM Tris 250 mM NaCl, pH 7.5 were collected on the
# SAXS/WAXS beam line of the Australian Synchrotron (Melbourne, Australia) using a 2D
# Photon counting Dectris/Pilatus 1M pixel detector (s = 4πsinθ/λ, where 2θ is the
# scattering angle). Here QM refers to the quadruple mutatation in the SFPQ(276-598)
# protein (L535A, ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "20 mM Tris, 250 mM NaCl", pH 7.5. Counter-ion:
# setting the pH adds a titrant that the recipe does not list. 20 mM Tris (pK(22 C) =
# 8.157) at pH 7.5 with Davies activities at I = 0.2672 M: the cationic (protonated)
# fraction is 0.8603, so Cl- = C x 0.8603 = 17.21 mM (sigma 0.90 mM: sigma_pH = 0.1, +-3
# C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not stated; the
# ordinary choice, assumed). The pH is taken as set at room temperature (22 +-3 C).
# Concentrations carry a 2 % sigma unless stated. Every solute below is in the bundled
# tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.005719-0.3638 A-1, 910
# rows, 0 with sigma <= 0 (dropped by the fit subset), 23 with a non-positive intensity
# (`seedModel` drops the non-positive bins). No q cut: the README noise-floor rule (median
# I/sigma below 0.5 together with about a quarter of the points non-positive) is not met
# over any useful part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header '4wij_tru Dro:0.028 Ra:1.400
# RGT:39.52 Vol: 83958. Chi^2: 1.651', SASBDB chi2 1.651; the .fit has no sigma column to
# recompute from. Model SASDMG8_fit1_model1.pdb: 4449 ATOM records (heavy atoms), no
# HETATM, chains AB, no hydrogens, 9 alternate-location atoms (the loader's altloc
# handling applies); SASBDB model = PDB 4WIJ (identical) (PDB (Protein Data Bank)).
# Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 4449 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # wavelength 1.033 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 20 mM Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I =
# 0.2672 M: the cationic (protonated) fraction is 0.8603, so Cl- = C x 0.8603 = 17.21 mM
# (sigma 0.90 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.0172052, 0.0008968, "chloride"),
    NonBiological(0.25, 0.005, "sodium chloride"),   # 250 mM NaCl, ±2%
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
    refChi2 = "CRYSOL 1.651",
    pdb = "SASDMG8_fit1_model1.pdb",
    fit = "SASDMG8_fit1.fit",
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

# Builds the Seed that `runSasdmg8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdmg8` below is the whole story (build the seed, then sample it).
function seedSasdmg8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdmg8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdmg8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdmg8(run)

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

    # `@__DIR__` (this SASDMG8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
