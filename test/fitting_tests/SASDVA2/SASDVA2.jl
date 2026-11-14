# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVA2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVA2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVA2_3ODQ.pdb")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVA2: human hemoglobin (HbA, Sigma-Aldrich; alpha 15.126 + beta 15.867 kDa
# chains and heme B, the tetramer being 64.5 kDa) at 5 mg/ml in 100 mM sodium phosphate
# buffer, pH 7.0, with 20 % (w/v) PEG 600. One of a series of hemoglobin entries
# in PEG buffers (SASDV62 = no PEG, SEC-SAXS; SASDV82/V92/VA2 = PEG 600 at 5/10/20 %;
# SASDVB2/VC2/VE2 = PEG 2000; SASDVD2 = PEG 4000).
#
# Paper: Baranova I, Angelova A, Stransky J, Andreasson J, Angelov B, "Hemoglobin-PEG
# interactions probed by small-angle X-ray scattering: insights for crystallization and
# diagnostics applications", J Phys Chem B (2024), DOI 10.1021/acs.jpcb.4c03003. Entry:
# https://www.sasbdb.org/data/SASDVA2/.
#
# Conditions not named in the paper are the SASBDB metadata. PAPER CONSULTED
# (2026-11-13, full text via Europe PMC, PMC11440596): Methods: lyophilized human Hb
# (Sigma-Aldrich) in 100 mM sodium phosphate made by mixing Na2HPO4 and NaH2PO4 "in a
# specified ratio" (the ratio is not given), pH set to 7.0 with 4 M HCl / 1 M NaOH; PEG
# 600, 2000 and 4000 (Sigma-Aldrich) dissolved in the same buffer at pH 7.0; SAXS
# samples 5 mg/mL Hb with PEG at 5, 10 and 20 % (w/v); laboratory SAXSpoint 2.0, 1.34 A,
# 293 K (about 20 C), 1 mm capillary, 30 frames, buffer (with the same PEG) subtracted
# in PRIMUS. About 86 % of the Hb is oxidized (metHb, UV-vis), which fits the 3ODQ
# methemoglobin model. Paper Table 1 row of this entry: "Hb with 20% (w/v) PEG600", I(0)
# Guinier 0.0690, Rg Guinier 2.57 nm, Rg P(r) 2.524 nm, Dmax 7.6 nm: this matches the
# SASBDB values quoted above, so the entry is the "20 % (w/v) PEG 600" sample of the
# paper. The paper fits CRYSOL to 3odq only for the SEC-SAXS control (SASDV62), not for
# the PEG samples.
#
# Instrument (SASBDB): Anton Paar SAXSpoint 2.0, in-house X-ray source, Institute of
# Biotechnology of the Czech Academy of Sciences (Centre of Molecular Structure, Vestec),
# Eiger R 1M, sample-detector distance 0.8256 m, wavelength 1.34 Å (=> hc/λ ≈ 9253 eV),
# 30 frames of 30 s, cell temperature 20 °C (storage 23 °C), 500 µL sample. Curve:
# 681 points, s 0.083-3.997 nm⁻¹, intensity unit "1/cm" (absolute scale). Guinier
# Rg 2.574 nm, P(r) Rg 2.524 nm, Dmax 7.6 nm, SASBDB's PRIMUS MW estimate
# 81.8 (81.845) kDa (the tetramer is 64.5 kDa).
#
# The .dat header lists the reduction: the curve is the Hb-in-PEG measurement minus the
# buffer measurement with the SAME PEG 600 percentage (datop SUB of the files
# "12_PEG600_20%_Hb_NaP_PEG600_20%_Hb_826mm.dat" and
# "11_PEG600_20%_NaP_PEG600_20%_826mm.dat", folder path omitted here), i.e. a matched buffer
# subtraction, read from the file header (the entry's own text). The SASBDB name of the
# sample is "Human Haemoglobin (Sigma-Aldrich) with 20 % (w/v) PEG600 in 100mM Sodium
# Phosphate buffer pH=7.0, c=5 mg/ml". 239 of 681 points have I ≤ 0 (noise beyond
# q ≈ 0.3 Å⁻¹); the fit stops at `Q_MAX_FIT` and `seedModel` drops non-positive bins.
#
# *** NO DEPOSITED ATOMIC FIT, NO REFERENCE CURVE: this entry has no model and no fit in
# *** SASBDB (the "fits" list is empty and there is no PDB link). The model used is that
# *** of the PEG-free control SASDV62 (its CRYSOL fit2, χ² 1.098, PDB 3ODQ, "identical"
# *** to the PDB entry according to SASBDB). The file here is the RCSB 3ODQ.pdb (a
# *** coordinate diff against SASBDB's own SASDV62_fit2_model1.pdb finds all
# *** ATOM/HETATM records identical, only REMARK/REVDAT text differs). So `results` gets
# *** no `references` and no `refChi2`, and the BAYSOL fit is NOT compared with a
# *** depositor fit. It is also an ASSUMPTION that the crystal tetramer is the species in
# *** solution in PEG.
#
# Model: 3ODQ is "Structure of a crystal form of human methemoglobin indicative of fiber
# formation" (X-ray, 3.10 Å; RCSB). Chains A and C are the alpha chain (141 residues), B
# and D the beta chain (146 residues), 1069/1123/1069/1123 ATOM heavy atoms (4384 in all),
# no hydrogens, no waters, and one heme (residue HEM, 43 atoms) per chain as HETATM
# records, 172 in all. The loader keeps the ligands of a known composition
# (`ligandSelector`, `KEEP_LIGANDS`, owner decision 2026-11-11) besides the heavy atoms
# of standard residues and modified amino acids and nucleotides: HEM is an `other`
# non-polymer in the bundled component table with a known formula (C34 H32 Fe N4 O4), so
# the four hemes (about 2.5 kDa, 3.8 % of the mass, with the four Fe) ARE scattered (4556
# heavy atoms), without hydrogens (pdb2pqr/PROPKA place those of the protein at PH), as
# CRYSOL includes them.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹ (SASBDB angular_unit "1/nm"); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB: pH 7.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 20.0                    # SASBDB cell temperature

