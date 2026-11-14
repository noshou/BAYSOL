# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDV62")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDV62.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDV62_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDV62_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDV62: human haemoglobin (Sigma-Aldrich), SEC-SAXS, in 100 mM sodium phosphate
# pH 7.0 with NO PEG: the control of the haemoglobin-PEG series (SASDV82, SASDV92,
# SASDVA2, SASDVB2, SASDVC2, SASDVD2, SASDVE2). Sample: HbA alpha chain (P69905,
# 15.126 kDa) and beta chain (P68871, 15.867 kDa), the alpha2-beta2 tetramer with four
# haem B groups (0.616 kDa each); SASBDB experimental MW 64.8 kDa.
#
# Publication (SASBDB): Baranova I, Angelova A, Stransky J, Andreasson J, Angelov B,
# "Hemoglobin-PEG Interactions Probed by Small-Angle X-ray Scattering: Insights for
# Crystallization and Diagnostics Applications", J Phys Chem B 2024 (published 2024 Sep
# 09), DOI 10.1021/acs.jpcb.4c03003. Entry: https://www.sasbdb.org/data/SASDV62/. The
# conditions below are the SASBDB entry metadata; the paper was NOT consulted.
#
# Instrument (SASBDB): Anton Paar SAXSpoint 2.0 (in-house X-ray source, Eiger R 1M),
# Institute of Biotechnology CAS, Centre of Molecular Structure, Vestec, Czech Republic;
# wavelength 1.34 Å (SASBDB `xray_energy` is null, so the energy is hc/λ ≈ 9252 eV);
# sample-detector distance 0.7926 m; 106 frames of 15 s, flow 0.05 (SASBDB gives no
# unit); cell temperature 20 °C (storage 23 °C); measured 2022-05-24; loaded at up to
# 18 mg/ml (concentration_max; the concentration in the SEC peak is not stated).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.089 and s_max
# 3.997 nm⁻¹; three text lines, then q, I, σ, then trailing text, all skipped by
# `_readCurve`) and is converted to Å⁻¹ (÷10). The intensities are in arbitrary units
# (SASBDB intensity_unit). 39 of the 680 points have I ≤ 0 (37 of them above 0.25 Å⁻¹);
# `seedModel` drops the non-positive bins. The whole curve is fitted (no q cut): the data
# go to 0.40 Å⁻¹ but the depositor's CRYSOL curve ends at 0.2495 Å⁻¹, so the refChi2 is
# not like for like. Above 0.25 Å⁻¹ the median I/σ is still 1.2 (14 % of the points have
# I ≤ 0), a weak tail rather than a flat noise floor.
#
# Model and depositor fit: SASDV62 has TWO fits. fit1 is DAMMIN (dummy atoms, χ² 1.043;
# not used). fit2 is CRYSOL against the atomic model, which SASBDB states is identical
# to PDB 3ODQ ("Structure of a crystal form of human methemoglobin indicative of fiber
# formation", 3.10 Å); SASDV62_fit2_model1.pdb is SASBDB's copy (its 4384 ATOM records
# were checked equal to the ones from files.rcsb.org). The 3ODQ file holds chains A, C
# (alpha) and B, D (beta), 4384 ATOM records (the tetramer), four HEM groups as HETATM
# records (43 atoms each, 172 in all, one per chain), no waters and no hydrogens. The
# deposited fit header reads "Dro: 0.007 Rg: 24.67 Vol: 58540. Chi^2: 1.098"; the fit
# file (419 points, q ≤ 0.2495 Å⁻¹) recomputed from its columns 2-4 gives χ² = 1.096, so
# the label is χ² (not χ) and the depositor's χ² is 1.098 (SASBDB chi_square_value).
#
# Haem: it is part of the macromolecule (SASBDB lists it among the sample molecules). The
# loader keeps ligands of a known composition (`ligandSelector`, `KEEP_LIGANDS`, owner
# decision 2026-11-11; `components.tsv` lists HEM as "other", non-polymer, C34 H32 Fe N4
# O4), so the four HEM groups (4 x 43 heavy atoms, the Fe included, 4 x 616 Da, about
# 3.8 % of the tetramer mass) ARE scattered, as in CRYSOL, which reads the HETATM records.
# pdb2pqr places no hydrogens on them (32 per haem, a deficit of about 0.4 % of the
# electrons). The model is the iron(III) form (methaemoglobin); the sample is Sigma human
# haemoglobin of unstated oxidation state.
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

# Buffer as deposited (SASBDB buffer name): "100 mM Sodium Phosphate", pH 7.0; nothing
# else is listed (no salt, no reductant). The measured macromolecule is deliberately NOT
# a solute (see BulkElectronDensity.Solute).
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
# anticorrelated, as the total is fixed, which the independent σ ignores).
const SOLUTES = Solute[
    NonBiological(0.0601, 0.0085, "disodium hydrogen phosphate"),   # HPO₄²⁻, 60.1 mM
    NonBiological(0.0399, 0.0085, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 39.9 mM
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

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdv62` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdv62` below is the whole story (build the seed, then sample it).
function seedSasdv62(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdv62(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdv62(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdv62()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.098",
    runLog = true,
)

# `@__DIR__` (this SASDV62/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
