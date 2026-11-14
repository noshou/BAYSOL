# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMJ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMJ9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDMJ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDMJ9_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 5)

# has 5 lines of headers, and some beam info at the end; need to skip.
qvals = Float64.(raw[1:2048, 1])
iExp = Float64.(raw[1:2048, 2])
σ_exp = Float64.(raw[1:2048, 3])

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Xiao et al. 2012, J. Virol. 86(8):4444-4454 ("FCoV Nsp7 and Nsp8
# Form a 2:1 Heterotrimer..."), DOI 10.1128/JVI.06635-11. Not open access
# (© ASM, all rights reserved), so the PDF is not bundled with the fixtures.
#
# The buffer that matters here is the one used for the SEC step immediately
# preceding SAXS ("SEC" paragraph, Materials and Methods):
#
#     10 mM Tris-HCl (pH 7.5), 200 mM NaCl, 5 mM DTT
#
# The paper's SAXS concentration series for Nsp7  was 1.2, 2.4, 4.7,
# 9.4 mg/ml ("SAXS" paragraph), with "the SAXS data from the most
# concentrated sample ... used for further analysis" but SASBDB's 
# entry metadata for SASDMJ9 (sasbdb.org/data/SASDMJ9/) states only one
# concentration was measured for the curve: 4.70 mg/ml, eight
# successive 15 s frames. 
#
# X33 (EMBL BioSAXS, DORIS storage ring, DESY Hamburg) recorded at a stated
# wavelength of 1.54 Å ("SAXS" paragraph) => energy = hc/λ ≈ 8051 eV
# (hc = 12398.42 eV·Å). Sample temperature was stated explicitly as 20°C.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, from X33's stated 1.54 Å wavelength
const TEMPERATURE_C = 20.0             # 20°C, stated in the paper
const IONIC_STRENGTH_M = 0.200           # 200 mM NaCl, matches the SEC/SAXS buffer above

# Nsp7 sequence, read directly off SASDMJ9_fit1_model1.pdb chain B (residues
# 2-83, 82 residues). Chain C models the identical sequence plus a 2-residue
# Gly-Ser cloning-tag remnant at residues 0-1 that's disordered (not modelled)
# in chain B; the tag-free chain B sequence is used here as the dominant,
# biologically relevant species (the paper itself describes the mature
# protein, not the tag, as "Nsp7").
const NSP7_SEQ =
    "KLTEMKCTNVVLLGLLSKMHVESNSKEWNYCVGLHNEINLCDDPDAVLEKLLALIAFFLS" *
    "KHNTCDLSDLIESYFENTTILQ"

# Average mass from NSP7_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH).
const NSP7_MW         = 9331.77   # g/mol
const NSP7_CONC_MG_ML = 4.70
const NSP7_MOLARITY   = NSP7_CONC_MG_ML / NSP7_MW   # ≈ 0.504 mM
const NSP7_MOLARITY_σ = MOLARITY_REL_SIGMA * NSP7_MOLARITY

# Buffer components Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 10 mM Tris titrated with
# HCl -> Cl⁻ = C·0.859 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.209 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.200, 0.002, "sodium chloride"),   # 200 mM NaCl, ±1%
    NonBiological(0.010, 0.0002, "tris"),              # 10 mM Tris-HCl, ±2%
    NonBiological(0.005, 0.0001, "dtt"),               # 5 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.008588, 0.000422, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The whole .dat is fitted (q 0.0067-0.5668 Å⁻¹); the depositor's fit ends at 0.5001 Å⁻¹,
# so refChi2 is not like for like.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fitSubset() -> (q, I, σ)

The whole curve: `qvals`, `I_exp`, `σ_exp`. (`seedModel`
bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    return qvals, iExp, σ_exp
end

# Builds the Seed that `runSasdmj9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdmj9` below is the whole story (build the seed, then sample it).
function seedSasdmj9(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdmj9(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdmj9(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdmj9()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.37",
    runLog = true,
)

# `@__DIR__` (this SASDMJ9/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
