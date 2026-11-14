# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJZ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJZ2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJZ2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJZ2_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 3)

# has 3 lines of headers (run description lines), no trailer: all 1727 rows are data.
qvals = Float64.(raw[1:1727, 1])
iExp = Float64.(raw[1:1727, 2])
σ_exp = Float64.(raw[1:1727, 3])

# qvals are in nm⁻¹ (SASBDB "1/nm", range 0.0758-4.665); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDJZ2/); paper: Czapinska H, Kowalska M,
# Zagorskaite E, Manakova E, Slyvka A, Xu SY, Siksnys V, Sasnauskas G, Bochtler M 2018,
# Nucleic Acids Res., "Activity and structure of EcoKMcrA", DOI 10.1093/nar/gky731. Open
# access (PMC6182155), no PDF is bundled; the numbers below are SASBDB's (the same buffer
# as the sister entry SASDJY2).
#
#   Sample:   N-terminal domain of EcoKMcrA (20.633 kDa) with the cognate hemimethylated
#             12-bp oligoduplex (7.435 kDa), 28.1 kDa in total, 1.14 mg/mL
#   Buffer:   "20 mM Tris–HCl pH 7.5, 200 mM KCl, 0.1 mM EDTA, 0.01% (w/v) sodium azide
#             and 1 mM DTT", pH 7.5
#   Temp.:    20 °C (cell; storage 10 °C)
#   Beamline: PETRA III EMBL P12, Pilatus 2M, wavelength 0.124 nm = 1.24 Å => energy =
#             hc/λ = 12398.42 eV·Å / 1.24 Å ≈ 9999 eV
#   Model:    SASDJZ2_fit1_model1.pdb, deposited with the CRYSOL fit1 (χ² 1.654): chains A
#             (protein) and G, H (the DNA duplex), 1876 atoms, no hydrogens, no HETATM.
#             SASBDB notes that the DNA in the model is homologous and does not correspond
#             in sequence to the DNA of the complex that was measured.

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - EDTA 0.1 mM: cations not stated (tetra-anion modelled); est. up to +0.0004 % as Na+

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, from the stated 0.124 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB cell temperature

# Buffer components. All names below are in the bundled NonBiological tables
# (src/bulk-electron-density/non-biological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.859 (pK(22 °C) = 8.156).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.217 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
# Sodium azide: 0.01 % w/v = 0.1 g/L / 65.01 g/mol = 1.538 mM, as in SASDJY2.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.02, 0.0004, "tris"),                              # 20 mM, ±2%
    NonBiological(0.2, 0.002, "potassium chloride"),                  # 200 mM KCl, ±1%
    NonBiological(0.0001, 2e-06, "edta"),                             # 0.1 mM, ±2%
    NonBiological(0.001538224888, 3.076449777e-05, "sodium azide"),   # 1.538 mM, ±2%
    NonBiological(0.001, 2e-05, "dtt"),                               # 1 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017182, 0.000852, "chloride"),
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "EDTA 0.1 mM: cations not stated (tetra-anion modelled); est. up to +0.0004 % as Na+",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDJZ2: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0076-0.4665 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.425 Å⁻¹ was used before, but the 157 points above
# 0.425 Å⁻¹ (σ > 0) have a median I/σ of 0.98 and 22 % of them have I ≤ 0, so the data
# above it are not demonstrably unusable (median I/σ 0.98 ≥ 0.5; I ≤ 0 share 22 % < 25 %;
# median I/σ 1.54 ≥ 1 in the lowest-q quarter (up to 0.44 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has no hydrogens. It holds protein and DNA, so
# `seedModel` runs PROPKA for the protein at PH and takes the nucleotides as supplied.
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

# Builds the Seed that `runSasdjz2Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdjz2Fit1` below is the whole story (build the seed, then sample it).
function seedSasdjz2Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjz2Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdjz2Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjz2Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.654",
    runLog = true,
)

# `@__DIR__` (this SASDJZ2/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
