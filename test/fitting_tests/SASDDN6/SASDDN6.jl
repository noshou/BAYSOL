# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDDN6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDDN6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDDN6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDDN6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDDN6: human stress-inducible Hsp70 (HSPA1A, P0DMV8), T204A mutant, an
# ATP-dependent antiparallel dimer (two 36.87 kDa chains; SASBDB experimental MW
# 148 kDa) at 2.5 mg/ml, with ATP, in 50 mM HEPES, 150 mM potassium acetate, 2 mM MgCl2,
# pH 7.5.
#
# Publication (SASBDB): Trcka F, Durech M, Vankova P, Chmelik J, Martinkova V, Hausner J,
# Kadek A, Marcoux J, Klumpler T, Vojtesek B, Muller P, Man P, "Human stress-inducible Hsp70
# has a high propensity to form ATP-dependent antiparallel dimers that are differentially
# regulated by co-chaperone binding", Mol Cell Proteomics 2019 (published 2018 Nov 20), DOI
# 10.1074/mcp.RA118.001044, PMID 30459217. Entry: https://www.sasbdb.org/data/SASDDN6/. The
# paper WAS consulted (the PDF in sources/, zjw320). Methods, "Small-angle X-ray Scattering
# (SAXS)" (PDF p. 4): "Data were collected at 277 K with ... Cu Kα X-ray (1.54 Å). Sample to
# detector (PILATUS 100K, Dectris) distance was 0.48 m ... Size exclusion buffer was used
# for the blank measurement. Hsp70-T204A protein samples were measured at 2.5 and 1.5
# mg/ml." Results (PDF p. 9): "T204A protein was pre-incubated with ATP and its dimeric form
# was separated by SEC before SAXS at two protein concentrations"; CRYSOL 2.8.3, dimer model
# χ² = 1.2 (1.5 mg/ml) and 1.1 (2.5 mg/ml; this entry, SASBDB 1.15). The paper does NOT
# state the composition of the SAXS (size-exclusion) buffer, nor an ATP concentration in it
# (0.2 mM ATP is the pre-incubation of the analytical SEC; the dimer fraction is separated
# from free ATP), so the buffer is the SASBDB field, which the paper does not contradict
# (its other assays use 25 or 50 mM HEPES pH 7.5, 100-150 mM KAc, 2 mM MgCl2). Owner's call:
# the analytical-SEC buffer of the paper is 25 mM HEPES, but it is not stated for the SAXS.
#
# Instrument (SASBDB): Rigaku BioSAXS-1000 (in-house source), Pilatus 100K detector,
# CEITEC Masaryk University, Brno, Czech Republic; wavelength 0.154 nm (SASBDB
# `xray_energy` is null, so the energy is hc/λ ≈ 8051 eV); sample-detector distance
# 0.48 m (the description text says 0.5 m); one 3600 s exposure; cell and storage
# temperature 4 °C; measured 2018-02-20; one concentration, 2.5 mg/ml.
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (angular_unit "1/A"; 430 points from
# 0.0138 to 0.631 Å⁻¹, no header lines, three columns q, I, σ). The intensities are in
# arbitrary units (SASBDB intensity_unit). I/σ is about 24 below 0.08 Å⁻¹, 3.6 at
# 0.14 Å⁻¹ and about 1 beyond 0.2 Å⁻¹; 48 of the 430 points have I ≤ 0 (none below
# 0.2 Å⁻¹, ten below 0.3 Å⁻¹, which `seedModel` drops). The whole curve is fitted (no q
# cut, see `Q_MAX_FIT`); the depositor's CRYSOL curve runs to 0.50 Å⁻¹.
#
# Model and depositor fit: a MODELLER 9.18 homology model of the antiparallel dimer
# ("HSP70dim_open_ATP", template 5E84 chains D/F, 63.6 % sequence identity, DOPE
# -138983) with two bound ATP (62 atoms), no PDB id. SASDDN6_fit1_model1.pdb is
# SASBDB's file: 10386 ATOM/HETATM records, two chains A and B of 672 residues (5224
# atoms each) plus the two ATP (the SASBDB MW 148.5 kDa), no waters, no hydrogens and no
# Mg²⁺ (the Mg²⁺ of the buffer is a solute here). The deposited fit header reads
# "HSP70dim  Dro:0.003  Ra:1.800  RGT:38.98  Vol:197648.  Chi^2: 1.150"; the fit file
# (346 rows, q = 0 to 0.5004 Å⁻¹) recomputed from its columns 2-4 over the 339 rows
# matching the .dat gives χ² = 1.149, so the label is χ² (not χ) and the depositor's χ²
# is 1.150 (SASBDB chi_square_value: 1.15, CRYSOL 2.8.3). The CRYSOL contrast of
# 0.003 e/Å³ is low for a protein in this buffer; the sampler is free to move it.
#
# Ligands: ATP (C10 H16 N5 O13 P3) is a ligand of a known composition in
# `components.tsv`, so the loader keeps both (`ligandSelector`, `KEEP_LIGANDS`, owner
# decision 2026-11-11); they carry no hydrogens (pdb2pqr places none on ligands).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A); no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB buffer pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, SASBDB wavelength 0.154 nm
const TEMPERATURE_C = 4.0                    # SASBDB cell temperature (storage 4 °C)

# Buffer as deposited (SASBDB buffer name and experiment description): "50mM HEPES,
# 150mM KCH3COO, 2mM MgCl2", pH 7.5, no ATP listed (the paper: the dimer was separated
# from free ATP by SEC and the SEC buffer was the blank); the measured macromolecule is
# deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Counter-ion: setting the pH adds a titrant that the deposited recipe does not list.
# Assumed: 50 mM HEPES titrated with NaOH -> Na⁺ = C·0.5134 (pK(22 °C) = 7.601; HEPES pK
# 7.564 at 25 °C, ΔH 21.0 kJ/mol, Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref.
# Data 31, 231, DOI 10.1063/1.1416902, quoted from the SASDKQ8/SASDB48 scripts and not
# re-checked). The pH is taken as set at room temperature (22 ± 3 °C), whatever the
# measurement temperature (4 °C), Davies-corrected at I ≈ 0.184 M (150 mM potassium
# acetate, 2 mM MgCl2 and the titration ions). σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift and ±2 % on C, as in SASDB48. Titrant: not stated; NaOH for Good's
# buffers is the convention (KOH would be as plausible beside 150 mM K⁺; the electron
# difference is below 0.01 %). Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),                     # 50 mM HEPES, ±2%
    NonBiological(0.15, 0.0015, "potassium acetate"),        # 150 mM KCH3COO, ±1%
    NonBiological(0.002, 0.00004, "magnesium chloride"),     # 2 mM MgCl2, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.025669, 0.003347, "sodium(1+)"),
]
# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "free ATP not in the buffer (dimer separated by SEC, paper and SASBDB list none)",
    "acid or base setting pH 7.5 not stated: NaOH assumed for HEPES (modelled)",
    "Mg²⁺-ATP and Mg²⁺-acetate ion pairing not modelled (known limitation of all scripts)",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDDN6: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS


# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0138-0.6314 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.3 Å⁻¹ was used before, but the 231 points above 0.3
# Å⁻¹ (σ > 0) have a median I/σ of 0.86 and 16 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 0.86 ≥ 0.5; I ≤ 0 share 16 % < 25 %; rule in
# README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH (the ATP ligands
# stay heavy-atom only).
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

# Builds the Seed that `runSasddn6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasddn6` below is the whole story (build the seed, then sample it).
function seedSasddn6(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasddn6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasddn6(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasddn6()

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
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.150",
    runLog = true,
)

# `@__DIR__` (this SASDDN6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
