# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDN75")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDN75.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDN75_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDN75_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDN75: the TetR/AcrR-like regulator SCO3201 from Streptomyces coelicolor
# (UniProt Q9KYU4, residues 23-236), homodimer (2 x 23.337 kDa), in 20 mM Tris/HCl, 400 mM
# NaCl, 50 mM imidazole, 1 mM DTT, pH 8.5 (SASBDB buffer; the paper's SAXS methods give
# the same composition).
#
# Publication: Werten S, Waack P, Palm GJ, Virolle MJ, Hinrichs W, "Crystal Structures of
# Free and Ligand-Bound Forms of the TetR/AcrR-Like Regulator SCO3201 from Streptomyces
# coelicolor Suggest a Novel Allosteric Mechanism", FEBS J 2022 (2022 Aug 26), DOI
# 10.1111/febs.16606, PMID 36017630 (open access; the SAXS methods and the buffer were
# read). Entry: https://www.sasbdb.org/data/SASDN75/.
#
# Instrument and conditions: ESRF BM29 (Grenoble), Pilatus 1M, sample-detector distance
# 2.9 m, merged curve, cell and storage temperature 20 °C (SASBDB). SASBDB `xray_energy`
# is null; the wavelength is SASBDB's `wavelength` 0.0992 nm (the field is in nm), 0.992
# Å, hc/λ ≈ 12 497 eV.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.037 and s_max
# 4.973 nm⁻¹; REMARK lines first, then q, I, σ, text skipped by `_readCurve`) and is
# converted to Å⁻¹ (÷10): 1042 points from 0.0037 to 0.4973 Å⁻¹, 6 of them with I ≤ 0
# (`seedModel` drops the non-positive bins). The whole curve is fitted: the README's q-cut
# rule is not met for any cut from 0.10 to 0.57 Å⁻¹.
#
# Model and depositor fit: one fit, CRYSOL (SASBDB chi_square_value 1.171).
# SASDN75_fit1_model1.pdb is, per SASBDB, "only one of the two homodimers in PDB entry
# 5EFY (chains C and D)", declared identical to the PDB: 2574 ATOM records (chain C
# residues 26-227, chain D 32-228), no HETATM, no hydrogens (pdb2pqr/PROPKA place them at
# PH). The fit file (1042 rows to 0.4973 Å⁻¹, header "Dro:0.075 Ra:1.400 RGT:23.79 Vol:
# 48795. Chi^2: 1.171") recomputed from its columns 2-4 gives χ² = 1.171: the label is χ²
# and the depositor's χ² is 1.171, over the same q range as the fit here.
#
# Flags: the model is one of the two dimers of the 5EFY asymmetric unit (SASBDB: the
# solution species); crystal model, no hydrogens. The wavelength comes from SASBDB (its
# `xray_energy` is null) except where stated; the whole entry is wired from the files
# above and has not been run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.5, PH_METER_SIGMA   # pH 8.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.992   # ≈ 12 497 eV, SASBDB wavelength 0.992 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer as deposited and confirmed by the paper: 20 mM Tris/HCl, 400 mM NaCl, 50 mM
# imidazole, 1 mM DTT, pH 8.5. Tris and imidazole are both titrated with HCl and share the
# chloride row. Method of notes/buffer-templates.md (Davies, A = 0.509; pH taken as set at
# 22 °C, no shift to 20 °C modelled), constants of tui/assets/data/buffer_templates.json:
# Tris pK 8.072 (25 °C, ΔH 47.45 kJ/mol, ΔCp -59 J/mol/K) and imidazole pK 6.993 (25 °C,
# ΔH 36.64 kJ/mol, ΔCp -9 J/mol/K), self-consistent ionic strength I = 0.41 M (0.4 M NaCl
# plus the protonated forms). Protonated fractions 0.383 (Tris: 7.66 mM) and 0.047
# (imidazole: 2.36 mM), hence 10.02 mM of chloride on top of the NaCl. σ = 2.17 mM (σ_pH
# 0.1, ±3 °C, ±0.02 pK and 30 % of the Davies shift in quadrature, ±2 % on the
# concentrations). DTT is a solute row; its own protonation is ignored.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2 %
    NonBiological(0.05, 0.001, "imidazole"),   # 50 mM imidazole, ±2 %
    NonBiological(0.4, 0.004, "sodium chloride"),   # 400 mM, ±1 %
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM, ±2 %
    NonBiological(0.010015, 0.0022, "chloride"),   # Tris-HCl + imidazole-HCl Cl⁻, 10.02 mM
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

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdn75` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdn75` below is the whole story (build the seed, then sample it).
function seedSasdn75(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdn75(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdn75(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdn75()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.171",
)

# `@__DIR__` (this SASDN75/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
