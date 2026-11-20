# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDF53")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDF53.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDF53 (fit2): the kinase domain of human Bruton's tyrosine kinase (Btk-KD, 31.8
# kDa, a monomer), measured at BM29 (ESRF) in batch mode at a protein concentration given in
# the .dat header only. Publication: Duarte D.P. et al., "Btk SH2-kinase interface is
# critical for allosteric kinase activation and its targeting inhibits B-cell neoplasms",
# Nat. Commun. 2020, 11, 2319, DOI 10.1038/s41467-020-16128-5 (open access, Europe PMC full
# text read: Methods, 'Small-angle X-ray scattering (SAXS)'). Entry:
# https://www.sasbdb.org/data/SASDF53/.
#
# Instrument (SASBDB): wavelength 0.09919 nm (SASBDB; the paper names the beamline, BM29 at
# the ESRF, not the wavelength). Temperature: 20 °C, SASBDB cell temperature; the paper
# gives only 'room temperature' for the in-line SEC and no batch temperature (flagged).
#
# Buffer: Buffer from the PAPER: 'All proteins were measured in buffer containing 25 mM Tris
# pH 7.5, 300 mM NaCl, 1 mM TCEP and 5% glycerol' (batch mode on the robotic sample changer,
# in-line SEC-SAXS on a Superdex 200 Increase). SASBDB lists 20 mM Tris, 150 mM NaCl, 1 mM
# TCEP, 5% glycerol (pH 7.5): it differs in the Tris and NaCl concentrations; the paper is
# the source of truth here and the difference is flagged. The paper does not say whether the
# 5% glycerol is v/v or w/v (v/v assumed).
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.0582-4.928 nm-1),
# converted to A-1 (divide by 10): q 0.00582-0.4928 A-1, 1038 rows, all sigma > 0, 5 with a
# non-positive intensity. No q cut: the median I/sigma above 0.3 A-1 is 3.3 and the
# noise-floor rule of the README (median I/sigma below 0.5 and 25 % non-positive) is far
# from met.
#
# Model and depositor fit: fit2 is a CRYSOL fit (header '1k2p.pdb  Dro:0.050  Ra:1.500
# RGT:20.37  Vol: 35090.  Chi^2: 1.275') against SASDF53_fit2_model1.pdb, PDB 1K2P chain A
# of the Btk kinase domain: 2087 ATOM records, 20 standard amino acids, no hydrogens, no
# HETATM, one chain. The .fit has four columns, q (A-1), I_exp, sigma, I_fit (the first row
# is q = 0.002 with zeros), the same scale as the .dat, so the reference curve is column 4
# and is not rescaled. The entry's fit1 (chi2 1.002) is an .fir file (another format, no
# model download) and is not used. The paper's model and 1K2P are the same crystal
# structure. The depositor's χ² is the header value, header Chi^2 1.275 = SASBDB 1.275
# (refChi2 = CRYSOL 1.275).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9919   # wavelength 0.9919 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 25 mM Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I =
# 0.3215 M (0.3 M NaCl plus the protonated Tris and its chloride): the acid fraction is
# 0.8609, so Cl- = C x 0.8609 = 21.52 mM (sigma 1.05 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK,
# 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not stated; the ordinary
# choice, assumed). The pH is taken as set at room temperature (22 +-3 C). TCEP is taken as
# neutralised (TCEP-HCl is acidic, but the pH is set after it is added) and only the neutral
# molecule is listed. Glycerol: 0.05 L/L x 1261 g/L / 92.094 g/mol = 0.6846 M, +-5 %. Every
# solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris, ±2%
    NonBiological(0.3, 0.006, "sodium chloride"),   # 300 mM NaCl, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.021523, 0.001053, "chloride"),
    NonBiological(0.6846, 0.0342, "glycerol"),   # 5 % v/v glycerol (assumed v/v), ±5%
    NonBiological(0.001, 2e-05, "tcep"),   # 1 mM TCEP, ±2%
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
    refChi2 = "CRYSOL 1.275",
    pdb = "SASDF53_fit2_model1.pdb",
    fit = "SASDF53_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 1.275
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

# Builds the Seed that `runSasdf53` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdf53` below is the whole story (build the seed, then sample it).
function seedSasdf53(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdf53(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdf53(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdf53(run)

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

    # `@__DIR__` (this SASDF53/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
