# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDDG7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDDG7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDDG7: Small but large enough: structural properties of armless mitochondrial
# tRNAs from the nematode Romanomermis culicivorax (tRNA-Ile, 47 nt as deposited, 15.1
# kDa). Same paper, instrument and buffer as SASDDF7 (tRNA-Arg, already in the repo,
# whose script this one copies).
#
# Paper: Jühling T, Duchardt-Ferner E, Bonin S, et al., Nucleic Acids Res (2018), DOI
# 10.1093/nar/gky593. Audited against the paper (round 5, 2026-11-13; the Supplementary
# Data were not available). NAR 46(17):9170-9180, Materials and Methods, "Small angle
# X-ray scattering" (p. 9171-9172): "tRNAArg and tRNAIle samples were concentrated to a
# final concentration of 6 mg/ml (tRNAArg) and 3.5 mg/ml (tRNAIle) in 200 ul buffer
# containing 50 mM HEPES-NaOH, pH 7.4 and 10 mM MgCl2 using centrifugation in an Amicon
# Ultra-4", SWING (SOLEIL) "with a beam wavelength of lambda = 1.033 A", "SEC elution was
# performed ... at 0.2 ml/min in 50 mM HEPES-NaOH, pH 7.4, and 10 mM MgCl2 (low salt
# conditions), or in a same buffer supplemented with 150 mM KCl (high salt conditions)".
# This entry is the low-salt monomer (peak 2): the .dat header reads "L_tRNAile_It_pk2".
# Model: "All-atom models of armless tRNAs were built using RNAcomposer ... perturbed [by
# ElNeMo normal modes] to generate conformations that better fitted experimental SAXS
# profiles owing to the goodness-of-fit (Chi2) determined with CRYSOL", "handled in PyMol
# 1.8.6 using the SASpy plugin and were minimized in Phenix" (the 47-nt model matches the
# paper's 42-47 nt transcripts without CCA). From the SASBDB entry only (the paper does
# not give them, nor contradict them): cell temperature 15 C.
#
# Sample: SEC-SAXS (US-SOMO frames, 4 °C storage), cell temperature 15.0 °C.
# Instrument: SOLEIL SWING, AVIEX PCCD170170, wavelength 0.1033 nm = 1.033 Å => energy =
# hc/λ ≈ 12002 eV (hc = 12398.42 eV·Å). Curve: SEC-SAS, already in Å⁻¹ (3 header lines,
# 667 rows, q 0.0062-0.4003 Å⁻¹).
#
# Model: SASDDG7_fit1_model1.pdb, PyMOL model, 997 atoms, heavy atoms only, element
# column present, residue names single letters (C/U/A/G). Unmodified.
#
# Depositor fit: CRYSOL, `.fit` header "Chi^2: 1.659" (Dro 0.005, Ra 1.400, RGT 20.62,
# Vol 13989). Recomputed from the `.fit` columns (q, I_exp, σ, I_fit; mean of
# ((I_exp - I_fit)/σ)² over the 667 points with σ > 0): 1.655, so the header is a chi2
# and not a chi. The SASBDB REST value agrees with the header (per
# notes/replacement-candidates.md). refChi2 = "CRYSOL 1.659". The first `.fit` rows
# (q = 0, 0.002 Å⁻¹) are CRYSOL extrapolation rows with σ = 0.
#
# Buffer as deposited: "50 mM HEPES-NaOH 10 mM MgCl2", pH 7.4 (SASBDB fields).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 667

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 15.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions. Setting the pH adds titrant counter-ions that
# the deposited recipe does not list. 50 mM HEPES titrated with NaOH (stated in the
# paper and SASBDB: "HEPES-NaOH") -> Na⁺ = C·0.435 (pK(22 °C) = 7.600).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.052 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C (identical buffer to SASDDF7, so its numbers are reused). Only the
# counter-ion is modelled; the volume change of the buffer's own (de)protonation is not.
# Titrant (stated here: NaOH; in general HCl for amine bases, NaOH for Good's buffers).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM, ±2%
    NonBiological(0.01, 0.0001, "magnesium chloride"),   # 10 mM, ±1%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.02174, 0.003183, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The data run to 0.4003 Å⁻¹ and the depositor's CRYSOL fit stops at the same q, so the
# whole curve is fitted.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.659",
    pdb = "SASDDG7_fit1_model1.pdb",
    fit = "SASDDG7_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 1.659
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasddg7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasddg7` below is the whole story (build the seed, then sample it).
function seedSasddg7(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasddg7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasddg7(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasddg7(run)

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

    # `@__DIR__` (this SASDDG7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
