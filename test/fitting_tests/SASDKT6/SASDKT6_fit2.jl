# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDKT6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDKT6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDKT6: Replicase polyprotein 1ab (non-structural protein 14) (nsp14, P0DTD1,
# Severe acute respiratory syndrome coronavirus 2, 60.131 kDa x 1). SARS-CoV-2
# non-structural protein 14 (nsp14). Publication: Matsuda A, Plewka J, Rawski M, Mourão A,
# Zajko W, Siebenmorgen T, Kresik L, Lis K, Jones A, Pachota M, Karim A, Hartman K, Nirwal
# S, Sonani R, Chykunova Y, Minia I, Mak P, Landthaler M, Nowotny M, Dubin G, Sattler M,
# Suder P, Popowicz G, Pyrć K, Czarna A, "Despite the odds: formation of the SARS-CoV-2
# methylation complex", Nucleic Acids Research (2024), DOI 10.1093/nar/gkae165 (the paper
# was NOT consulted, except where stated: every condition below is the SASBDB entry
# metadata, flagged). Entry: https://www.sasbdb.org/data/SASDKT6/.
#
# Instrument (SASBDB): ESRF BM29 (Grenoble, France), detector Pilatus 1M; wavelength 1 A
# (SASBDB wavelength field / experiment description); energy HC/lambda. Temperature: the
# 25 C DEFAULT (SASBDB gives no temperature for this entry; flagged). SASBDB experiment
# description: "Synchrotron SAXS data from solutions of SARS-CoV-2 non-structural protein
# 14 (nsp14) in 50 mM Tris, 150 mM NaCl, 5 mM MgCl2, 2 mM β-mercaptoethanol, pH 8.5 were
# collected on the BM29 beam line at the ESRF (Grenoble, France) using a Pilatus 1M
# detector at a sample-detector distance of 2.8 m and at a wavelength of λ = 0.1 nm (I(s)
# vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). In-line size-exclusion ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "50 mM Tris, 150 mM NaCl, 5 mM MgCl2, 2 mM
# β-mercaptoethanol", pH 8.5. Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 50 mM Tris (pK(22 C) = 8.157) at pH 8.5 with Davies activities at I =
# 0.1838 M: the cationic (protonated) fraction is 0.3767, so Cl- = C x 0.3767 = 18.84 mM
# (sigma 3.64 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). The pH is taken as set at
# room temperature (22 +-3 C). Concentrations carry a 2 % sigma unless stated. Every
# solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.2055-2.605 nm-1),
# converted to A-1 (divide by 10): q 0.02055-0.2605 A-1, 468 rows, 0 with sigma <= 0
# (dropped by the fit subset), 11 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit2_model1): CRYSOL fit, header 'nsp14.pd Dro:0.013 Ra:1.800
# RGT:31.46 Vol: 78492. Chi^2: 1.234', SASBDB chi2 1.234; recomputed from the .fit columns
# 2-4: chi2 1.234. Model SASDKT6_fit2_model1.pdb: 4111 ATOM records (heavy atoms), no
# HETATM, chains B, no hydrogens; SASBDB model = PDB 5C8U (derived) (PyMOL). Depositor
# chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 4111 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1   # wavelength 1 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 50 mM Tris (pK(22 C) = 8.157) at pH 8.5 with Davies activities at I =
# 0.1838 M: the cationic (protonated) fraction is 0.3767, so Cl- = C x 0.3767 = 18.84 mM
# (sigma 3.64 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.0188358, 0.003644, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM MgCl2, ±2%
    NonBiological(0.002, 4e-05, "2-mercaptoethanol"),   # 2 mM beta-mercaptoethanol, ±2%
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
    refChi2 = "CRYSOL 1.234",
    pdb = "SASDKT6_fit2_model1.pdb",
    fit = "SASDKT6_fit2.fit",
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

# Builds the Seed that `runSasdkt6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdkt6` below is the whole story (build the seed, then sample it).
function seedSasdkt6(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdkt6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdkt6(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdkt6(run)

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

    # `@__DIR__` (this SASDKT6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
