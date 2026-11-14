# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDV82")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDV82.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDV82_fit1_model1.pdb")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDV82: human haemoglobin (Sigma-Aldrich), 5 mg/ml, single concentration, in
# 100 mM sodium phosphate pH 7.0 with 5 % (w/v) PEG 600 ("5% (w/v) PEG600 is the final
# concentration", SASBDB buffer comment): one member of the haemoglobin-PEG series
# (control without PEG: SASDV62; others SASDV92, SASDVA2, SASDVB2, SASDVC2, SASDVD2,
# SASDVE2). Sample: HbA alpha chain (P69905, 15.126 kDa) and beta chain (P68871,
# 15.867 kDa), the alpha2-beta2 tetramer with four haem B groups (0.616 kDa each);
# SASBDB experimental MW 57.9 kDa.
#
# Publication (SASBDB): Baranova I, Angelova A, Stransky J, Andreasson J, Angelov B,
# "Hemoglobin-PEG Interactions Probed by Small-Angle X-ray Scattering: Insights for
# Crystallization and Diagnostics Applications", J Phys Chem B 2024 (published 2024 Sep
# 09), DOI 10.1021/acs.jpcb.4c03003. Entry: https://www.sasbdb.org/data/SASDV82/.
#
# Conditions not named in the paper are the SASBDB metadata. PAPER CONSULTED
# (2026-11-13, full text via Europe PMC, PMC11440596): Methods: lyophilized human Hb
# (Sigma-Aldrich) in 100 mM sodium phosphate made by mixing Na2HPO4 and NaH2PO4 "in a
# specified ratio" (the ratio is not given), pH set to 7.0 with 4 M HCl / 1 M NaOH; PEG
# 600, 2000 and 4000 (Sigma-Aldrich) dissolved in the same buffer at pH 7.0; SAXS
# samples 5 mg/mL Hb with PEG at 5, 10 and 20 % (w/v); laboratory SAXSpoint 2.0, 1.34 A,
# 293 K (about 20 C), 1 mm capillary, 30 frames, buffer (with the same PEG) subtracted
# in PRIMUS. About 86 % of the Hb is oxidized (metHb, UV-vis), which fits the 3ODQ
# methemoglobin model. Paper Table 1 row of this entry: "Hb with 5% (w/v) PEG600", I(0)
# Guinier 0.1100, Rg Guinier 2.39 nm, Rg P(r) 2.399 nm, Dmax 6.71 nm: this matches the
# SASBDB values quoted above, so the entry is the "5 % (w/v) PEG 600" sample of the
# paper. The paper fits CRYSOL to 3odq only for the SEC-SAXS control (SASDV62), not for
# the PEG samples.
#
# Instrument (SASBDB): Anton Paar SAXSpoint 2.0 (in-house X-ray source, Eiger R 1M),
# Institute of Biotechnology CAS, Centre of Molecular Structure, Vestec, Czech Republic;
# wavelength 1.34 Å (SASBDB `xray_energy` is null, so the energy is hc/λ ≈ 9252 eV);
# sample-detector distance 0.8256 m; 30 frames of 30 s; cell temperature 20 °C (storage
# 23 °C); measured 2022-09-30; concentration 5 mg/ml (the sample name, and
# concentration_max).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.083 and s_max
# 3.997 nm⁻¹; three text lines, then q, I, σ, then trailing text, all skipped by
# `_readCurve`) and is converted to Å⁻¹ (÷10). The intensities are in 1/cm
# (SASBDB intensity_unit). The curve is NOISY: the first points have σ/I ≈ 0.2-0.4 (a weak
# signal after the PEG-buffer subtraction at 5 mg/ml), and 234 of the 681 points
# have I ≤ 0 (140 of them above 0.25 Å⁻¹). The fit is cut at `Q_MAX_FIT` = 0.25 Å⁻¹ (the
# range of the control's CRYSOL fit; ASSUMED, no fit exists for this entry); 326
# positive points remain below it and `seedModel` drops the non-positive bins.
# Expect a loose posterior.
#
# *** NO DEPOSITED FIT AND NO MODEL: SASBDB lists no fit, no model and no PDB link for
# *** SASDV82. The model used is that of the control SASDV62, PDB 3ODQ (SASDV62's own
# *** SASBDB file, "identical" to 3ODQ), copied as SASDV82_fit1_model1.pdb: the
# *** assumption is that haemoglobin keeps its crystal structure in 5 % PEG 600 (the
# *** paper is about PEG-haemoglobin interactions, so this need not hold). The depositors
# *** give no CRYSOL curve for this entry, so there is NO reference curve and NO `refChi2`
# *** (`results` is called without `references`; the control's curve is not drawn, since
# *** it belongs to a different sample and curve).
#
# Model content (read from the PDB file): 3ODQ ("Structure of a crystal form of human
# methemoglobin indicative of fiber formation", 3.10 Å) has chains A, C (alpha) and B, D
# (beta), 4384 ATOM records (the tetramer), four HEM groups as HETATM records (43 atoms
# each, 172 in all, one per chain), no waters and no hydrogens. The haem is part of the
# macromolecule, and BAYSOL's loader keeps ligands of a known composition
# (`ligandSelector`, `KEEP_LIGANDS`, owner decision 2026-11-11; `components.tsv` lists
# HEM as "other", non-polymer), so the four HEM groups ARE scattered, without hydrogens:
# 4 x 616 Da, about 3.8 % of the tetramer mass, 4556 heavy atoms in all. The model is the
# iron(III) form (methaemoglobin); the sample is Sigma human haemoglobin of unstated
# oxidation state.
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
const TEMPERATURE_C = 20.0                    # SASBDB cell temperature (storage 23 °C)

