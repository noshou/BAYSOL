# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDCA3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCA3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDCA3_fit3_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDCA3_fit3.fit")

raw = readdlm(_DATA_PATH; skipstart = 0)

# has no header and no trailer: all 248 rows are data.
qvals = Float64.(raw[1:248, 1])
iExp = Float64.(raw[1:248, 2])
σ_exp = Float64.(raw[1:248, 3])

# qvals are in nm⁻¹ (range 0.081-3.362; the depositor's .fit file is in Å⁻¹); must convert
# to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDCA3/); paper: Pozner A, Hudson NO,
# Trewhella J, Terooatea TW, Miller SA, Buck-Koehntop BA 2018, J. Mol. Biol.
# ("The C-Terminal Zinc Fingers of ZBTB38 are Novel Selective Readers of DNA Methylation"),
# DOI 10.1016/j.jmb.2017.12.014.
#
#   Sample:   1:1 complex of ZBTB38(1006-1153) (zinc fingers 6-10, 147 residues, 17.337
#             kDa) with the 27-bp methylated CZ38BS DNA duplex (54 nt, 16.705 kDa), 34.0
#             kDa; 3.4 mg/mL (estimated, error ≈ 30 %), 120 x 30 s frames
#   Buffer:   "10 mM Tris, 1 mM tris(2-carboxy-ethyl)phosphine (TCEP), 0.05% NaN3, 10% D2O",
#             pH 6.8; no salt is stated
#   Temp.:    22 °C (cell)
#   Source:   in-house Anton Paar SAXSess (Univ. of Utah, line focus), Mythen 1K detector,
#             wavelength 0.154 nm = 1.54 Å => energy = hc/λ ≈ 8051 eV. The data are
#             desmeared and on an absolute scale (cm⁻¹).
#   Models:   SASBDB lists three fits for this entry; only fit3 is bundled: the HADDOCK /
#             SASREF atomistic model (the initial model of the paper, χ² 1.643 with CRYSOL,
#             "fit3 model built with HADDOCK") is SASDCA3_fit3_model1.pdb. The DNA
#             methylation is not represented in the model (no 5CM residue).
#   Chains:   A (the 54-nt DNA, both strands in one chain, residue names G/C/A/T without
#             the D prefix), B (zinc fingers 6-9 with four zincs, ATOM records "ZN") and
#             C (ZF10, with one zinc ATOM residue "ZN2"); 2299 atoms, no hydrogens. The
#             depositor's fit3 is a single-conformer CRYSOL fit.

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables): none. Every stated component is modelled; the
# depositors state no salt, so none is added.

const PH, σ_PH = 6.8, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, from the stated 0.154 nm
const TEMPERATURE_C = 22.0                    # 22 °C, SASBDB (cell)

# The solvent contains 10 % D2O (v/v): 0.1 L/L × 1.1044 g/mL / 20.0276 g/mol = 5.514 M,
# listed as a solute with ϕ° 18.132 cm³/mol (derived from M/ρ), which displaces 99.98 mL
# of water per litre and adds the same 10 electrons per molecule. ±5 % on the fraction.
#
# Buffer components. All names below are in the bundled NonBiological tables
# (src/bulk-electron-density/non-biological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 10 mM Tris titrated with HCl -> Cl⁻ = C·0.9628 (pK(22 °C) = 8.156; ΔH
# 47.45 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.017 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
#
# 0.05 % NaN3 (w/v) = 0.5 g/L; MW(NaN3) = 65.01 g/mol => ≈ 7.69 mM. TCEP is taken as the
# free acid/base without its own HCl (TCEP·HCl would add up to 1 mM chloride).
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.010, 0.0002, "tris"),             # 10 mM Tris, ±2%
    NonBiological(0.001, 0.00002, "tcep"),            # 1 mM TCEP, ±2%
    NonBiological(0.007691, 0.000154, "sodium azide"),   # 0.05 % w/v NaN3, ±2%
    NonBiological(5.514, 0.276, "d2o"),                   # 10 % v/v D2O, ±5%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.009628, 0.000222, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: a mixed protein + DNA model, so the pipeline runs Pdb2pqr
# with PROPKA at PH for the protein (nucleotides are taken as supplied, not titrated).
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

# Builds the Seed that `runSasdca3Fit3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdca3Fit3` below is the whole story (build the seed, then sample it).
function seedSasdca3Fit3(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdca3Fit3(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdca3Fit3(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdca3Fit3()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit3",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit3", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.643",
    runLog = true,
)

# `@__DIR__` (this SASDCA3/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