# Buffer as deposited (SASBDB): "100mM Sodium Phosphate buffer with 20% (w/v) PEG600",
# comment "20% (w/v) PEG600 is the final concentration", pH 7.0. The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Phosphate: 100 mM total, "sodium phosphate" with no recipe given. ASSUMED: made from
# NaH2PO4 and Na2HPO4 (no other cation or anion, so sodium is the sole counter-ion and
# comes with the salts). Split at pH 7.0 from the second dissociation, pK2 7.198 at 25 °C,
# ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol (Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref.
# Data 31, 231, DOI 10.1063/1.1416902; values quoted from memory of that table and NOT
# re-checked here, as in SASDN32), integrated to 20 °C: pK2 = 7.2105 (thermodynamic).
# Davies activity correction at the self-consistent ionic strength (I = a + 3b ≈ 0.22 M,
# 40.1 mM H2PO4⁻ and 59.9 mM HPO4²⁻, Davies constant A = 0.5070 at 20 °C, from memory;
# PEG's effect on the activities is NOT modelled and Davies is at the edge of its range):
# H2PO4⁻ 40.08 mM, HPO4²⁻ 59.92 mM, the sum 100 mM. Without the Davies term (I = 0) it
# would be 61.9 / 38.1 mM. σ combines σ_pH = 0.1 (±5.7 mM), 30 % of the Davies shift
# (±6.5 mM), ±0.02 pK (±1.1 mM) and ±3 °C (±0.5 mM): 8.7 mM for both species, anticorrelated
# in truth but taken as independent. The pH is taken as set at the cell temperature.
# The table has both salts (`sodium dihydrogen phosphate`, `disodium hydrogen phosphate`).
#
# PEG 600 at 20 % w/v: ASSUMED the "600" is the mean molar mass Mn = 600 g/mol (the
# loader reads "PEG 600" as the family form "PEG {Mn}": n = (600 − 18.015)/44.053 ≈ 13.2
# oxyethylene units, ϕ° from the PEG line of the table; checked in the source, not run) and
# that % w/v is g per 100 mL of FINAL solution (the entry says "final concentration").
# 20 g/100 mL = 200 g/L / 600 g/mol = 0.3333 M of chains. The real Mn of a "PEG 600"
# lot spreads (a nominal 570-630 g/mol, about ±5 %), the w/v reading is not exact for a
# mixture that is not volume-additive, so σ is 10 % (0.0333 M), not the usual 2 %.
# *** NONLINEARITY AT 20 % w/v (ASSUMPTION, not modelled): 0.333 M of chains is 4.4 M of
# *** oxyethylene units, about 20 g of polymer per 100 mL, well above the dilute range in
# *** which the table's PEG partial molar volume (the dilute-solution line fitted to PEG
# *** 200-10000 data) holds. Excluded volume, PEG hydration and polymer-polymer overlap
# *** make the apparent molar volume, and thus the solvent electron density the model
# *** computes from "molarity per litre of solution", concentration dependent, so the
# *** 20 % buffer density is the least certain part of this model. The 10 % molarity
# *** uncertainty only partly covers it. SASBDB's Guinier I(0) is 0.0687 1/cm against
# *** 0.0962 at 10 %, and its PRIMUS MW estimate (81.8 kDa against the 64.5 kDa tetramer)
# *** is high: contrast, association or heme state, none of it checked here.
const SOLUTES = Solute[
    # 100 mM sodium phosphate at pH 7.0: H2PO4⁻ part
    NonBiological(0.04008, 0.0087, "sodium dihydrogen phosphate"),
    # 100 mM sodium phosphate at pH 7.0: HPO4²⁻ part
    NonBiological(0.05992, 0.0087, "disodium hydrogen phosphate"),
    # 20 % (w/v) PEG 600: 200 g/L / 600 g/mol = 0.3333 M of chains, ±10 %
    Polymer(0.3333, 0.0333, "PEG 600"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.400 Å⁻¹,
# but the 174 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.06 and 47 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.32 Å⁻¹) has a median I/σ of -0.06.
const Q_MAX_FIT = 0.3

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

# Builds the Seed that `runSasdva2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdva2` below is the whole story (build the seed, then sample it).
function seedSasdva2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdva2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdva2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdva2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log. There is no depositor fit for this entry, so no
# `references` and no `refChi2` (the log's `refChi2` row stays empty).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    runLog = true,
)

# `@__DIR__` (this SASDVA2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
