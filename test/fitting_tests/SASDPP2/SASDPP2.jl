# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDPP2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPP2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDPP2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDPP2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# Audit 2026-11-13 (owner rule: papers first; a value is open only if neither the paper nor
# the SASBDB record states it): SASBDB lists no publication, and its record states the
# complete buffer, pH, temperature and wavelength used below, so nothing is assumed beyond
# the titrant/counter-ion convention.
#
# SASBDB SASDPP2: apo Pyrococcus furiosus Argonaute (Piwi domain-containing protein,
# UniProt Q8U3D2 residues 5-770, monomer, 91.34 kDa; SASBDB experimental MW 86 kDa) in a
# buffer with 6 M urea at 37 °C. SASBDB lists no publication for the entry (project
# "Argonaute protein SAXS investigation", released 2022-06-24); the buffer below is the
# SASBDB buffer field and the entry's experiment description, so no paper was consulted.
#
# Instrument (SASBDB): beamline BL19U2, Shanghai Synchrotron Radiation Facility (SSRF),
# Pilatus 1M, sample-detector distance 3 m, wavelength 0.103 nm (SASBDB `xray_energy` is
# null, so the energy is hc/λ ≈ 12 037 eV); one concentration, 0.25 mg/ml, 10 frames of
# 0.5 s, cell temperature 37 °C (storage -80 °C).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (angular_unit "1/A"; q from 0.0076 to
# 0.2504 Å⁻¹, 512 points, no text lines), so there is NO nm⁻¹ conversion here. All
# intensities are positive and the data end at q = 0.25 Å⁻¹, so the whole curve is fitted
# (the depositor's CRYSOL curve ends at 0.2466 Å⁻¹).
#
# Model and depositor fit: one fit, CRYSOL, against the atomic model that SASBDB states is
# identical to PDB 1Z26 (Pyrococcus furiosus Argonaute, crystal structure). The deposited
# SASDPP2_fit1_model1.pdb is not the crystal file itself: it has 12 645 ATOM records, no
# chain id, residues 18-770, no HETATM and no waters, and 6399 of the atoms are
# hydrogens (the crystal file has none); it looks like a hydrogenated MD or modelling
# frame of the protein, but how it was made is not stated. The RCSB file 1Z26.pdb (5951
# ATOM records, chain A, 155 HETATM: HOH and WO4) is kept beside it for comparison and is
# not used. The deposited fit header reads "pfago6Mu Dro:0.003 Ra:1.400 RGT:30.80
# Vol:103365. Chi^2: 2.753" and SASBDB's chi_square_value is the same 2.753 (REST and
# header agree), so refChi2 is CRYSOL's χ² 2.753. The .fit file is CRYSOL's: columns q
# (Å⁻¹), I_exp, σ, I_fit; its first rows are a q grid at which the experimental columns
# are 0 (no data) and only I_fit is meaningful, which is all `Reference` uses.
#
# Hydrogens: the model already carries its own explicit hydrogens, so
# `ADD_HYDROGENS = false` and they are used as given (as in SASDP48). Their
# protonation states are whatever the depositors set; the sample pH 8.0 is not applied to
# them. The 6 M urea is a property of the solvent only: the model is not changed by it.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB: pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12 037 eV, SASBDB wavelength 0.103 nm
const TEMPERATURE_C = 37.0                    # SASBDB cell temperature

# Buffer as deposited (SASBDB buffer name and experiment description): "20 mM Tris-HCl,
# 250 mM NaCl, 2 mM DTT, 6 M urea", pH 8.0. The measured macromolecule is deliberately
# NOT a solute (see BulkElectronDensity.Solute). All names are rows of the bundled
# NonBiological tables.
#
# Urea 6 M: the table has one value, ϕ° = 44.23 cm³/mol at infinite dilution (measured),
# used here at 6 M (6.0 M x 44.23 = 265 mL of solvent per litre displaced); the true
# apparent molar volume of urea changes by a few percent over 0-6 M, which is not
# modelled. ±2 % on the molarity.
#
# Counter-ion. "Tris-HCl" at pH 8.0: the Tris·H⁺ fraction that carries a Cl⁻ is the
# charged fraction at the pH, with pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys.
# Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; 8.072 at 25 °C, ΔH 47.45 kJ/mol),
# Davies-corrected (A = 0.509) at the self-consistent I ≈ 0.263 M. The pH is taken as set
# at room temperature (22 ± 3 °C, as in the sibling scripts), which fixes the counter-ion
# amount whatever the 37 °C of the measurement: pK(22 °C) = 8.156, pK' = 8.289, charged
# fraction 0.660, Cl⁻ = 0.020 x 0.660 = 13.2 mM. σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK,
# 30 % of the Davies shift and ±2 % on the Tris concentration (0.0015 M). (At 37 °C the
# Tris pK would be 7.75 and the fraction 0.43; the room-temperature convention is
# kept.)
const SOLUTES = Solute[
    NonBiological(0.020, 0.0004, "tris"),             # 20 mM Tris, ±2 %
    NonBiological(0.250, 0.005, "sodium chloride"),   # 250 mM NaCl, ±2 %
    NonBiological(0.002, 0.00004, "dtt"),             # 2 mM DTT, ±2 %
    NonBiological(6.0, 0.12, "urea"),                 # 6 M urea, ±2 %
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.013204, 0.001491, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The whole .dat is fitted (q 0.0076-0.2504 Å⁻¹); the depositor's fit ends at 0.2466 Å⁻¹,
# so refChi2 is not like for like.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = false: the model carries its own hydrogens (see Source).
const ADD_HYDROGENS = false

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdpp2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdpp2` below is the whole story (build the seed, then sample it).
function seedSasdpp2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpp2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdpp2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpp2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
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
    refChi2 = "CRYSOL 2.753",
    runLog = true,
)

# `@__DIR__` (this SASDPP2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
