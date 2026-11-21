# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDYV6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDYV6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDYV6: pyruvate kinase (SASBDB molecule "Pk", 55 kDa), AlphaFold monomer model,
# protein.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1021/acsomega.6c06099. NOT read in this session; every condition below is
# the SASBDB one (paper preferred, SASBDB used: FLAGGED).
#
# Buffer (SASBDB only): "20 mM Tris-HCl pH, 300 mM NaCl", pH 8.0, 15 °C. Tris is titrated
# with HCl (counter-ion chloride).
#
# Instrument and conditions: Diamond Light Source B21 (SASBDB), SEC-SAXS; wavelength
# 0.09464 nm = 0.9464 Å (SASBDB), energy = hc/λ ≈ 13101 eV; temperature: SASBDB.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 2521 usable points, q from 0.0091 to 0.340 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDYV6_fit2_model1.pdb (one structure; 3839 heavy atoms + 0 H;
# 501 residues, 3839 atom records) and the SASBDB fit file SASDYV6_fit2.fit (CRYSOL fit
# file, column 4 = fitted intensity; the SASBDB header chi2 is 2.101; recomputed: 1.997;
# the depositor χ² used here is 2.101). The deposited hydrogens (if any) are replaced:
# pdb2pqr rebuilds them at PH.
#
# The depositor fit 1 is a GASBOR bead model and is not used; fit 2 (CRYSOL, AlphaFold
# monomer) is. SASBDB lists the molecule as a monomer of 55 kDa; the oligomeric state in
# solution is the paper subject, so a disagreement of the monomer model with the data is
# expected.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9464   # ≈ 13101 eV, wavelength 0.9464 Å
const TEMPERATURE_C = 15.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 20 mM Tris at pH 8.0 (tris template: Clarke-Glew pK at 22 °C, pH taken as set at 22 ± 3
# °C, repository convention, notes/buffer-templates.md section 2; Davies activities at the
# self-consistent I ≈ 0.313 M): 13.23 mM of the Tris is the protonated cation, whose
# counter-ion is Cl⁻ (σ 1.46 mM from σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift
# and ±2 % on C). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),               # 20 mM Tris, ±2 %
    # Cl⁻ of the HCl titration (see above)
    NonBiological(0.013235, 0.001456, "chloride"),
    NonBiological(0.3, 0.006, "sodium chloride"),      # 300 mM NaCl, ±2 %
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
    tag = "fit2_model1",
    refChi2 = "CRYSOL 2.101",
    pdb = "SASDYV6_fit2_model1.pdb",
    fit = "SASDYV6_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² CRYSOL 2.101
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

# Builds the Seed that `runSasdyv6` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdyv6` below is the whole story (build the seed, then
# sample it).
function seedSasdyv6(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdyv6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdyv6(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdyv6(run)

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

    # `@__DIR__` (this SASDYV6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
