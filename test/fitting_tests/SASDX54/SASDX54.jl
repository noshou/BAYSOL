# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDX54")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDX54.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDX54: precursor microRNA 20a (pre-miR-20a).
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1016/j.jmb.2025.169317 (J. Mol. Biol. 2025, pre-miR-20a NMR/Dicer study),
# read as the PMC full text. Read: Methods, SAXS: "SAXS buffer contained 50 mM potassium
# phosphate buffer, pH 7.5, 50 mM NaCl, 1 mM MgCl2, and all data were collected at 22 °C".
# SASBDB adds 5 mM BME (not in the sentence of the paper; a neutral reductant, omitted from
# the solutes). Co-flow SEC-SAXS at the BioCAT beamline 18-ID, APS (SASBDB: wavelength
# 0.1033 nm = 1.033 Å, 22 °C).
#
# Instrument and conditions: Advanced Photon Source BioCAT 18-ID (SASBDB); wavelength 0.1033
# nm = 1.033 Å, energy = hc/λ ≈ 12002 eV; 22 °C.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A), 1698 points, q from 0.0029 to
# 0.420 Å⁻¹; NO nm⁻¹ conversion is applied. No q cut: the whole deposited curve is fitted,
# `seedModel` drops the non-positive bins. The rule of test/fitting_tests/README.md (a tail
# is cut only if its median I/σ is below 0.5 or 25 % of it is non-positive) is not met
# anywhere in the curve.
#
# Model and depositor fit: SASBDB gives one fit, FoXS (fit1) against SASDX54_fit1_model1.pdb
# (one structure; 1548 heavy atoms + 781 H; 73 residues). The .fit file: 1698 rows, q
# 0.0029-0.4201 Å⁻¹; header 0.8785 equals the recomputation with column 3 as the model and
# column 4 as σ; recomputed from the .fit columns over the usable rows: 0.8785; the
# depositor's χ² used here is 0.879. Cleaned copy: the deposited model uses names the
# hydrogenator does not recognise as nucleotides or amino acids or that are not in the
# component table, so the fit reads `SASDX54_fit1_model1_clean.pdb` (the original
# `SASDX54_fit1_model1.pdb` is kept next to it): G5: 32 atom records, C3: 32 atom records.
# Nothing else was changed. The deposited model carries 781 hydrogen records; pdb2pqr
# (AMBER, no PROPKA for the nucleic acid alone; PARSE + PROPKA for protein-nucleic acid
# files) rebuilds them at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, wavelength 1.033 Å
const TEMPERATURE_C = 22.0   # paper (all data at 22 °C)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). "50 mM potassium phosphate" is a mix of KH2PO4 and K2HPO4 at
# pH 7.5: the HPO4²⁻ fraction is 0.8237 (pK2 and its temperature dependence from Goldberg,
# Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH
# 3.6 kJ/mol, ΔCp -230 J/K/mol) with the pH taken as set at 22 ± 3 °C (ASSUMPTION: the paper
# does not say at which temperature the pH was set), Davies-corrected at I ≈ 0.185 M (0.05 M
# NaCl + 1 mM MgCl2 + the phosphate and its potassium). σ combines σ_pH = 0.1, ±3 °C, ±0.02
# pK, 30 % of the Davies shift and ±2 % on C (0.0027 M on each species). The macromolecule
# is deliberately NOT a solute.
const SOLUTES = Solute[
    # 50 mM KPi, H2PO4⁻ part
    NonBiological(0.008813, 0.0027, "potassium dihydrogen phosphate"),
    # 50 mM KPi, HPO4²⁻ part
    NonBiological(0.041187, 0.0027, "dipotassium hydrogen phosphate"),
    NonBiological(0.05, 0.0005, "sodium chloride"),   # 50 mM, ±1 %
    NonBiological(0.001, 0.00002, "magnesium chloride"),   # 1 mM, ±2 %
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from the
# diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and bins the
# curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the hydrogens are built by pdb2pqr at PH (see the model note above).
const ADD_HYDROGENS = true

# Largest q fitted (Å⁻¹); Inf = the whole curve (see the q note in the header).
const Q_MAX_FIT = Inf

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "FoXS 0.879",
    pdb = "SASDX54_fit1_model1_clean.pdb",
    fit = "SASDX54_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
    rescale = false,
    software = "FoXS",
),   # deposited χ² = FoXS 0.879
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

# Builds the Seed that `runSasdx54` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdx54` below is the whole story (build the seed, then
# sample it).
function seedSasdx54(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdx54(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdx54(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdx54(run)

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

    # `@__DIR__` (this SASDX54/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
