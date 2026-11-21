# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDMG6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMG6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMG6: 5CMX (31-nt thrombin-binding-aptamer-like G-quadruplex).
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1093/nar/gkac182 (Nucleic Acids Res. 2022, "Long promoter sequences form
# higher-order G-quadruplexes: an integrative structural biology study of c-Myc, k-Ras and
# c-Kit promoter sequences"), read as the PMC full text. Read: "Two separate buffers were
# used throughout: TBAP ... and BPEK (potassium phosphate). Buffers contained 1 mM EDTA and
# had a pH of either 6.8 (TBAP) or 7.2 (BPEK)"; "All samples analyzed by [SAXS] were in BPEK
# buffer supplemented with 185 mM KCl"; SEC-SAXS at the BioCAT beamline (18ID), APS. The
# text read does NOT give the phosphate concentration, the SAXS temperature or the
# wavelength. SASBDB gives "6 mM Na2HPO4, 2 mM NaH2PO4, 1 mM Na2EDTA, 185 mM KCl, pH 7.2
# (BPEK buffer)", 22 °C and 0.1033 nm. FLAGGED FALLBACK: only the total phosphate (8 mM) is
# taken from SASBDB; the paper calls the buffer potassium phosphate while the SASBDB line
# writes Na salts, and the weighed 6:2 ratio of the SASBDB line is not the HPO4/H2PO4 ratio
# of pH 7.2 (about 0.70), so the species are computed from the pH with potassium as the
# cation (the paper's wording).
#
# Instrument and conditions: Advanced Photon Source BioCAT 18-ID (SASBDB); wavelength 0.1033
# nm = 1.033 Å, energy = hc/λ ≈ 12002 eV; 22 °C (SASBDB).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A), 1210 points, q from 0.0047 to
# 0.353 Å⁻¹; NO nm⁻¹ conversion is applied. No q cut: the whole deposited curve is fitted,
# `seedModel` drops the non-positive bins. The rule of test/fitting_tests/README.md (a tail
# is cut only if its median I/σ is below 0.5 or 25 % of it is non-positive) is not met
# anywhere in the curve.
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL (fit1) against
# SASDMG6_fit1_model1.pdb (one structure; 613 heavy atoms + 0 H; 31 residues). The .fit
# file: 1213 rows, q 0.0000-0.3526 Å⁻¹; the .fit file has no header; recomputed from columns
# 2-4 it gives the SASBDB value; recomputed from the .fit columns over the usable rows:
# 1.8543; the depositor's χ² used here is 1.854. The deposited model has heavy atoms only;
# pdb2pqr (AMBER, no PROPKA for the nucleic acid alone; PARSE + PROPKA for protein-nucleic
# acid files) builds the hydrogens at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, wavelength 1.033 Å
const TEMPERATURE_C = 22.0   # SASBDB only (the paper text read gives no SAXS temperature)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). 8 mM potassium phosphate at pH 7.2: the HPO4²⁻ fraction is
# 0.7042 (pK2 and its temperature dependence from Goldberg, Kishore & Lennen 2002, J. Phys.
# Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp -230 J/K/mol)
# with the pH taken as set at 22 ± 3 °C (ASSUMPTION), Davies-corrected at I ≈ 0.204 M (0.185
# M KCl + the phosphate and its potassium); σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift and ±2 % on C (0.0006 M on each species). EDTA (1 mM) is entered as the
# repository's `H2EDTA` row, its potassium counter-ions (up to 2 mM) are left out. The DNA
# is deliberately NOT a solute.
const SOLUTES = Solute[
    # 8 mM phosphate (BPEK), H2PO4⁻ part
    NonBiological(0.002366, 0.0006, "potassium dihydrogen phosphate"),
    # 8 mM phosphate (BPEK), HPO4²⁻ part
    NonBiological(0.005634, 0.0006, "dipotassium hydrogen phosphate"),
    NonBiological(0.185, 0.00185, "potassium chloride"),   # 185 mM, ±1 %
    NonBiological(0.001, 0.00002, "H2EDTA"),   # 1 mM EDTA, ±2 %
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
    refChi2 = "CRYSOL 1.854",
    pdb = "SASDMG6_fit1_model1.pdb",
    fit = "SASDMG6_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 1.854
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

# Builds the Seed that `runSasdmg6` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdmg6` below is the whole story (build the seed, then
# sample it).
function seedSasdmg6(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdmg6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdmg6(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdmg6(run)

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

    # `@__DIR__` (this SASDMG6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
