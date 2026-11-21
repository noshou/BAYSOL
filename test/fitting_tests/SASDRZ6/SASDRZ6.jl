# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDRZ6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRZ6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDRZ6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDRZ6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRZ6: THSD7A (Thrombospondin type-1 domain-containing protein 7A; Homo
# sapiens; 16.656 kDa SASBDB molecule MW, monomer) in the SASBDB buffer "25mM Tris, 150 mM
# NaCl, 5 mM NaNO3", pH 7.5. Sample: D1-D2 N-terminal domains of thrombospondin type-1
# domain-containing protein 7A.
#
# Publication: Bochel A, Mortensen S, Seifert L, Hengel F, Jeffries C, Chojnowski G, Kretz
# O, Huber T, Tomas N, Wilmanns M, "Structure of the N-terminal didomain d1_d2 of the
# Thrombospondin type-1 domain-containing 7A", preprint/unpublished (2023 May 04), DOI
# 10.1101/2023.05.03.539264. Entry: https://www.sasbdb.org/data/SASDRZ6/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.124 nm = 1.24 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9999 eV); cell temperature 20.0
# °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.01955 to 7.335 1/nm, 2620 points)
# and is converted to Å⁻¹ (÷10); 26 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.088); model:
# alphafold Q9UPZ6 (identical); SASBDB model software: AlphaFold Protein Structure
# Database. SASDRZ6_fit1_model1.pdb: 1164 ATOM records (147 residues, chains A), 1164
# heavy atoms, no hydrogens; one structure only.
# The fit file SASDRZ6_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.088
# Rg: 24.03 Vol:  20572. Chi^2: 1.088"; χ² recomputed from the file with the data's σ is
# 1.088 (label 1.088), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
# The depositor fit covers q ≤ 0.5 Å⁻¹ only while the data run to 0.7335 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, SASBDB wavelength 1.24 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "25mM Tris, 150 mM NaCl, 5 mM NaNO3", pH 7.5 (SASBDB). Tris pK 8.072 (25 °C, ΔH
# 47.45 kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json)
# moved to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the
# self-consistent ionic strength I = 0.176 M gives pK' = 8.279. The protonated fraction
# of 25 mM is 0.857; with HCl titration the counter-ion is chloride 21.44 mM (σ 1.12 mM:
# σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    NonBiological(0.005, 0.0001, "sodium nitrate"),   # 5 mM, ±2%
    # counter-ion of the HCl titration, 21.44 mM
    NonBiological(0.021437, 0.00112, "chloride"),
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

# Builds the Seed that `runSasdrz6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdrz6` below is the whole story (build the seed, then sample it).
function seedSasdrz6()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdrz6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdrz6()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdrz6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.088",
)

# `@__DIR__` (this SASDRZ6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
