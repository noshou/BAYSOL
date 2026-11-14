# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDA58")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDA58.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDA58_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDA58_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDA58: pUL26N (UL26N, the N-terminal protease domain of the assemblin of the
# Pseudorabies virus, Suid herpesvirus 1, UniProt Q83417 residues 1-224 with an N-terminal
# His tag, 26.6 kDa per chain), a dimer in solution (SASBDB experimental MW 45 kDa, 9.83
# mg/ml, the highest concentration of the series).
#
# Publication (SASBDB): Zühlsdorf M, Werten S, Klupp BG, Palm GJ, Mettenleiter TC,
# Hinrichs W, "Dimerization-Induced Allosteric Changes of the Oxyanion-Hole Loop Activate
# the Pseudorabies Virus Assemblin pUL26N, a Herpesvirus Serine Protease", PLoS Pathog
# 2015, DOI 10.1371/journal.ppat.1005045. Entry: https://www.sasbdb.org/data/SASDA58/. The
# paper was read in full (round-4 audit, 2026-11-13: Methods "Small-angle X-ray
# scattering", S5 Fig legend; the S1 Table, a .docx, is not in the PDF); it does not report
# a CRYSOL fit (it used FFMAKER and OLIGOMER), so the deposited fit is the depositor's own
# addition.
#
# Instrument (SASBDB): EMBL beamline P12, PETRA III (DESY, Hamburg), Pilatus 2M,
# sample-detector distance 3.1 m; 20 frames of 0.05 s (the paper: 20 successive 50 ms
# exposures); cell temperature 10 °C (the paper: "In all experiments the sample
# temperature was 283 K", the same); measured 2013-09-23. Wavelength: the paper states
# λ = 1.24 Å (Methods and the S5 Fig legend), the SASBDB entry 0.12 nm (`xray_energy` is
# null) is the same value rounded, so the paper's is used: energy = hc/λ = 12 398.42 /
# 1.24 ≈ 9999 eV.
#
# Round-5 rescan (2026-11-13): confirmed, nothing new (buffer, 283 K and 1.24 A are the
# paper's Methods statements already cited above).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.068 and s_max
# 4.437 nm⁻¹), converted to Å⁻¹ (÷10) below. The intensities are in arbitrary units.
# Beyond about 0.175 Å⁻¹ the signal-to-noise falls to about 1 and 350 of the 1661 points
# are non-positive (the first at 0.175 Å⁻¹), so the fit is cut at `Q_MAX_FIT` = 0.17 Å⁻¹
# (the depositor's CRYSOL curve runs to 0.44 Å⁻¹).
#
# Model and depositor fit: fit1 is CRYSOL-style (SASBDB lists no software; the header
# reads "pdb4v07. Dro:0.040 Ra:1.400 RGE:26.04 RGT:25.95 Vol: 54783. Chi^2: 1.288")
# against SASDA58_fit1_model1.pdb, which SASBDB states is identical to PDB 4V07 (the UL26N
# dimer, chains A and B; 3477 ATOM and HETATM records: 7 Cl⁻, 1 Mg²⁺, 133 HOH, no
# hydrogens). fit2 is DAMMIN (dummy atoms, chi2 1.196; not used). The header label is the
# χ² ("Chi^2:") and equals SASBDB's chi_square_value 1.288 (REST and header agree), so
# refChi2 is 1.288. The .fit file has the CRYSOL layout: columns q (Å⁻¹), I_exp, σ, I_fit,
# with a leading q grid at which the experimental columns are placeholders and only I_fit
# is meaningful (all `Reference` uses). The waters are dropped by the loader; the ions are
# kept as known-composition HETATM ligands. The crystal structure's Mg²⁺ and Cl⁻ are those
# of its crystallisation.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB: pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, the paper's λ = 1.24 Å
const TEMPERATURE_C = 10.0                     # SASBDB cell temperature = paper's 283 K

