# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDC57")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDC57.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDC57 (fit2): human dUTPase (hDUT, 18.0 kDa per chain, a homotrimer; the
# deposited sample is 'hDUT-dHis', 1.25 mg/ml), measured at EMBL P12 (PETRA III).
# Publication: Nyiri K. et al., "Structural model of human dUTPase in complex with a novel
# proteinaceous inhibitor", Sci. Rep. 2018, 8, 4326, DOI 10.1038/s41598-018-22145-8 (open
# access, Europe PMC full text read: the SAXS methods). Entry:
# https://www.sasbdb.org/data/SASDC57/.
#
# Instrument (SASBDB): wavelength 0.124 nm (SASBDB; the paper gives 1.24 A, EMBL P12).
# Temperature: 20 °C, the paper (batch samples of hDUT and Stl 'in buffer B ... at 20 C');
# SASBDB says 10 C, which is the 283 K of the paper's in-line SEC-SAXS complex runs, not of
# this batch curve (flagged).
#
# Buffer: Buffer from the PAPER: 'samples [of hDUT and Stl] were measured in buffer B (50 mM
# HEPES, pH = 7.5, 300 mM NaCl, 5 mM MgCl2) while flowing through a temperature controlled
# capillary at 20 C'. SASBDB lists the same recipe (and a cell temperature of 10 C, see
# above). The paper does not say how the HEPES was titrated (NaOH assumed).
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1322-5.031 nm-1),
# converted to A-1 (divide by 10): q 0.01322-0.5031 A-1, 1779 rows, all sigma > 0, 149 (8 %)
# with a non-positive intensity. No q cut: the median I/sigma above 0.3 A-1 is 0.96 (a noisy
# tail), but the README's rule (a) for a cut (median I/sigma below 0.5 and at least 25 %
# non-positive above the cut) is first met only above 0.47 A-1, a sliver of the curve, and
# the depositor's fit spans the whole range; the fit is left uncut (open point: check the
# sampler health, and test a cut at about 0.47 if it diverges).
#
# Model and depositor fit: fit2 is a CRYSOL fit (header '00092hDp  Dro:0.048  Ra:1.400
# RGT:27.95  Vol: 80480.  Chi^2: 1.059') against SASDC57_fit2_model1.pdb, the hDUT
# homotrimer (chains A, B, C, 942 ATOM records each, 2826 in all, 19 standard amino acids,
# no hydrogens, no HETATM). 36 of the atoms carry an alternate-location label (A or B, 18
# each): the loader keeps both because they differ in altloc (README of
# src/molecular-structure), so those 18 sidechain atoms are counted twice (open point, 0.6 %
# of the atoms). The .fit has four columns but its I_exp and sigma columns are not on the
# .dat scale (last row 101, 66.8 against 4.0e-05, 8.5e-04), so the reference curve (column
# 4) is rescaled to the data (rescale = true). The entry's fit1 (chi2 1.0) is an .fir file
# and is not used. The depositor's χ² is the header value, header Chi^2 1.059; SASBDB rounds
# to 1.06 (refChi2 = CRYSOL 1.059).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 50 mM HEPES (pK(22 C) = 7.600) titrated with NaOH
# (the titrant is not stated; NaOH is the ordinary choice and is assumed) at pH 7.5 with
# Davies activities at I = 0.341 M (0.3 M NaCl, 5 mM MgCl2 and the HEPES anion with its
# sodium): the anion fraction is 0.5204, so Na+ = 0.05 x 0.5204 = 26.02 mM (sigma 3.36 mM:
# sigma_pH = 0.1 alone gives 3.1 mM, plus +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 %
# on C). The pH is taken as set at room temperature. The MgCl2 chloride (10 mM) comes with
# the salt row. Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM HEPES, ±2%
    NonBiological(0.3, 0.006, "sodium chloride"),   # 300 mM NaCl, ±2%
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM MgCl2, ±2%
    # Na+ counter-ion of the HEPES titration (see the note above)
    NonBiological(0.026018, 0.003355, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut (see the Source for the numbers): the README's noise-floor rule is not met over
# any useful part of the curve.
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    refChi2 = "CRYSOL 1.059",
    pdb = "SASDC57_fit2_model1.pdb",
    fit = "SASDC57_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = true,
    software = "CRYSOL",
),   # deposited χ² = 1.059
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

# Builds the Seed that `runSasdc57` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdc57` below is the whole story (build the seed, then sample it).
function seedSasdc57(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdc57(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdc57(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdc57(run)

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

    # `@__DIR__` (this SASDC57/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
