# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVC2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVC2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVC2_3ODQ.pdb")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVC2: human hemoglobin A (Sigma-Aldrich), the (alpha beta)2 tetramer, 5 mg/ml,
# in 100 mM sodium phosphate pH 7.0 with 5 % (w/v) PEG 2000.
#
# Publication (SASBDB): Baranova I, Angelova A, Stransky J, Andreasson J, Angelov B,
# "Hemoglobin-PEG Interactions Probed by Small-Angle X-ray Scattering: Insights for
# Crystallization and Diagnostics Applications", J Phys Chem B, 2024 Sep 9, DOI
# 10.1021/acs.jpcb.4c03003. Entry: https://www.sasbdb.org/data/SASDVC2/.
#
# Conditions not named in the paper are the SASBDB metadata. PAPER CONSULTED
# (2026-11-13, full text via Europe PMC, PMC11440596): Methods: lyophilized human Hb
# (Sigma-Aldrich) in 100 mM sodium phosphate made by mixing Na2HPO4 and NaH2PO4 "in a
# specified ratio" (the ratio is not given), pH set to 7.0 with 4 M HCl / 1 M NaOH; PEG
# 600, 2000 and 4000 (Sigma-Aldrich) dissolved in the same buffer at pH 7.0; SAXS
# samples 5 mg/mL Hb with PEG at 5, 10 and 20 % (w/v); laboratory SAXSpoint 2.0, 1.34 A,
# 293 K (about 20 C), 1 mm capillary, 30 frames, buffer (with the same PEG) subtracted
# in PRIMUS. About 86 % of the Hb is oxidized (metHb, UV-vis), which fits the 3ODQ
# methemoglobin model. Paper Table 1 row of this entry: "Hb with 5% (w/v) PEG2000", I(0)
# Guinier 0.110, Rg Guinier 2.41 nm, Rg P(r) 2.358 nm, Dmax 6.5 nm: this matches the
# SASBDB values quoted above, so the entry is the "5 % (w/v) PEG 2000" sample of the
# paper. The paper fits CRYSOL to 3odq only for the SEC-SAXS control (SASDV62), not for
# the PEG samples.
#
# Instrument (SASBDB): Anton Paar SAXSpoint 2.0, in-house X-ray source, Eiger R 1M
# detector, Institute of Biotechnology CAS / Centre of Molecular Structure, Vestec
# (Czech Republic); wavelength 1.34 Å, sample-detector distance 0.8256 m; measured
# 2022-10-06; 30 frames x 30 s, flow 0.7 (flow cell, 500 µL); cell temperature 20 °C
# (storage temperature 23 °C); a single concentration, 5 mg/ml. SASBDB records no
# "xray_energy"; the energy is hc/λ of the stated wavelength (9.25 keV).
#
# The sibling entry SASDVB2 (same study, same instrument session, same day, same model
# file): see its script. SASDVB2's metadata gives the same buffer as this entry, but
# its data file is a PEG-FREE hemoglobin curve (sample "NaP_Hb_2.001", "1 week after SEC"),
# whereas this entry's file is the PEG sample ("NaP_PEG2000_5%_Hb", parents
# 09_PEG2000_5%_NaP_PEG2000_5% = the PEG buffer blank and 10_PEG2000_5%_Hb_... = the
# sample). So this entry is the one that is truly in PEG 2000, and the buffer
# blank that was subtracted carried the PEG too (the .dat header names it as parent).
#
# Curve: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; 0.083-3.997 nm⁻¹, 681 points,
# intensity in 1/cm), converted to Å⁻¹ (÷10). The curve is signal only to q ≈ 0.12 Å⁻¹
# (mean I/σ about 36 below 0.1 Å⁻¹, 5 in 0.1-0.15, about 0 above 0.15; 256 of the 681
# points are ≤ 0). The fit is cut at `Q_MAX_FIT` = 0.15 Å⁻¹ (an assumption of this
# script, not of SASBDB) and `seedModel` drops the non-positive bins.
# SASBDB: Guinier Rg 2.41 ± 0.03 nm, P(r) Rg 2.358 nm, Dmax 6.5 nm, Porod MW 21 kDa
# (below the tetramer's 64.5 kDa: the Porod value of a noisy curve is not trusted),
# experimental MW 60.3 kDa.
#
# Model, NO depositor fit: SASBDB lists no model and no fit for this entry ("fits": empty).
# The script uses the model of the PEG-free control SASDV62 of the same study (SASDV62's
# fit2 is the atomic model "identical" to PDB 3ODQ, CRYSOL fit): PDB 3ODQ, "structure
# of a crystal form of human methemoglobin indicative of fiber formation" (RCSB,
# downloaded unchanged). It holds 4384 ATOM records, no hydrogens, no waters and no
# alternate locations: four chains, A and C alpha (141 residues, 1069 atoms), B and D
# beta (146 residues, 1123 atoms), plus 4 HEM (heme B, 43 HETATM atoms each, residue
# names "HEM" in chains A-D). The loader keeps the polymer atoms and the ligands
# of a known composition (`ligandSelector`, `KEEP_LIGANDS`, owner decision 2026-11-11),
# and the bundled component table lists HEM (C34 H32 Fe N4 O4) as "other / non-polymer",
# so the 4 hemes (the Fe and the porphyrin, 4 x 616 Da, about 3.8 % of the tetramer's
# mass) ARE scattered and part of the excluded volume, without hydrogens. The crystal
# form is methemoglobin at 3.1 Å (P 61 2 2); the protein in solution is the Sigma human
# hemoglobin, whose oxidation state is not stated in the entry. ASSUMPTION: the crystal
# structure is a good enough model of the solution structure; the deposited MW 60.3 kDa
# agrees with a tetramer. No reference curve is drawn (no `references`), and `refChi2`
# is left unset.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB: pH 7.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9252 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 20.0                    # SASBDB cell temperature 20 °C

