# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDU29")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDU29.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDU29_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDU29_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 2)

# has 2 lines of headers, and 2 lines of trailer (range-from/range-to) at the end; need to
# skip.
qvals = Float64.(raw[1:1227, 1])
iExp = Float64.(raw[1:1227, 2])
σ_exp = Float64.(raw[1:1227, 3])

# q is already in Å⁻¹ (range 0.00417-0.3571, SASBDB "1/A", APS BioCAT 18ID); no unit
# conversion is applied, `checkQAngstrom` asserts it.
checkQAngstrom(qvals)

# The .dat is the SASBDB display copy, "scaled by a factor of 10000000" (its I(q) is
# ≈ 3 at the lowest q), while the depositor's .fit file holds the original, unscaled
# intensities (≈ 3e-7): the ratio of the two is 1e7 at every shared q. The fit does not
# depend on the scale (a free scale is profiled), but the reference curve of the
# comparison figure is brought onto the .dat's scale with this factor.
const FIT_FILE_SCALE = 1e7

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDU29/); paper: Srivastava D et al.
# 2024, Structure ("Molecular basis of CRX/DNA recognition and stoichiometry at the Ret4
# response element"), DOI 10.1016/j.str.2024.07.004.
#
#   Sample:   the homeodomain of cone-rod homeobox protein (CRX, UniProt O43186, 2 x
#             9.763 kDa) bound to the 20-bp Ret4 element of the rhodopsin promoter (sense
#             CAGGAGCTTAGGAGGGGGAG, antisense CTCCCCCTCCTAAGCTCCTG): a 2:1 CRX:DNA
#             complex of 31.9 kDa; SEC-SAXS (Superdex 75 10/300), 4.6 mg/mL injected
#   Buffer:   "20 mM Tris, 150 mM KCl, 5 % glycerol, 1 mM TCEP", pH 7.5
#   Temp.:    22 °C (cell; storage 4 °C)
#   Beamline: APS BioCAT 18ID, Pilatus3 X 1M, "wavelength of λ = 0.1033 nm" => 1.033 Å
#             => energy = hc/λ ≈ 12002 eV
#   Model:    SASDU29_fit1_model1.pdb (a Coot-built crystal model: CRYST1 and ANISOU
#             records are present), chains A and B (CRX homeodomain copies, residues
#             39-201 numbering), E and F (the two DNA strands, 20 nt each), 1899 ATOM
#             atoms, no hydrogens, plus 6 glycerol atoms (HETATM GOL), which are not
#             nucleotides and are dropped by the loader (nucleotideSelector keeps ATOM
#             records and HETATM nucleotides only). The deposited fit1 (χ² 1.546) is a
#             Pepsi-SAXS-style output whose header ("Convex: Concave: Inner:") is the
#             depositor's own contrast tool.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 22.0                     # 22 °C, SASBDB (cell)

# Buffer components. All names below are in the bundled NonBiological tables
# (src/bulk-electron-density/non-biological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.8573 (pK(22 °C) = 8.156; ΔH
# 47.45 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.167 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.150, 0.0015, "potassium chloride"),   # 150 mM KCl, ±1%
    NonBiological(0.020, 0.0004, "tris"),                  # 20 mM Tris, ±2%
    # 5 % v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL) and MW
    # (92.094 g/mol): 5 mL glycerol/100 mL soln * 1.2613 g/mL / 92.094 g/mol * 1000 ≈
    # 0.685 M. ±5 % as for SASDJ72's glycerol (a v/v -> molarity approximation, ignores
    # mixing non-ideality).
    NonBiological(0.685, 0.0342, "glycerol"),
    NonBiological(0.001, 0.00002, "tcep"),                 # 1 mM TCEP, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017146, 0.000851, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.357 Å⁻¹,
# but the 199 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.30 and 37 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.31 Å⁻¹) has a median I/σ of 0.46. The
# refChi2 is over the depositor's full 0.004-0.357 Å⁻¹ range.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: a mixed protein + DNA model, so the pipeline runs Pdb2pqr
# with PROPKA at PH for the protein (nucleotides are taken as supplied, not titrated).
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

# Builds the Seed that `runSasdu29Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdu29Fit1` below is the whole story (build the seed, then sample it).
function seedSasdu29Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdu29Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdu29Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdu29Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "SASBDB fit1",
    Float64.(crysol[:, 1]),
    FIT_FILE_SCALE .* Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "Pepsi-SAXS-style 1.546 (software not stated)",
    runLog = true,
)

# `@__DIR__` (this SASDU29/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
