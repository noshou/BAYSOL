# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDPZ8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPZ8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPZ8: Development of DNA Aptamers for Visualization of Glial Brain Tumors and
# Detection of Circulating Tumor Cells (Gli-233, a 33-nt ssDNA aptamer, 10.2 kDa),
# modelled by a GROMACS MD frame.
#
# Paper: Kichkailo A, Narodov A, Komarova M, et al., Mol Ther Nucleic Acids (2023),
# DOI 10.1016/j.omtn.2023.03.015. The paper's full text could not be reached; the
# conditions below are the SASBDB entry metadata (https://www.sasbdb.org/data/SASDPZ8/):
# temperature 4 °C, pH 7.4, wavelength and the named buffer DPBS with Ca and Mg. The
# buffer is a named standard whose full recipe is citable (see below), so the entry is
# accepted under the round-7 rule (AUDIT7).
#
# Sample: curve extrapolated to infinite dilution from a dilution series, cell
# temperature 4.0 °C (SASBDB). Instrument: ESRF BM29, Pilatus 1M, wavelength
# 0.09919 nm = 0.9919 Å => energy = hc/λ ≈ 12500 eV (hc = 12398.42 eV·Å).
#
# Buffer as deposited: "Dulbecco phosphate-buffered saline (DPBS, with Ca and Mg)", pH
# 7.4, no concentrations. The standard Dulbecco recipe with calcium and magnesium
# (Dulbecco & Vogt 1954), cited from supplier formulations of DPBS +Ca +Mg (PAN-Biotech,
# mg/L: NaCl 8000, KCl 200, Na2HPO4 1150, KH2PO4 200, CaCl2·2H2O 133, MgCl2·6H2O 100;
# the molarities in SOLUTES agree within 1 %), see SOLUTES.
# The aptamer is deliberately NOT a solute.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (`_readCurve` keeps the numeric rows) and is
# converted to Å⁻¹ (÷10). Rows with a non-positive intensity (at high q) are dropped by
# `seedModel` after binning.
#
# Model (fit1, GROMACS, 1043 atoms with 371 hydrogens, ATOM records): used as deposited,
# no cleaning; pdb2pqr rebuilds the hydrogens as for SASDK36.
#
# Depositor fit: CRYSOL, header "Chi^2: 1.041", the SASBDB REST value is also 1.041, and
# recomputing the reduced χ² from the .fit columns gives 1.0410; 1.041 is used. Fit2
# (DAMMIF) is a dummy-bead model and is not fitted.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9919   # ≈ 12500 eV, from the stated 0.09919 nm
const TEMPERATURE_C = 4.0

# Buffer components (the measured aptamer is deliberately NOT listed). The depositors
# name the buffer only; the standard Dulbecco PBS with Ca and Mg is 137.93 mM NaCl,
# 2.67 mM KCl, 8.06 mM Na₂HPO₄, 1.47 mM KH₂PO₄, 0.90 mM CaCl₂, 0.493 mM MgCl₂. The
# phosphates are the two species already, so no titrant counter-ion is added. σ is ±5 %
# on every component to cover the differences between suppliers' formulations.
const SOLUTES = Solute[
    NonBiological(0.13793, 0.0069, "sodium chloride"),   # 137.93 mM, ±5%
    NonBiological(0.00267, 0.00013, "potassium chloride"),   # 2.67 mM, ±5%
    NonBiological(0.00806, 0.0004, "disodium hydrogen phosphate"),   # 8.06 mM, ±5%
    NonBiological(0.00147, 0.00007, "potassium dihydrogen phosphate"),   # 1.47 mM, ±5%
    NonBiological(0.0009, 0.000045, "calcium chloride"),   # 0.90 mM, ±5%
    NonBiological(0.000493, 0.000025, "magnesium chloride"),   # 0.493 mM, ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The whole .dat is fitted (q 0.0139-0.4846 Å⁻¹); the depositor's fit ends at 0.3518 Å⁻¹,
# so refChi2 is not like for like.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model's 371 GROMACS hydrogens are rebuilt by pdb2pqr (as for SASDK36).
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.041",
    pdb = "SASDPZ8_fit1_model1.pdb",
    fit = "SASDPZ8_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # Gli-233 GROMACS frame; deposited χ² = 1.041
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdpz8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdpz8` below is the whole story (build the seed, then sample it).
function seedSasdpz8(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpz8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdpz8(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpz8(run)

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
                fitCurve...,
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

    # `@__DIR__` (this SASDPZ8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
