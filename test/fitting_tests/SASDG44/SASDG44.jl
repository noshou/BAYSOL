# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDG44")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDG44.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDG44_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDG44_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDG44: HAd3K (Human adenovirus serotype 3 fibre knob; Human adenovirus serotype
# 3; 23.072 kDa SASBDB molecule MW, trimer) in the SASBDB buffer "20 mM Tris-HCl, 150 mM
# NaCl, 3 mM CaCl2", pH 8.0. Sample: Adenovirus Ad3 fibre knob in complex with the EC2-EC3
# fragment of desmoglein 2.
#
# Publication: Vassal-Stermann E, Hutin S, Fender P, Burmeister WP, "Intermediate-
# resolution crystal structure of the human adenovirus B serotype 3 fibre knob in complex
# with the EC2-EC3 fragment of desmoglein 2.", Acta Crystallogr F Struct Biol Commun (2019
# Dec 1), DOI 10.1107/S2053230X19015784. Entry: https://www.sasbdb.org/data/SASDG44/.
#
# BUFFER SOURCE: SASBDB buffer fields (20 mM Tris-HCl, 150 mM NaCl, 3 mM CaCl2, pH 8.0).
# The paper (Acta Cryst F, see the Publication line) is not open access and could not be
# retrieved, so no value was checked against it. The SASBDB cell temperature 293.0 is
# Kelvin (the other temperatures of SASBDB are °C): 293.0 K = 20 °C (owner).
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus 1M; wavelength 0.099 nm = 0.99 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 12524 eV); cell temperature 20.0 °C;
# sample-detector distance 2.864 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.01409 to 0.2005 1/A, 332 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 1
# points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ > 0
# points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 0.795); model:
# pdb 6sit (identical); SASBDB model software: Other. SASDG44_fit1_model1.pdb: 6376 ATOM
# records (817 residues, chains ABCD), 6376 heavy atoms, no hydrogens; one structure only.
# The fit file SASDG44_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "complex3
# Dro:0.075  Ra:1.400  RGT:34.19  Vol:122272.  Chi^2: 0.795"; χ² recomputed from the file
# with the data's σ is 0.794 (label 0.795), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: SASBDB cell temperature 293.0 read as Kelvin = 20 °C; paper not retrievable (not
# open access); whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12524 eV, SASBDB wavelength 0.99 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM Tris-HCl, 150 mM NaCl, 3 mM CaCl2", pH 8.0 (SASBDB). Tris pK 8.072 (25
# °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.172 M
# gives pK' = 8.279. The protonated fraction of 20 mM is 0.655; with HCl titration the
# counter-ion is chloride 13.10 mM (σ 1.49 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    NonBiological(0.003, 6e-05, "calcium chloride"),   # 3 mM, ±2%
    # counter-ion of the HCl titration, 13.10 mM
    NonBiological(0.013103, 0.00149, "chloride"),
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

# Builds the Seed that `runSasdg44` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdg44` below is the whole story (build the seed, then sample it).
function seedSasdg44()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdg44(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdg44()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdg44()

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
    refChi2 = "CRYSOL 0.795",
)

# `@__DIR__` (this SASDG44/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
