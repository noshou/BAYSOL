# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDKY3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDKY3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDKY3_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDKY3_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDKY3: the 101-nt Varkud satellite (VS) ribozyme (SASBDB molecule 32.654 kDa;
# model 31.45 kDa), a nucleic-acid entry.
#
# Paper: DOI 10.1093/nar/gkab963 (Nucleic Acids Research 2021, the NMR-SAXS structure of
# the VS ribozyme). The paper WAS consulted (OUP full-text page; no page numbers are
# available there, so sections are cited): "SAXS data collection and analysis" gives
# the SAXS buffer as 50 mM MES pH 6.5, 50 mM KCl, then the "SAXS-5" buffer with 5 mM
# MgCl2, and "all SAXS data collection was performed at 20°C". Only the first
# 100,000 of about 192,000 characters of that page were read. The paper's supplement
# (sources/gkab963_supplemental_file.pdf, Table S1, column "TR4P 5 mM Mg2+") was read
# afterwards and confirms: 50 mM MES, 50 mM KCl, 5 mM MgCl2, pH 6.5; wavelength
# 1.34 Å; sample temperature 20 °C; q range measured 0.0106-0.5778 Å⁻¹; merged
# concentrations 0.5-5.0 mg/mL; CRYSOL (default parameters) q range 0.011-0.3 Å⁻¹.
# The Fig. 4 caption says "NMRG-5 buffer" (the NMR buffer), which does not match the
# Methods text ("SAXS-5") or Table S1; Methods, Table S1 and the SASBDB buffer agree
# (MES/KCl/MgCl2), so they are used. "Description of the NMR-SAXS structural
# ensemble": CRYSOL was run "with default parameters and a qmax of 0.3 Å⁻¹"; the best
# ensemble member gave χ²free = 1.08 and the crystal model (PDB 4R4V) 1.8.
#
# Instrument (SASBDB): Xenocs BioXolver L with a MetalJet source, Pilatus3 R 300K,
# Université de Montréal; wavelength 0.134 nm = 1.34 Å, energy = hc/λ ≈ 9252 eV; 10
# frames of 30 s; 0.5 mg/ml; cell 20 °C (storage 4 °C).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit "1/A"), 430 points, q from 0.0107
# to about 0.58 Å⁻¹, so NO nm⁻¹ conversion is applied. The whole curve is fitted (no q cut,
# see `Q_MAX_FIT`); the depositor's fit (the paper's CRYSOL q range, Table S1) ends at
# 0.3 Å⁻¹.
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL (fit1) against the NMR-SAXS hybrid
# model SASDKY3_fit1_model1.pdb (software "Other"): one blank chain, residues 201-301
# (101 nt), 2160 heavy atoms + 1092 H, no HETATM groups, no waters, no MODEL records, no
# altloc duplicates; a 5' monophosphate (OP3) is present and the last residue is named
# RG3. The fit file has padding rows (q = 0 and 0.002-0.010 with I_exp = 0). The header
# reads "Chi^2: 1.197"; recomputing from columns 2-4 over the 218 usable rows gives
# 1.2021 (0.4 % above), so the label is χ² (not χ) and the depositor's χ² is 1.197
# (= SASBDB chi_square_value).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.5, PH_METER_SIGMA   # paper and SASBDB: pH 6.5 (no σ stated)
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9252 eV, SASBDB wavelength 0.134 nm
const TEMPERATURE_C = 20.0                    # paper: all SAXS collection at 20 °C

# Buffer (paper, "SAXS data collection and analysis", and SASBDB): 50 mM MES, 50 mM KCl,
# 5 mM MgCl2, pH 6.5. The macromolecule is deliberately NOT a solute. Counter-ion
# (convention of the sibling scripts): the pH of MES is set with NaOH, the titrant is
# not stated. The pH is taken as set at room temperature (22 ± 3 °C); pK(MES, 22 °C) =
# 6.296 (the value used by the SASDF42 script). Davies (A = 0.509, g(I) = √I/(1+√I)
# - 0.3 I) at the self-consistent ionic strength: Ibase = 0.050 (KCl) + 0.015 (MgCl2)
# = 0.065 M, I = Ibase + C f with f the ionized fraction f = 1/(1 + 10^-(pH - pK +
# A g)); iterating gives f = 0.6715, I = 0.0986 M, so Na⁺ = 0.050 x 0.6715 =
# 0.03358 M. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and
# ±2 % on C: 0.00289 M. The RNA's own charge (about 1.5 mM) is neglected. ΔH(MES)
# (about 15 kJ/mol) is not in this repository; the temperature term of σ is below
# 0.0007 and no citation is claimed for it.
# Not modelled: Mg²⁺ binding to the RNA.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "mes"),   # 50 mM, ±2 %
    NonBiological(0.05, 0.0005, "potassium chloride"),   # 50 mM, ±1 %
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM, ±2 %
    # Na⁺ counter-ion from NaOH titration of MES (see note above)
    NonBiological(0.03358, 0.00289, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0107-0.5807 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.3 Å⁻¹ was used before, but the 213 points above 0.3
# Å⁻¹ (σ > 0) have a median I/σ of 0.98 and 20 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 0.98 ≥ 0.5; I ≤ 0 share 20 % < 25 %; median
# I/σ 1.84 ≥ 1 in the lowest-q quarter (up to 0.37 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model carries 1092 hydrogens already; pdb2pqr/PROPKA/Reduce rebuild
# them for the nucleic acid at PH (as the sibling nucleic-acid scripts do).
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

# Builds the Seed that `runSasdky3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdky3` below is the whole story (build the seed, then sample it).
function seedSasdky3(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdky3(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdky3(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdky3()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
fitCurve = _readFit(_FIT_PATH, 1.0, 4)
reference = BAYSOL.Reference("CRYSOL fit1", fitCurve...; qMax = Q_MAX_FIT)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.197",
    runLog = true,
)

# `@__DIR__` (this SASDKY3/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
