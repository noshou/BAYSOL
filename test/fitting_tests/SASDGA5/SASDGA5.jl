# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDGA5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDGA5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDGA5 (fit2): the C-terminal signalling domain of the sigma regulator PupR
# (PupR CCSSD, Pseudomonas capeferrum, 24.1 kDa, a monomer, SASBDB experimental MW 26
# kDa), SEC-SAXS. Publication: Jensen J. L., Jernberg B. D., Sinha S., Colbert C. L.,
# "Structural basis of cell surface signaling by a conserved sigma regulator in
# Gram-negative bacteria", J. Biol. Chem. 2020, 295, 4584, DOI 10.1074/jbc.RA119.010697.
# Entry: https://www.sasbdb.org/data/SASDGA5/. The structure is the paper's crystal
# structure of the domain (a selenomethionine variant).
#
# Instrument (paper and SASBDB): BioCAT 18ID at the Advanced Photon Source, Pilatus3 X
# 1M, sample-detector distance 3.5 m, wavelength 1.03 Å (the paper: "(~12 keV)"; hc/λ ≈
# 12037 eV), inline Superdex 200 Increase 10/300, 0.6 mL/min, 1 s exposures every 3 s "at
# ambient temperature": SASBDB gives the cell temperature 25 °C, used here as the
# ambient value and flagged as an assumption (the paper states no number).
#
# Buffer: SASBDB "25 mM HEPES 400 mM LiCl 10% v/v glycerol", pH 7.5; the paper (Methods,
# SEC-SAXS): "equilibrated with 25 mM HEPES, pH 7.5, 400 mM LiCl, 10% (v/v) glycerol".
# The two agree.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (q 0.0262-0.3665 Å⁻¹, 1118 rows, free-text header;
# the .dat says "primus/qt temporary file", a PRIMUS-merged curve; no non-positive
# intensity). No q cut: the median I/σ above 0.3 Å⁻¹ is 2.2 and none of the points is
# non-positive. The depositor's CRYSOL fit covers the whole curve (to 0.3665 Å⁻¹).
#
# Model and depositor fit: SASBDB lists three fits; fit1 (MultiFoXS, χ² 1.547, an
# ensemble) and fit3 (DAMMIN, dummy atoms, 1.456) are not used, fit2 is CRYSOL (SASBDB
# software "CRYSOL", chi_square_value 4.862, model software "Other", type "atomic")
# against SASDGA5_fit2_model1.pdb: chain R, residues 111-323 (the paper's PupR CCSSD
# crystal structure), 3709 records of which 1828 are heavy atoms (the file carries 1881
# hydrogens, which the loader drops before pdb2pqr places its own), and 15 selenomethionines
# (MSE, 75 atoms, kept as the residue name of the deposit; the loader's component table
# knows MSE, and a seedModel load check passed). The CRYSOL χ² of 4.862 is high: the
# model is a single rigid crystal structure, no flexibility (the paper fits MultiFoXS
# ensembles with 1.55 for this reason; fit2 is the single structure and the only atomic
# single-structure fit of the entry). The header reads "chainR.p  Dro:0.065  Ra:1.800
# RGE:21.78  RGT:21.13  Vol: 31631.  Chi^2: 4.862", equal to SASBDB's value; refChi2 is
# 4.862.
# The .fit layout is CRYSOL's four columns `q (Å⁻¹), I_exp, σ, I_fit`, with a leading
# grid of q = 0-0.026 at which the experimental columns are placeholders.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12037 eV, from the stated 1.03 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 25 mM HEPES (pK(22 °C) = 7.600) titrated with NaOH -> the anion fraction
# at pH 7.5 is 52.1 %, so Na⁺ = C·0.5206 = 13.02 mM (σ 1.68 mM; I ≈ 0.413 M, mostly the 0.4
# M LiCl). The titrant is NOT stated by either source: NaOH is the ordinary choice and is
# assumed (LiOH would give the same amount of a different cation; σ does not cover it).
# The pH is taken as set at room temperature (22 ± 3 °C). Method, see SASDP74. Only the
# counter-ion is modelled.
#
# Glycerol 10 % v/v (the paper and SASBDB say v/v): 0.10 L/L x 1261 g/L / 92.094 g/mol =
# 1.3693 M, ±5 %. LiCl 400 mM as stated (±2 %). Every solute below is in the bundled
# tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),   # 25 mM HEPES, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.01302, 0.001677, "sodium(1+)"),
    NonBiological(0.4, 0.008, "lithium chloride"),   # 400 mM LiCl, ±2%
    NonBiological(1.3693, 0.0685, "glycerol"),   # 10 % v/v glycerol, ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut (see the Source): the data end at 0.3665 Å⁻¹ with a median I/σ of 2.2 above
# 0.3 Å⁻¹.
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model carries hydrogens; the loader's canonical copy drops them and
# pdb2pqr/PROPKA place their own at PH (as for every protein entry). It has 15
# selenomethionines (MSE), see the Source.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    refChi2 = "CRYSOL 4.862",
    pdb = "SASDGA5_fit2_model1.pdb",
    fit = "SASDGA5_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # PupR CCSSD crystal structure, H present; deposited χ² = 4.862
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut: `Q_MAX_FIT` is infinite).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdga5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdga5` below is the whole story (build the seed, then sample it).
function seedSasdga5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdga5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdga5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdga5(run)

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

    # `@__DIR__` (this SASDGA5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
