# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDQS6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQS6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDQS6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDQS6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQS6: GRP78-NBD (Endoplasmic reticulum chaperone BiP; Homo sapiens; 42.042 kDa
# SASBDB molecule MW, monomer) in the SASBDB buffer "phosphate buffered saline", pH 7.2.
# Sample: Glucose-regulated protein 78 nucleotide-binding domain (GRP78-NBD) in complex
# with the C-terminal of Cerebral dopamine neurotrophic factor (C-CDNF).
#
# Publication: Graewert MA, Volkova M, Jonasson K, Määttä JAE, Gräwert T, Mamidi S,
# Kulesskaya N, Evenäs J, Johnsson RE, Svergun D, Bhattacharjee A, Huttunen HJ,
# "Structural basis of CDNF interaction with the UPR regulator GRP78.", Nat Commun (2024
# Sep 18), DOI 10.1038/s41467-024-52478-0. Entry: https://www.sasbdb.org/data/SASDQS6/.
#
# BUFFER SOURCE (paper first, SASBDB second): the paper (Nat Commun 2024, see the
# Publication line) gives PBS with 1.5 % glycerol at pH 7.2 (its Table 1 and methods);
# SASBDB gives only "phosphate buffered saline", pH 7.2, and agrees on the pH. PBS is
# entered as the standard recipe 137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4 and 1.8 mM KH2PO4
# (the composition is stated neither in the paper nor in SASBDB); the salts are entered as
# such, so no speciation is computed. The glycerol unit is not stated, v/v assumed.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.124 nm = 1.24 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9999 eV); cell temperature 20.0
# °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.07913 to 3.371 1/nm, 1181 points)
# and is converted to Å⁻¹ (÷10); 0 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.119); model:
# SASBDB model software: SREFLEX. SASDQS6_fit1_model1.pdb: 3560 ATOM records (439
# residues, chains AG), 3420 heavy atoms, 140 hydrogens (replaced by pdb2pqr/PROPKA); one
# structure only.
# The fit file SASDQS6_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "revised_
# Dro:0.010  Ra:1.800  RGT:23.47  Vol: 64499.  Chi^2: 1.119"; χ² recomputed from the file
# with the data's σ is 1.119 (label 1.119), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: glycerol (1.5 %) from the paper, not in the SASBDB buffer name; glycerol
# percentage unit not stated, v/v assumed; whole entry wired from the files above; not
# run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.2, PH_METER_SIGMA   # SASBDB pH 7.2 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, SASBDB wavelength 1.24 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "phosphate buffered saline", pH 7.2 (SASBDB): no buffering species, only the
# salts below.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.137, 0.00274, "sodium chloride"),   # 137 mM, ±2%
    NonBiological(0.0027, 5.4e-05, "potassium chloride"),   # 2.7 mM, ±2%
    NonBiological(0.01, 0.0002, "disodium hydrogen phosphate"),   # 10 mM, ±2%
    NonBiological(0.0018, 3.6e-05, "potassium dihydrogen phosphate"),   # 1.8 mM, ±2%
    NonBiological(0.2054, 0.0103, "glycerol"),   # 1.5 % v/v glycerol (assumed v/v), ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has hydrogens, replaced here: pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `runSasdqs6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdqs6` below is the whole story (build the seed, then sample it).
function seedSasdqs6()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdqs6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdqs6()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdqs6()

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
    refChi2 = "CRYSOL 1.119",
)

# `@__DIR__` (this SASDQS6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
