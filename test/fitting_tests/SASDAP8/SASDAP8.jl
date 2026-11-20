# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDAP8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAP8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDAP8_fit1_model1_clean.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDAP8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDAP8: kLBS1-2 DNA (kLBS1-2 DNA; unidentified herpesvirus; 24.0 kDa SASBDB
# molecule MW, monomer) in the SASBDB buffer "Tris", pH 7.6. Sample: kLBS1-2 DNA.
#
# Publication: Ponnusamy R, Petoukhov MV, Correia B, Custodio TF, Juillard F, Tan M, Pires
# de Miranda M, Carrondo MA, Simas JP, Kaye KM, Svergun DI, McVey CE, "KSHV but not MHV-68
# LANA induces a strong bend upon binding to terminal repeat viral DNA.", Nucleic Acids
# Res (2015 Nov 16), DOI 10.1093/nar/gkv987. Entry: https://www.sasbdb.org/data/SASDAP8/.
#
# BUFFER SOURCE (paper first, SASBDB second): the paper (Nucleic Acids Res 2015, see the
# Publication line) gives no buffer in its SAXS section; the only Tris in the paper is the
# annealing buffer "11.1 mM Tris pH 7.6, 55.5 mM NaCl, 5.5 mM MgCl2", which is used
# (SASBDB gives only "Tris", pH 7.6, no concentration). The paper's Table 3 lists this
# entry (kLBS1-2, 38 bp) at BM29 with λ = 0.09 nm and 293 K, so T = 20 °C and 0.9 Å are
# used; SASBDB has no temperature and says 0.93 Å (the model energy is that of 0.9 Å; the
# difference is 3 %). The model has GUA/CYT/THY/ADE residue names (a legacy naming); in
# the cleaned copy SASDAP8_fit1_model1_clean.pdb they are renamed DG/DC/DT/DA (columns
# 18-20 only), the original is kept next to it.
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus 1M; wavelength 0.9 nm = 9 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 1378 eV); cell temperature 20.0 °C;
# sample-detector distance 2.43 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.1031 to 4.967 1/nm, 1028 points)
# and is converted to Å⁻¹ (÷10); 348 points have I ≤ 0. q cut at 0.249 Å⁻¹ (README rule):
# above it there are 523 points with a median I/σ of -0.42, 67 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.96.
#
# Model and depositor fit: fit 1 of the entry is None (chi_square_value 2.879); model:
# SASBDB model software: CRYSOL. SASDAP8_fit1_model1_clean.pdb: 2522 ATOM records (80
# residues, chains AB), 2522 heavy atoms, no hydrogens; one structure only.
# The fit file SASDAP8_fit1.fit has 3 columns (q, I_exp, I_fit; no σ), header "ktr12.pd
# Dro:0.075  Ra:1.400  RGE:36.94  RGT:38.90  Vol: 19525.  Chi^2: 2.879"; label χ² 2.879
# (not recomputed: the file has no σ column), so the reference curve is column 3; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: Tris concentration is the annealing buffer of the paper, not stated for the SAXS
# measurement; SASBDB has no temperature and wavelength 0.93 Å; the paper's 293 K and 0.9
# Å are used; DNA model with residue names renamed in a cleaned copy; whole entry wired
# from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.6, PH_METER_SIGMA   # SASBDB pH 7.6 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 9   # ≈ 1378 eV, SASBDB wavelength 9 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "Tris", pH 7.6 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279,
# the constants of tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken
# as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength
# I = 0.081 M gives pK' = 8.256. The protonated fraction of 11.1 mM is 0.819; with HCl
# titration the counter-ion is chloride 9.09 mM (σ 0.58 mM: σ_pH 0.1, ±3 °C, ±0.02 pK,
# 30 % of the Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.0111, 0.000222, "tris"),   # 11.1 mM Tris, ±2%
    NonBiological(0.0555, 0.00111, "sodium chloride"),   # 55.5 mM, ±2%
    NonBiological(0.0055, 0.00011, "magnesium chloride"),   # 5.5 mM, ±2%
    # counter-ion of the HCl titration, 9.09 mM
    NonBiological(0.009093, 0.000576, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.28 Å⁻¹ (README rule (b)); the median I/σ is 4.4 at 0.21 to 0.25 Å⁻¹ and
# 1.3 at 0.25 to 0.29. The cut of the first run, 0.249 Å⁻¹, left tail ESS 305 (four MAP
# modes) at every rung; at 0.28 the run converges after the ladder's second rung.
const Q_MAX_FIT = 0.28

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

# Builds the Seed that `runSasdap8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdap8` below is the whole story (build the seed, then sample it).
function seedSasdap8(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdap8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdap8(; seed)
    # start radii (1, 2, 3) instead of (4, 10, 20): in the first run the 14 chains, eight of
    # them from the far starts (±10, ±20) and the others from secondary modes, did not mix
    # (bulk ESS 170, tail ESS 47 to 206, R̂ 1.02 to 1.03; two chains sat at step size 0 with
    # 1023-step trees), while the chains of the main mode were healthy (ε about 0.4)
    res = BAYSOL.runModel(s, nSamples, nAdapt; chainStartRadii = (1.0, 2.0, 3.0))
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdap8()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, I_fit (no σ).
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 3]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 2.879",
)

# `@__DIR__` (this SASDAP8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
