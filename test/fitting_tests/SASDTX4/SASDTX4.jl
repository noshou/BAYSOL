# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDTX4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTX4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDTX4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDTX4_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTX4: G-actin (rabbit skeletal muscle alpha-actin, P68135, 377 residues,
# 42.05 kDa; SASBDB experimental MW 42.1 kDa), globular monomers at 1.25 mg/ml, in 5 mM
# Tris/Tris-HCl, 0.1 mM CaCl2, 1 mM NaN3, 0.2 mM ATP, pH 8.05.
#
# Publication (SASBDB): Ryzhykau Y, Povarova O, Dronova E, Kuklina D, Antifeeva I,
# Ilyinsky N, Okhrimenko I, Semenov Y, Kuklin A, Ivanovich V, Fonin A, Uversky V,
# Turoverov K, Kuznetsova I, "Small-angle X-ray scattering structural insights into
# alternative pathway of actin oligomerization associated with inactivated state",
# Biochem Biophys Res Commun 2023 Nov, DOI 10.1016/j.bbrc.2023.149340. Entry:
# https://www.sasbdb.org/data/SASDTX4/. The paper WAS consulted (the PDF, Methods 2.1-
# 2.4 and Results 3.1): "G-actin in buffer G (0.2 mM ATP, 0.1 mM CaCl2, 1 mM NaN3, 5 mM
# Tris-HCl, pH 8.05)" (Sec. 2.1), the very buffer of the SASBDB buffer field, so pH 8.05
# is the stated value (the "~8.1" of Results 3.1 is only the pH at which the net charge
# of -17 e is quoted, and the SASBDB description's "8.1" is a rounding of it). The SAXS
# of the 1.25 mg/ml G-actin sample (initial time point) was fitted with PDB 3HBT and
# CRYSOL, chi2 = 1.037 (Sec. 3.1), the depositor's value. The instrument parameters
# (temperature, wavelength, distance) are in the paper's Table S1, which was not
# available; they are the SASBDB entry's, and the paper does not contradict them.
#
# Round-5 rescan (2026-11-13): confirmed, nothing new; the buffer sentence above is
# the only buffer statement and Table S1 (temperature, wavelength) is not in the PDF.
#
# Instrument (SASBDB): Rigaku MicroMax 007-HF (in-house source), multiwire gas-filled ASM
# DTR Triton 200 detector, Moscow Institute of Physics and Technology (MIPT),
# Dolgoprudny, Russia; wavelength 0.15406 nm (Cu K-alpha; SASBDB `xray_energy` is null,
# so the energy is hc/λ ≈ 8047 eV); sample-detector distance 2 m; one 3600 s frame; cell
# temperature 20 °C (storage 4 °C); measured 2021-07-01; SASBDB lists one concentration,
# 1.25 mg/ml (concentration_min is entered as 1.3, a typo for 1.25).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (angular_unit "1/A"; 334 points from
# 0.0140 to 0.1805 Å⁻¹; two text lines, then q, I, σ, then "range-from / range-to"
# lines, all skipped by `_readCurve`). The intensities are in arbitrary units
# (SASBDB intensity_unit). The curve is noisy (I/σ is about 5 at 0.075 Å⁻¹ and below 1.5
# beyond 0.14 Å⁻¹) and 30 of the 334 points have I ≤ 0; `seedModel` drops the
# non-positive bins. The whole curve is fitted (no q cut).
#
# Model and depositor fit: SASBDB states the atomic model is identical to PDB 3HBT
# ("The structure of native G-actin", rabbit skeletal muscle actin, ATP form). The
# fixture SASDTX4_fit1_model1.pdb is SASBDB's copy; all 2919 ATOM/HETATM records were
# checked equal (columns 1-54) to files.rcsb.org/download/3HBT.pdb, kept beside it as
# 3HBT.pdb. It holds 2810 ATOM records (chain A), one ATP (31 atoms), one Ca²⁺, one
# 3-methylhistidine (HIC, a modified amino acid the loader keeps as part of the
# polymer), five sulfate ions (SO4, crystallisation additive: not in the sample buffer
# but present in the file CRYSOL read, and kept as ligands here for the same reason)
# and 61 waters (dropped by the loader: the hydration shell stands for them). The
# deposited fit header reads "3HBT.pdb  Dro:0.075  Ra:1.680  RGT:23.97  Vol: 54571.
# Chi^2: 1.037"; the fit file (342 rows, q = 0 to 0.1805 Å⁻¹) recomputed from its
# columns 2-4 over the 334 rows with σ > 0 gives χ² = 1.036, so the label is χ² (not χ)
# and the depositor's χ² is 1.037 (SASBDB chi_square_value: the same; CRYSOL 2.0 per
# SASBDB).
#
# Ligands: the ATP and the Ca²⁺ of the model are the sample's own (0.2 mM ATP and 0.1 mM
# CaCl2 are in the buffer) and are scattered, as in CRYSOL. ATP and Ca²⁺ are ligands of
# a known composition in `components.tsv`, so the loader keeps them
# (`ligandSelector`, `KEEP_LIGANDS`); neither carries hydrogens (pdb2pqr places none on
# ligands).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A); no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.05, PH_METER_SIGMA   # SASBDB and paper (Sec. 2.1): pH 8.05

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5406   # ≈ 8047 eV, SASBDB wavelength 0.15406 nm
const TEMPERATURE_C = 20.0                    # SASBDB cell temperature (storage 4 °C)

