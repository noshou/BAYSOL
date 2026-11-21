# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDNF7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNF7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNF7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNF7_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDNF7: human casein kinase 2 alpha (CK2α, UniProt P68400, 39.2 kDa, monomer),
# apo form, in 25 mM Tris, 500 mM NaCl, pH 8.5 (SASBDB buffer; the paper's SAXS section
# names the same composition). The curve is the ligand-free reference of a study of CK2
# inhibition by a ruthenium polyoxometalate.
#
# Publication: Fabbian S, Giachin G, Bellanda M, Borgo C, Ruzzene M, Spuri G, Campofelice
# A, Veneziano L, Bonchio M, Carraro M, Battistutta R, "Mechanism of CK2 Inhibition by a
# Ruthenium-Based Polyoxometalate", Front Mol Biosci 2022, DOI 10.3389/fmolb.2022.906390,
# PMID 35720133 (open access; the SAXS buffer was read). Entry:
# https://www.sasbdb.org/data/SASDNF7/.
#
# Instrument and conditions: ESRF BM29 (Grenoble), sample-detector distance 2.867 m, cell
# and storage temperature 20 °C (SASBDB). `xray_energy` is null; the wavelength is
# SASBDB's `wavelength` 0.099 nm (the field is in nm), 0.99 Å, hc/λ ≈ 12 523 eV.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.080 and s_max
# 5.205 nm⁻¹; text lines first, then q, I, σ) and is converted to Å⁻¹ (÷10): 993 points
# from 0.0080 to 0.5205 Å⁻¹, 3 of them with I ≤ 0. The whole curve is fitted: the README's
# q-cut rule is not met anywhere in the tail.
#
# Model and depositor fit: SASDNF7 has two fits. fit1 is CRYSOL (chi_square_value 1.29) on
# the atomic model that SASBDB declares identical to PDB 3Q04 ("Crystal structure of the
# apo-form of human CK2 alpha at pH 8.5"); SASDNF7_fit1_model1.pdb has chain A (residues
# 3-330, ANISOU lines, 13 atoms with alternate location B), one ethylene glycol (EDO),
# three sulfates (SO4) and 253 crystal waters. fit2 is DAMMIF (dummy atoms; not used). The
# fit file (993 rows to 0.5205 Å⁻¹, header "Dro:0.020 Ra:1.720 RGT:21.79 Vol: 52625.
# Chi^2: 1.290") recomputed from its columns 2-4 gives χ² = 1.290 (label χ², same q range
# as the fit here).
#
# Flags: the model's three SO4 and one EDO (crystallisation ligands; the loader keeps
# known ligands) are not in the SAXS buffer; 13 atoms have an alternate location and the
# file carries ANISOU records; the 253 crystal waters are dropped by the loader. The
# wavelength comes from SASBDB (its `xray_energy` is null) except where stated; the whole
# entry is wired from the files above and has not been run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.5, PH_METER_SIGMA   # pH 8.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12 523 eV, SASBDB wavelength 0.99 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer: 25 mM Tris, 500 mM NaCl, pH 8.5 (SASBDB and the paper agree). Computed with the
# amine method of notes/buffer-templates.md (Davies, A = 0.509; the pH is taken as set at
# 22 °C and no shift of the pH to the measuring temperature is modelled): Tris pK 8.072
# (25 °C, ΔH 47.45 kJ/mol, ΔCp -59 J/mol/K, the constants of
# tui/assets/data/buffer_templates.json), self-consistent ionic strength I = 0.51 M
# (Davies is at the edge of its range there). The pH is set with HCl, so the protonated
# fraction (0.382) of the amine comes with a chloride counter-ion: 0.382 x 25 mM = 9.55
# mM. σ = 1.88 mM (σ_pH 0.1, ±3 °C, ±0.02 pK and 30 % of the Davies shift in quadrature,
# and ±2 % on the concentrations).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris, ±2 %
    NonBiological(0.5, 0.005, "sodium chloride"),   # 500 mM, ±1 %
    NonBiological(0.009547, 0.0019, "chloride"),   # counter-ion of Tris-HCl, 9.55 mM
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

# Builds the Seed that `runSasdnf7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdnf7` below is the whole story (build the seed, then sample it).
function seedSasdnf7()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdnf7(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdnf7()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdnf7()

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
    refChi2 = "CRYSOL 1.29",
)

# `@__DIR__` (this SASDNF7/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
