# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMS6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMS6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMS6 (fit1): the homodimer of human NONO (p54nrb, 30.1 kDa per chain, SASBDB
# experimental MW 61.6 kDa, the same construct as PDB entry 5IFM), SEC-SAXS. Publication:
# Knott G. J. et al., "Structural basis of dimerization and nucleic acid binding of human
# DBHS proteins NONO and PSPC1", Nucleic Acids Research 2022, 50, 522, DOI
# 10.1093/nar/gkab1216. Entry: https://www.sasbdb.org/data/SASDMS6/. The paper itself
# was not read for this entry (it is not in `sources/`): every condition below is the
# SASBDB entry metadata.
#
# Instrument (SASBDB): SAXS/WAXS beamline of the Australian Synchrotron, Pilatus 1M,
# wavelength 0.1 nm (SASBDB `xray_energy` is null, so hc/λ ≈ 12398 eV). Cell temperature
# AND storage temperature are 4 °C in SASBDB; used here as given (an SEC-SAXS run at the
# Australian Synchrotron is normally at ambient temperature, so this may be the cold-room
# value of the column; flagged).
#
# Buffer (SASBDB, the only source): "20 mM Tris-Cl (pH 7.5), 250 mM KCl, 50 mM L-proline,
# 0.5 mM EDTA", pH 7.5.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (q 0.0060-0.3755 Å⁻¹, 944 rows; the file is the
# US-SOMO
# SAXS-HPLC export "nono_apo_2_bs_avg_scaled_q0_00604951_0_375508"); 111 rows have a
# non-positive intensity. q cut, from 0.25 Å⁻¹ (evidence at `Q_MAX_FIT`): above it there
# are 322 points with a median I/σ of 0.41, 30 % of them non-positive, and the
# lowest-q quarter of them has a median I/σ of 0.88. The depositor's CRYSOL curve covers
# 0.0154-0.3755 Å⁻¹ (921 rows); the data below 0.0154 Å⁻¹ are fitted here as well, so
# refChi2 is not like for like.
#
# Model and depositor fit: fit1 is CRYSOL (SASBDB software "CRYSOL", chi_square_value
# 0.937, model "PDB (Protein Data Bank)", type "atomic") against SASDMS6_fit1_model1.pdb:
# the NONO homodimer in chains K (residues 53-312, 2115 atoms) and L (residues 53-308,
# 2071 atoms), 4186 heavy atoms, no hydrogens, no HETATM, from PDB 5IFM. The header
# reads "NONO_KL.  Dro:0.028  Ra:1.800  RGE:27.94  RGT:27.05  Vol: 68714.  Chi^2: 0.937",
# equal to SASBDB's value; refChi2 is 0.937. The .fit layout is CRYSOL's four columns
# `q (Å⁻¹), I_exp, σ, I_fit` (no placeholder grid here: the first row is at q = 0.0154).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the stated 0.1 nm
const TEMPERATURE_C = 4.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 20 mM Tris-Cl: titrated with HCl (the name says "Tris-Cl") -> Cl⁻ =
# C·0.860 = 17.21 mM (pK(22 °C) = 8.157, I ≈ 0.267 M: 0.25 M KCl and the protonated Tris
# with its chloride; σ 0.844 mM). The pH is taken as set at room temperature (22 ± 3 °C);
# the sample is at 4 °C and Tris pH changes by -0.03 per K, so this is a larger
# approximation than at 20 °C. Method, see SASDP74. Only the counter-ion is modelled.
#
# L-proline 50 mM (neutral zwitterion in the table, measured volume). EDTA 0.5 mM: the
# salt form is not stated (the same neutral "edta" entry as in SASDRL2's buffer is used).
# KCl 250 mM and the Tris and proline concentrations ±2 %, EDTA ±2 %. Every solute below
# is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.25, 0.005, "potassium chloride"),   # 250 mM KCl, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.01721, 0.000844, "chloride"),
    NonBiological(0.05, 0.001, "proline"),   # 50 mM L-proline, ±2%
    NonBiological(0.0005, 0.00001, "edta"),   # 0.5 mM EDTA, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.25 Å⁻¹ (see the Source): the 322 points above
# it have a median I/σ of 0.41, 30 % are non-positive, lowest-q quarter 0.88.
const Q_MAX_FIT = 0.25

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 0.937",
    pdb = "SASDMS6_fit1_model1.pdb",
    fit = "SASDMS6_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # NONO homodimer (5IFM), no H; deposited χ² = 0.937
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

# Builds the Seed that `runSasdms6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdms6` below is the whole story (build the seed, then sample it).
function seedSasdms6(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdms6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdms6(run; seed)
    # the default rerun (2000 + 2000) ended just short of the convergence gate (R̂ above
    # 1.01 or bulk ESS under 400), so this entry reruns with 4 times the draws
    # δ = 99: at the default 95 this entry exceeded the 0.1 % divergence limit; 99 passed
    # seeds 0, 1 and 2 (2026-11-16; see "When a run fails" in src/inference/README.md).
    res = BAYSOL.runModel(s, nSamples, nAdapt; δ = 99, retryNDraws = 8000)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdms6(run)

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
        runLog = true,
    )

    # `@__DIR__` (this SASDMS6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
