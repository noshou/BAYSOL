# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDAH5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAH5.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDAH5_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDAH5_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDAH5: Hfq (RNA chaperone Hfq; Escherichia coli; 11.2 kDa SASBDB molecule MW,
# hexamer) in the SASBDB buffer "50 mM Tris-HCL 150 mM NaCl 1.0 mM DTT", pH 8.8. Sample:
# Complex of Hfq with DsrA.
#
# Publication: Ribeiro Ede A Jr, Beich-Frandsen M, Konarev PV, Shang W, Vecerek B,
# Kontaxis G, Hämmerle H, Peterlik H, Svergun DI, Bläsi U, Djinović-Carugo K, "Structural
# flexibility of RNA as molecular basis for Hfq chaperone function.", Nucleic Acids Res
# (2012 Sep), DOI 10.1093/nar/gks510. Entry: https://www.sasbdb.org/data/SASDAH5/.
#
# BUFFER SOURCE (paper first, SASBDB second; they DISAGREE): the paper (Nucleic Acids Res
# 2012, see the Publication line) measured the SAXS samples in "50 mM bicine buffer, pH
# 8.8, containing 100 mM NaCl and 250 mM KCl" at 35 °C (X33, EMBL, λ = 1.5 Å). SASBDB says
# "50 mM Tris-HCl, 150 mM NaCl, 1.0 mM DTT", pH 7.5. The paper is followed, so Bicine (pK
# 8.334, dpK/dT -0.0155, ΔH 26.34 kJ/mol of buffer_templates.json, NaOH titrant) and no
# DTT; the bicine template and the "bicine" solute exist, so nothing is missing.
#
# Instrument and conditions (SASBDB): DORIS III, DESY, Hamburg, beamline EMBL X33, X-ray
# synchrotron, detector Pilatus 1M-W; wavelength 0.15 nm = 1.5 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 8266 eV); cell temperature 35.0
# °C; sample-detector distance 2.7 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.1138 to 6.016 1/nm, 2160 points)
# and is converted to Å⁻¹ (÷10); 54 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is None (chi_square_value 2.25); model:
# SASBDB model software: SASREF. SASDAH5_fit1_model1.pdb: 4193 ATOM records (642 residues,
# chains ABN), 4193 heavy atoms, no hydrogens; one structure only.
# The fit file SASDAH5_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "sExp iExp Err
# iFit // ChiExp =   1.50"; χ² recomputed from the file with the data's σ is 2.235 (label
# 2.25), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.3002 Å⁻¹ only while the data run to 0.6016 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: SASBDB and the paper disagree on the buffer (Tris pH 7.5 vs bicine pH 8.8); the
# paper is used; the .fit header says "ChiExp = 1.50" (a root, 1.5² = 2.25), the software
# is not stated in SASBDB; wired as a depositor reference; whole entry wired from the
# files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.8, PH_METER_SIGMA   # SASBDB pH 8.8 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, SASBDB wavelength 1.5 Å
const TEMPERATURE_C = 35.0   # SASBDB cell temperature

# Buffer "50 mM Tris-HCL 150 mM NaCl 1.0 mM DTT", pH 8.8 (SASBDB). Bicine pK 8.334 (25
# °C, ΔH 26.34 kJ/mol, dpK/dT -0.0155, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.380; Davies (A = 0.509) at the self-consistent ionic strength I = 0.389 M
# gives pK' = 8.244. The deprotonated (anionic) fraction of 50 mM is 0.782; with NaOH
# titration the counter-ion is sodium 39.12 mM (σ 2.36 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "bicine"),   # 50 mM Bicine, ±2%
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM, ±2%
    NonBiological(0.25, 0.005, "potassium chloride"),   # 250 mM, ±2%
    # counter-ion of the NaOH titration, 39.12 mM
    NonBiological(0.039117, 0.00236, "sodium"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`iExp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdah5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdah5` below is the whole story (build the seed, then sample it).
function seedSasdah5()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdah5(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdah5()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdah5()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "depositor fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "depositor 2.25",
)

# `@__DIR__` (this SASDAH5/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
