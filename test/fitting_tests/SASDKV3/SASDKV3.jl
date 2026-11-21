# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDKV3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDKV3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDKV3: III-IV-V three-way junction J345 of the Neurospora Varkud satellite (VS)
# ribozyme.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1093/nar/gkab963 (Nucleic Acids Research 2021, "An integrative NMR-SAXS
# approach for structural determination of large RNAs defines the substrate recognition
# mechanism of the VS ribozyme"), read as the PMC full text (Europe PMC XML). Read: the
# Methods ("SAXS-5 buffer (SAXS buffer with 5 mM MgCl2)", "all SAXS data collection was
# performed at 20°C, either on the G-1 beamline at the Cornell High Energy Synchrotron
# Source (MacCHESS; for SL6, J345 and J236) ...") and the SAXS buffer (MES pH 6.5, KCl) as
# read for the sibling entry SASDKY3. The Fig. 4 caption says "NMRG-5 buffer" where the
# Methods say "SAXS-5"; both name the same MES/KCl/MgCl2 buffer and agree with SASBDB. The
# paper's own CRYSOL settings (qmax 0.3 Å⁻¹) were not read for these three subdomains; the
# depositor's fit ends at 0.3005 Å⁻¹.
#
# Instrument and conditions: Cornell High Energy Synchrotron Source (CHESS) G1 (SASBDB);
# wavelength 0.1245 nm = 1.245 Å (SASBDB; the paper gives no wavelength in the text read),
# energy = hc/λ ≈ 9959 eV; cell 20 °C.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A), 749 points, q from 0.0119 to
# 0.970 Å⁻¹; NO nm⁻¹ conversion is applied. The data extend beyond the depositor's fit: the
# depositor's fit ends at 0.3005 Å⁻¹, the curve at 0.970 Å⁻¹; the 331 points above the fit
# range (σ > 0) have a median I/σ of 2.50 and 7 of them (2 %) have I ≤ 0. No q cut: the
# whole deposited curve is fitted, `seedModel` drops the non-positive bins. The rule of
# test/fitting_tests/README.md (a tail is cut only if its median I/σ is below 0.5 or 25 % of
# it is non-positive) is not met anywhere in the curve.
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL (fit1) against
# SASDKV3_fit1_model1.pdb (one structure; 999 heavy atoms + 508 H; 47 residues). The .fit
# file: 424 rows, q 0.0000-0.3005 Å⁻¹; the header value is the depositor's χ²; recomputed
# from the .fit columns over the usable rows: 0.8312; the depositor's χ² used here is 0.834.
# Cleaned copy: the deposited model uses names the hydrogenator does not recognise as
# nucleotides or amino acids or that are not in the component table, so the fit reads
# `SASDKV3_fit1_model1_clean.pdb` (the original `SASDKV3_fit1_model1.pdb` is kept next to
# it): RG5: 32 atom records, RG3: 35 atom records. Nothing else was changed. The deposited
# model carries 508 hydrogen records; pdb2pqr (AMBER, no PROPKA for the nucleic acid alone;
# PARSE + PROPKA for protein-nucleic acid files) rebuilds them at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.5, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.245   # ≈ 9959 eV, wavelength 1.245 Å
const TEMPERATURE_C = 20.0   # paper (all SAXS collection at 20 °C)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Buffer (paper, "SAXS data collection and analysis"; SASBDB
# agrees): 50 mM MES pH 6.5, 50 mM KCl, 5 mM MgCl2. The macromolecule is deliberately NOT a
# solute. Counter-ion (convention of SASDKY3, the same buffer of the same paper, whose
# derivation is reused unchanged): the pH of MES is set with NaOH, the titrant is not
# stated. pH taken as set at 22 ± 3 °C with pK(MES, 22 °C) = 6.296, Davies (A = 0.509, g(I)
# = √I/(1+√I) - 0.3 I) at the self-consistent ionic strength (0.0986 M), so Na⁺ = 0.050 x
# 0.6715 = 0.03358 M; σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and
# ±2 % on C: 0.00289 M. The RNA's own charge is neglected. Not modelled: Mg²⁺ binding to the
# RNA.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "mes"),   # 50 mM, ±2 %
    NonBiological(0.05, 0.0005, "potassium chloride"),   # 50 mM, ±1 %
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM, ±2 %
    # Na⁺ counter-ion from the NaOH titration of MES (see the note above)
    NonBiological(0.03358, 0.00289, "sodium(1+)"),
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
    refChi2 = "CRYSOL 0.834",
    pdb = "SASDKV3_fit1_model1_clean.pdb",
    fit = "SASDKV3_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 0.834
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

# Builds the Seed that `runSasdkv3` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdkv3` below is the whole story (build the seed, then
# sample it).
function seedSasdkv3(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdkv3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdkv3(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdkv3(run)

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

    # `@__DIR__` (this SASDKV3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