# Buffer as deposited (SASBDB buffer name): "100mM Sodium Phosphate buffer with 5% (w/v)
# PEG2000", comment "5% (w/v) PEG2000 is the final concentration.", pH 7.0. The measured
# hemoglobin is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Phosphate: 100 mM total, "sodium phosphate" with no stoichiometry or recipe, so the
# species at pH 7.0 are NaH2PO4 and Na2HPO4 (the recipe is assumed to be mono- and
# dibasic sodium phosphate mixed to pH 7.0, with no other counter-ion). The split uses
# pK2 of Goldberg, Kishore & Lennen 2002 (DOI 10.1063/1.1416902; 7.198 at 25 °C, ΔH
# 3.6 kJ/mol, ΔCp −230 J/K/mol; quoted from the other phosphate scripts here, not
# re-checked) at 20 °C: pK2 = 7.210, Davies-corrected at the self-consistent ionic
# strength I = 0.22 M (pK2' = 6.827). Result: HPO4²⁻ 59.8 mM (0.598 of the total),
# H2PO4⁻ 40.2 mM, Na⁺ 159.8 mM as the counter-ion of both. Without the Davies correction
# the split would be 38.1 / 61.9 mM. σ combines σ_PH = 0.1 (±5.6 mM) and 30 % of the
# Davies shift (±6.5 mM): 0.009 M for both species. PEG's effect on the activity
# coefficients and on the pH meter reading is not modelled. The table has both salts
# (`disodium hydrogen phosphate`, `sodium dihydrogen phosphate`).
#
# PEG 2000, 5 % (w/v) = 50 g/L; "PEG2000" is a grade, whose mean molar mass is taken as
# Mn = 2000 g/mol (the supplier and lot are not in the entry, and the real Mn of a "2000"
# lot spreads ±5 % or more), so 50 / 2000 = 0.025 M of chains. The loader reads "PEG
# 2000" as the family form "PEG {Mn}": n = (2000 − 18.015)/44.053 ≈ 45.0 units. σ is
# 10 % (0.0025 M), not the usual 2 %, for the grade, the "% (w/v)" reading (the entry
# says w/v, so no w/w ambiguity) and the volume non-additivity of 50 g/L of PEG.
const SOLUTES = Solute[
    # 100 mM phosphate at pH 7.0 (see above): HPO4²⁻ part
    NonBiological(0.0598, 0.009, "disodium hydrogen phosphate"),
    # H2PO4⁻ part
    NonBiological(0.0402, 0.009, "sodium dihydrogen phosphate"),
    # 5 % (w/v) PEG 2000: 50 g/L / 2000 g/mol = 0.025 M of chains, ±10 %
    Polymer(0.025, 0.0025, "PEG 2000"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.15 Å⁻¹. The data run to 0.400 Å⁻¹,
# but the 434 points above 0.15 Å⁻¹ (σ > 0) have a median I/σ of -0.20 and 56 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.21 Å⁻¹) has a median I/σ of -0.07.
const Q_MAX_FIT = 0.15

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# 3ODQ has no hydrogens: pdb2pqr/PROPKA place them at PH (the hemes stay as they are, no
# hydrogens on them, see above).
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

# Builds the Seed that `runSasdvc2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvc2` below is the whole story (build the seed, then sample it).
function seedSasdvc2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvc2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvc2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvc2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log. The entry has no deposited fit, so there is no
# reference curve (`references` defaults to none) and no depositor χ² (`refChi2` unset).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    runLog = true,
)

# `@__DIR__` (this SASDVC2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
