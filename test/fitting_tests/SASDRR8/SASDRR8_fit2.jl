# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDRR8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRR8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDRR8_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDRR8_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRR8: chloroplast FOF1-ATP synthase (spinach, 6FKF; SASBDB experimental MW 880
# kDa for the dimer-containing mixture; model MW 558 kDa, monomer), in 300 mM NaCl, 30 mM
# HEPES, 2 mM MgCl2, 0.04 % (w/v) tPCC-alpha-M detergent, pH 8.0 (mix of anion-exchange
# fractions eluted at 260 to 340 mM NaCl).
#
# Publication: DOI 10.3390/ijms241310720 (Int J Mol Sci 2023). Entry:
# https://www.sasbdb.org/data/SASDRR8/. The paper WAS consulted (Europe PMC full text): it
# gives the same buffer (Section 4.3: 30 mM HEPES, 2 mM MgCl2, 0.04 % (w/v) tPCC-α-M and
# NaCl 150 to 450 mM; the paper's pH is 8.0, the dialysis buffer of this 300 mM sample);
# the SAXS temperature is "room temperature" in the paper against 20 °C in SASBDB:
# SASBDB's 20 °C is used (flagged, a few degrees do not change the modelled buffer beyond
# the quoted σ). Paper check, 2026-11-14 (sources/ijms-24-10720.pdf): the only
# contradiction is the wavelength, Cu Kα λ = 1.5405 Å in the paper (Section 4.4) against
# 0.154 nm in SASBDB; the paper's value is used below (8048 eV against 8051 eV, a
# negligible change). The paper gives no other SAXS-buffer component and no other pH.
#
# Instrument (paper, Rigaku MicroMax-007 HF, Cu Kα): wavelength 1.5405 Å; sample-detector
# distance 2.0 m; room temperature, SASBDB cell temperature 20 °C (storage 4 °C).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q from 0.0110 to 0.1805 Å⁻¹; no text
# header). Intensities are arbitrary units.
#
# Model and depositor fit: fit2 of SASBDB (CRYSOL 1.347; fit1 has 1.149 and is the other
# model). The fixture SASDRR8_fit2_model1.pdb is SASBDB's copy, unmodified. It holds 39052
# ATOM records (no hydrogens) and 177 HETATM records: 3 ATP (93 atoms), 3 ADP (54), 5 Mg²⁺
# and 25 waters. The loader keeps ATP, ADP and MG (known composition, `KEEP_LIGANDS`; no
# hydrogens are placed on ligands) and drops the waters: 39204 heavy atoms in all. The
# .fit header reads "6fkf.pdb Dro:0.020 Ra:1.640 RGT:65.37 Vol:757369. Chi^2: 1.347"; the
# label is χ² (SASBDB chi_square_value 1.347, the same). The sample is a mixture (SASBDB
# experimental MW 880 kDa against the 558 kDa monomer model): the sample may contain
# dimers, which a single-model fit cannot reproduce (the mismatch is stated, not fitted).
# The ATP/ADP of the model are not in the buffer.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A); no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB and paper buffer pH 8.0

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5405   # ≈ 8048 eV, Cu Kα (paper; SASBDB 0.154 nm)
const TEMPERATURE_C = 20.0   # SASBDB cell temperature; paper says room temperature

# HEPES + NaOH gives Na⁺ at the pH: HEPES pK 7.564 at 25 °C, ΔH 21.0 kJ/mol (Goldberg
# 2002, as above), moved to 22 °C by van't Hoff, Davies-corrected at the self-consistent
# ionic strength; HEPES 30 mM at pH 8.0, I(others) = 0.5 x (NaCl 0.6 + MgCl2 0.012) =
# 0.306 M: ionized fraction 0.774, Na⁺ = 23.21 mM, σ 1.42 mM (σ_pH, ±3 °C, ±0.02 pK, 30 %
# of the Davies shift, ±2 % on C).
#
# DETERGENT: tPCC-alpha-M (4-trans-(4-trans-propylcyclohexyl)cyclohexyl alpha-maltoside,
# C27H48O11, 548.7 g/mol), 0.04 % (w/v) = 0.4 g/l = 0.729 mM (paper, Section 4.3), taken
# from the polymers table (row `tPCC-alpha-M`, an estimated partial molar volume).
# ASSUMPTION: the table value is a monomer volume at infinite dilution, but at 0.73 mM the
# detergent
# is most likely above its CMC (the CMC was not looked up here) and mostly micellar, with
# a different (tighter-packed, hydrated) effective volume and electron density. The whole
# amount is entered as free monomer; its 5 % uncertainty covers only the concentration
# (w/v stated to one significant figure), not the micellization.
const SOLUTES = Solute[
    NonBiological(0.3, 0.006, "sodium chloride"),          # 300 mM NaCl, ±2%
    NonBiological(0.03, 0.0006, "hepes"),                  # 30 mM HEPES, ±2%
    NonBiological(0.002, 0.00004, "magnesium chloride"),   # 2 mM MgCl2, ±2%
    Polymer(0.000729, 0.0000365, "tPCC-alpha-M"),         # 0.04 % (w/v), ±5 %
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.023211, 0.001417, "sodium"),
]
# The omissions listed above, one line each. Every run of this script, and every
# developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "tPCC-alpha-M entered as monomer at infinite dilution (table value), not micellar",
    "sample temperature: paper says room temperature, SASBDB 20 C used",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDRR8: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

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

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdrr8Fit2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdrr8Fit2` below is the whole story (build the seed, then sample it).
function seedSasdrr8Fit2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdrr8Fit2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdrr8Fit2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdrr8Fit2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit2", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.347",
    runLog = true,
)

BAYSOL.printSummary(result)
