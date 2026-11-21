# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDPG2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPG2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPG2: NOX-E36 (40 nt), L-RNA Spiegelmer (modelled as D-RNA), HEPES.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: none (SASBDB lists no publication for this project, "Spiegelmers NOX-E36 and
# NOX-A12"), so every condition below is the SASBDB one (FLAGGED). Spiegelmers are L-RNA;
# the deposited model is an ordinary (D-RNA) MC-Fold|MC-Sym model, which is right for SAXS
# because the scattering is identical for the mirror image.
#
# Buffer (SASBDB only): "20 mM HEPES", pH 7.52; SASBDB gives no salt and no titrant, so
# only HEPES and its Na⁺ counter-ion (NaOH titration, the repository convention for HEPES)
# are entered (FLAGGED: any other salt of the real buffer is unknown). SASBDB gives a cell
# temperature of 5.8 °C (taken as stated; FLAGGED as unusual, it only sets the solvent
# density and the thermal terms, the counter-ion computation uses the pH as set at 22 °C).
#
# Instrument and conditions: EMBL X33, DORIS III, DESY, Hamburg (SASBDB); wavelength 0.15
# nm = 1.5 Å, energy = hc/λ ≈ 8266 eV; 5.8 °C (SASBDB).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit 1/nm), converted to Å⁻¹ by
# dividing by NM_INV_PER_ANGSTROM_INV, 2183 usable points, q from 0.0073 to 0.571 Å⁻¹.
# q cut (2026-11-19): the points below 0.0321 Å⁻¹ (96 of them) are left out, because the
# depositor's CRYSOL fit file has I_exp = 0 (no data) there and its first fitted point is
# q = 0.03212 Å⁻¹; fitting that range makes BAYSOL's χ² and the depositor's one cover the
# same points (same σ, same upper end 0.571 Å⁻¹). `seedModel` also drops non-positive bins.
#
# Model and depositor fit: SASDPG2_fit1_model1.pdb (one structure; 997 heavy atoms + 287
# H; 40 residues, 1284 atom records) and the SASBDB fit file SASDPG2_fit1.fit (CRYSOL,
# column 4 = fitted intensity; the SASBDB header chi2 is 1.007; recomputed: matches the
# recomputation with the .fit own error column (1.0067); against the .dat errors 1.201;
# the depositor χ² used here is 1.007). The deposited hydrogens (if any) are replaced:
# pdb2pqr rebuilds them at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # SASBDB angular_unit "1/nm"
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.52, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, wavelength 1.5 Å
const TEMPERATURE_C = 5.8   # SASBDB (5.8 °C, FLAGGED)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 20 mM HEPES titrated with NaOH to pH 7.52: the anionic fraction follows from pKa 7.564
# at 25 °C moved to 22 °C (HEPES template of the repository, Goldberg et al. 2002, ΔH 20.4
# kJ/mol), the pH taken as set at 22 ± 3 °C (repository convention, notes/buffer-
# templates.md section 2), Davies-corrected at the self-consistent I ≈ 0.010 M: Na⁺ = 9.58
# mM; σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C (1.3
# mM). Only the counter-ion is modelled. The RNA is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),              # 20 mM HEPES, ±2 %
    # Na⁺ of the NaOH titration (see above)
    NonBiological(0.009583, 0.0013, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from the
# diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and bins the
# curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the hydrogens are built by pdb2pqr at PH (see the model note above).
const ADD_HYDROGENS = true

# Smallest and largest q fitted (Å⁻¹): the depositor's range (see the Source note);
# Inf = the curve is fitted up to its last point.
const Q_MIN_FIT = 0.0321
const Q_MAX_FIT = Inf

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.007",
    pdb = "SASDPG2_fit1_model1.pdb",
    fit = "SASDPG2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² CRYSOL 1.007
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `Q_MIN_FIT ≤ q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(
        i -> Q_MIN_FIT ≤ qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0,
        eachindex(qvals),
    )
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdpg2` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdpg2` below is the whole story (build the seed, then
# sample it).
function seedSasdpg2(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpg2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdpg2(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpg2(run)

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

    # `@__DIR__` (this SASDPG2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
