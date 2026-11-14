# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDNW9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNW9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNW9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNW9_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDNW9: the nucleotide-binding domain of human GRP78/BiP (GRP78-NBD, UniProt
# P11021 residues 26-405, 42.04 kDa; SASBDB experimental MW 45 kDa), SEC-SAXS in
# phosphate buffered saline pH 7.2 with 1.5 % glycerol, up to 10 mg/ml loaded.
#
# Publication (SASBDB): Graewert MA, Volkova M, Jonasson K, Määttä JAE, Gräwert T,
# Mamidi S, Kulesskaya N, Evenäs J, Johnsson RE, Svergun D, Bhattacharjee A,
# Huttunen HJ, "Structural basis of CDNF interaction with the UPR regulator GRP78",
# Nat Commun 2024 (published 2024 Sep 18), DOI 10.1038/s41467-024-52478-0. Entry:
# https://www.sasbdb.org/data/SASDNW9/. The paper WAS consulted (Europe PMC full text,
# PMC11408689): its SAXS section states "All measurements were performed in PBS pH
# 7.2" and 20 °C, 10 µl injections, a Superdex 200 5/150 column, 0.35 ml/min, 1.5 %
# glycerol added to the buffer; it gives no PBS recipe (see the buffer note below).
#
# Instrument (SASBDB): EMBL beamline P12, PETRA III, DESY, Hamburg; Pilatus 6M;
# wavelength 0.124 nm = 1.24 Å (SASBDB `xray_energy` is null, so the energy is hc/λ ≈
# 9999 eV); sample-detector distance 3.0 m; 30 frames of 0.5 s (SASBDB); sample
# temperature 20 °C (SASBDB, also the paper); measured 2021-03-21.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.079 and s_max
# 3.371 nm⁻¹; two text lines, then q, I, σ, all skipped by `_readCurve`) and is
# converted to Å⁻¹ (÷10). The intensities are on an arbitrary scale. 231 of the 1181
# points have I ≤ 0 (the first one at 0.167 Å⁻¹; 52 of them below 0.24 Å⁻¹). The fit
# is cut at `Q_MAX_FIT` = 0.24 Å⁻¹ because of that noise floor (evidence at the constant;
# the depositor's CRYSOL curve ends at 0.2397 Å⁻¹); `seedModel` drops the non-positive bins.
#
# Model and depositor fit: the single fit is CRYSOL against the atomic model, which
# SASBDB states is identical to PDB 3IUC ("based on 3iuc.pdb (one chain)"; the crystal
# structure of the human BiP/GRP78 ATPase domain in complex with ADP). SASDNW9_fit1_
# model1.pdb holds chain G, residues 28-406, 2925 ATOM records, no hydrogens, B = 20.0,
# no HETATM records (no ADP, no Ca²⁺, no waters). Compared with 3IUC.pdb (beside it in
# the fixture folder): chain A of 3IUC has 2930 ATOM records and its own frame, so the
# model is NOT a verbatim copy (re-oriented, atom count differs by 5; the cause was
# not examined). The ADP and the Ca²⁺ of 3IUC are not in the model, so they are not
# scattered. The deposited fit header reads "Dro: 0.045 Rg: 22.54 Vol: 52053.
# Chi^2: 0.993", whereas SASBDB's chi_square_value is 1.014. The header is the one
# used here (HEADER over REST). The .fit file (832 points, q ≤ 0.2397 Å⁻¹; columns q
# (Å⁻¹), I_exp, σ, I_fit) recomputed from its columns 2-4 gives χ² = 0.993, so
# "Chi^2:" is χ² and the header is self-consistent; why SASBDB's 1.014 differs is not
# documented (not chased).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.2, PH_METER_SIGMA   # SASBDB and paper: pH 7.2

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, SASBDB wavelength 0.124 nm
const TEMPERATURE_C = 20.0                    # SASBDB and paper

# Buffer. SASBDB buffer name: "phosphate buffered saline", pH 7.2, no concentrations.
# Paper (Nat Commun 2024, Methods "Small angle X-ray scattering", PDF read
# in the round-6 audit, 2026-11-13): "All measurements were performed in PBS pH 7.2" and
# "The buffer was supplemented with 1.5% glycerol to reduce radiation damage" (Table 1:
# "PBS, pH 7.2, 1.5% glycerol"). The paper is the source of truth, so the 1.5 % glycerol
# of the SAXS buffer is modelled although the SASBDB buffer name omits it. The unit of
# "%" is not stated; bare % glycerol is read as v/v (project convention, ±5 %). The
# measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# PBS recipe: neither the paper nor SASBDB lists it (checked: paper main text, SASBDB
# entry page). Under the owner rule of 2026-11-13 a named standard buffer is accepted
# when its full recipe is in a citable standard reference: the Cold Spring Harbor
# Protocols "PBS (1x)" recipe, 137 mM NaCl, 2.7 mM KCl, 10 mM Na₂HPO₄, 1.8 mM KH₂PO₄
# (11.8 mM phosphate in all), with the pH adjusted to the entry's 7.2. At pH 7.2 the
# phosphate is split into HPO₄²⁻ and H₂PO₄⁻ with pK₂ = 7.198 at 25 °C (Goldberg,
# Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; the
# value quoted from the SASDV62 script and not re-checked), Davies-corrected (A = 0.509)
# at the self-consistent ionic strength I ≈ 0.168 M: HPO₄²⁻ fraction 0.700 (without the
# activity correction 0.501), i.e. 8.27 mM as disodium hydrogen phosphate and 3.53 mM as
# sodium dihydrogen phosphate (the 1.8 mM of potassium is taken as sodium salt: the K⁺
# amount is within the σ below). σ_phosphate = 0.9 mM combines σ_pH = 0.1 (±0.57 mM) and
# 30 % of the Davies shift (±0.70 mM); because the exact PBS of the lab is not named,
# the phosphate rows carry 2 mM and the NaCl row 10 % (0.014 M).
#
# Glycerol 1.5 % v/v: 0.015 L/L x 1261.3 g/L / 92.094 g/mol = 0.2054 M (the 0.1370 M per
# % of SASDRJ8), ±5 % (v/v -> molarity conversion): 0.01027 M.
const SOLUTES = Solute[
    NonBiological(0.137, 0.014, "sodium chloride"),               # 137 mM NaCl (CSHL PBS)
    NonBiological(0.0027, 0.0014, "potassium chloride"),          # 2.7 mM KCl (CSHL PBS)
    NonBiological(0.00827, 0.002, "disodium hydrogen phosphate"),   # HPO₄²⁻, 8.27 mM
    NonBiological(0.00353, 0.002, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 3.53 mM
    NonBiological(0.2054, 0.01027, "glycerol"),                   # 1.5 % v/v (paper), ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.24 Å⁻¹. The data run to 0.337 Å⁻¹,
# but the 349 points above 0.24 Å⁻¹ (σ > 0) have a median I/σ of -0.02 and 51 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.26 Å⁻¹) has a median I/σ of -0.03.
const Q_MAX_FIT = 0.24

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdnw9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdnw9` below is the whole story (build the seed, then sample it).
function seedSasdnw9(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdnw9(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdnw9(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdnw9()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 0.993",
    runLog = true,
)

# `@__DIR__` (this SASDNW9/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
