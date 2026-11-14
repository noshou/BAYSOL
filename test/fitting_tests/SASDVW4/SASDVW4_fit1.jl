# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVW4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVW4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVW4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVW4_fit1.fit")

# The .dat has 2 lines of header and 9 lines of processing history at the end, and the
# latter break `readdlm` (the history has quote characters), so `_readCurve` (common.jl,
# numeric rows only) reads it: 200 points (7 of them with I ≤ 0, which `seedModel`
# drops when it bins).
qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 200

# qvals are in nm⁻¹ (0.06-10.0); must convert to Å⁻¹ (0.006-1.0).
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVW4, fit1 (CRYSOL fit of the PyMOL model). Same paper as SASDVV4 (already
# in the repo, same script layout; that entry is the 10 mM MgCl2 sample, this one the
# 1 mM MgCl2 sample): Gezelle et al. 2025, Nucleic Acids Res., "A conserved viral RNA
# fold enables nuclease resistance across kingdoms of life", DOI
# 10.1093/nar/gkaf840 (PMID 40884403). Audited against the paper (round 5, 2026-11-13;
# main text only, its Supplementary Table S1 was not available). NAR 53(16):gkaf840,
# Materials and methods, "Small-angle X-ray scattering" (p. 5): "RNAs were buffer-
# exchanged into SAXS buffer (50 mM Tris-HCl pH 7.5, 100 mM sodium chloride, 1 mM DTT,
# either with or without 10 mM MgCl2)", 3 mg/ml, SEC on a Superdex 200 Increase 10/300
# GL "pre-equilibrated in SAXS buffer with or without MgCl2 ... 0.75 ml/min" (the SEC
# buffer is the SAXS buffer), 16-ID (LiX) NSLS-II. The 1 mM MgCl2 of this sample is
# stated in Data availability (p. 14): "SASDVW4 (ST9a WT 54 nucleotides, monomer, 1 mM
# MgCl2)"; the Methods sentence above names only the 0 and 10 mM variants and does not
# contradict it. Model: Methods, "we first fitted the SAXS data of 59-base ST9a WT
# xrRNA ... to the final structure coordinates containing 55 of the 59 bases" and
# Results (p. 9), "the best fit observed when SAXS data for a 54-nucleotide minimal
# xrRNA element were collected in Mg2+-containing buffer (chi2 = 1.26)" against the
# crystal structure (PDB 9CFN); the paper does not mention PyMOL or the Mg2+ ion of the
# deposited model (SASBDB: "PyMOL", chi2 1.779 for this 1 mM curve). FLAG: the model
# has 55 residues (A1-G55 by residue number; the 5' residue without phosphate) against
# the 54 nt of the sample; the paper does not say how the one-nucleotide difference
# arises (sequences in its Supplementary Table S3, not available). Round 6 (2026-11-13):
# the paper itself says that crystal structure was fitted to the 54-nt sample data, and
# the depositor's CRYSOL fit is this model, so the model is the paper's; the paper wins
# any conflict. From the SASBDB entry
# only (the paper defers to Supplementary Table S1 and does not contradict them):
# temperature 20 C, wavelength 0.082 nm, and the absence of NaN3 from this buffer name.
#
# Sample: ST9 RNA, wild type (54 nt, 17.5 kDa), in-line SEC-SAXS of a 3 mg/mL
# injection (flow 0.75 mL/min), 20 °C, NSLS-II 16-ID (LiX), Pilatus3 S 1M, wavelength
# 0.082 nm => energy = hc/λ ≈ 15.1 keV (hc = 12398.42 eV·Å). Curve: SEC-SAS, 1/nm,
# 0.06-10.0 nm⁻¹.
#
# Model: SASDVW4_fit1_model1.pdb, PyMOL model, 1177 atoms (RNA chain A, residue names
# A/C/G/U, heavy atoms only, plus one Mg²⁺ HETATM, residue MG chain D). Unmodified.
#
# Depositor fit: CRYSOL, `.fit` header "Chi^2: 1.779" (Dro 0.032, Rg 17.13, Vol 17636).
# Recomputed from the `.fit` columns (q, I_exp, σ, I_fit; mean of ((I_exp - I_fit)/σ)²
# over the 188 points, 0.018-1.0 Å⁻¹): 1.770, so the header is a chi2 and not a chi. The
# SASBDB REST value agrees with the header (1.779, per notes/replacement-candidates.md).
# refChi2 = "CRYSOL 1.779". The .fit file starts at 0.018 Å⁻¹, so the overlaid
# reference curve does not cover the first points.
#
# Buffer (SASBDB buffer name):
#
#     50 mM Tris pH 7.5, 100 mM NaCl, 1 mM DTT, 1 mM MgCl2
#
# SASBDB gives no separate pH field; the pH is the 7.5 of the buffer name (the paper:
# "50 mM Tris-HCl pH 7.5"). Unlike the SASDVV4 and SASDV25 records, this buffer name
# lists no NaN3, so none is included; the paper's Methods never mention azide (3.1e-5 M
# would be negligible against 100 mM NaCl anyway).

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 0.82   # ≈ 15120 eV, from the stated 0.082 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB

# Buffer components. Counter-ions. Setting the pH adds titrant counter-ions that the
# deposited recipe does not list.
# 50 mM Tris titrated with HCl (stated: "Tris-HCl") -> Cl⁻ = C·0.856 (pK(22 °C) =
# 8.156). The pH is
# taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion amount
# whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-
# corrected at I ≈ 0.146 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift,
# and ±2 % on C (same recipe and relative σ, 5 %, as SASDVV4; recomputed by hand for
# this ionic strength, not by running code). Only the counter-ion is modelled; the volume
# change of the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine
# bases (Tris, imidazole, histidine, Bis-Tris), NaOH for Good's buffers (here the paper
# names HCl).
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.050, 0.001, "tris"),                  # 50 mM Tris, ±2%
    NonBiological(0.100, 0.001, "sodium chloride"),       # 100 mM NaCl, ±1%
    NonBiological(0.001, 0.00002, "dtt"),                 # 1 mM DTT, ±2%
    NonBiological(0.001, 0.00001, "magnesium chloride"),  # 1 mM MgCl2, ±1%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.04280, 0.002136, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole curve is fitted, up to 1.0 Å⁻¹ (the .dat and the .fit file end
# there). The tail is signal, not noise (median I/σ 2.9 above 0.3 Å⁻¹, no point with
# I ≤ 0).

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE, no PROPKA for a
# nucleic-acid-only file)
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut). (`seedModel`
bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(>(0), σ_exp)
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdvw4Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdvw4Fit1` below is the whole story (build the seed, then sample it).
function seedSasdvw4Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvw4Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvw4Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvw4Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.779",
    runLog = true,
)

# `@__DIR__` (this SASDVW4/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
