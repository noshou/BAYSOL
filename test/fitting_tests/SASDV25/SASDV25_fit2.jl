# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDV25")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDV25.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDV25_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDV25_fit2.fit")

# The .dat has 2 lines of header and 9 lines of processing history at the end, and the
# latter break `readdlm` (the history has quote characters), so `_readCurve` (common.jl,
# numeric rows only) reads it: 200 points.
qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 200

# qvals are in nm⁻¹ (0.06-10.0); must convert to Å⁻¹ (0.006-1.0).
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDV25, fit2 (the CRYSOL fit of the RNAMasonry atomic model). Not fit1: its
# model (PyMOL) has a depositor chi2 of 125.7 and is not used. Same paper as SASDVV4
# (already in the repo, same script layout and buffer recipe): Gezelle et al. 2025,
# Nucleic Acids Res., "A conserved viral RNA fold enables nuclease resistance across
# kingdoms of life", DOI 10.1093/nar/gkaf840 (PMID 40884403). Audited against the paper
# (round 5, 2026-11-13; main text only, its Supplementary Table S1 was not available):
# NAR 53(16):gkaf840, Materials and methods, "Small-angle X-ray scattering" (p. 5):
# "RNAs were buffer-exchanged into SAXS buffer (50 mM Tris-HCl pH 7.5, 100 mM sodium
# chloride, 1 mM DTT, either with or without 10 mM MgCl2) using 3 kDa molecular weight
# cutoff Amicon centrifugal concentrators", "Samples were adjusted to a final
# concentration of 3 mg/ml", SEC on a Superdex 200 Increase 10/300 GL "pre-equilibrated
# in SAXS buffer with or without MgCl2 ... at a flow rate of 0.75 ml/min" (so the SEC
# buffer is the SAXS buffer), 16-ID (LiX) NSLS-II, Pilatus 1M. Data availability (p. 14):
# "SASDV25 (ST9a PK mutant, monomer, 0 mM MgCl2)" = the no-Mg variant of that buffer.
# Results (p. 9): "Calculated SAXS curves for ST9a xrRNA PKm modeled in an open
# conformation using RNAmasonry best fit the experimental SAXS data of ST9a-PKm (chi2 =
# 0.96)", and Methods: "We further used the processed SEC-SAXS data of ST9a PKm monomer
# (0 mM MgCl2) to create a structural model with RNAmasonry", i.e. this model (fit2) and
# 0.958. From the SASBDB entry only (the paper defers to Supplementary Table S1, not
# available, and does not contradict them): temperature 20 C, wavelength 0.082 nm and
# the 0.0002 % w/v NaN3 (the paper never mentions azide).
#
# Sample: ST9 RNA, PK mutant (59 nt, 19.1 kDa), in-line SEC-SAXS of a 3 mg/mL
# injection (flow 0.75 mL/min), 20 °C, NSLS-II 16-ID (LiX), Pilatus3 S 1M, wavelength
# 0.082 nm => energy = hc/λ ≈ 15.1 keV (hc = 12398.42 eV·Å). Curve: SEC-SAS, 1/nm,
# 0.06-10.0 nm⁻¹.
#
# Model: SASDV25_fit2_model1.pdb, RNAMasonry model (REMARK header lines with the
# RNAMasonry energy and node data only), 1261 atoms, heavy atoms only, residue names
# G/A/C/U, no ions and no Mg²⁺ (the buffer has none). Unmodified.
#
# Depositor fit: CRYSOL, `.fit` header "Chi^2: 0.958" (Dro 0.039, Rg 25.26, Vol 18920).
# Recomputed from the `.fit` columns (q, I_exp, σ, I_fit; mean of ((I_exp - I_fit)/σ)²
# over the 200 points to 1.0 Å⁻¹): 0.953, so the header is a chi2 and not a chi. The
# SASBDB REST value agrees with the header (0.958, per notes/replacement-candidates.md).
# refChi2 = "CRYSOL 0.958".
#
# Buffer (SASBDB buffer name, "0 mM MgCl2 buffer" in its comment field):
#
#     50 mM Tris pH 7.5, 100 mM NaCl, 1 mM DTT, 0.0002% w/v NaN3, no MgCl2
#
# SASBDB gives no separate pH field; the pH is the 7.5 of the buffer name.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 0.82   # ≈ 15120 eV, from the stated 0.082 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB

# Buffer components. 0.0002 % w/v NaN3 = 0.002 g/L / 65.01 g/mol = 3.08e-5 M. Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# 50 mM Tris titrated with HCl (stated: "Tris-HCl") -> Cl⁻ = C·0.856 (pK(22 °C) =
# 8.156). The pH is
# taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion amount
# whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-
# corrected at I ≈ 0.143 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift,
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
    NonBiological(3.076e-5, 6.2e-7, "sodium azide"),      # 0.0002 % w/v NaN3, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.04280, 0.002136, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole curve is fitted, up to 1.0 Å⁻¹ (the .dat and the .fit file end
# there). The tail is signal, not noise (median I/σ 4.5 above 0.3 Å⁻¹, no point with
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

# Builds the Seed that `runSasdv25Fit2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdv25Fit2` below is the whole story (build the seed, then sample it).
function seedSasdv25Fit2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdv25Fit2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdv25Fit2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdv25Fit2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit2", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 0.958",
    runLog = true,
)

# `@__DIR__` (this SASDV25/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
