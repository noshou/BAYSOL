# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVE2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVE2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDV62_fit2_model1.pdb")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVE2: human hemoglobin (Sigma-Aldrich) at 5 mg/mL in 100 mM sodium phosphate
# buffer, pH 7.0, with 10 % (w/v) PEG 2000 (SASBDB buffer name: "100mM Sodium Phosphate
# buffer with 10% (w/v) PEG2000";
# comment "10% (w/v) PEG2000 is the final concentration."). Sample, as named by SASBDB:
# "Human Haemoglobin (Sigma-Aldrich) with 10% PEG2000 in 100mM Sodium Phosphate buffer,
# pH=7.0, c=5mg/ml".
#
# Publication (SASBDB): Baranova I, Angelova A, Stransky J, Andreasson J, Angelov B,
# "Hemoglobin-PEG Interactions Probed by Small-Angle X-ray Scattering: Insights for
# Crystallization and Diagnostics Applications", J Phys Chem B, 2024 Sep 9,
# DOI 10.1021/acs.jpcb.4c03003. Entry: https://www.sasbdb.org/data/SASDVE2/.
#
# Conditions not named in the paper are the SASBDB metadata. PAPER CONSULTED
# (2026-11-13, full text via Europe PMC, PMC11440596): Methods: lyophilized human Hb
# (Sigma-Aldrich) in 100 mM sodium phosphate made by mixing Na2HPO4 and NaH2PO4 "in a
# specified ratio" (the ratio is not given), pH set to 7.0 with 4 M HCl / 1 M NaOH; PEG
# 600, 2000 and 4000 (Sigma-Aldrich) dissolved in the same buffer at pH 7.0; SAXS
# samples 5 mg/mL Hb with PEG at 5, 10 and 20 % (w/v); laboratory SAXSpoint 2.0, 1.34 A,
# 293 K (about 20 C), 1 mm capillary, 30 frames, buffer (with the same PEG) subtracted
# in PRIMUS. About 86 % of the Hb is oxidized (metHb, UV-vis), which fits the 3ODQ
# methemoglobin model. Paper Table 1 row of this entry: "Hb with 10% (w/v) PEG2000",
# I(0) Guinier 0.0820, Rg Guinier 2.83 nm, Rg P(r) 2.912 nm, Dmax 11.3 nm: this matches
# the SASBDB values quoted above, so the entry is the "10 % (w/v) PEG 2000" sample of
# the paper. The paper fits CRYSOL to 3odq only for the SEC-SAXS control (SASDV62), not
# for the PEG samples.
#
# Instrument (SASBDB): Anton Paar SAXSpoint 2.0, in-house X-ray source, Eiger R 1M
# detector, Institute of Biotechnology CAS / Centre of Molecular Structure, Vestec;
# wavelength 1.34 Å, sample-detector distance 0.8256 m, cell temperature 20.0 °C
# (storage 23.0 °C; the curve's file names say 293.2 K), 30 frames of 30 s (flow
# 0.7, 500 µL), measured 2022-10-06; the SASBDB record gives no energy field, only the
# wavelength. Single-concentration curve, concentration_max 5.0 mg/mL. SASBDB lists the
# macromolecule as subunit alpha (15.13 kDa), subunit beta (15.87 kDa) and heme B
# (0.62 kDa), each as a monomer; the entry's experimental MW is 93 kDa (SAXS
# estimate; the tetramer is 64.5 kDa with hemes) and plays no role in the fit.
#
# Curve: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; 681 points, q 0.0829 to 3.997
# nm⁻¹, intensity in 1/cm), converted to Å⁻¹ (÷10): q 0.00829 to 0.3997 Å⁻¹. The file has
# three text lines (sample, buffer name, parents), the three columns q, I, σ, and a
# trailer of datop lines; `_readCurve` keeps only the numeric rows. The curve is the
# difference of the protein-in-PEG-buffer and the matched PEG-buffer measurements (the
# datop line is "... SUB ..." and the parents are the Hb and the buffer runs of the
# same PEG concentration), so the buffer subtraction used the SAME PEG buffer. 271 of the
# 681 points have I ≤ 0 (173 of them at q < 0.3 Å⁻¹).
# The data are noisy beyond q ≈ 0.2 Å⁻¹ (the signal falls to the size of σ); the fit is
# cut at `Q_MAX_FIT`, and `seedModel` drops non-positive bins.
#
# Model, NO depositor atomic fit (this is the point of the script): SASDVE2 carries
# no CRYSOL/FoXS fit and no PDB link (its only fit is a DAMMIF dummy-atom model, chi² 1.076,
# which is not an atomic model and is not used). The scripts therefore use the
# model of the PEG-free control entry SASDV62 (SASBDB fit2 of that entry, CRYSOL chi² 1.098,
# PDB link 3ODQ, "identical"): `SASDV62_fit2_model1.pdb` is SASBDB's own copy of the
# structure file and is the same as RCSB 3ODQ except for REMARK/REVDAT lines (diff
# checked). 3ODQ: "Structure of a crystal form of human methemoglobin indicative of fiber
# formation", 3.1 Å, the alpha2beta2 tetramer: chains A and C alpha (141 residues
# each), B and D beta (146 each), 4384 protein atoms in total, NO hydrogens, NO waters
# (the file has none), and 4 heme groups (HEM, HETATM records, 43 atoms each, 172 in total,
# residue 142 in alpha and 147 in beta). `seedModel` keeps the heavy atoms of the
# standard amino acids and the ligands of a known composition (waters are dropped;
# `KEEP_LIGANDS`, owner decision 2026-11-11), so the four hemes (and their Fe) ARE
# scattered, without hydrogens: protein and hemes together are about 64.4 kDa (SASBDB's
# model_mw for the control is 64.5 kDa; the sample is Sigma human Hb, probably
# methemoglobin, as in 3ODQ). *** ASSUMPTION: the crystal tetramer is the
# solution structure in the PEG buffer; PEG interaction with hemoglobin is exactly what
# the paper studies, and the fit cannot tell a conformation change from a hydration or
# contrast change. No reference curve is drawn (there is none: `results(...; references)`
# is left out, as in SASDN32 and SASDJ62), and the depositor's chi² in the log is "—".
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB: pH 7.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9252 eV, from SASBDB's wavelength 1.34 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature (storage 23.0 °C)

