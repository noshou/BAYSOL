# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXK4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXK4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXK4: IgE (165 kDa), Chimera model, protein.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1016/j.ijbiomac.2025.147658. NOT read in this session; every condition
# below is the SASBDB one (paper preferred, SASBDB used: FLAGGED).
#
# Buffer (SASBDB only): "20 mM Tris, 50 mM NaCl", pH 8.4, 20 °C. Tris is titrated with HCl
# (counter-ion chloride).
#
# Instrument and conditions: PETRA III (SASBDB), SEC-SAXS; wavelength 0.124 nm = 1.24 Å
# (SASBDB), energy = hc/λ ≈ 9999 eV; temperature: SASBDB.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit 1/nm), converted to Å⁻¹ by
# dividing by NM_INV_PER_ANGSTROM_INV, 2591 usable points, q from 0.0023 to 0.727 Å⁻¹. No
# q cut: the whole deposited curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDXK4_fit2_model1.pdb (one structure; 10971 heavy atoms + 0
# H; 1476 residues, 10971 atom records) and the SASBDB fit file SASDXK4_fit2.fit (CRYSOL
# fit file, column 4 = fitted intensity; the SASBDB header chi2 is 1.673; recomputed:
# 1.598; the depositor χ² used here is 1.673). The deposited hydrogens (if any) are
# replaced: pdb2pqr rebuilds them at PH. SIZE: 10971 heavy atoms.
#
# The depositor fit 1 of this entry is a DAMMIF dummy-atom model and is not used; fit 2
# (CRYSOL, Chimera-built model, six chains A-D, H, L) is.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # SASBDB angular_unit "1/nm"
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.4, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, wavelength 1.24 Å
const TEMPERATURE_C = 20.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 20 mM Tris at pH 8.4 (tris template: Clarke-Glew pK at 22 °C, pH taken as set at 22 ± 3
# °C, repository convention, notes/buffer-templates.md section 2; Davies activities at the
# self-consistent I ≈ 0.058 M): 8.25 mM of the Tris is the protonated cation, whose
# counter-ion is Cl⁻ (σ 1.53 mM from σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift
# and ±2 % on C). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),               # 20 mM Tris, ±2 %
    # Cl⁻ of the HCl titration (see above)
    NonBiological(0.008253, 0.00153, "chloride"),
    NonBiological(0.05, 0.001, "sodium chloride"),     # 50 mM NaCl, ±2 %
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
    refChi2 = "CRYSOL 1.673",
    pdb = "SASDXK4_fit2_model1.pdb",
    fit = "SASDXK4_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² CRYSOL 1.673
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

# Builds the Seed that `runSasdxk4` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdxk4` below is the whole story (build the seed, then
# sample it).
function seedSasdxk4(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxk4(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdxk4(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxk4(run)

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

    # `@__DIR__` (this SASDXK4/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
