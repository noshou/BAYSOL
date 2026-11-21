# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDCR9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCR9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDCR9: DARPin D1 (monomer, 17.886 kDa); Kif2A (monomer, 47.834 kDa); alpha
# tubulin (dimer, 50.151 kDa); beta tubulin (dimer, 49.936 kDa), measured at G1.
# Publication: Trofimova D et al., "Ternary complex of Kif2A-bound tandem tubulin
# heterodimers represents a kinesin-13-mediated microtubule depolymerization reaction
# intermediate." Nat Commun 2018, DOI 10.1038/s41467-018-05025-7 (SASBDB metadata only; the
# paper was not consulted). Entry: https://www.sasbdb.org/data/SASDCR9/.
#
# Instrument (SASBDB): wavelength 0.1267 nm (hc/lambda = 9786 eV). Temperature: 22 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: 'HEPES 20 mM, MgCl2 1mM, NaCl 150mM', pH 7.2. Paper not
# consulted (SASBDB metadata only). LARGE: Kif2A-tubulin-DARPin complex, 17769 heavy atoms
# with GTP, GDP, ANP, MG and PO4 ligands. SASBDB cell temperature 22 C.
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.00859-0.2735 A-1, 464 rows, 0
# with sigma <= 0, 64 with a non-positive intensity. No q cut.
#
# Model and depositor fit (fit2_model1): CRYSOL fit (header 'Kif2A_Tu Dro:0.062 Ra:1.520
# RGT:55.81 Vol:328909. Chi^2: 1.087'; SASBDB chi2 1.087) against SASDCR9_fit2_model1.pdb:
# single atomic model: 17769 heavy atoms, chain(s) ABCDEGHIPx, no hydrogens, HETATM GTP x64,
# MG x5, GDP x56, PO4 x5, ANP x31. The .fit has 4 columns (q, I_exp, sigma, I_fit); the
# reference curve is column 4, not rescaled. Header Chi^2 1.087 (SASBDB 1.087); recomputed
# 1.090. fit2 of SASBDB.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.267   # wavelength 1.267 Å
const TEMPERATURE_C = 22.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 20 mM at pH 7.2, 22 C (hepes template, Davies at I =
# 0.160 M): 6.89 mM Na+ from the NaOH titration (sigma 1.20 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.2, 6.89 mM
    NonBiological(0.006892, 0.001195, "sodium(1+)"),
    NonBiological(0.001, 2e-05, "magnesium chloride"),   # 1 mM MgCl2, +-2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
]

# No q cut: the README noise-floor rule is not met over any useful part of the curve.
const Q_MAX_FIT = Inf

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the
# file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    refChi2 = "CRYSOL 1.087",
    pdb = "SASDCR9_fit2_model1.pdb",
    fit = "SASDCR9_fit2.fit",
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

# Builds the Seed that `runSasdcr9` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdcr9` below is the whole story).
function seedSasdcr9(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdcr9(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdcr9(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdcr9(run)

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

    # `@__DIR__` (this SASDCR9/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
