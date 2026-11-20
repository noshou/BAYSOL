# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDDH7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDDH7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDDH7_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDDH7_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDDH7: CitAP-BsLA (citrate-binding CitAP domain fused to lipase A of Bacillus
# subtilis BsLA; None; 38.495 kDa SASBDB molecule MW, dimer) in the SASBDB buffer "10 mM
# glycine buffer, 10 mM NaCl, 1 mM sodium citrate", pH 10.0. Sample: Citrate-binding PAS
# domain from the sensor histidine kinase, CitA, fused to lipase EstA in the presence of
# citrate.
#
# Publication: Kaschner M, Schillinger O, Fettweiss T, Nutschel C, Krause F, Fulton A,
# Strodel B, Stadler A, Jaeger KE, Krauss U, "A combination of mutational and
# computational scanning guides the design of an artificial ligand-binding controlled
# lipase.", Sci Rep (2017 Feb 20), DOI 10.1038/srep42592. Entry:
# https://www.sasbdb.org/data/SASDDH7/.
#
# BUFFER SOURCE (paper first, SASBDB second): the paper (Sci Rep 2017, see the Publication
# line) gives "10 mM glycine buffer pH 10, 10 mM NaCl (± citrate), 10 °C sample
# temperature" (BM29). SASBDB gives 10 mM glycine, 10 mM NaCl, 1 mM Na citrate, pH 10 and
# a cell temperature of 20 °C. The paper's 10 °C is used (SASBDB disagrees); the 1 mM
# citrate is that of the "+ citrate" dataset of SASBDB. Citrate enters as trisodium
# citrate ("sodium citrate" is not in the solute table); fit 2 of the entry is the CRYSOL
# one (fit 1 is DAMMIF).
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus 1M; wavelength 0.09919 nm = 0.9919 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 12500 eV); cell temperature 10.0 °C;
# sample-detector distance 2.849 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.03606 to 5.012 1/nm, 1036 points)
# and is converted to Å⁻¹ (÷10); 1 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 2.262); model:
# SASBDB model software: GROMACS. SASDDH7_fit2_model1.pdb: 5396 ATOM records (710
# residues, chains AB), 5396 heavy atoms, no hydrogens; one structure only.
# The fit file SASDDH7_fit2.fit has 4 columns (q, I_exp, σ, I_fit), header "dimer_fr
# Dro:0.052  Ra:1.640  RGT:33.85  Vol:101102.  Chi^2: 2.262"; χ² recomputed from the file
# with the data's σ is 2.254 (label 2.262), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: SASBDB cell temperature 20 °C disagrees with the paper (10 °C); the paper is
# used; citrate charge state not stated, trisodium citrate assumed (1 mM, small effect);
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 10.0, PH_METER_SIGMA   # SASBDB pH 10.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.9919   # ≈ 12500 eV, SASBDB wavelength 0.9919 Å
const TEMPERATURE_C = 10.0   # SASBDB cell temperature

# Buffer "10 mM glycine buffer, 10 mM NaCl, 1 mM sodium citrate", pH 10.0 (SASBDB).
# Glycine pK 9.78 (25 °C, ΔH 44.2 kJ/mol, dpK/dT -0.026, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 9.858; Davies (A = 0.509) at the self-consistent ionic strength I = 0.016 M
# gives pK' = 9.803. The deprotonated (anionic) fraction of 10 mM is 0.611; with NaOH
# titration the counter-ion is sodium 6.11 mM (σ 0.71 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "glycine"),   # 10 mM Glycine, ±2%
    NonBiological(0.01, 0.0002, "sodium chloride"),   # 10 mM, ±2%
    # counter-ion of the NaOH titration, 6.11 mM
    NonBiological(0.006114, 0.000706, "sodium"),
    # 1 mM sodium citrate (taken as trisodium citrate), ±2%
    NonBiological(0.001, 2e-05, "trisodium citrate"),
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

# Builds the Seed that `runSasddh7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasddh7` below is the whole story (build the seed, then sample it).
function seedSasddh7(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasddh7(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasddh7(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasddh7()

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
    refChi2 = "CRYSOL 2.262",
)

# `@__DIR__` (this SASDDH7/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
