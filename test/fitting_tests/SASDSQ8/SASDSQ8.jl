# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDSQ8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSQ8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDSQ8: holo-D43 (RNA device 43 in the ligand-bound state, the PD-1 RNA device
# with its ligand tetracycline, three-letter code TAC), RNA, CRYSOL reference fit. Same
# paper and instrument as SASDSP8 (the apo state); this script follows it.
#
# NOT YET RUN: wired on 2026-11-18 without a fit (no run was allowed).
#
# Paper: DOI 10.1093/nar/gkaf156 (Nucleic Acids Res. 2025), not read in this session.
#
# Buffer and conditions (the owner's SI, 2026-11-18): holo-D43 in 10 mM Bis-Tris, 100 mM
# KCl, 1 mM MgCl2, pH 6.8; NSLS-II 16-ID LiX, Pilatus3 S 1M, 3.7 m, λ = 0.08202 nm =
# 0.8202 Å (energy hc/λ ≈ 15117 eV); 1.2 to 10 mg/ml extrapolated to infinite dilution
# and merged; 20 °C; 20 frames x 0.5 s. Bis-Tris is titrated with HCl (repository
# `bis-tris` template), so its chloride is the counter-ion. The TAC concentration is NOT
# in the buffer (owner: not needed): TAC is part of the model only.
#
# Curve units: SASBDB angular_unit "1/A", so NO nm⁻¹ conversion; 181 points, q from
# 0.0050 to 0.800 Å⁻¹. No q cut; `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDSQ8_fit1_model1.pdb (one structure: the RNA with hydrogens,
# 3847 ATOM records, and 53 HETATM records of the ligand TAC, chain A residue 301: 22 C,
# 2 N, 8 O and 21 H) and the SASBDB fit file SASDSQ8_fit1.fit (CRYSOL, column 4 = fitted
# intensity; header chi2 63.691, used as the depositor χ²; not recomputed). TAC is in the
# component table (type "other", non-polymer, C22 H24 N2 O8): a residue that is neither
# amino acid nor nucleotide, so the hydrogenator treats it as a ligand: if pdb2pqr drops
# it, its HEAVY atoms are put back from the input (`_restoreLigandResidues!`) and its
# deposited hydrogens are not (the model has 21 of the 24 of the formula). Only the RNA
# is protonated at PH. As with SASDSP8 the cryo-EM model has missing residues (SASBDB
# comment), so a large χ² (63.7) is expected of both fits.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.8, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 0.8202   # ≈ 15116 eV, wavelength 0.8202 Å
const TEMPERATURE_C = 20.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 10 mM Bis-Tris at pH 6.8 (bis-tris template, whose pK is not independently verified in
# the repository table: Clarke-Glew pK at 22 °C, pH taken as set at 22 ± 3 °C, repository
# convention, notes/buffer-templates.md section 2; Davies activities at the self-
# consistent I ≈ 0.107 M): 4.11 mM of the Bis-Tris is the protonated cation, whose
# counter-ion is Cl⁻ from the HCl titration (σ 0.67 mM from σ_pH = 0.1, ±3 °C, ±0.02 pK,
# 30 % of the Davies shift and ±2 % on C). The RNA is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "bis-tris"),           # 10 mM Bis-Tris, ±2 %
    # Cl⁻ of the HCl titration (see above)
    NonBiological(0.00411, 0.00067, "chloride"),
    NonBiological(0.1, 0.002, "potassium chloride"),   # 100 mM KCl, ±2 %
    NonBiological(0.001, 2e-05, "magnesium chloride"), # 1 mM MgCl2, ±2 %
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
    refChi2 = "CRYSOL 63.691",
    pdb = "SASDSQ8_fit1_model1.pdb",
    fit = "SASDSQ8_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² CRYSOL 63.691
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

# Builds the Seed that `runSasdsq8` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdsq8` below is the whole story (build the seed, then
# sample it).
function seedSasdsq8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdsq8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdsq8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdsq8(run)

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

    # `@__DIR__` (this SASDSQ8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