# Buffer as deposited (SASBDB buffer name and additive fields): "50 mM Tris/HCl, 0.5 M
# NaCl, 0.25 M imidazole, 5 % glycerol, 50 mM urea, 0.2 M MgCl2", pH 7.5 (with 0.5 M NaCl,
# 0.25 M imidazole, 5 % glycerol and 50 mM urea in the additive field). The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# The 0.2 M MgCl2 (decided by the round-4 audit): the paper's base buffer is "0.5 M NaCl,
# 50 mM Tris pH 7.5, 0.25 M imidazole, 5% glycerol, 50 mM urea" and it measured a second
# series with 0.2 M MgCl2 added ("buffer used for SAXS measurements", Results; S5 Fig B
# red). This entry is the 9.83 mg/ml curve whose SASBDB buffer fields include 0.2 M MgCl2
# and whose model is the dimer (45 kDa); the paper's ab initio model (the SASBDB DAMMIN
# fit2) is "10 mg/ml in MgCl2-containing buffer", where the dimerisation is virtually
# complete, so the curve is the MgCl2 one and the line below stays. "5 % glycerol" has
# no unit in the paper (v/v is the convention; ±5 % covers v/v against w/w).
#
# Glycerol 5 % v/v: 0.05 L/L x 1261 g/L / 92.094 g/mol = 0.6846 M (the value of SASDKQ8);
# ±5 % since v/v against w/w is not stated.
#
# Counter-ion. Setting the pH adds titrant counter-ions that the deposited recipe does not
# list. Assumed: Tris and imidazole titrated with HCl (not stated). Method as in SASDP48
# and SASDYW6: the pH is taken as set at room temperature (22 ± 3 °C), so the amount is
# the same whatever the 10 °C of the measurement; pK(22 °C) = 8.156 for Tris (Goldberg,
# Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902, ΔH 47.45
# kJ/mol) and 7.058 for imidazole (6.993 at 25 °C, ΔH 36.64 kJ/mol, same source); the
# protonated fractions, Davies-corrected (A = 0.509) at the self-consistent I ≈ 1.22 M,
# are 0.845 for Tris (Cl⁻ 42.3 mM) and 0.304 for imidazole (Cl⁻ 75.9 mM), 118.1 mM in all.
# THE IONIC STRENGTH IS FAR ABOVE THE RANGE OF THE DAVIES EQUATION (about 0.5 M), so the
# fractions are indicative. σ is the sum (not the quadrature, both depend on the same pH)
# of the two: σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C (2.2 mM
# and 15.1 mM). Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not.
const SOLUTES = Solute[
    NonBiological(0.050, 0.001, "tris"),                 # 50 mM Tris, ±2%
    NonBiological(0.500, 0.010, "sodium chloride"),      # 0.5 M NaCl, ±2%
    NonBiological(0.250, 0.005, "imidazole"),            # 0.25 M imidazole, ±2%
    NonBiological(0.6846266, 0.0342, "glycerol"),        # 5 % v/v glycerol, ±5%
    NonBiological(0.050, 0.001, "urea"),                 # 50 mM urea, ±2%
    NonBiological(0.200, 0.004, "magnesium chloride"),   # 0.2 M MgCl2 (see note), ±2%
    # Cl⁻ counter-ion from HCl titration of Tris and imidazole (see note above)
    NonBiological(0.118145, 0.0173, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.17 Å⁻¹. The data run to 0.444 Å⁻¹,
# but the 1040 points above 0.17 Å⁻¹ (σ > 0) have a median I/σ of 0.46 and 34 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.24 Å⁻¹) has a median I/σ of 0.73.
const Q_MAX_FIT = 0.17

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

# Builds the Seed that `runSasda58` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasda58` below is the whole story (build the seed, then sample it).
function seedSasda58(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasda58(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasda58(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasda58()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL-style (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
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
    refChi2 = "CRYSOL 1.288",
    runLog = true,
)

# `@__DIR__` (this SASDA58/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
