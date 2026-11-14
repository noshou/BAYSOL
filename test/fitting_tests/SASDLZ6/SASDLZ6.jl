# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDLZ6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDLZ6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDLZ6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDLZ6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDLZ6: Azospirillum brasilense glutamate synthase, the (αβ)6 hexamer
# (PDB 2vdc cryo-EM model, 89,598 heavy atoms; SASBDB experimental MW 1419 kDa, model
# 1279 kDa), buffer without ligands.
#
# Paper: Cottevieille M, et al., J Biol Chem 283(13):8237-8249 (2008), DOI
# 10.1074/jbc.M708529200. The paper WAS consulted (PDF /home/noso/BAYSOL/sources/
# PIIS0021925820527798.pdf; journal page = 8236 + PDF page). Experimental Procedures,
# p. 8238: protein in "25 mM Hepes/KOH buffer, pH 7.5, containing 1 mM EDTA and 1 mM
# dithiothreitol"; beamline X33 (DESY, Hamburg), 0.75 to 10.0 mg/ml, sample-detector
# distance 2.7 m, λ = 0.15 nm, 0.1 < s < 5 nm⁻¹, PRIMUS. OLIGOMER fits mixtures of αβ
# monomer, (αβ)2 dimer and (αβ)6 hexamer from the cryo-EM model, PDB 2vdc (p. 8239).
# Table 1, p. 8244: line "None", plot 04, 0.8 mg/ml (the SASBDB .dat header says 0.75),
# Rg 7.64 ± 0.04 nm, MM 1419 ± 212 kDa, 10.0 % αβ + 90.0 % (αβ)6, χ = 1.60. P. 8243:
# the cryo-EM model alone agrees well only at high concentration (plot 01, χ 9.49).
# The SAXS TEMPERATURE IS NOT STATED in the paper (25 °C appears only for the kinetic
# assays) nor, as far as read, in the record: 25 °C is ASSUMED (flagged).
#
# Instrument: EMBL X33, DORIS III, DESY; MAR 345 image plate, 60 s; λ = 0.15 nm (paper
# p. 8238 and record), energy = hc/λ ≈ 8266 eV.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; free-text header and
# trailer lines, skipped by `_readCurve`; 2174 numeric rows, q from 0.0603 to 5.087 nm⁻¹)
# and is converted to Å⁻¹ (÷10); intensities are arbitrary. The deposited fit covers
# s 0.00996 to 0.25 Å⁻¹ (1038 rows); the cut and its reason are at `Q_MAX_FIT` below.
#
# Model and depositor fit: fit1 is OLIGOMER, a 90 % hexamer + 10 % monomer MIXTURE; here
# the single deposited hexamer model is fitted, so this fit cannot reproduce the 10 %
# monomer and the reference curve is the mixture's. The header reads "Chi=   1.60":
# recomputing over the 1038 rows gives χ² = 2.5639 and χ = 1.6012, so 1.60 is χ (not
# χ²) and the depositor's χ² is 1.60² = 2.56 (= SASBDB chi_square_value 2.56).
#
# Model contents: SASDLZ6_fit1_model1.pdb, chains A-L (6 α + 6 β), no hydrogens, no waters,
# no MODEL records, no altloc duplicates: 88,830 ATOM + 768 HETATM = 89,598 heavy atoms.
# HETATM groups: FAD 318 atoms (6 x 53), FMN 186 (6 x 31), SF4 96 (12 x 8), F3S 42 (6 x 7),
# AKG 60 (6 x 10), OMT 66 (6 x 11). All are in components.tsv (FAD, FMN, AKG, SF4, F3S
# "other"; OMT "l-peptide linking", parent MET, kept as a modified residue) and the
# loader keeps them (`KEEP_LIGANDS`). MISMATCH: the model contains AKG (2-oxoglutarate)
# and OMT (methionine sulfone) while the measured sample has no ligands.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # paper p. 8238: pH 7.5 (no σ stated)
const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, λ = 0.15 nm (paper p. 8238)
const TEMPERATURE_C = 25.0                   # ASSUMED: not stated (see the source block)

# Buffer (paper p. 8238): 25 mM HEPES/KOH, 1 mM EDTA, 1 mM DTT, pH 7.5. The
# macromolecule is deliberately NOT a solute. Counter-ion: the titrant is KOH (stated), so
# K⁺ = C f. pH taken as set at 22 ± 3 °C, pK(HEPES, 22 °C) = 7.600 (as the SASDWR5
# script, Goldberg, Kishore & Lennen 2002, DOI 10.1063/1.1416902). Davies (A = 0.509) at
# I = Ibase + C f, Ibase = 0.003 M (the EDTA salt, below): f = 0.4730, I = 0.0148 M, so
# the K⁺ of HEPES = 0.025 x 0.4730 = 11.82 mM (σ 1.55 mM: σ_pH = 0.1, ±3 °C, ±0.02 pK,
# 30 % of the Davies shift, ±2 % on C).
# EDTA: the salt form is not stated; ASSUMED H2EDTA²⁻ + 2 K⁺ at pH 7.5 (the table's
# "H2EDTA"), so 2 x 1 mM = 2 mM K⁺ more; K⁺ in total = 11.82 + 2 = 13.82 mM.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),   # 25 mM, ±2 %
    NonBiological(0.001, 0.00002, "H2EDTA"),   # 1 mM, ±2 %
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM, ±2 %
    # K⁺ counter-ions: KOH titration of HEPES plus the EDTA salt (see note above)
    NonBiological(0.01382, 0.00160, "potassium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.25 Å⁻¹. The data run to 0.509 Å⁻¹,
# but the 1118 points above 0.25 Å⁻¹ (σ > 0) have a median I/σ of 0.30 and 40 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.31 Å⁻¹) has a median I/σ of 0.41.
const Q_MAX_FIT = 0.25

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

# Builds the Seed that `runSasdlz6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdlz6` below is the whole story (build the seed, then sample it).
function seedSasdlz6(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdlz6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdlz6(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdlz6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is OLIGOMER's (fit1): columns s (Å⁻¹), I_exp, I_fit, σ, discrepancy;
# the fitted intensity is column 3 (the I_exp column equals the .dat, so no rescaling).
# It is a MIXTURE fit (90 % hexamer + 10 % monomer); the curve here is the mixture's.
fitCurve = _readFit(_FIT_PATH, 1.0, 3)
reference = BAYSOL.Reference("OLIGOMER fit1", fitCurve...; qMax = Q_MAX_FIT)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "OLIGOMER 2.56 (chi 1.60 squared; 90 % hexamer + 10 % monomer)",
    runLog = true,
)

# `@__DIR__` (this SASDLZ6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
