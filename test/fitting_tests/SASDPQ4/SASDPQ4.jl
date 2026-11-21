# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDPQ4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPQ4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPQ4: urate oxidase tetramer, consensus SAXS profile (datcombine), 136.4 kDa.
#
# NOT YET RUN: this entry was wired on 2026-11-19 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Sample: Aspergillus flavus urate oxidase (uricase), tetramer (34.109 kDa per chain;
# UniProt Q00511) with N-terminal Ser acetylated and bound 8-azaxanthine (SASBDB).
# Consensus profile of the round-robin study: eleven independent profiles (6 SEC-SAXS, 2
# batch, 3 merged) combined with datcombine (ATSAS 3.1.0, outlier and error filters); "the
# buffer for the substantial majority of the contributing data was 100 mM Tris, pH 8.0,
# 150 mM NaCl" (SASBDB experiment text); batch concentrations 1-7 mg/ml. Paper: Trewhella
# J et al., Acta Cryst. D 2022, 78, DOI 10.1107/S2059798322009184 (not read; everything is
# the SASBDB record). This is the first consensus profile; SASDUB4 is the updated one.
#
# Instrument and conditions: NONE of the SASBDB record's instrument fields is set: the
# curve is a consensus merge of many beamlines and facilities (round-robin study,
# Trewhella et al.), so no single wavelength or temperature exists. ASSUMPTIONS (flagged):
# 10 keV (λ = 1.2398 Å; the f′, f″ corrections of the light atoms are insensitive to it)
# and 20 °C (the usual sample temperature of the round-robin protocols; the SASBDB record
# has none).
#
# D2O: the SASBDB buffer field carries no D2O comment for this entry, but the input files
# of the merge include D2O and H2O profiles (10-U-X7_B1pt4-D2O and 11-U-X7_B1pt4-H2O-Gt of
# the Parent(s) list in the .dat). BAYSOL's solvent is H2O (the buffer's ρₑ comes from
# ρ_w(T) plus the solutes); there is no D2O-as-solvent setting (the D2O row of
# nonbiological.tsv is the partial molar volume of D2O as a dilute solute in H2O). This is
# SAXS: H/D exchange of the protein does not change its scattering, only the solvent
# electron density differs, by about 0.4 % (D2O 0.3329 against H2O 0.3343 e/Å³ at 20 °C).
# The depositor's own CRYSOL fit used the default (H2O-like) solvent density as well.
# Expected to be absorbed by the sampled ρₑ, not run.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A; 498 points, q 0.006 to 1.0
# Å⁻¹, no unit footer), no conversion (checkQAngstrom checks the range). The curve is a
# consensus profile with very small σ (median I/σ of the top 80 % of the points >5), so χ²
# values are large for every method (the depositor's own note: "the unusually good
# statistics for the consensus SAXS data generally give rise to large χ-square values for
# the model fits"). No q cut: no point has I ≤ 0 and the median I/σ is far above 0.5
# everywhere, so the rule of test/fitting_tests/README.md is not met. The depositor's fit
# covers the whole curve (498 rows, q 0.006-1.0 Å⁻¹). The noisiest part is the top 20 % (q
# ≥ 0.80 Å⁻¹) with a median I/σ of 5.4 and no non-positive point, still far from the noise
# floor of the rule.
#
# Model and depositor fit: fit2 of the entry, CRYSOL (ATSAS online, default parameters
# with a constant background added; the header reads Dro 0.011, Rg 30.89, Vol 171466,
# Chi^2 40.756, agreeing with SASBDB), against SASDPQ4_fit2_model1.pdb (the same
# coordinates as SASDUB4_fit1_model1.pdb: PDB 3L8W tetramer, C-terminal SLKSKL added; 9624
# ATOM, 56 XAN, 4 NA, no TER records). The XAN ligands and Na ions are kept as in SASDUB4.
# The depositor's χ² used here is 40.756. fit1 is a DAMMIN bead model (not usable); fit3
# Pepsi-SAXS 25.1, fit4 FoXS 19.5 and fit5 WAXSiS 15.2 are not wired. The same OPEN point
# about the missing TER records as SASDUB4.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# (qvals are already in Å⁻¹, no unit conversion)
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA   # SASBDB buffer field and experiment text
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2398   # see the instrument note above
const TEMPERATURE_C = 20.0   # ASSUMED, see the note above

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl: the pH is set with HCl, so the titrant counter-ion
# is Cl⁻ = C x (1 - f), f the deprotonated fraction (pK(Tris) and its temperature
# dependence from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902: 8.072, ΔH 47.45 kJ/mol, ΔCp -59 J/K/mol); pH taken as set at 22 ± 3
# °C (ASSUMPTION, the source gives no setting temperature), Davies-corrected at I ≈ 0.216
# M (0.15 M NaCl + Tris ions); Cl⁻ = 0.065841 M. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK,
# 30 % of the Davies shift and ±2 % on C: 0.007526 M. The same recipe reproduces the
# repository's SASDGF3 and SASDVX4 values. The titrant (HCl) is assumed, as in the other
# Tris scripts.
const SOLUTES = Solute[
    NonBiological(0.1, 0.002, "tris"),   # 100 mM Tris-HCl, ±2%
    # Cl⁻ counter-ion of the HCl titration of Tris (see the note above)
    NonBiological(0.065841, 0.007526, "chloride"),
    NonBiological(0.15, 0.0015, "sodium chloride"),   # 150 mM NaCl, ±1%
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
    tag = "fit2_model1",
    refChi2 = "CRYSOL 40.756",
    pdb = "SASDPQ4_fit2_model1.pdb",
    fit = "SASDPQ4_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 40.756
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

# Builds the Seed that `runSasdpq4` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdpq4` below is the whole story (build the seed, then
# sample it).
function seedSasdpq4(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpq4(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdpq4(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpq4(run)

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

    # `@__DIR__` (this SASDPQ4/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
