# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJQ7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJQ7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJQ7: Cathepsin Z (CTSZ, Q9UBR2, Homo sapiens, 27.149 kDa x 2). Human
# Cathepsin X. Publication: Dolenc I, Štefe I, Turk D, Taler-Verčič A, Turk B, Turk V,
# Stoka V, "Human cathepsin X/Z is a biologically active homodimer.", Biochim Biophys Acta
# Proteins Proteom (2020), DOI 10.1016/j.bbapap.2020.140567 (the paper was NOT consulted,
# except where stated: every condition below is the SASBDB entry metadata, flagged).
# Entry: https://www.sasbdb.org/data/SASDJQ7/.
#
# Instrument (SASBDB): PETRA III EMBL P12 (DESY; Hamburg, Germany), detector Pilatus 2M;
# wavelength 1.24 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of Human Cathepsin X in 20 mM sodium acetate, 1 mM EDTA, pH 5.5
# were collected on the EMBL P12 beam line at PETRA III (DESY, Hamburg, Germany) using a
# Pilatus 2M detector at a sample-detector distance of 3 m and at a wavelength of λ =
# 0.124 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). Solute
# concentrations ranging between 0.5 and 1.5 mg/ml were measured at ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "20 mM sodium acetate, 1 mM EDTA", pH 5.5.
# Acetate: 20 mM total at pH 5.5 (pK(22 C) = 4.756, Davies I = 0.0173 M): the anionic
# fraction is 0.8634, so the split is sodium acetate 17.268 mM and acetic acid 2.732 mM
# (sigma 0.627 mM); Na+ comes with the salt, so there is no separate counter-ion. Assumed:
# the pH is set with acetic acid/sodium acetate. The pH is taken as set at room
# temperature (22 +-3 C). Concentrations carry a 2 % sigma unless stated. Every solute
# below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1729-3.919 nm-1),
# converted to A-1 (divide by 10): q 0.01729-0.3919 A-1, 1368 rows, 0 with sigma <= 0
# (dropped by the fit subset), 79 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header '1ef7-dim Dro:0.075 Ra:1.800
# RGT:24.50 Vol: 63940. Chi^2: 1.130', SASBDB chi2 1.13; recomputed from the .fit columns
# 2-4: chi2 1.130. Model SASDJQ7_fit1_model1.pdb: 3816 ATOM records (heavy atoms), no
# HETATM, chains AB, no hydrogens; SASBDB model = PDB 1EF7 (identical) (PDB (Protein Data
# Bank)). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 3816 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 5.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Acetate: 20 mM total at pH 5.5 (pK(22 C) = 4.756, Davies I =
# 0.0173 M): the anionic fraction is 0.8634, so the split is sodium acetate 17.268 mM and
# acetic acid 2.732 mM (sigma 0.627 mM); Na+ comes with the salt, so there is no separate
# counter-ion. Assumed: the pH is set with acetic acid/sodium acetate. Every solute below
# is in the bundled tables.
const SOLUTES = Solute[
    # acetate part as sodium acetate (17.268 mM)
    NonBiological(0.0172684, 0.000627, "sodium acetate"),
    # protonated part as acetic acid (2.732 mM)
    NonBiological(0.00273162, 0.000627, "acetic acid"),
    NonBiological(0.001, 2e-05, "H2EDTA"),   # 1 mM EDTA as H2EDTA(2-), ±2%
    NonBiological(0.002, 4e-05, "sodium(1+)"),   # its two Na+ (Na2EDTA assumed), ±2%
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
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.13",
    pdb = "SASDJQ7_fit1_model1.pdb",
    fit = "SASDJQ7_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),
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

# Builds the Seed that `runSasdjq7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjq7` below is the whole story (build the seed, then sample it).
function seedSasdjq7(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjq7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdjq7(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjq7(run)

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

    # `@__DIR__` (this SASDJQ7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
