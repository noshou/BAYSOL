# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDZD6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDZD6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDZD6: transducin-bound phosphodiesterase-6 (PDE6 alpha/beta, gamma,
# transducin-alpha*) active state, protein complex with ligands.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: none listed by SASBDB; every condition below is the SASBDB one (FLAGGED).
#
# Buffer (SASBDB only): "25 mM Tris, 100 mM NaCl, 2 mM MgCl2, 2% glycerol", pH 8.0, 4 °C.
# Tris is titrated with HCl (counter-ion chloride). The 2 % glycerol is taken as v/v
# (SASBDB does not say): 0.274 M with σ 20 % (FLAGGED).
#
# Instrument and conditions: CHESS (SASBDB); wavelength 0.11 nm = 1.10 Å (SASBDB, CHESS),
# energy = hc/λ ≈ 11271 eV; temperature: SASBDB.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 2127 usable points, q from 0.0062 to 0.500 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDZD6_fit1_model1.pdb (one structure; 19438 heavy atoms + 0
# H; 2410 residues, 19438 atom records) and the SASBDB fit file SASDZD6_fit1.fit (FoXS fit
# file (q, exp, model, error), column 3 = model intensity; the SASBDB header chi2 is
# 5.271; recomputed: 5.342 (column 3 = model; FoXS layout q, exp, model, error); the
# depositor χ² used here is 5.271). The deposited hydrogens (if any) are replaced: pdb2pqr
# rebuilds them at PH. SIZE: 19438 heavy atoms.
#
# SIZE: PDB 7JSN, 19438 heavy atoms (large, six chains, 249 kDa) with the ligands GTP,
# 35G, VDN and Zn²⁺/Mg²⁺ (all in the component table; their protonation is not verified:
# first-run check). The FoXS .fit covers q to 0.30 Å⁻¹ and is in the column order q, exp,
# model, error. SASBDB lists no publication.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.1   # ≈ 11271 eV, wavelength 1.1 Å
const TEMPERATURE_C = 4.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 25 mM Tris at pH 8.0 (tris template: Clarke-Glew pK at 22 °C, pH taken as set at 22 ± 3
# °C, repository convention, notes/buffer-templates.md section 2; Davies activities at the
# self-consistent I ≈ 0.122 M): 16.26 mM of the Tris is the protonated cation, whose
# counter-ion is Cl⁻ (σ 1.83 mM from σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift
# and ±2 % on C). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),              # 25 mM Tris, ±2 %
    # Cl⁻ of the HCl titration (see above)
    NonBiological(0.016263, 0.001829, "chloride"),
    NonBiological(0.1, 0.002, "sodium chloride"),      # 100 mM NaCl, ±2 %
    NonBiological(0.002, 4e-05, "magnesium chloride"), # 2 mM MgCl2, ±2 %
    # 2 % glycerol taken as v/v (0.274 M), ±20 %
    NonBiological(0.274, 0.055, "glycerol"),
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

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "FoXS 5.271",
    pdb = "SASDZD6_fit1_model1.pdb",
    fit = "SASDZD6_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
    rescale = false,
    software = "FoXS",
),   # deposited χ² FoXS 5.271
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

# Builds the Seed that `runSasdzd6` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdzd6` below is the whole story (build the seed, then
# sample it).
function seedSasdzd6(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdzd6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdzd6(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdzd6(run)

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

    # `@__DIR__` (this SASDZD6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
