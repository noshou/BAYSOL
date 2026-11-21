# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXF3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXF3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXF3: h-OGA (human O-GlcNAcase, dimer), AlphaFold model, protein.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1038/s41467-025-63893-2. NOT read in this session; every condition below
# is the SASBDB one (paper preferred, SASBDB used: FLAGGED).
#
# Buffer (SASBDB only): "25 mM Tris buffer, 150 mM NaCl, and 0.5 mM TCEP", pH 7.5, 20 °C.
# Tris is titrated with HCl (counter-ion chloride).
#
# Instrument and conditions: in-house SAXS, Aarhus University (SASBDB: Department of
# Chemistry, iNANO); wavelength 1.34 (SASBDB lists "1.34", a value that only makes sense
# in Å for an in-house source: read as Å, FLAGGED, SASBDB gives no unit), energy = hc/λ ≈
# 9253 eV; temperature: SASBDB.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 105 usable points, q from 0.0098 to 0.416 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDXF3_fit1_model1.pdb (one structure; 11950 heavy atoms + 0
# H; 1512 residues, 11950 atom records) and no depositor fit. The deposited hydrogens (if
# any) are replaced: pdb2pqr rebuilds them at PH. SIZE: 11950 heavy atoms.
#
# The SASBDB .fit (software "Other", header χ² 0.8276) is NOT reproduced from its own
# columns (recomputed against the .dat: 5.3), so it is left out as a reference curve and
# the depositor χ² is not passed (reference-less run); the AlphaFold model is a two-chain
# (dimer) model with no hydrogens.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, wavelength 1.34 Å
const TEMPERATURE_C = 20.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 25 mM Tris at pH 7.5 (tris template: Clarke-Glew pK at 22 °C, pH taken as set at 22 ± 3
# °C, repository convention, notes/buffer-templates.md section 2; Davies activities at the
# self-consistent I ≈ 0.171 M): 21.44 mM of the Tris is the protonated cation, whose
# counter-ion is Cl⁻ (σ 1.06 mM from σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift
# and ±2 % on C). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),              # 25 mM Tris, ±2 %
    # Cl⁻ of the HCl titration (see above)
    NonBiological(0.021438, 0.001065, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),     # 150 mM NaCl, ±2 %
    NonBiological(0.0005, 1e-05, "tcep"),              # 0.5 mM TCEP, ±2 %
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from the
# diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and bins the
# curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the hydrogens are built by pdb2pqr at PH (see the model note above).
const ADD_HYDROGENS = true

# Largest q fitted (Å⁻¹); Inf = the whole curve (the whole curve is fitted).
const Q_MAX_FIT = Inf

# One run per atomic model; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = nothing,
    pdb = "SASDXF3_fit1_model1.pdb",
    fit = nothing,
    fitScale = 1.0,
    fitCol = 0,
    rescale = false,
    software = "none",
),   # no depositor fit: no reference curve and no refChi2 (see the header)
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

# Builds the Seed that `runSasdxf3` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdxf3` below is the whole story (build the seed, then
# sample it).
function seedSasdxf3(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxf3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdxf3(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxf3(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
    # run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
    fitCurve =
        run.fit === nothing ? nothing :
        try
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

    # `@__DIR__` (this SASDXF3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
