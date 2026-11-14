# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVU5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVU5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVU5: The structure and function of the DNA binding domain of class B MpARF2
# share more traits with class A AtARF5 than to that of class B AtARF1 (MpARF3 DNA-binding
# domain, 45.5 kDa, with two 20-mer DNA strands, 57.9 kDa in total).
#
# Paper: Crespo I, Malfois M, Rienstra J, et al., Structure (2025), DOI
# 10.1016/j.str.2025.02.006. Conditions below are from the SASBDB entry metadata
# (https://www.sasbdb.org/data/SASDVU5/); the paper itself was not consulted.
#
# Sample: 3.50 mg/ml, single concentration, 20 frames of 0.5 s. Instrument: ALBA BL11-NCD,
# wavelength 0.1 nm = 1.0 Å => energy = hc/λ ≈ 12398 eV (hc = 12398.42 eV·Å). Sample
# temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "20 mM Tris-HCl, 150 mM NaCl, 1 mM DTT", pH 8.0. Curve units: the
# SASBDB .dat is in nm⁻¹ (2 header lines, 1963 rows, 3 trailer lines, CRLF line endings)
# and is converted to Å⁻¹ (÷10). The reference fit (Pepsi-SAXS) is read from the same
# folder.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the stated 0.1 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed:
# 20 mM Tris titrated with HCl ->
# Cl⁻ = C·0.655 (pK(22 °C) = 8.156).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.163 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.15, 0.0015, "sodium chloride"),   # 150 mM, ±1%
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris-HCl, ±2%
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.013096, 0.001459, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole curve is fitted. The data reach 0.58 Å⁻¹ but the depositor's
# Pepsi-SAXS fit stops at 0.50 Å⁻¹, so the refChi2 is not like for like. Above 0.3 Å⁻¹
# the median I/σ is 1.0 (12 % of the points have I ≤ 0; it falls below 0.5 only above
# 0.52 Å⁻¹).

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH
# The model has ANISOU records and three chains (A protein, C and D the two DNA strands).

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "Pepsi-SAXS 2.613",
    pdb = "SASDVU5_fit1_model1.pdb",
    fit = "SASDVU5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "Pepsi-SAXS",
),   # deposited χ² = 2.613 (Pepsi-SAXS, SwissModel-based model)
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

# Builds the Seed that `runSasdvu5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvu5` below is the whole story (build the seed, then sample it).
function seedSasdvu5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvu5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvu5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvu5(run)

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

    # `@__DIR__` (this SASDVU5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
