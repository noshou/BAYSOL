# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDML3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDML3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDML3: Mycobacterium phage TipsytheTRex immunity repressor bound to 24mer DNA.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1038/s41467-022-31678-6 (Nat. Commun. 2022, "A monomeric mycobacteriophage
# immunity repressor utilizes two domains to recognize an asymmetric DNA sequence"), read as
# the PMC full text. Read (Methods, SEC-SAXS-MALS): "a 140 µL sample ... prepared in 20 mM
# Tris pH 7.5, 0.5 M NaCl, and 1 mM DTT. SEC-SAXS-MALS data were collected at the ALS
# beamline 12.3.1 ... The X-ray wavelength was set at λ = 1.127 Å ... q ranging from 0.01
# Å⁻¹ to 0.4 Å⁻¹ ... All experiments were performed at 20 °C". The paper compares the
# crystal structure (7R6R) with the protein:24-bp curve with FoXS (χ² = 1.6). The SASBDB
# entry (SASDML3) holds a BILBOMD model, not the crystal structure; the depositor's fit is
# FoXS against that model.
#
# Instrument and conditions: ALS 12.3.1 SIBYLS (SASBDB and paper); wavelength 1.127 Å
# (paper), energy = hc/λ ≈ 11001 eV; 20 °C (paper).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A), 707 points, q from 0.0098 to
# 0.403 Å⁻¹; NO nm⁻¹ conversion is applied. The data extend beyond the depositor's fit: the
# depositor's fit ends at 0.3002 Å⁻¹, the curve at 0.403 Å⁻¹; the 186 points above the fit
# range (σ > 0) have a median I/σ of 0.06 and 85 of them (46 %) have I ≤ 0. No q cut: the
# whole deposited curve is fitted, `seedModel` drops the non-positive bins. The rule of
# test/fitting_tests/README.md (a tail is cut only if its median I/σ is below 0.5 or 25 % of
# it is non-positive) is not met anywhere in the curve.
#
# Model and depositor fit: SASBDB gives one fit, FoXS (fit1) against SASDML3_fit1_model1.pdb
# (one structure; 2650 heavy atoms + 2160 H; 251 residues). The .fit file: 520 rows, q
# 0.0109-0.3002 Å⁻¹; the header reads "Chi^2 = 1.624" for 705 points, the file lists only
# the 520 rows up to 0.300 Å⁻¹ and gives 1.661 on them; recomputed from the .fit columns
# over the usable rows: 1.6607; the depositor's χ² used here is 1.624. Cleaned copy: the
# deposited model uses names the hydrogenator does not recognise as nucleotides or amino
# acids or that are not in the component table, so the fit reads
# `SASDML3_fit1_model1_clean.pdb` (the original `SASDML3_fit1_model1.pdb` is kept next to
# it): HSD: 204 atom records. Nothing else was changed. The deposited model carries 2160
# hydrogen records; pdb2pqr (AMBER, no PROPKA for the nucleic acid alone; PARSE + PROPKA for
# protein-nucleic acid files) rebuilds them at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.127   # ≈ 11001 eV, wavelength 1.127 Å
const TEMPERATURE_C = 20.0   # paper (all experiments at 20 °C)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl: the pH is set with HCl, so the titrant counter-ion
# is Cl⁻ = C x (1 - f), f the deprotonated fraction (pK(Tris) and its temperature dependence
# from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902: 8.072, ΔH 47.45 kJ/mol, ΔCp -59 J/K/mol); pH taken as set at 22 ± 3 °C
# (ASSUMPTION, the source gives no setting temperature), Davies-corrected at I ≈ 0.517 M
# (0.5 M NaCl); Cl⁻ = 0.01721 M. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift and ±2 % on C: 0.00084 M. The same recipe reproduces the repository's SASDGF3 value
# (Tris 0.020, Cl⁻ 0.01710). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM, ±2 %
    # Cl⁻ counter-ion of the HCl titration of Tris (see the note above)
    NonBiological(0.017212, 0.00084, "chloride"),
    NonBiological(0.5, 0.005, "sodium chloride"),   # 0.5 M, ±1 %
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
    tag = "fit1_model1",
    refChi2 = "FoXS 1.624",
    pdb = "SASDML3_fit1_model1_clean.pdb",
    fit = "SASDML3_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),   # deposited χ² = FoXS 1.624
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

# Builds the Seed that `runSasdml3` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdml3` below is the whole story (build the seed, then
# sample it).
function seedSasdml3(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdml3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdml3(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdml3(run)

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

    # `@__DIR__` (this SASDML3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
