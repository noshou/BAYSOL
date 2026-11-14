# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, DEFAULT_TEMPERATURE_C
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMM9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMM9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDMM9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDMM9_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMM9: RocR, the response regulator of Pseudomonas aeruginosa PAO1 (UniProt
# Q9HX69, 42.8 kDa per chain; the tetramer, 4 x 42.8 = 171.3 kDa; SASBDB experimental
# MW 170 kDa), in 50 mM Tris-HCl, 250 mM NaCl, 10 mM imidazole, 5 % glycerol, 0.5 mM
# DTT, pH 7.5; up to 5.5 mg/ml (concentration_max).
#
# Publication (SASBDB): Chen M, Kotaka M, Vonrhein C, Bricogne G, Rao F, Chuah M,
# Svergun D, Schneider G, Liang Z, Lescar J, "Structural Insights into the Regulatory
# Mechanism of the Response Regulator RocR from Pseudomonas aeruginosa in Cyclic
# Di-GMP Signaling", J Bacteriol 2012 (published 2012 Jun 29), DOI 10.1128/JB.00560-12.
# Entry: https://www.sasbdb.org/data/SASDMM9/ (released 2021, the measurement is from
# 2011-12-09). The conditions below are the SASBDB entry metadata, checked against the
# paper (J Bacteriol 2012, Fig. 3, measured at EMBL X33):
# the paper's own Fig. 3A fits the WILD-TYPE RocR curve with the calculated scattering
# of the R286W crystal tetramer (curve 2, closed), the depositor's fit1 is that same
# comparison (header χ 1.08), so a wild-type curve against the R286W model is the
# paper's own design, not a mismatch introduced here (round 7, AUDIT7).
#
# Instrument (SASBDB): EMBL beamline X33, DORIS III, DESY, Hamburg; Pilatus 1M-W;
# wavelength 0.15 nm = 1.5 Å (SASBDB `xray_energy` is null, so the energy is
# hc/λ ≈ 8266 eV); sample-detector distance 2.7 m; 8 frames of 15 s. Neither SASBDB nor
# the paper gives a SAXS temperature, so the package default (`DEFAULT_TEMPERATURE_C`,
# 25 °C) is used, an ASSUMED value accepted by the owner for such entries.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.201 and s_max
# 6.032 nm⁻¹; the "Sample"-style text lines, then q, I, σ, all skipped by `_readCurve`)
# and is converted to Å⁻¹ (÷10). The intensities are on an arbitrary scale (about 88
# at the lowest q). 29 of the 2128 points have I ≤ 0 (the first at 0.255 Å⁻¹; 7 below
# 0.3 Å⁻¹). The whole curve is fitted (the data go to 0.60 Å⁻¹, the deposited CRYSOL
# curve to 0.50 Å⁻¹), and `seedModel` drops the non-positive bins.
#
# Model and depositor fit: fit1 is CRYSOL 2.8 against SASBDB's atomic model, a REFMAC
# 5.5.0102 refinement of the crystal structure (type "other", no PDB link; the file
# starts with the REMARK 3 block, "HEADER ----"): chains A-D (389, 392, 380 and 371
# residues, the tetramer, no hydrogens) plus 168 HOH, 4 Mg²⁺ (chains E, G, H, I, one
# each) and 15 EPE atoms (one HEPES molecule, chain J) that are all written as ATOM
# records. The loader drops waters by name and keeps the ligands of a known
# composition (`KEEP_LIGANDS`: `components.tsv` has MG and EPE); that this file's ATOM
# records for MG/EPE pass pdb2pqr and the loader is UNTESTED (the SASDAX2 script is the
# precedent for ligands written as ATOM records). The Mg²⁺ and the HEPES come from the
# crystallization conditions, NOT from the SAXS buffer (which lists neither); they are
# scattered anyway because they are part of the deposited model and of the CRYSOL fit.
# The other fit (DAMMIF) has no χ².
#
# Depositor χ²: the fit file's first line reads "rocr-fin  Dro:0.020  Ra:1.760
# RGE:36.93  RGT:36.56  Vol:225847.  Chi:1.081", whereas SASBDB's chi_square_value is
# 1.168561. The header label is "Chi:" (χ, CRYSOL's root-mean-square deviate, NOT
# "Chi^2:"): 1.081² = 1.1686, which IS the REST value. So the two numbers agree and
# the depositor's χ² is 1.169 (the label string below carries χ², the quantity the
# other entries give). The .fit file (1763 points, 3 columns q (Å⁻¹), I_exp, I_fit; no
# σ column; the first 11 rows, q < 0.02 Å⁻¹, repeat one constant in the I_exp column
# and carry the fitted curve alone) recomputed with the data's σ gives χ ≈ 1.08, i.e.
# the header is χ.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB: pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, SASBDB wavelength 0.15 nm
const TEMPERATURE_C = DEFAULT_TEMPERATURE_C  # ASSUMED, in neither SASBDB nor the paper

# Buffer as deposited (SASBDB buffer name): "50 mM Tris-HCl, 250 mM NaCl, 10 mM
# imidazole, 5 % glycerol, 0.5 mM DTT", pH 7.5. The measured macromolecule is
# deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Counter-ions. Setting the pH adds titrant counter-ions. Assumed (not stated): Tris
# and imidazole titrated with HCl, so Cl⁻ = c·f with f the protonated fraction. Tris:
# pK(22 °C) = 8.156 (the SASDCM5 script, from Goldberg, Kishore & Lennen 2002, J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; not re-checked), f = 0.860,
# 43.0 mM. Imidazole: pK = 6.993 (SASDYW6 script, same source, 25 °C, not re-checked),
# f = 0.296, 3.0 mM. Both Davies-corrected (A = 0.509) at I ≈ 0.29 M, the pH taken as
# set at room temperature. Cl⁻ = 46.0 mM in addition to the 250 mM of NaCl; σ = 3 mM
# covers σ_pH = 0.1 (1.5 mM), 30 % of the Davies shift (0.6 mM) and the titrant
# assumption. Glycerol: "5 %" without unit, taken as v/v: 50 mL/L · 1.2613 g/mL /
# 92.094 g/mol = 0.685 M; if it was w/v the value would be 0.543 M, so σ = 0.07 M
# (about 10 %) spans both. DTT 0.5 mM and the other rows ±2 %/±1 %.
const SOLUTES = Solute[
    NonBiological(0.250, 0.0025, "sodium chloride"),   # 250 mM NaCl, ±1%
    NonBiological(0.050, 0.001, "tris"),               # 50 mM Tris-HCl, ±2%
    NonBiological(0.010, 0.0002, "imidazole"),         # 10 mM imidazole, ±2%
    NonBiological(0.685, 0.07, "glycerol"),            # 5 % (v/v assumed), see above
    NonBiological(0.0005, 1e-05, "dtt"),               # 0.5 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris and imidazole (see note above)
    NonBiological(0.04598, 0.003, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The whole .dat is fitted (q 0.0201-0.6032 Å⁻¹); the depositor's fit ends at 0.5002 Å⁻¹,
# so refChi2 is not like for like.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdmm9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdmm9` below is the whole story (build the seed, then sample it).
function seedSasdmm9(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdmm9(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdmm9(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdmm9()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, I_fit (three columns, no σ);
# the q = 0 row cannot be drawn on a log axis.
crysol = readdlm(_FIT_PATH; skipstart = 1)
shown = crysol[:, 1] .> 0
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[shown, 1]),
    Float64.(crysol[shown, 3]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.169",
    runLog = true,
)

# `@__DIR__` (this SASDMM9/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
