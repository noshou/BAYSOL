# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDPD3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPD3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPD3: ESS2p (HIV-1 splice-site A3 regulatory RNA), RNA, depositor atomic fit.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1016/j.jmb.2022.167728 (J. Mol. Biol. 2022, "Encoded Conformational
# Dynamics of the HIV Splice Site A3 Regulatory Locus"). NOT read in this session; the
# buffer is the SASBDB one (FLAGGED: paper preferred, SASBDB used).
#
# Buffer (SASBDB only): "20 mM Bis-Tris, 20 mM NaCl", pH 6.2. SASBDB gives NEITHER a
# temperature NOR a wavelength: 25 °C and 1.033 Å (Advanced Photon Source, 12 keV) are the
# accepted defaults (FLAGGED). Bis-Tris is titrated with HCl (repository `bis-tris`
# template), so its chloride is the counter-ion.
#
# Instrument and conditions: Advanced Photon Source (SASBDB); the wavelength and the
# temperature are not stated by SASBDB (defaults above).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 1257 usable points, q from 0.0110 to 0.387 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDPD3_fit1_model1.pdb (one structure; 908 heavy atoms + 461
# H; 43 residues, 1369 atom records) and the SASBDB fit file SASDPD3_fit1.fit (SASBDB fit
# file (sExp, iExp, Err, iFit+Const), column 4 = fitted intensity; the SASBDB header chi2
# is 1.458; recomputed: 1.455 from the .fit own columns; the depositor χ² used here is
# 1.458). Cleaned copy: the deposited records are not read as nucleotides or ions as
# written (HETATM records, terminal residue names, ion naming), so the fit reads
# `SASDPD3_fit1_model1_clean.pdb` (the original `SASDPD3_fit1_model1.pdb` is kept next to
# it): G5->G: 32 atom records, C3->C: 32 atom records. Nothing else was changed. The
# deposited hydrogens (if any) are replaced: pdb2pqr rebuilds them at PH.
#
# The depositor fit covers 693 of the 1257 data points (q from 0.0146 Å⁻¹; SASBDB labels
# the fit DAMMIN although the .fit is an atomic-model fit "iFit(+Const)", a constant is
# added to the model curve), so its χ² covers a narrower q range than this fit (the
# SASDWT5/SASDMU4 precedent); the whole curve is fitted here.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.2, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, wavelength 1.033 Å
const TEMPERATURE_C = 25.0   # DEFAULT, unstated (FLAGGED)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 20 mM Bis-Tris at pH 6.2 (bis-tris template, whose pK is not independently verified in
# the repository table: Clarke-Glew pK at 22 °C, pH taken as set at 22 ± 3 °C, repository
# convention, notes/buffer-templates.md section 2; Davies activities at the self-
# consistent I ≈ 0.034 M): 14.39 mM of the Bis-Tris is the protonated cation, whose
# counter-ion is Cl⁻ from the HCl titration (σ 1.1 mM from σ_pH = 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on C). The RNA is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "bis-tris"),           # 20 mM Bis-Tris, ±2 %
    # Cl⁻ of the HCl titration (see above)
    NonBiological(0.014388, 0.0011, "chloride"),
    NonBiological(0.02, 0.0004, "sodium chloride"),    # 20 mM NaCl, ±2 %
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
    refChi2 = "SASBDB fit 1.458",
    pdb = "SASDPD3_fit1_model1_clean.pdb",
    fit = "SASDPD3_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "SASBDB fit",
),   # deposited χ² SASBDB fit 1.458
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

# Builds the Seed that `runSasdpd3` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdpd3` below is the whole story (build the seed, then
# sample it).
function seedSasdpd3(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpd3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdpd3(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpd3(run)

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

    # `@__DIR__` (this SASDPD3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
