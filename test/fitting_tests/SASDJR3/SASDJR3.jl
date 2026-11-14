# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJR3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJR3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJR3_fit2_model1_HIS.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJR3_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJR3: the nucleotide-binding domain SaNsrF of the ABC transporter NsrFP of
# Streptococcus agalactiae (UniProt Q8DZX1, residues 1-250 plus an N-terminal His-tag
# construct; 30.895 kDa; monomer; SASBDB experimental MW 30.9 kDa), apo, at up to
# 4.2 mg/ml, in 100 mM HEPES, 150 mM NaCl, 10 % glycerol, pH 8.
#
# Publication (SASBDB): Furtmann F, Porta N, Hoang D, Reiners J, Schumacher J, Gottstein
# J, Gohlke H, Smits S, "Characterization of the nucleotide-binding domain NsrF from the
# BceAB-type ABC-transporter NsrFP from the human pathogen Streptococcus agalactiae",
# Sci Rep 2020 (published 2020 Sep 16), DOI 10.1038/s41598-020-72237-7. Entry:
# https://www.sasbdb.org/data/SASDJR3/. The paper's open-access full text (Europe PMC,
# PMC7494861) and, in the round-6 audit (2026-11-13), the PDF in sources/ were read
# (Methods, "Small angle X-ray scattering (SAXS)"): "All measurements were performed at
# 15 °C with protein concentrations between 0.5 and 4.2 mg mL-1 ... twelve frames with an
# exposer time of ten minutes ... Data were scaled to absolute intensity against water";
# Results: the CRYSOL fit of the TopModel model gives "χ2 value of 1.16". The paper
# states NO buffer for the SAXS run (no sentence names it), so the SASBDB entry (buffer
# field and experiment description: 100 mM HEPES, 150 mM NaCl, 10 % glycerol, pH 8)
# is the only statement of it and is what is modelled; the paper does not contradict
# it. The only buffer of the Methods is the purification (IMAC and SEC) buffer, 100 mM
# HEPES pH 8, 300 mM NaCl, 20 % glycerol, which is the storage buffer ("a buffer system
# containing 300 mM of NaCl was used for protein storage") and not a statement about the
# SAXS sample.
#
# Instrument (SASBDB): Xenocs Xeuss 2.0 Q-Xoom with Pilatus3 R 300K and a GENIX 3D Cu
# ultra-low-divergence source, Center for Structural Studies, Heinrich Heine University
# Duesseldorf; wavelength 0.154 nm (SASBDB `xray_energy` is null, so the energy is
# hc/λ ≈ 8051 eV); sample-detector distance 0.55 m; twelve 600 s frames; cell
# temperature 15 °C (storage 10 °C); measured 2019-12-11; the curve is a merge of
# low-angle data of lower concentrations with the high-angle data of 4.2 mg/ml.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; 682 points from 0.199 to
# 4.176 nm⁻¹; two text lines, then q, I, σ, then "range-from / range-to" lines, all
# skipped by `_readCurve`) and is converted to Å⁻¹ (÷10). The intensities are on an
# absolute scale (SASBDB intensity_unit 1/cm). I/σ is 27 at 0.06 Å⁻¹, 13 at 0.10 Å⁻¹
# and about 2 beyond 0.14 Å⁻¹; 80 of the 682 points have I ≤ 0 (7 below 0.2 Å⁻¹, 41
# below 0.3 Å⁻¹; `seedModel` drops them). The whole curve is fitted (no q cut,
# see `Q_MAX_FIT`); the depositor's CRYSOL curve ends at 0.33 Å⁻¹.
#
# Model and depositor fit: SASDJR3 has TWO fits. fit1 is GASBOR (dummy residues, χ²
# 0.97; not used). fit2 is CRYSOL against the TopModel homology model (SASBDB: "Other",
# TopModel; no PDB id, 28.31 kDa), χ² 1.156 (the paper: 1.16). SASDJR3_fit2_model1.pdb
# is SASBDB's file: 4035 ATOM records, no chain id, residues 2 onward, no ligands, no
# waters, and explicit hydrogens (2038 of the 4035 atoms; protein only, amber-style
# names). CLEANED COPY: 102 atom records of 9 histidines carry the amber residue name
# HIE; `components.tsv` knows HIE as an unrelated drug-like component (C23 H27 F3 N4 O3),
# not as a histidine, so the loader would mis-classify those residues. The fitted copy
# SASDJR3_fit2_model1_HIS.pdb differs from the original ONLY in the residue name of
# those records (HIE -> HIS, columns 18-20); coordinates and every other column are
# unchanged, and the original is kept beside it. The loader drops the model's hydrogens
# and pdb2pqr/PROPKA place them again at PH. The deposited fit header reads
# "SaNsrF_T  Dro:0.075  Ra:1.400  RGT:22.34  Vol: 38096.  Chi^2: 1.156"; the fit file
# (541 rows, q = 0 to 0.332 Å⁻¹) recomputed from its columns 2-4 over the 529 rows
# matching the .dat gives χ² = 1.156, so the label is χ² (not χ) and the depositor's χ²
# is 1.156 (SASBDB chi_square_value: the same).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB buffer pH 8 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, SASBDB wavelength 0.154 nm
const TEMPERATURE_C = 15.0                    # SASBDB cell temperature (storage 10 °C)

# Buffer (SASBDB buffer name and experiment description; the paper names no SAXS buffer,
# see the Source note): "100 mM HEPES, 150 mM NaCl, 10% glycerol", pH 8; the measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Counter-ion: setting the pH adds a titrant that the recipe does not list.
# Convention: 100 mM HEPES titrated with NaOH (Good's buffer) -> Na⁺ = C·0.7714 (pK(22
# °C) = 7.601; HEPES pK 7.564 at 25 °C, ΔH 21.0 kJ/mol, Goldberg, Kishore & Lennen
# 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902, quoted from the
# SASDKQ8/SASDB48 scripts and not re-checked). The pH is taken as set at room
# temperature (22 ± 3 °C), whatever the measurement temperature, Davies-corrected at I ≈
# 0.227 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C, as
# in SASDB48. Titrant: not stated; NaOH for Good's buffers (convention). Only the
# counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not.
#
# Glycerol 10 % (bare %, read as v/v by convention, as in SASDRJ8): 10 mL glycerol/100 mL
# solution x 1.2613 g/mL / 92.094 g/mol x 1000 ≈ 1.3696 M, ±5 % relative.
const SOLUTES = Solute[
    NonBiological(0.1, 0.002, "hepes"),                  # 100 mM HEPES, ±2%
    NonBiological(0.15, 0.0015, "sodium chloride"),      # 150 mM NaCl, ±1%
    NonBiological(1.3696, 0.0685, "glycerol"),           # 10 % v/v glycerol, ±5%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.07714, 0.004937, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0199-0.4176 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.3 Å⁻¹ was used before, but the 202 points above 0.3
# Å⁻¹ (σ > 0) have a median I/σ of 1.07 and 19 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 1.07 ≥ 0.5; I ≤ 0 share 19 % < 25 %; median
# I/σ 1.24 ≥ 1 in the lowest-q quarter (up to 0.33 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model's own hydrogens are dropped by the loader; pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `runSasdjr3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjr3` below is the whole story (build the seed, then sample it).
function seedSasdjr3(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjr3(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdjr3(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjr3()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.156",
    runLog = true,
)

# `@__DIR__` (this SASDJR3/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
