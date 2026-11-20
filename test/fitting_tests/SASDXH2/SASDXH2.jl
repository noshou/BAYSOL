# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXH2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXH2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDXH2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDXH2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXH2: Mammalian translation elongation factor eEF1A2 (Mammalian translation
# elongation factor eEF1A2; None; 50.47 kDa SASBDB molecule MW, monomer) in the SASBDB
# buffer "25 mM Tris HCl, 150 mM NaCl, 6 mM βME, 20% glycerol, 0.01mM GDP,", pH 7.5.
# Sample: Mammalian translation elongation factor eEF1A2.
#
# Publication: Novosylna O, Shalak V, Dąbrowska K, Patmanidis I, Lozhko D, Bondarchuk T,
# Schiøtt B, Pedersen J, Knudsen C, Nissen P, Dadlez M, Negrutskii B, "Dynamics and
# structural features of the eEF1A1 and eEF1A2 paralogs", Nucleic Acids Research (2025 Nov
# 13), DOI 10.1093/nar/gkaf1177. Entry: https://www.sasbdb.org/data/SASDXH2/.
#
# BUFFER SOURCE (paper first, SASBDB second): the SAXS methods of the paper (Nucleic Acids
# Res 2025, see the Publication line) give only the protein concentrations, no buffer; its
# MD box has 25 mM Tris, 1 mM GDP, 165 mM NaCl, 5 % glycerol and 6 mM 2-mercaptoethanol,
# its HDX buffer 25 mM Tris-HCl, 150 mM NaCl, 5 mM 2-mercaptoethanol, 1 mM GDP. The SASBDB
# buffer "25 mM Tris HCl, 150 mM NaCl, 6 mM βME, 20% glycerol, 0.01 mM GDP" is therefore
# used (the trailing comma is a dropped item). The paper counts the glycerol of its MD box
# as w/v (525 glycerol molecules in a 12 nm box = 0.50 M ≈ 4.6 % w/v, not 3.7 % v/v), but
# glycerol is a liquid, so the "%" of this entry is read as v/v (owner, 2026-11-18): 20 %
# v/v = 200 mL/L x 1.2613 g/mL (20 C) / 92.094 g/mol = 2.739 M. The unit is not stated.
#
# Instrument and conditions (SASBDB): Department of Chemistry, iNANO building, Aarhus
# Uinversity, Aarhus C, beamline Bruker Nanostar w Excillum source, X-ray in house,
# detector VÅNTEC-2000; wavelength 0.134 nm = 1.34 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 9253 eV); cell temperature 20.0 °C;
# sample-detector distance 0.9 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.009813 to 0.4157 1/A, 105 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 0 points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ >
# 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.651); model:
# SASBDB model software: Chimera. SASDXH2_fit1_model1.pdb: 3547 ATOM records (463
# residues, chains  ), 3547 heavy atoms, no hydrogens; one structure only.
# The fit file SASDXH2_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.005
# Rg: 26.41 Vol:  63574. Chi^2: 1.651"; χ² recomputed from the file with the data's σ is
# 1.635 (label 1.651), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: glycerol 20 % read as v/v (liquid; owner decision), not stated for the
# SAXS buffer; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "25 mM Tris HCl, 150 mM NaCl, 6 mM βME, 20% glycerol, 0.01mM GDP,", pH 7.5
# (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.171 M
# gives pK' = 8.279. The protonated fraction of 25 mM is 0.857; with HCl titration the
# counter-ion is chloride 21.43 mM (σ 1.12 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 21.43 mM
    NonBiological(0.021431, 0.00112, "chloride"),
    NonBiological(0.006, 0.00012, "2-mercaptoethanol"),   # 6 mM 2-mercaptoethanol, ±2%
    NonBiological(2.739, 0.137, "glycerol"),   # 20 % v/v glycerol (1.2613 g/mL), ±5%
    NonBiological(1e-05, 2e-07, "gdp(2-)"),   # 0.01 mM GDP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`iExp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdxh2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdxh2` below is the whole story (build the seed, then sample it).
function seedSasdxh2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxh2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdxh2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxh2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.651",
)

# `@__DIR__` (this SASDXH2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
