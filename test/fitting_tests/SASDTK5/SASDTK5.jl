# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDTK5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTK5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTK5: Heme-substituted protein assembly bridged by synthetic porphyrin:
# achieving controlled configuration while maintaining rotational freedom
#
# Paper: Inaba H, Shisaka Y, Ariyasu S, et al., RSC Advances (2024),
# DOI 10.1039/D4RA01042F. Open access (CC BY); PDF not in the
# repository, see test/fixtures/experiments/SASDTK5/README.txt (PMC
# PMC10941265). SASBDB entry: https://www.sasbdb.org/data/SASDTK5/
#
# Sample: HasApf5 (dimer, 19.034 kDa/chain); measured at up to 8.0 mg/ml
# (SEC-SAS). Instrument: Photon Factory (PF), High Energy Accelerator Research
# Organization (KEK) (X-ray synchrotron), wavelength 0.1 nm = 1 Å => energy = hc/λ
# ≈ 12398 eV (hc = 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "50 mM CHES, 5 % glycerol", pH 9.5. Only the components with a
# partial- molar-volume entry and a stated concentration are modelled below; the
# measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹. The reference fit files are read
# from the same folder; each run's comparison curve is the depositor's fit for that
# model. ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 9.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1   # ≈ 12398 eV, from the stated 0.1 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 50 mM CHES titrated with
# KOH -> K⁺ = C·0.560 (pK(22 °C) = 9.464). The pH is taken as set at room temperature (22 ±
# 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T) from
# Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902)
# pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.028 M. σ combines σ_PH, ±3 °C, ±0.02
# pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume
# change of the buffer's own (de)protonation is not. Titrant: CHES–KOH stated in the paper.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "ches"),   # 50 mM, ±2%
    NonBiological(0.6846265772, 0.01369253154, "glycerol"),   # 684.6 mM, ±2%
    # K⁺ counter-ion from KOH titration of CHES (see note above)
    NonBiological(0.027985, 0.003620, "potassium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
        tag = "fit2_model1",
        refChi2 = "CRYSOL 1.14",
        pdb = "SASDTK5_fit2_model1.pdb",
        fit = "SASDTK5_fit2.fit",
        fitScale = 1.0,
        fitCol = 3,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 93 Å; deposited χ² = 1.138
    (
        tag = "fit3_model1",
        refChi2 = "CRYSOL 1.17",
        pdb = "SASDTK5_fit3_model1.pdb",
        fit = "SASDTK5_fit3.fit",
        fitScale = 1.0,
        fitCol = 3,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 81 Å; deposited χ² = 1.167
    (
        tag = "fit4_model1",
        refChi2 = "CRYSOL 5.22",
        pdb = "SASDTK5_fit4_model1.pdb",
        fit = "SASDTK5_fit4.fit",
        fitScale = 1.0,
        fitCol = 3,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 110 Å; deposited χ² = 5.221
    (
        tag = "fit5_model1",
        refChi2 = "CRYSOL 1.81",
        pdb = "SASDTK5_fit5_model1.pdb",
        fit = "SASDTK5_fit5.fit",
        fitScale = 1.0,
        fitCol = 3,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 91 Å; deposited χ² = 1.805
    (
        tag = "fit6_model1",
        refChi2 = "CRYSOL 1.03",
        pdb = "SASDTK5_fit6_model1.pdb",
        fit = "SASDTK5_fit6.fit",
        fitScale = 1.0,
        fitCol = 3,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 94 Å; deposited χ² = 1.026
    (
        tag = "fit7_model1",
        refChi2 = "CRYSOL 6.09",
        pdb = "SASDTK5_fit7_model1.pdb",
        fit = "SASDTK5_fit7.fit",
        fitScale = 1.0,
        fitCol = 3,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 110 Å; deposited χ² = 6.085
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdtk5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdtk5` below is the whole story (build the seed, then sample it).
function seedSasdtk5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdtk5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdtk5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdtk5(run)

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
                fitCurve...,
            ),
        )
    end
    BAYSOL.results(
        result, (qFit, iFit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        formFactorLog = formFactorLog, nAtoms = nAtoms,
        refChi2 = run.refChi2,
        runLog = true,
    )

    # `@__DIR__` (this SASDTK5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
