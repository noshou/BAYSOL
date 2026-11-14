# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDUX3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUX3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDUX3_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDUX3_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUX3: actin filament fragment (F-actin, 17 subunits in the model, sample
# 'p4a1', SASBDB concentration up to 2 mg/ml), in F-buffer: 50 mM KCl, 50 mM Tris-HCl, pH
# 8.0, 5 mM MgCl2, 1 mM ATP, 0.1 % 2-mercaptoethanol.
#
# Publication (SASBDB): DOI 10.1016/j.ijbiomac.2024.134556 (Int J Biol Macromol 2024).
# Entry: https://www.sasbdb.org/data/SASDUX3/. The paper was NOT consulted (paywalled, not
# reachable from the session); buffer, pH, temperature and wavelength are the SASBDB
# entry's.
#
# Instrument (SASBDB): wavelength 0.155 nm (SASBDB `xray_energy` is null, so the energy is
# hc/λ ≈ 8000 eV); sample-detector distance 3.1 m; cell temperature 10 °C.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (q from 0.068 to 4.43 nm⁻¹; 7 text header lines
# that `_readCurve` skips); converted to Å⁻¹. Intensities are arbitrary units.
#
# Model and depositor fit: fit1 of SASBDB (CRYSOL 2.314; the entry has three fits, 2.314,
# 3.108 and 7.705, and fit1 is the best). The fixture SASDUX3_fit1_model1.pdb is SASBDB's
# copy with THREE FIXES (also in the fixture's README.txt; the original is the SASBDB
# download): 50337 records, no hydrogens, 17 chains of 2961 atoms. Each chain holds the
# actin residues, its own ADP (27 atoms), one Mg and 11 atoms of residue 73. As deposited,
# (1) the ADP was written as ATOM records: now HETATM (a non-polymer, so the loader keeps
# it as a ligand); (2) residue 73 was named HMS, which the component table knows as a
# saccharide phosphate (the wwPDB's HMS), but it is the methylated histidine of actin
# (N-methyl on NE2, atom CM): now HIC (3-methylhistidine's table entry, parent HIS) with
# CM renamed CZ, as the table names it; (3) the 17 atoms named MTL with the element "M"
# are the Mg2+ of each Mg-ADP (one per chain, beside the ADP): now residue MG, atom MG,
# element MG, HETATM. The fits' structure was not otherwise touched. The loader was not
# run on the fixed file: the result is checked by the owner's run. The .fit header
# reads "3.pdb Dro:0.000 Ra:1.800 RGT:***** Vol:824777. Chi^2:
# 2.314"; the label is χ² (SASBDB chi_square_value 2.314, the same). The fit file has 1665
# rows of which 1661 have σ > 0 (q = 0.0068 to 0.4437 Å⁻¹).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB buffer pH 8.0 (F-buffer)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.55   # ≈ 8000 eV, SASBDB wavelength 0.155 nm
const TEMPERATURE_C = 10.0   # SASBDB cell temperature (storage 10 °C)

# Counter-ion: Tris-HCl at a pH is modelled as Tris base plus HCl (the convention of the
# other scripts), the titrant amount from Goldberg's pK (Tris pK 8.072 at 25 °C, ΔH 47.45
# kJ/mol; Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902), moved to 22 °C (pH set at room temperature, 22 ± 3 °C, whatever the
# measurement temperature) by van't Hoff, Davies-corrected at the self-consistent ionic
# strength. The σ combines σ_pH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
# Only the counter-ion is modelled. Here Tris 50 mM at pH 8.0, I(others) = 0.5 x (KCl 0.05
# + MgCl2 (4 x 0.005 + 0.01)) = 0.065 M: protonated fraction 0.647, Cl⁻ = 32.34 mM, σ 3.77
# mM. ATP 1 mM is the solute `atp` as the neutral acid; its counter-ions are not stated
# and not modelled, nor is the Mg²⁺-ATP complexation. 2-mercaptoethanol 0.1 % is assumed
# v/v (the SASBDB field gives no unit): 1.114 g/ml, 78.13 g/mol, 14.26 mM, ±5 %.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),                    # 50 mM Tris, ±2%
    NonBiological(0.05, 0.001, "potassium chloride"),      # 50 mM KCl, ±2%
    NonBiological(0.005, 0.0001, "magnesium chloride"),    # 5 mM MgCl2, ±2%
    NonBiological(0.001, 0.00002, "atp"),                  # 1 mM ATP, ±2%
    NonBiological(0.01426, 0.000713, "2-mercaptoethanol"), # 0.1 % (v/v assumed), ±5%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.032338, 0.003768, "chloride"),
]
# The omissions listed above, one line each. Every run of this script, and every
# developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "counter-ions of ATP (1 mM, salt not stated) and Mg-ATP complexation not modelled",
    "2-mercaptoethanol 0.1 % unit not stated (v/v assumed)",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDUX3: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.443 Å⁻¹,
# but the 546 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.20 and 41 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.34 Å⁻¹) has a median I/σ of 0.05. The run
# time of this 50k-atom filament is NOT the reason.
const Q_MAX_FIT = 0.3

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

# Builds the Seed that `runSasdux3Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdux3Fit1` below is the whole story (build the seed, then sample it).
function seedSasdux3Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdux3Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdux3Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdux3Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
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
    refChi2 = "CRYSOL 2.314",
    runLog = true,
)

BAYSOL.printSummary(result)
