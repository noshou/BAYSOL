# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDMN6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMN6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMN6: cKit-12 (c-Kit promoter, 12-repeat construct), G-quadruplex DNA, BPEK
# buffer.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1093/nar/gkac182 (Nucleic Acids Res. 2022, "Long promoter sequences form
# higher-order G-quadruplexes: an integrative structural biology study of c-Myc, k-Ras and
# c-Kit promoter sequences"). The buffer text below is the one read from the PMC full text
# for the sibling entry SASDMJ6 (same paper, same buffer): "Two separate buffers were used
# throughout: TBAP ... and BPEK (potassium phosphate). Buffers contained 1 mM EDTA and had
# a pH of either 6.8 (TBAP) or 7.2 (BPEK)"; "All samples analyzed by [SAXS] were in BPEK
# buffer supplemented with 185 mM KCl"; SEC-SAXS at the BioCAT beamline (18ID), APS. The
# paper text does NOT give the phosphate concentration, the SAXS temperature or the
# wavelength.
#
# Buffer source: pH, KCl and EDTA from the paper (above); the total phosphate (8 mM) and
# the temperature come from SASBDB only (FLAGGED FALLBACK): SASBDB writes "6 mM Na2HPO4, 2
# mM NaH2PO4, 1 mM Na2EDTA, 185 mM KCl, pH 7.2 (BPEK buffer)". The paper calls the buffer
# potassium phosphate while the SASBDB line writes Na salts, and the weighed 6:2 ratio is
# not the HPO4/H2PO4 ratio of pH 7.2 (about 0.70), so the species are computed from the pH
# with potassium as the cation (the paper wording), as in SASDMJ6.
#
# Instrument and conditions: Advanced Photon Source BioCAT 18-ID (SASBDB); wavelength
# 0.1033 nm = 1.033 Å, energy = hc/λ ≈ 12002 eV; 22 °C (SASBDB).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 1221 usable points, q from 0.0043 to 0.353 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDMN6_fit1_model1.pdb (one structure; 1362 heavy atoms + 708
# H; 67 residues, 2070 atom records) and the SASBDB fit file SASDMN6_fit1.fit (CRYSOL,
# column 4 = fitted intensity; the SASBDB header chi2 is 4.065; recomputed: 4.126; the
# depositor χ² used here is 4.065). Cleaned copy: the deposited records are not read as
# nucleotides or ions as written (HETATM records, terminal residue names, ion naming), so
# the fit reads `SASDMN6_fit1_model1_clean.pdb` (the original `SASDMN6_fit1_model1.pdb` is
# kept next to it): DG5->DG: 31 atom records, HETATM->ATOM: 65 atom records, DG3->DG: 34
# atom records, K+ -> K: 3 atom records. Nothing else was changed. The deposited hydrogens
# (if any) are replaced: pdb2pqr rebuilds them at PH.
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
const TEMPERATURE_C = 22.0   # SASBDB only

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 8 mM potassium phosphate at pH 7.2: the HPO4²⁻ fraction is 0.7042 (pK2 and its
# temperature dependence from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data
# 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp -230 J/K/mol) with the pH
# taken as set at 22 ± 3 °C (the repository convention, notes/buffer-templates.md section
# 2), Davies-corrected at I ≈ 0.204 M (0.185 M KCl + the phosphate and its potassium); σ
# combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C (0.0006 M
# on each species). EDTA (1 mM) is entered as the repository `H2EDTA` row, its potassium
# counter-ions (up to 2 mM) are left out. The DNA is deliberately NOT a solute.
const SOLUTES = Solute[
    # 8 mM phosphate (BPEK), H2PO4⁻ part
    NonBiological(0.002366, 0.0006, "potassium dihydrogen phosphate"),
    # 8 mM phosphate (BPEK), HPO4²⁻ part
    NonBiological(0.005634, 0.0006, "dipotassium hydrogen phosphate"),
    NonBiological(0.185, 0.00185, "potassium chloride"), # 185 mM, ±1 %
    NonBiological(0.001, 2e-05, "H2EDTA"),             # 1 mM EDTA, ±2 %
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
    refChi2 = "CRYSOL 4.065",
    pdb = "SASDMN6_fit1_model1_clean.pdb",
    fit = "SASDMN6_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² CRYSOL 4.065
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

# Builds the Seed that `runSasdmn6` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdmn6` below is the whole story (build the seed, then
# sample it).
function seedSasdmn6(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdmn6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdmn6(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdmn6(run)

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

    # `@__DIR__` (this SASDMN6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
