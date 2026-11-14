# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDM96")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDM96.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDM96: Long promoter sequences form higher-order G-quadruplexes: an integrative
# structural biology study of c-Myc, k-Ras and c-Kit promoter sequences (the entry is the
# 24-nt human telomere quadruplex 2GKU, hybrid-1 topology, 7.7 kDa).
#
# Paper: Monsen RC, DeLeeuw LW, Dean WL, et al., Nucleic Acids Res (2022), DOI
# 10.1093/nar/gkac182 (consulted via Europe PMC for the buffer). SASBDB entry:
# https://www.sasbdb.org/data/SASDM96/
#
# Sample: co-flow SEC-SAXS. Instrument: Advanced Photon Source BioCAT 18ID, Pilatus3 X
# 1M, wavelength 0.1033 nm = 1.033 Å => energy = hc/λ ≈ 12002 eV (hc = 12398.42 eV·Å).
# Sample temperature: 22 °C (SASBDB cell temperature).
#
# Buffer (paper, NAR 2022, p. 4129-4130 and SI Table S4): "BPEK (potassium phosphate)
# buffer supplemented with 185 mM KCl", 1 mM EDTA, pH 7.2, 22 °C, 1.033 Å. The paper is the
# source of truth (owner rule, 2026-11-13): its potassium phosphate replaces the sodium
# phosphates of the SASBDB comment ("6 mM Na2HPO4, 2 mM NaH2PO4, 1 mM Na2EDTA, 185 mM
# KCl"), which conflicts with the paper's cation. The paper gives no phosphate
# concentrations and no EDTA salt, so the SASBDB concentrations are kept (6 mM
# K2HPO4 + 2 mM KH2PO4) and the EDTA stays the SASBDB disodium salt (not contradicted).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (`_readCurve` keeps the numeric rows);
# rows with a non-positive intensity are dropped by `seedModel` after binning. The model
# (written by Maestro, chain A, 781 atoms incl. 274 hydrogens, from the 2GKU NMR
# structure) carries two K⁺ ions as residues `K` (HETATM), the same layout as the
# SASDM76 model.
#
# Depositor fit: CRYSOL, header "Chi^2: 1.172", the SASBDB REST value is also 1.172, and
# recomputing the reduced χ² from the .fit columns gives 1.1721; 1.172 is used.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 22.0

# Buffer components (the measured macromolecule is deliberately NOT listed). The
# phosphates are the two species already (6 mM K2HPO4 + 2 mM KH2PO4: the paper's
# potassium phosphate with the SASBDB concentrations), so they are used as given: no
# titrant counter-ion is added. "1 mM Na2EDTA" (SASBDB; the paper names no EDTA salt) is
# the disodium salt, i.e. H2EDTA²⁻ with two Na⁺ (the table has the H2EDTA ion and the
# sodium ion).
const SOLUTES = Solute[
    NonBiological(0.185, 0.00185, "potassium chloride"),   # 185 mM, ±1%
    NonBiological(0.006, 0.00012, "dipotassium hydrogen phosphate"),   # 6 mM K2HPO4, ±2%
    NonBiological(0.002, 4e-05, "potassium dihydrogen phosphate"),   # 2 mM KH2PO4, ±2%
    NonBiological(0.001, 2e-05, "H2EDTA"),   # 1 mM Na2EDTA: H2EDTA²⁻ part, ±2%
    NonBiological(0.002, 4e-05, "sodium"),   # 1 mM Na2EDTA: the two Na⁺, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.350 Å⁻¹,
# but the 174 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.30 and 27 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.31 Å⁻¹) has a median I/σ of 0.64.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model already carries 274 hydrogens; as for SASDM76 (same writer, same
# layout) pdb2pqr rebuilds them from the heavy atoms.
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.172",
    pdb = "SASDM96_fit1_model1.pdb",
    fit = "SASDM96_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # 2GKU quadruplex with 274 H and 2 K; deposited χ² = 1.172
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

# Builds the Seed that `runSasdm96` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdm96` below is the whole story (build the seed, then sample it).
function seedSasdm96(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdm96(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdm96(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdm96(run)

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

    # `@__DIR__` (this SASDM96/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
