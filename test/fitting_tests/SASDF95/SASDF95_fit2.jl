# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDF95")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDF95.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDF95_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDF95_fit2.fit")

raw = readdlm(_DATA_PATH; skipstart = 2)

# has 2 lines of headers (a blank line and "Sample: ..."), and 2 lines of trailer
# ("range-from"/"range-to") at the end; need to skip. CRLF line endings. The trailer rows
# pad `readdlm` with strings, so only the numeric rows 1-844 are converted (columns 1-3).
qvals = Float64.(raw[1:844, 1])
iExp = Float64.(raw[1:844, 2])
σ_exp = Float64.(raw[1:844, 3])

# q is already in Å⁻¹ (range 0.0070-0.3348, SASBDB "1/A", SSRF BL19U2 merged curve); no unit
# conversion is applied, `checkQAngstrom` asserts it.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDF95/); paper: Liu Y, Gao Z, Liu G,
# Geng Z, Dong Y, Zhang H 2020, Front. Microbiol. 10:3158 ("Structural Insights Into the
# Transcriptional Regulation of HigBA Toxin-Antitoxin System by Antitoxin HigA in
# Pseudomonas aeruginosa"), DOI 10.3389/fmicb.2019.03158. No PDF is bundled, so every
# number below is SASBDB's.
#
#   Sample:   PaHigA-DNA complex: antitoxin HigA dimer (2 x 11.248 kDa) bound to a 32-bp
#             DNA duplex (2 x 10.006 kDa), 42.5 kDa in total; 1-5 mg/mL, merged curve
#   Buffer:   "20 mM Tris, 300 mM NaCl, 5% (v/v) glycerol, and 1 mM PMSF", pH 8.0
#   Temp.:    23 °C (cell; storage 10 °C)
#   Beamline: SSRF BL19U2, Pilatus 1M, wavelength 0.103 nm = 1.03 Å => energy =
#             hc/λ = 12398.42 eV·Å / 1.03 Å ≈ 12037 eV
#   Model:    SASDF95_fit2_model1.pdb, the model of the depositor's CRYSOL fit2 (χ² 6.229):
#             chains A, B, E, F (HigA protein) and C, D (the DNA duplex), 4073 atoms, no
#             hydrogens, no HETATM; the CRYSOL curve stops at 0.330 Å⁻¹

const PH, σ_PH = 8.0, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12037 eV, from SASBDB's 0.103 nm
const TEMPERATURE_C = 23.0                    # 23 °C, SASBDB cell temperature

# Buffer components. All names below are in the bundled NonBiological tables
# (src/bulk-electron-density/non-biological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.661 (pK(22 °C) = 8.156).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.313 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
# Glycerol: 5 % v/v taken as 0.6846 M (as in SASDJ62, SASDJ72). PMSF: our own estimated
# table entry, as in SASDYW6 (it hydrolyzes in water; its ρₑ impact at 1 mM is minimal).
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.020, 0.0004, "tris"),                     # 20 mM Tris, ±2%
    NonBiological(0.300, 0.003, "sodium chloride"),           # 300 mM NaCl, ±1%
    NonBiological(0.6846265772, 0.01369253154, "glycerol"),   # 5 % v/v = 684.6 mM, ±2%
    NonBiological(0.001, 0.00005, "pmsf"),                    # 1 mM PMSF, ±5% (unstable)
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.013234, 0.001459, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has no hydrogens. It holds protein and DNA, so
# `seedModel` runs PROPKA for the protein at PH and takes the nucleotides as supplied.
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

# Builds the Seed that `runSasdf95Fit2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdf95Fit2` below is the whole story (build the seed, then sample it).
function seedSasdf95Fit2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdf95Fit2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdf95Fit2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdf95Fit2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit2", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 6.229",
    runLog = true,
)

# `@__DIR__` (this SASDF95/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
