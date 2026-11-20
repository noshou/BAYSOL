# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVY2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVY2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVY2: Sub-element stem-loop 5a (SL5a, 34 nt) within the SARS-CoV-2 5'-genomic
# element stem-loop 5.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1021/jacs.4c08406 (J. Am. Chem. Soc. 2024, SARS-CoV-2 5'-genomic stem-loop
# 5), read as the PMC full text. Read: "Final RNA samples were buffer-exchanged to 25 mM
# potassium phosphate (KPi, pH 6.2) and 50 mM potassium chloride (KCl) (NMR buffer)"; "we
# recorded SAXS data from a sample of 1 mg/mL in NMR buffer without D2O" (for SL5a; the same
# sentence for the full SL5). The SAXS temperature is not stated in the text read; 20 °C is
# the SASBDB value. The deposited SASBDB comment says the stem-loops were also measured with
# 10 mM Mg²⁺; this entry is the Mg²⁺-free curve (its SASBDB buffer line has no Mg²⁺).
#
# Instrument and conditions: PETRA III EMBL P12 (SASBDB); wavelength 0.124028 nm = 1.24028
# Å, energy = hc/λ ≈ 9996 eV; 20 °C (SASBDB).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit 1/nm), 2583 points, q from 0.0145 to
# 0.735 Å⁻¹ after dividing by NM_INV_PER_ANGSTROM_INV. The data extend beyond the
# depositor's fit: the depositor's fit ends at 0.4998 Å⁻¹, the curve at 0.735 Å⁻¹; the 843
# points above the fit range (σ > 0) have a median I/σ of 1.46 and 83 of them (10 %) have I
# ≤ 0. q cut at 0.70 Å⁻¹ (`Q_MAX_FIT`): the 126 points above it (σ > 0, q 0.700-0.735 Å⁻¹)
# have 33 non-positive intensities (26 %, limit 25 %) and a median I/σ of 0.66, so the tail
# fails the usable-data rule; the 717 points of the 0.50-0.70 Å⁻¹ band just below the cut
# have 50 non-positive (7 %) and a median I/σ of 1.65, so the cut sits where the data become
# unusable, not earlier. The depositor fitted up to 0.500 Å⁻¹.
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL (fit1) against
# SASDVY2_fit1_model1.pdb (one structure; 698 heavy atoms + 355 H; 33 residues). The .fit
# file: 1740 rows, q 0.0145-0.4998 Å⁻¹; the header value is the depositor's χ²; recomputed
# from the .fit columns over the usable rows: 2.1099; the depositor's χ² used here is 2.111.
# The deposited model carries 355 hydrogen records; pdb2pqr (AMBER, no PROPKA for the
# nucleic acid alone; PARSE + PROPKA for protein-nucleic acid files) rebuilds them at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # qvals are in nm⁻¹; convert to Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.2, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24028   # ≈ 9996 eV, wavelength 1.24028 Å
const TEMPERATURE_C = 20.0   # SASBDB only (the paper text read gives no SAXS temperature)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). "25 mM potassium phosphate" is a mix of KH2PO4 and K2HPO4 at
# pH 6.2: the HPO4²⁻ fraction is 0.1660 (pK2 and its temperature dependence from Goldberg,
# Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH
# 3.6 kJ/mol, ΔCp -230 J/K/mol) with the pH taken as set at 22 ± 3 °C (ASSUMPTION: the paper
# does not say at which temperature the pH was set), Davies-corrected at I ≈ 0.083 M (0.05 M
# KCl + the phosphate and its potassium). σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift and ±2 % on C (0.0011 M on each species). The macromolecule is
# deliberately NOT a solute.
const SOLUTES = Solute[
    # 25 mM KPi, H2PO4⁻ part
    NonBiological(0.020851, 0.0011, "potassium dihydrogen phosphate"),
    # 25 mM KPi, HPO4²⁻ part
    NonBiological(0.004149, 0.0011, "dipotassium hydrogen phosphate"),
    NonBiological(0.05, 0.0005, "potassium chloride"),   # 50 mM, ±1 %
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
const Q_MAX_FIT = 0.7

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 2.111",
    pdb = "SASDVY2_fit1_model1.pdb",
    fit = "SASDVY2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 2.111
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

# Builds the Seed that `runSasdvy2` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdvy2` below is the whole story (build the seed, then
# sample it).
function seedSasdvy2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvy2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvy2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvy2(run)

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

    # `@__DIR__` (this SASDVY2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
