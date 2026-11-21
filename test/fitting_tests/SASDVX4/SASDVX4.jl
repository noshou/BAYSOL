# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVX4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVX4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVX4: ST9a RNA, WT (59 nucleotides in 10 mM MgCl2; monomer).
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1093/nar/gkaf840 (Nucleic Acids Res. 2025, ST9a exoribonuclease-resistant
# RNA with a 9-bp pseudoknot), read as the PMC full text. Read: "RNAs were buffer-exchanged
# into SAXS buffer (50 mM Tris-HCl pH 7.5, 100 mM sodium chloride, 1 mM DTT, either with or
# without 10 mM MgCl2) ... SEC-SAXS ... at the 16-ID (LiX) beamline, NSLS-II ... Superdex
# 200 Increase pre-equilibrated in SAXS buffer with or without MgCl2". The paper's text
# gives neither the temperature nor the wavelength of the SAXS runs; both are SASBDB values
# (20 °C; 0.082 nm = 0.82 Å). 0.0002 % (w/v) NaN3 is from SASBDB (not in the sentence of the
# paper). This entry is the with-Mg²⁺ condition.
#
# Instrument and conditions: NSLS-II 16-ID LiX (SASBDB); wavelength 0.082 nm = 0.82 Å,
# energy = hc/λ ≈ 15120 eV; 20 °C (SASBDB).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit 1/nm), 230 points, q from 0.0060 to
# 1.900 Å⁻¹ after dividing by NM_INV_PER_ANGSTROM_INV. The data extend beyond the
# depositor's fit: the depositor's fit ends at 1.4800 Å⁻¹, the curve at 1.900 Å⁻¹; the 14
# points above the fit range (σ > 0) have a median I/σ of 2.00 and 0 of them (0 %) have I ≤
# 0. No q cut: the whole deposited curve is fitted, `seedModel` drops the non-positive bins.
# The rule of test/fitting_tests/README.md (a tail is cut only if its median I/σ is below
# 0.5 or 25 % of it is non-positive) is not met anywhere in the curve. The curve reaches 1.9
# Å⁻¹ with I/σ of about 2-3 throughout (no noise tail by the rule), so it is fitted whole;
# at that q the forward model needs a high spherical-harmonic order (see open points).
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL (fit1) against
# SASDVX4_fit1_model1.pdb (one structure; 1177 heavy atoms + 0 H; 56 residues). The .fit
# file: 214 rows, q 0.0080-1.4800 Å⁻¹; the header value is the depositor's χ²; recomputed
# from the .fit columns over the usable rows: 5.8873; the depositor's χ² used here is 5.915.
# The deposited model has heavy atoms only; pdb2pqr (AMBER, no PROPKA for the nucleic acid
# alone; PARSE + PROPKA for protein-nucleic acid files) builds the hydrogens at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # qvals are in nm⁻¹; convert to Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 0.82   # ≈ 15120 eV, wavelength 0.82 Å
const TEMPERATURE_C = 20.0   # SASBDB only (the paper text read gives no SAXS temperature)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl: the pH is set with HCl, so the titrant counter-ion
# is Cl⁻ = C x (1 - f), f the deprotonated fraction (pK(Tris) and its temperature dependence
# from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902: 8.072, ΔH 47.45 kJ/mol, ΔCp -59 J/K/mol); pH taken as set at 22 ± 3 °C
# (ASSUMPTION, the source gives no setting temperature), Davies-corrected at I ≈ 0.173 M
# (0.1 M NaCl + 10 mM MgCl2); Cl⁻ = 0.04288 M. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 %
# of the Davies shift and ±2 % on C: 0.00213 M. The same recipe reproduces the repository's
# SASDGF3 value (Tris 0.020, Cl⁻ 0.01710). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM, ±2 %
    # Cl⁻ counter-ion of the HCl titration of Tris (see the note above)
    NonBiological(0.042879, 0.00213, "chloride"),
    NonBiological(0.1, 0.001, "sodium chloride"),   # 100 mM, ±1 %
    NonBiological(0.01, 0.0002, "magnesium chloride"),   # 10 mM, ±2 %
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM DTT, ±2 %
    NonBiological(0.0000308, 0.0000006, "sodium azide"),   # 0.0002 % w/v NaN3, ±2 %
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
    refChi2 = "CRYSOL 5.915",
    pdb = "SASDVX4_fit1_model1.pdb",
    fit = "SASDVX4_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 5.915
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

# Builds the Seed that `runSasdvx4` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdvx4` below is the whole story (build the seed, then
# sample it).
function seedSasdvx4(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvx4(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdvx4(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvx4(run)

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

    # `@__DIR__` (this SASDVX4/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
