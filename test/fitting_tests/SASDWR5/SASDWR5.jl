# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWR5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWR5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWR5: A protein-dependent riboswitch activates ribosomal frameshifting in
# cardioviruses (stimulatory element RNA, 37 nt, 11.8 kDa).
#
# Paper: Betts J, et al., Molecular Cell (2026), DOI 10.1016/j.molcel.2026.07.036.
# Conditions below are from the SASBDB entry metadata
# (https://www.sasbdb.org/data/SASDWR5/); the paper itself was not consulted.
#
# Sample: 7.1 mg/ml injected on an in-line SEC column (Superdex 75 Increase 5/150, 20 °C).
# Instrument: PETRA III EMBL P12, wavelength 0.123983 nm = 1.23983 Å => energy = hc/λ
# ≈ 10000 eV (hc = 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "20 mM HEPES pH 7.4, 400 mM KCl 2% v/v glycerol, 1 mM DTT"; the
# SASBDB pH field is empty, the pH is taken from the buffer text. Curve units: the SASBDB
# .dat is in nm⁻¹ (2 header lines, 2653 rows, 7 trailer lines, CRLF line endings) and is
# converted to Å⁻¹ (÷10). The model is the SREFLEX model (fit1); the entry also has a Coot
# model fit (fit3, χ 13.95) that is not fitted here. The reference fit file has a q = 0
# row with zero data, which the comparison plot drops.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.23983   # ≈ 10000 eV, from the stated 0.123983 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed:
# 20 mM HEPES titrated with NaOH ->
# Na⁺ = C·0.463 (pK(22 °C) = 7.600; the titrant could equally be KOH, the difference is
# negligible).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.409 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
# 2 % v/v glycerol = 0.2738 M (ρ = 1.261 g/mL, MW = 92.094 g/mol), ±5 % because it is a
# v/v -> molarity conversion (as SASDJ72).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM, ±2%
    NonBiological(0.4, 0.004, "potassium chloride"),   # 400 mM, ±1%
    NonBiological(0.2738, 0.01369, "glycerol"),   # 2 % v/v, ±5%
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.009262, 0.001339, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole curve is fitted. The data reach 0.741 Å⁻¹ but the depositor's
# CRYSOL fit stops at 0.5001 Å⁻¹, so the refChi2 is not like for like. Above 0.5 Å⁻¹ the
# median I/σ is 3.5 (2 % of the points have I ≤ 0).

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
    refChi2 = "CRYSOL 1.11 (SREFLEX model)",
    pdb = "SASDWR5_fit1_model1.pdb",
    fit = "SASDWR5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL (SREFLEX model)",
),   # deposited χ² = 1.11 (CRYSOL, SREFLEX model from an AlphaFold template)
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

# Builds the Seed that `runSasdwr5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdwr5` below is the whole story (build the seed, then sample it).
function seedSasdwr5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwr5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdwr5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwr5(run)

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

    # `@__DIR__` (this SASDWR5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
