# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDA38")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDA38.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDA38: TGA (monomer, 79.491 kDa), measured at EMBL P12. Publication: Chen X et
# al., "Structural Basis for Antigen Recognition by Transglutaminase 2-specific
# Autoantibodies in Celiac Disease." J Biol Chem 2015, DOI 10.1074/jbc.M115.669895 (SASBDB
# metadata only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDA38/.
#
# Instrument (SASBDB): wavelength 0.12 nm (hc/lambda = 10332 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM Tris 150mM NaCl 1mM EDTA', pH 7.2. Paper not
# consulted (SASBDB metadata only). EDTA taken as the disodium salt (flagged).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.01994-4.509 nm-1), converted to A-1 (divide
# by 10): q 0.00199-0.4509 A-1, 1705 rows, 0 with sigma <= 0, 57 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 1.1.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'new_tg_c Dro:0.028 Ra:1.800
# RGE:32.73 RGT:30.60 Vol:103193. Chi:1.228'; SASBDB chi2 1.51) against
# SASDA38_fit1_model1.pdb: single atomic model: 5419 heavy atoms, chain(s) E, no hydrogens.
# The .fit has 3 columns (q, I_exp, I_fit); the reference curve is column 3, not rescaled.
# SASBDB chi2 1.51, which the recomputation reproduces (1.508); the .fit header says 1.228.
# The model carries a single chain labelled E.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # wavelength 1.2 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 20 mM at pH 7.2, 10 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.173 M): 19.30 mM Cl- from the HCl titration
# (sigma 0.45 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, +-2%
    # Cl- of the HCl titration to pH 7.2, 19.30 mM
    NonBiological(0.019299, 0.000447, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
    NonBiological(0.001, 2e-05, "H2EDTA"),   # 1 mM EDTA, +-2%
    NonBiological(0.002, 4e-05, "sodium(1+)"),   # Na+ of disodium EDTA (assumed salt), 2 mM
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
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.51",
    pdb = "SASDA38_fit1_model1.pdb",
    fit = "SASDA38_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
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

# Builds the Seed that `runSasda38` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasda38` below is the whole story).
function seedSasda38(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasda38(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasda38(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasda38(run)

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

    # `@__DIR__` (this SASDA38/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
