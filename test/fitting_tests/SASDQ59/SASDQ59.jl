# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDQ59")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQ59.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDQ59_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDQ59_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQ59: DpdA(D95A) (DNA-guanine transglycosylase - D95A mutant; Salmonella
# enterica subsp. enterica serovar Montevideo; 50.396 kDa SASBDB molecule MW, monomer) in
# the SASBDB buffer "100 mM KCl, 50 mM Tris pH 7.0, 1 mM DTT", pH 7.0. Sample: Mutant
# 7-deazapurine in DNA protein A (D95A).
#
# Publication: Gedara SH, Wood E, Gustafson A, Liang C, Hung SH, Savage J, Phan P, Luthra
# A, de Crécy-Lagard V, Dedon P, Swairjo MA, Iwata-Reuyl D, "7-Deazaguanines in DNA:
# functional and structural elucidation of a DNA modification system.", Nucleic Acids Res
# (2023 Mar 17), DOI 10.1093/nar/gkad141. Entry: https://www.sasbdb.org/data/SASDQ59/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Advanced Light Source (ALS), Berkeley, CA, beamline
# 12.3.1 (SIBYLS), X-ray synchrotron, detector Pilatus3 X 2M; wavelength 0.1 nm = 1 Å (the
# `wavelength` field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 12398 eV);
# cell temperature 24.9 °C; sample-detector distance 1.5 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.01039 to 0.44 1/A, 849 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 95
# points have I ≤ 0. q cut at 0.3883 Å⁻¹ (README rule): above it there are 102 points with
# a median I/σ of 0.46, 37 % of them non-positive, and the lowest-q quarter of them has a
# median I/σ of 0.24.
#
# Model and depositor fit: fit 1 of the entry is FoXS (chi_square_value 0.88563); model:
# SASBDB model software: GROMACS. SASDQ59_fit1_model1.pdb: 3540 ATOM records (436
# residues, chains  A), 3540 heavy atoms, no hydrogens; one structure only.
# The depositor's FoXS curve (SASDQ59_fit1.fit, 4 columns, χ² 0.88563) is kept in the
# fixtures but not drawn: FoXS output has a different layout, so this entry is wired
# WITHOUT a reference curve and WITHOUT `refChi2` (`results` is called without
# `references`).
#
# Flags: buffer from SASBDB only (paper not read); whole entry wired from the files above;
# not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB pH 7.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1   # ≈ 12398 eV, SASBDB wavelength 1 Å
const TEMPERATURE_C = 24.9   # SASBDB cell temperature

# Buffer "100 mM KCl, 50 mM Tris pH 7.0, 1 mM DTT", pH 7.0 (SASBDB). Tris pK 8.072 (25
# °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.147 M
# gives pK' = 8.274. The protonated fraction of 50 mM is 0.950; with HCl titration the
# counter-ion is chloride 47.48 mM (σ 1.26 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.1, 0.002, "potassium chloride"),   # 100 mM, ±2%
    # counter-ion of the HCl titration, 47.48 mM
    NonBiological(0.047476, 0.00126, "chloride"),
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.3883 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.46, 37 % of the points non-positive).
const Q_MAX_FIT = 0.3883

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`iExp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdq59` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdq59` below is the whole story (build the seed, then sample it).
function seedSasdq59()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdq59(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdq59()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdq59()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log.
# No reference curve and no refChi2 for this entry (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
)

# `@__DIR__` (this SASDQ59/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