# Buffer as deposited (SASBDB buffer name) and as in the paper (Sec. 2.1, "buffer G"):
# "5 mM Tris/Tris-HCl, 0.1 mM CaCl2, 1 mM NaN3, 0.2 mM ATP", pH 8.05; the macromolecule
# is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Counter-ion: "Tris/Tris-HCl" at a pH is modelled as Tris plus HCl (the convention of the
# other scripts, see the fitting-test README), the titrant amount from Goldberg's pK
# (Tris pK 8.072 at 25 °C, ΔH 47.45 kJ/mol; Goldberg, Kishore & Lennen 2002, J. Phys.
# Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902, quoted from the SASDAN8 script and not
# re-checked), moved to 22 °C (pH set at room temperature, 22 ± 3 °C, whatever the
# measurement temperature) by van't Hoff (pK = 8.157), Davies-corrected at the
# self-consistent ionic strength I ≈ 0.0042 M (0.5 x [BH⁺ + Cl⁻ + CaCl2 + NaN3 ions]):
# protonated fraction 0.578, Cl⁻ = 2.891 mM. σ combines σ_pH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift and ±2 % on C, as in SASDAN8. Only the counter-ion is modelled; the
# volume change of the buffer's own (de)protonation is not.
#
# ATP 0.2 mM is the solute `atp` as the neutral acid; the ATP⁴⁻ counter-ions (Na⁺ or Tris-H⁺
# from the salt used) are not stated and not modelled (0.2 mM x about 2-3 charges, below 0.1
# % of the buffer electrons; listed under BUFFER_OMISSIONS).
const SOLUTES = Solute[
    NonBiological(0.005, 0.0001, "tris"),                  # 5 mM Tris, ±2%
    NonBiological(0.0001, 0.000002, "calcium chloride"),   # 0.1 mM CaCl2, ±2%
    NonBiological(0.001, 0.00002, "sodium azide"),         # 1 mM NaN3, ±2%
    NonBiological(0.0002, 0.000004, "atp"),                # 0.2 mM ATP, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.002891, 0.000379, "chloride"),
]
# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "counter-ions of ATP (0.2 mM, salt not stated) not modelled (< 0.1 % of electrons)",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDTX4: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS


# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the curve ends at 0.1805 Å⁻¹ (noise-dominated beyond 0.14 Å⁻¹) and so does
# the depositor's CRYSOL curve: the whole curve is fitted.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdtx4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdtx4` below is the whole story (build the seed, then sample it).
function seedSasdtx4(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdtx4(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdtx4(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdtx4()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.037",
    runLog = true,
)

# `@__DIR__` (this SASDTX4/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
