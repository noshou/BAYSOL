# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDAK6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAK6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDAK6_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDAK6_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDAK6: xylose (glucose) isomerase from Streptomyces rubiginosus (UniProt
# P24300, 43.2 kDa per chain, a tetramer, SASBDB experimental MW 184 kDa) in PBS with 50 %
# glycerol, pH 7.4, extrapolated to infinite dilution from 1.2-12.83 mg/ml. Project
# "Standard proteins" of the EMBL Hamburg outstation (contributor E. Valentini); the
# glycerol series of this standard.
#
# Publication: none listed by SASBDB, so there is no DOI. Entry:
# https://www.sasbdb.org/data/SASDAK6/. The conditions below are the SASBDB entry
# metadata; there is no paper to consult.
#
# Instrument (SASBDB): EMBL beamline X33, DORIS III (DESY, Hamburg), Pilatus 1M-W,
# sample-detector distance 2.7 m, wavelength 0.15 nm (SASBDB `xray_energy` is null, so the
# energy is hc/λ ≈ 8266 eV); 8 frames of 15 s; measured 2012-04-24. SASBDB gives NO cell
# or storage temperature ("None") and no paper exists: 25 °C is used, the owner's accepted
# default where neither source states a temperature (round 7, AUDIT7); it is flagged as an
# assumption.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.087 and s_max
# 6.017 nm⁻¹), converted to Å⁻¹ (÷10) below. No point is non-positive and the mean
# I/σ beyond 0.3 Å⁻¹ is still about 5, so the whole curve is fitted (no q cut). The data
# go to 0.6017 Å⁻¹ but the depositor's CRYSOL curve ends at 0.45 Å⁻¹, so refChi2 is not
# like for like.
#
# Model and depositor fit: fit2 is a CRYSOL-style fit (SASBDB lists no software) against
# SASDAK6_fit2_model1.pdb, an "assembly" (the SASBDB log is assembly00.log) built from PDB
# 1OAD (the dimer of the asymmetric unit, kept beside it as 1OAD.pdb, unchanged, not
# used): the tetramer, 24 chain ids (4 protein chains with 3037-3042 atoms each and the
# small ligand chains), 12 266 ATOM and HETATM records, 12 158 of them ATOM, no hydrogens,
# no waters. It carries the crystallisation ligands of 1OAD (16 MPD, 32 MRD, 36 MQD, 16
# TRS, 4 Mg²⁺, 4 Mn²⁺, all known components, kept by the loader); they are in the
# depositor's model and so in the CRYSOL fit, and are kept as deposited, although the
# sample contains neither MPD nor Tris. fit1 is DAMMIF (chi2 2.158; not used). The fit
# header reads "assembly  Dro:0.013  Ra:1.400  RGE:34.20  RGT:33.00  Vol:230987.
# Chi:1.431" and SASBDB's chi_square_value is 2.047761. They DISAGREE only in what they
# are: 1.431² = 2.048, so the header "Chi:" is χ and SASBDB's number is χ², confirmed by
# recomputing from the .fit columns 2-4 (χ² ≈ 2.05). refChi2 is therefore 2.048, the χ²
# that the log compares with (the header value 1.431 would be a χ, not comparable). The
# .fit file has the CRYSOL layout: columns q (Å⁻¹), I_exp, σ, I_fit, with a leading q grid
# at which the experimental columns are placeholders and only I_fit is meaningful (all
# `Reference` uses).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB: pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, SASBDB wavelength 0.15 nm
const TEMPERATURE_C = 25.0                    # ASSUMED default, neither source gives one

# Buffer as deposited (SASBDB buffer name and additive fields): "PBS, 50% Glycerol, 0.076
# M NaCl", pH 7.4, additive "Glycerol 50.000 %, NaCl 0.076 M". The measured macromolecule
# is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# PBS is a named standard buffer; its recipe is cited from Cold Spring Harb Protoc 2006,
# pdb.rec8247 (137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8 mM KH2PO4), diluted
# to the aqueous half of the 50 % glycerol solution, i.e. KCl 1.35 mM, Na2HPO4 5.0 mM and
# KH2PO4 0.9 mM (its HPO4²⁻/H2PO4⁻ split is that of the recipe at pH 7.4, no counter-ion
# is added); the NaCl is the 0.076 M of the additive field, taken as the total NaCl (the
# half-strength PBS alone would be 68.5 mM; whether the 0.076 M is on top of it is not
# stated). Each assumed concentration carries ±5 %.
#
# Glycerol 50 %: v/v is assumed (w/w is not excluded): 0.5 L/L x 1261 g/L / 92.094 g/mol =
# 6.846 M (10 times the 5 % of SASDKQ8), ±5 %. The solute table's glycerol volume is the
# value at infinite dilution, used here at 6.85 M; the real mixing volume of glycerol and
# water is not modelled, nor is the change of the buffer's pH and ionic activity at 50 %
# glycerol.
const SOLUTES = Solute[
    NonBiological(0.076, 0.0038, "sodium chloride"),   # 0.076 M NaCl, ±5%
    NonBiological(0.00135, 0.00007, "potassium chloride"),   # 1.35 mM KCl (PBS/2), ±5%
    NonBiological(0.005, 0.00025, "disodium hydrogen phosphate"),   # 5.0 mM (PBS/2), ±5%
    NonBiological(0.0009, 0.000045, "potassium dihydrogen phosphate"),   # 0.9 mM, ±5%
    NonBiological(6.8463, 0.3423, "glycerol"),   # 50 % v/v glycerol, ±5%
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

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdak6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdak6` below is the whole story (build the seed, then sample it).
function seedSasdak6(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdak6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdak6(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdak6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL-style (fit2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 2.048",
    runLog = true,
)

# `@__DIR__` (this SASDAK6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
