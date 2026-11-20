# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDLY8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDLY8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDLY8: Recombinant Mycobacterium tuberculosis H37Rv (RV0792c, O86331,
# Mycobacterium tuberculosis H37Rv, 32.503 kDa x 2). Mycobacterium tuberculosis Rv0792c, a
# GntR homolog. Publication: Chauhan NK, Anand A, Sharma A, Dhiman K, Gosain TP, Singh P,
# Singh P, Khan E, Chattopadhyay G, Kumar A, Sharma D, Ashish, Sharma TK, Singh R,
# "Structural and Functional Characterization of Rv0792c from Mycobacterium tuberculosis:
# Identifying Small Molecule Inhibitor against HutC Protein.", Microbiol Spectr (2022),
# DOI 10.1128/spectrum.01973-22 (the paper was NOT consulted, except where stated: every
# condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDLY8/.
#
# Instrument (SASBDB): CSIR - Institute of Microbial Technology (IMTech) Anton Paar
# SAXSpace (Chandigarh, India), detector Mythen 1K; wavelength 1.5414 A (SASBDB wavelength
# field / experiment description); energy HC/lambda. Temperature: 10 C, SASBDB cell
# temperature. SASBDB experiment description: "SAXS data from solutions of Mycobacterium
# tuberculosis Rv0792c, a GntR homolog in 25 mM HEPES Buffer; 400 mM NaCl, pH 7.2 were
# collected at Anton Paar SAXSpace, CSIR - Institute of Microbial Technology (IMTech)
# using a Mythen 1K detector at a sample-detector distance of 0.3 m and at a wavelength of
# λ = 0.15414 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). One
# solute concentration of 3.20 mg/ml ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "25 mM HEPES Buffer; 400 mM NaCl,", pH 7.2.
# Counter-ion: 25 mM HEPES (pK(22 C) = 7.600) at pH 7.2 with Davies activities at I =
# 0.4088 M: the anionic fraction is 0.3525, so Na+ = C x 0.3525 = 8.81 mM (sigma 1.56 mM,
# same sources as for Tris). The titrant is NaOH (not stated; the ordinary choice,
# assumed). The pH is taken as set at room temperature (22 +-3 C). Concentrations carry a
# 2 % sigma unless stated. Every solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1373-5 nm-1), converted
# to A-1 (divide by 10): q 0.01373-0.5 A-1, 249 rows, 0 with sigma <= 0 (dropped by the
# fit subset), 0 with a non-positive intensity (`seedModel` drops the non-positive bins).
# No q cut: the README noise-floor rule (median I/sigma below 0.5 together with about a
# quarter of the points non-positive) is not met over any useful part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'P_Rv0792 Dro:0.048 Ra:1.800
# RGT:33.20 Vol: 77330. Chi^2: 0.936', SASBDB chi2 0.936; recomputed from the .fit columns
# 2-4: chi2 0.932. Model SASDLY8_fit1_model1.pdb: 4564 ATOM records (heavy atoms), no
# HETATM, chains AB, 4624 deposited hydrogens (replaced by pdb2pqr); SASBDB model with no
# PDB link (Other). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 4564 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.5414   # wavelength 1.5414 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 25 mM HEPES (pK(22 C) = 7.600) at pH 7.2 with
# Davies activities at I = 0.4088 M: the anionic fraction is 0.3525, so Na+ = C x 0.3525 =
# 8.81 mM (sigma 1.56 mM, same sources as for Tris). The titrant is NaOH (not stated; the
# ordinary choice, assumed). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),   # 25 mM HEPES, ±2%
    # Na+ counter-ion of the HEPES titration (see the note above)
    NonBiological(0.00881213, 0.00155636, "sodium(1+)"),
    NonBiological(0.4, 0.008, "sodium chloride"),   # 400 mM NaCl, ±2%
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
    refChi2 = "CRYSOL 0.936",
    pdb = "SASDLY8_fit1_model1.pdb",
    fit = "SASDLY8_fit1.fit",
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

# Builds the Seed that `runSasdly8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdly8` below is the whole story (build the seed, then sample it).
function seedSasdly8(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdly8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdly8(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdly8(run)

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

    # `@__DIR__` (this SASDLY8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
