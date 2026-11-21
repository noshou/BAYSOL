# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDPW7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPW7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDPW7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDPW7_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPW7: FAD-dependent monooxygenase from Stenotrophomonas maltophilia (with
# reducing agent) (Monooxygenase (M154I, A283T); Stenotrophomonas maltophilia; 38.941 kDa
# SASBDB molecule MW, monomer) in the SASBDB buffer "25 mM Bis-Tris, 150 mM NaCl, 30 mM
# DTT", pH 6.5. Sample: FAD-dependent monooxygenase from Stenotrophomonas maltophilia
# (with reducing agent).
#
# Publication: Malý M, Kolenko P, Stránský J, Švecová L, Dušková J, Koval' T, Skálová T,
# Trundová M, Adámková K, Černý J, Božíková P, Dohnálek J, "Tetracycline-modifying enzyme
# Sm               TetX from Stenotrophomonas maltophilia", Acta Crystallographica Section
# F Structural Biology Communications (2023 Jul 05), DOI 10.1107/S2053230X23005381. Entry:
# https://www.sasbdb.org/data/SASDPW7/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH; comment: reducing agent DTT for
# breaking of potential disulfide bridges); the publication was NOT read for this entry,
# so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Institute of Biotechnology, Czech Academy of
# Sciences/Centre of Molecular Structure, Vestec, beamline Anton Paar SAXSpoint 2.0, X-ray
# in house, detector Eiger R 1M; wavelength 0.134 nm = 1.34 Å (the `wavelength` field is
# in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9253 eV); cell temperature 4.0 °C;
# sample-detector distance 0.826 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.1289 to 3.997 1/nm, 674 points) and
# is converted to Å⁻¹ (÷10); 84 points have I ≤ 0. q cut at 0.3376 Å⁻¹ (README rule):
# above it there are 108 points with a median I/σ of 0.49, 38 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.68.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 0.894); model:
# SASBDB model software: REFMAC. SASDPW7_fit1_model1.pdb: 2611 ATOM records (348 residues,
# chains C), 2665 heavy atoms, no hydrogens; HETATM groups kept as ligands: FAD 53 atoms,
# CL 1 atoms; one structure only. PDB title: "HEADER    ----
# 15-DEC-21   xxxx".
# The fit file SASDPW7_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "sx1392_3
# Dro:0.030  Ra:1.800  RGT:22.50  Vol: 50134.  Chi^2: 0.894"; χ² recomputed from the file
# with the data's σ is 0.890 (label 0.894), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.1301 Å⁻¹ only while the data run to 0.3997 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: ligand HETATM groups scattered with the protein; the model is a preliminary model
# of PDB 8AQ8 chain C with FAD; sibling of the wired SASDPV7; buffer from SASBDB only
# (paper not read); Bis-Tris constants are `verified: false` in buffer_templates.json;
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 6.5, PH_METER_SIGMA   # SASBDB pH 6.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 4.0   # SASBDB cell temperature

# Buffer "25 mM Bis-Tris, 150 mM NaCl, 30 mM DTT", pH 6.5 (SASBDB). Bis-Tris pK 6.484
# (25 °C, ΔH 28.4 kJ/mol, dpK/dT -0.0167, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 6.534; Davies (A = 0.509) at the self-consistent ionic strength I = 0.165 M
# gives pK' = 6.656. The protonated fraction of 25 mM is 0.589; with HCl titration the
# counter-ion is chloride 14.72 mM (σ 1.72 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "bis-tris"),   # 25 mM Bis-Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 14.72 mM
    NonBiological(0.01472, 0.00171, "chloride"),
    NonBiological(0.03, 0.0006, "dtt"),   # 30 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.3376 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.49, 38 % of the points non-positive).
const Q_MAX_FIT = 0.3376

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

# Builds the Seed that `runSasdpw7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdpw7` below is the whole story (build the seed, then sample it).
function seedSasdpw7()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpw7(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdpw7()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpw7()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 0.894",
)

# `@__DIR__` (this SASDPW7/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
