# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDAN8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAN8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDAN8: KSHV but not MHV-68 LANA induces a strong bend upon binding to terminal
# repeat viral DNA (the entry is the free mLBS1-2 terminal-repeat DNA, 30 kDa, no
# protein).
#
# Paper: Ponnusamy R, Petoukhov MV, Correia B, et al., Nucleic Acids Res (2015), DOI
# 10.1093/nar/gkv987. SASBDB entry: https://www.sasbdb.org/data/SASDAN8/ (the buffer, pH,
# temperature and instrument below are the SASBDB entry metadata; the paper was not
# consulted for them).
#
# Sample: mLBS1-2 DNA (chains A and B of the model), up to 5 mg/ml. Instrument: PETRA III
# EMBL P12 (X-ray synchrotron), Pilatus 2M, wavelength 0.12 nm = 1.2 Å => energy = hc/λ
# ≈ 10332 eV (hc = 12398.42 eV·Å). Sample temperature: 10 °C (SASBDB cell temperature).
#
# Buffer as deposited: "10 mM TRIS 150 mM NaCl", pH 7.6. The measured macromolecule is
# deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (q 0.238-4.61 nm⁻¹, 3 header lines, 3 trailer
# lines) and is converted to Å⁻¹ (÷10); 276 of its 1667 points have a non-positive
# intensity, dropped by `seedModel` after binning. The depositor's `.fit` is the
# 3-column CRYSOL variant (q, the resampled data, the CRYSOL curve), whose curve is not on
# the data's scale: it is rescaled to the data for the overlay (`rescale = true`).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.6, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # ≈ 10332 eV, from the stated 0.12 nm
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions. Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 10 mM Tris titrated with
# HCl -> Cl⁻ = C·0.826 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.158 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.15, 0.0015, "sodium chloride"),   # 150 mM, ±1%
    NonBiological(0.01, 0.0002, "tris"),   # 10 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.008261, 0.000485, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.461 Å⁻¹,
# but the 614 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.18 and 43 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.34 Å⁻¹) has a median I/σ of 0.45.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has no hydrogens. It holds DNA only, so
# `seedModel` takes the nucleic route (AMBER force field, no PROPKA).
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 2.464 (header; 4.58 recomputed from the file with a free scale)",
    pdb = "SASDAN8_fit1_model1.pdb",
    fit = "SASDAN8_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
    rescale = true,
    software = "CRYSOL",
),   # B-DNA duplex, 2044 atoms; header χ² = 2.464, rescaled col 3 gives 4.58
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdan8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdan8` below is the whole story (build the seed, then sample it).
function seedSasdan8(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdan8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdan8(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdan8(run)

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
        runLog = true,
    )

    # `@__DIR__` (this SASDAN8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
