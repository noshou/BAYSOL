# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDV46")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDV46.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDV46_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDV46_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDV46: tau4RD domain (Isoform Tau-F of Microtubule-associated protein tau
# (C291A, K311C, K317C, C322A); Homo sapiens; 13.7 kDa SASBDB molecule MW, monomer) in the
# SASBDB buffer "100 mM NaCl", pH 6.8. Sample: Microtubule-associated protein tau, lysine-
# rich four-repeat domain 4RD.
#
# Publication: Viola G, Trivellato D, Laitaoja M, Jänis J, Felli IC, D'Onofrio M, Mollica
# L, Giachin G, Assfalg M, "Conformational signatures induced by ubiquitin modification in
# the amyloid-forming tau repeat domain.", Proc Natl Acad Sci U S A (2025 Apr 15), DOI
# 10.1073/pnas.2425831122. Entry: https://www.sasbdb.org/data/SASDV46/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.123972 nm = 1.24 Å (the `wavelength`
# field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 10001 eV); cell
# temperature 20.0 °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.08969 to 4.004 1/nm, 1354 points)
# and is converted to Å⁻¹ (÷10); 0 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 1.742); model:
# SASBDB model software: AMBER. SASDV46_fit2_model1.pdb: 1971 ATOM records (130 residues,
# chains  ), 1971 heavy atoms, no hydrogens; one structure only. PDB title: "TITLE
# Protein in water t= 4600.00000 step= 2300000".
# The fit file SASDV46_fit2.fit has 4 columns (q, I_exp, σ, I_fit), header "Tau_46.p
# Dro:0.043  Ra:1.780  RGT:31.86  Vol: 17542.  Chi^2: 1.742"; χ² recomputed from the file
# with the data's σ is 1.738 (label 1.742), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: buffer from SASBDB only (paper not read); no buffering species: 100 mM NaCl only,
# the pH is the stated value; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 6.8, PH_METER_SIGMA   # SASBDB pH 6.8 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.2397   # ≈ 10001 eV, SASBDB wavelength 1.2397 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "100 mM NaCl", pH 6.8 (SASBDB): no buffering species, only the salts below.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM, ±2%
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

# Builds the Seed that `runSasdv46` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdv46` below is the whole story (build the seed, then sample it).
function seedSasdv46(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdv46(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdv46(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdv46()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.742",
)

# `@__DIR__` (this SASDV46/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