# Buffer as deposited (SASBDB buffer name: "100mM Sodium Phosphate buffer with 10% (w/v)
# PEG2000", pH 7.0).
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Sodium phosphate, 100 mM total, pH 7.0 at 20 °C. SASBDB gives no recipe, so the split into
# H₂PO₄⁻ and HPO₄²⁻ is computed, as in the other phosphate scripts (SASDN32): pK₂ of
# phosphoric acid 7.198 at 25 °C with ΔH 3.6 kJ/mol (Goldberg, Kishore & Lennen 2002,
# J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902, as quoted in SASDN32's script,
# NOT re-checked here; ΔCp neglected), which gives pK₂ = 7.209 at 20 °C by van't Hoff.
# The sodium phosphate is assumed made from NaH₂PO₄ and Na₂HPO₄ only (nothing titrated with
# a
# strong acid or base). The Davies activity correction (A = 0.507 at 20 °C) is solved
# self-consistently: with x the HPO₄²⁻ fraction the ionic strength is I = 0.1 + 0.2 x
# (PEG neglected), and [HPO₄²⁻]/[H₂PO₄⁻] = 10^(pH − pK₂)·γ₁/γ₂. The solution is x = 0.600
# at I = 0.220 M: Na₂HPO₄ 60.0 mM, NaH₂PO₄ 40.0 mM (sodium 160 mM, which the two salts
# carry;
# no separate "sodium" entry). Without the activity correction x would be 0.382 (38.2 mM
# Na₂HPO₄), so the correction matters at this ionic strength; Davies is at the edge of its
# range there and PEG changes the activities, so σ is 10 mM for each species (a pH shift of
# ±0.1 would move the split by about ±0.05 M; σ_PH enters the model separately).
# The pH is taken as set at the 20 °C measurement temperature.
#
# PEG: SASBDB says "10 % (w/v) PEG 2000 (w/v)" and states that this is the final
# concentration.
# w/v is read as g per 100 mL of solution, so 100 g/L; the grade PEG 2000 is
# the mean molar mass Mn = 2000 g/mol (assumption: the nominal grade is Mn; commercial PEGs
# have a dispersity of ~1.05-1.1 and a lot spread of ~±10 %), so 100 / 2000 =
# 0.0500 M of chains, σ 5 % (the w/v is stated explicitly, the Mn is the uncertain part).
# The loader reads "PEG 2000" as the family form "PEG {Mn}": n = (2000 − 18.015)/44.053 =
# 44.99 units, Z = 1090 e⁻, ϕ° = 1671.8 cm³/mol with σ 1 % (verified against
# `_polymer_family_ϕ°`'s regular expression and PEG_V0 line (19.24 + 36.73 n); the
# numbers were computed by hand and NOT run through the loader). Mixing volumes are not
# additive at this loading; BAYSOL treats each solute as molarity per litre of solution.
# The PEG buffer used to subtract the solvent contains the same PEG (see above), so the
# PEG is a buffer component and not part of the macromolecule.
const SOLUTES = Solute[
    # 100 mM sodium phosphate at pH 7.0: HPO₄²⁻ as disodium hydrogen phosphate, 60 mM
    NonBiological(0.0600, 0.010, "disodium hydrogen phosphate"),
    # H₂PO₄⁻ as sodium dihydrogen phosphate, 40 mM
    NonBiological(0.0400, 0.010, "sodium dihydrogen phosphate"),
    # 10 % (w/v) PEG 2000 (w/v): 100 g/L / 2000 g/mol = 0.0500 M of chains, ±5 %
    Polymer(0.0500, 0.0025, "PEG 2000"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.400 Å⁻¹,
# but the 174 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of -0.11 and 56 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.32 Å⁻¹) has a median I/σ of 0.05.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has no hydrogens: pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `runSasdve2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdve2` below is the whole story (build the seed, then sample it).
function seedSasdve2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdve2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdve2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdve2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; there is no depositor fit, so no reference.
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    runLog = true,
)

# `@__DIR__` (this SASDVE2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
