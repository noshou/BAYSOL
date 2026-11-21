# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDTV4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTV4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDTV4_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDTV4_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTV4: Fe8×FerSUMO (Bacterial non-heme ferritin (N19Q, I59V, N-terminal His-
# SUMO fusion); Helicobacter pylori (strain J99 / ATCC 700824); 31.469 kDa SASBDB molecule
# MW, octamer) in the SASBDB buffer "25 mM Tris, 150 mM NaCl", pH 7.4. Sample: 8×FerSUMO -
# Chimeric protein complex of ferritin from Helicobacter pylori fused to an N-terminal
# His6-SUMO protein tag.
#
# Publication: Sudarev V, Gette M, Bazhenov S, Tilinova O, Zinovev E, Manukhov I, Kuklin
# A, Ryzhykau Y, Vlasov A, "Ferritin-based fusion protein shows octameric deadlock state
# of self-assembly", Biochemical and Biophysical Research Communications (2024 Jan), DOI
# 10.1016/j.bbrc.2023.149276. Entry: https://www.sasbdb.org/data/SASDTV4/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH; comment: pH 7.4; Tris, 25mM; NaCl,
# 150 mM); the publication was NOT read for this entry, so no value was checked against
# the paper.
#
# Instrument and conditions (SASBDB): Moscow Institute of Physics and Technology (MIPT),
# Dolgoprudny, beamline Rigaku MicroMax 007-HF, X-ray in house, detector Multiwire gas-
# filled ASM DTR Triton 200; wavelength 0.15406 nm = 1.541 Å (the `wavelength` field is in
# nm; `xray_energy` is null, so the energy is hc/λ ≈ 8048 eV); cell temperature 20.0 °C;
# sample-detector distance 2.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.007 to 0.214 1/A, 415 points) and is
# in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 84
# points have I ≤ 0. q cut at 0.12 Å⁻¹ (README rule): above it there are 188 points with a
# median I/σ of 0.18, 44 % of them non-positive, and the lowest-q quarter of them has a
# median I/σ of 0.94.
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 1.066); model:
# SASBDB model software: AlphaFold. SASDTV4_fit2_model1.pdb: 34808 ATOM records (2192
# residues, chains ABCDEFGH), 17736 heavy atoms, 17072 hydrogens (replaced by
# pdb2pqr/PROPKA); one structure only.
# The fit file SASDTV4_fit2.fit has 4 columns (q, I_exp, σ, I_fit), header "_FerSumo
# Convex:  0.000  Concave: -2.400  Inner:   2.00  Chi^2: 1.066"; χ² recomputed from the
# file with the data's σ is 1.061 (label 1.066), so the reference curve is column 4; q in
# Å⁻¹ (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.1305 Å⁻¹ only while the data run to 0.214 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: large structure (17736 heavy atoms); AlphaFold prediction (no experimental
# structure); buffer from SASBDB only (paper not read); whole entry wired from the files
# above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5406   # ≈ 8048 eV, SASBDB wavelength 1.5406 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "25 mM Tris, 150 mM NaCl", pH 7.4 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.172 M gives pK' = 8.279. The protonated fraction of 25
# mM is 0.883; with HCl titration the counter-ion is chloride 22.08 mM (σ 0.98 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 22.08 mM
    NonBiological(0.02208, 0.000984, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.12 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.18, 44 % of the points non-positive).
const Q_MAX_FIT = 0.12

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has hydrogens, replaced here: pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `runSasdtv4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdtv4` below is the whole story (build the seed, then sample it).
function seedSasdtv4()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdtv4(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdtv4()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdtv4()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.066",
)

# `@__DIR__` (this SASDTV4/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
