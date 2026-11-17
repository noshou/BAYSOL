# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWT5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWT5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWT5 (fit1): the BRC4 repeat of BRCA2 bound to the N-terminally truncated
# RAD51 (Δ97-RAD51, UniProt Q06609 from residue 97), a 1:1 complex of 31.0 kDa (SASBDB
# experimental MW 29.6 kDa from Vc, SLS-confirmed), SEC-SAXS. Publication: Rinaldi F. et
# al., "Breaking new ground into RAD51 BRC repeats interplay in homologous recombination",
# Communications Biology (2026), DOI 10.1038/s42003-026-11218-4. Entry:
# https://www.sasbdb.org/data/SASDWT5/.
#
# Instrument (SASBDB): Diamond Light Source B21, Eiger 4M, wavelength 0.09464 nm
# (SASBDB `xray_energy` is null, so the energy is hc/λ ≈ 13101 eV); 52 successive frames
# of the elution peak (of 600); cell temperature 15 °C (SASBDB; storage 15 °C as well).
# The paper (Methods) names the beamline but defers the collection parameters to its
# Supplementary Tables S11-S19, which are not available here: temperature and wavelength
# are the SASBDB values only.
#
# Buffer: SASBDB "20 mM K2HPO4/KH2PO4, 100 mM NaCl, 200 mM Li2SO4, 1 mM DTT, 2%
# sucrose", pH 8.0; the paper's Methods give the same composition (pH 8.00) as the
# equilibration buffer of the SEC steps ("20 mM K2HPO4/KH2PO4 pH 8.00, 100 mM NaCl, 200 mM
# Li2SO4, 1 mM DTT, 2% sucrose"). The buffer is a high-contrast one (0.2 M
# of a sulfate salt, 2 % sucrose), which is why the entry is of interest.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (q 0.0083-0.328 Å⁻¹, 2448 rows; 65 rows have a
# non-positive intensity). No q cut: above 0.3 Å⁻¹ the 216 points have a median I/σ of 0.98
# and 13 % of them are non-positive, so the noise-floor rule (see `notes`, round 9) is not
# met. The depositor's FoXS fit covers only 0.0134-0.2381 Å⁻¹ (1720 points), so its
# χ² of 1.151 is not like for like with the fit of the whole curve; the data below
# 0.0134 Å⁻¹ and above 0.238 Å⁻¹ are fitted here as well.
#
# Model and depositor fit: fit1 is FoXS 1.151 (SASBDB software "FoXS", header of the .fit:
# "Chi^2 = 1.15100773240444", offset 0, scaling c = 3.0667e-9) against
# SASDWT5_fit1_model1.pdb, an AlphaFold model of the complex (type "atomic"), 2170 heavy
# atoms in two chains (A: 1855 atoms, residues 1-243, Δ97-RAD51; B: 315 atoms, residues
# 1-39, BRC4 with the four non-native residues GWHM at its N-terminus), no hydrogens, no
# waters, no HETATM. The .fit layout (FoXS): `# q exp_intensity error model_intensity`,
# q in Å⁻¹; `model_intensity` is already on the scale of the data (all `Reference` uses).
# refChi2 is the χ² of the header and of the REST field (1.151008).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9464   # ≈ 13101 eV, from the stated 0.09464 nm
const TEMPERATURE_C = 15.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). The phosphate is K2HPO4/KH2PO4 (paper and SASBDB), set to
# pH 8.00 by mixing the two salts, so no titrant is added. The split comes from pK2 of
# phosphoric acid at 22 °C = 7.205 (Goldberg, Kishore & Lennen 2002, DOI
# 10.1063/1.1416902) with a Davies correction (A = 0.509) at I = 0.757 M (0.1 M NaCl, 0.2 M
# Li2SO4 and the phosphate itself). That I is above 0.5 M, where Davies is unreliable
# (the TUI calculator warns); the split changes by under 0.5 % against I = 0.157 M, so
# the choice hardly matters. At pH 8.00: 93.5 % HPO4²⁻ and 6.5 % H2PO4⁻, i.e. 18.70 mM
# K2HPO4 and 1.298 mM KH2PO4 (σ 0.564 and 0.426 mM: σ_PH, ±3 °C, ±0.02 pK, 30 % Davies,
# ±2 % on C; the table has the dipotassium and the monopotassium salt). The pH is taken as
# set at room temperature (22 ± 3 °C).
#
# Sucrose "2 %" is assumed w/v (the paper writes "2% sucrose"): 20 g/L / 342.30 g/mol =
# 58.4 mM, ±10 % (w/w or v/v would differ by a few percent). DTT 1 mM, ±2 %. NaCl 100 mM
# (±2 %) and Li2SO4 200 mM (±2 %) are as stated. Every solute below is in the bundled
# tables.
const SOLUTES = Solute[
    NonBiological(0.0187, 0.000564, "dipotassium hydrogen phosphate"),   # 18.70 mM
    NonBiological(0.001298, 0.000426, "potassium dihydrogen phosphate"),   # 1.298 mM
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM NaCl, ±2%
    NonBiological(0.2, 0.004, "lithium sulfate"),   # 200 mM Li2SO4, ±2%
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM DTT, ±2%
    NonBiological(0.0584, 0.0058, "sucrose"),   # 2 % (w/v assumed), 58.4 mM, ±10%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the data run to 0.328 Å⁻¹ but the noise-floor rule is not met above 0.3 Å⁻¹
# (216 points, median I/σ 0.98, 13 % non-positive; lowest-q quarter 1.13), see the Source.
const Q_MAX_FIT = Inf

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
    refChi2 = "FoXS 1.151",
    pdb = "SASDWT5_fit1_model1.pdb",
    fit = "SASDWT5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),   # AlphaFold model of Δ97-RAD51/BRC4, no H; deposited χ² = 1.151
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

# Builds the Seed that `runSasdwt5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdwt5` below is the whole story (build the seed, then sample it).
function seedSasdwt5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwt5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdwt5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwt5(run)

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

    # `@__DIR__` (this SASDWT5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