# Buffer as deposited (SASBDB buffer name): "100mM Sodium Phosphate buffer with 5% (w/v)
# PEG600", pH 7.0 (the study's buffer is "X % (w/v) PEGn in 100 mM sodium phosphate
# buffer"); nothing else is listed (no salt, no reductant). The measured macromolecule
# is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# The entry gives total phosphate and pH, not the salts, so the monobasic/dibasic split
# is computed: H₂PO₄⁻ (as sodium dihydrogen phosphate) and HPO₄²⁻ (as disodium hydrogen
# phosphate), Na⁺ coming with the salts. pK₂ = 7.198 at 25 °C, ΔH = 3.6 kJ/mol
# (Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902; the same values as the SASDMZ9 script, quoted from there and not
# re-checked), moved to 20 °C by van't Hoff (pK₂ = 7.209, ΔCp ignored), Davies-corrected
# (A = 0.509, as at 25 °C) at the self-consistent ionic strength I = 0.1 + 0.2 x with x the
# HPO₄²⁻ fraction (I ≈ 0.22 M; Davies is at the edge of its range there): pK₂' ≈ 6.82,
# x = 0.601, i.e. HPO₄²⁻ 60.1 mM and H₂PO₄⁻ 39.9 mM (without the activity correction
# x would be 0.382). The pH is taken as set at room temperature, and no temperature
# shift of the pH between 23 and 20 °C is modelled. σ combines σ_pH = 0.1 (±0.053 on x)
# and 30 % of the Davies shift (±0.066), 0.0085 M for both species (they are
# anticorrelated, as the total is fixed, which the independent σ ignores). PEG is not
# in the ionic strength and its effect on the pK₂ and the pH reading is not modelled.
#
# PEG 600, 5 % w/v: the entry states the unit (w/v) explicitly, so 50 g/L; the grade is
# the mean molar mass Mn = 600 g/mol, so 50 / 600 = 0.0833 M of chains ("PEG 600" is
# read by the loader as the family form "PEG {Mn}", as "PEG 1500" is in SASDAX2; n =
# (600 − 18.015)/44.053 ≈ 13.2 oxyethylene units, ϕ° ≈ 19.24 + 36.73 n ≈ 504 cm³/mol by
# the PEG line of Ayranci & Sahin 2008, taken from the constants of the loader, not
# re-derived). The real Mn of a "600" lot is a range (the nominal grade 570-630 g/mol,
# a vendor convention not checked against this lot), and the Hb solution is diluted to
# the final 5 %, so σ is 5 % (0.0042 M), more than the usual 2 %. The PEG is NOT a
# polymer chain of the macromolecule: it is a buffer component (`Polymer` solute).
const SOLUTES = Solute[
    NonBiological(0.0601, 0.0085, "disodium hydrogen phosphate"),   # HPO₄²⁻, 60.1 mM
    NonBiological(0.0399, 0.0085, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 39.9 mM
    # 5 % (w/v) PEG 600 = 50 g/L / 600 g/mol = 0.0833 M of chains, ±5 % (see above)
    Polymer(0.0833, 0.0042, "PEG 600"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.25 Å⁻¹. The data run to 0.400 Å⁻¹,
# but the 261 points above 0.25 Å⁻¹ (σ > 0) have a median I/σ of -0.12 and 54 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.29 Å⁻¹) has a median I/σ of -0.25.
const Q_MAX_FIT = 0.25

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

# Builds the Seed that `runSasdv82` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdv82` below is the whole story (build the seed, then sample it).
function seedSasdv82(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdv82(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdv82(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdv82()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log. No depositor fit exists for this entry, so there
# is no `references` and no `refChi2` (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    runLog = true,
)

# `@__DIR__` (this SASDV82/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
