# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMA6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMA6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMA6: Long promoter sequences form higher-order G-quadruplexes: an integrative
# structural biology study of c-Myc, k-Ras and c-Kit promoter sequences (the entry is the
# 22-nt kRas promoter G-quadruplex, hybrid form,
# PDB 5I2V, 7.0 kDa; sequence AGGGCGGTGTGGGAATAGGGAA).
#
# Paper: Monsen RC, DeLeeuw LW, Dean WL, et al., Nucleic Acids Res (2022), DOI
# 10.1093/nar/gkac182. SASBDB entry: https://www.sasbdb.org/data/SASDMA6/ . The paper was
# NOT consulted again for this entry: it is the same deposition as SASDM96 and SASDM76
# (same instrument, same BPEK buffer, same temperature). The values below come from the
# SASBDB record (REST summary, read 2026-11-12) and agree with those two scripts.
#
# Sample: co-flow SEC-SAXS, 3.5 mg/mL, sample volume 320 µL.
# Instrument: Advanced Photon Source BioCAT 18ID, Pilatus3 X 1M, wavelength 0.1033 nm =
# 1.033 Å => energy = hc/λ ≈ 12002 eV (hc = 12398.42 eV·Å). Sample temperature: 22 °C
# (SASBDB cell temperature; the storage temperature is not stated).
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
# rows with a non-positive intensity are dropped by `seedModel` after binning.
#
# Model (fit1_model1; SASBDB lists Chimera 1.15 as the software, type "atomic", from the
# 5I2V NMR structure): 714 atoms incl. 246 hydrogens; it keeps the RCSB 5I2V header
# (HEADER/TITLE/COMPND) and carries ATOM records for the 22 nt and two K⁺ ions named `K`
# (HETATM, residues 101 and 102). Same layout as SASDM96 and SASDM76; the file is used as
# downloaded (nothing was cleaned).
#
# Depositor fit: CRYSOL (no version stated), header "Chi^2: 3.003" (Dro:0.072), the
# SASBDB REST chi_square_value is also 3.003. Recomputing (1/N) Σ ((I_exp − I_fit)/σ)²
# from the .fit columns (1202 rows) gives 3.0035 (N − 1: 3.0060); the header
# value 3.003 is used (the small difference to the recomputation was not
# investigated).
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

# No q cut: the whole deposited curve (q 0.0045-0.3526 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.3 Å⁻¹ was used before, but the 183 points above 0.3
# Å⁻¹ (σ > 0) have a median I/σ of 1.15 and 25 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 1.15 ≥ 0.5; median I/σ 1.49 ≥ 1 in the
# lowest-q quarter (up to 0.31 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model already carries 246 hydrogens; as for SASDM76 (same writer, same
# layout) pdb2pqr rebuilds them from the heavy atoms.
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 3.003",
    pdb = "SASDMA6_fit1_model1.pdb",
    fit = "SASDMA6_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # 5I2V quadruplex with 246 H and 2 K; deposited χ² = 3.003
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

# Builds the Seed that `runSasdma6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdma6` below is the whole story (build the seed, then sample it).
function seedSasdma6(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdma6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdma6(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdma6(run)

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

    # `@__DIR__` (this SASDMA6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
