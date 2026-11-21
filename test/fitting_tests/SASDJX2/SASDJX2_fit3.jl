# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJX2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJX2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJX2: Modification-dependent EcoKMcrA restriction endonuclease in complex with
# cognate hemimethylated 12-bp oligoduplex.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1093/nar/gky731 (Nucleic Acids Res. 2018, "Activity and structure of
# EcoKMcrA"), read as the PMC full text. Read: "All samples were transferred into the buffer
# containing 20 mM Tris-HCl pH 7.5, 200 mM KCl, 0.1 mM EDTA, 0.01% (w/v) sodium azide and 1
# mM DTT using desalting columns NAP5". The text read gives no SAXS temperature or
# wavelength; SASBDB gives 20 °C and 0.124 nm (P12). The entry has three fits; fit1 (SASREF,
# coarse model without hydrogens) and fit2 (CRYSOL, a second dimer conformation) are not
# used; this script uses fit3 (CRYSOL, chi2 1.513, one structure with two protein chains and
# two DNA strands).
#
# Instrument and conditions: PETRA III EMBL P12 (SASBDB); wavelength 0.124 nm = 1.24 Å,
# energy = hc/λ ≈ 9999 eV; 20 °C (SASBDB).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit 1/nm), 1727 points, q from 0.0076 to
# 0.467 Å⁻¹ after dividing by NM_INV_PER_ANGSTROM_INV. No q cut: the whole deposited curve
# is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASBDB gives three fits, fit3 is used, CRYSOL (fit3) against
# SASDJX2_fit3_model1.pdb (one structure; 4882 heavy atoms + 0 H; 578 residues). The .fit
# file: 1678 rows, q 0.0000-0.4665 Å⁻¹; the header reads "Chi^2: 1.513" and matches the
# recomputation; recomputed from the .fit columns over the usable rows: 1.5134; the
# depositor's χ² used here is 1.513. The deposited model has heavy atoms only; pdb2pqr
# (AMBER, no PROPKA for the nucleic acid alone; PARSE + PROPKA for protein-nucleic acid
# files) builds the hydrogens at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # qvals are in nm⁻¹; convert to Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, wavelength 1.24 Å
const TEMPERATURE_C = 20.0   # SASBDB only (the paper text read gives no SAXS temperature)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl: the pH is set with HCl, so the titrant counter-ion
# is Cl⁻ = C x (1 - f), f the deprotonated fraction (pK(Tris) and its temperature dependence
# from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902: 8.072, ΔH 47.45 kJ/mol, ΔCp -59 J/K/mol); pH taken as set at 22 ± 3 °C
# (ASSUMPTION, the source gives no setting temperature), Davies-corrected at I ≈ 0.217 M
# (0.2 M KCl); Cl⁻ = 0.01718 M. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift and ±2 % on C: 0.00085 M. The same recipe reproduces the repository's SASDGF3 value
# (Tris 0.020, Cl⁻ 0.01710). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM, ±2 %
    # Cl⁻ counter-ion of the HCl titration of Tris (see the note above)
    NonBiological(0.017183, 0.00085, "chloride"),
    NonBiological(0.2, 0.002, "potassium chloride"),   # 200 mM, ±1 %
    NonBiological(0.0001, 0.000002, "H2EDTA"),   # 0.1 mM EDTA, ±2 %
    NonBiological(0.001538, 0.00003, "sodium azide"),   # 0.01 % w/v NaN3, ±2 %
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM DTT, ±2 %
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
    tag = "fit3_model1",
    refChi2 = "CRYSOL 1.513",
    pdb = "SASDJX2_fit3_model1.pdb",
    fit = "SASDJX2_fit3.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 1.513
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

# Builds the Seed that `runSasdjx2` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdjx2` below is the whole story (build the seed, then
# sample it).
function seedSasdjx2(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjx2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdjx2(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = "_fit3"

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjx2(run)

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

    # `@__DIR__` (this SASDJX2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
