# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDZW5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDZW5.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDZW5_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDZW5_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDZW5: OaaC (Condensation Domain from Coprococcus Eutactus; Coprococcus
# eutactus ATCC 27759; 54.044 kDa SASBDB molecule MW, dimer) in the SASBDB buffer "10mM
# HEPES pH 7.5, 50mM NaCl, 0.2mM TCEP", pH 7.5. Sample: The FAA Condensation Domain, OaaC
# from Coprococcus Eutactus (Plipastatin synthase subunit A).
#
# Publication: Singh J, Grant T, Gulick A, "Structure of a Stand-Alone Homodimeric NRPS
# Condensation Domain Reveals Occlusion of the Canonical Carrier-Protein Interface",
# preprint/unpublished (2026 Apr 28), DOI 10.64898/2026.04.24.720670. Entry:
# https://www.sasbdb.org/data/SASDZW5/.
#
# BUFFER SOURCE: SASBDB buffer fields ("10 mM HEPES pH 7.5, 50 mM NaCl, 0.2 mM
# TCEP", the gel-filtration buffer). The preprint (bioRxiv 2026.04.24.720670) is
# not available in the open full-text service. Units: the SASBDB label "1/A" is
# right (Guinier Rg of the curve 32.6 Å in Å⁻¹ against 30.9 Å from the Cα of the
# model; read as nm⁻¹ it would be 326 Å), so there is NO conversion. The curve runs
# to 2.099 Å⁻¹; `Q_SANITY_RANGE` of common.jl (0.05 to 3.5 Å⁻¹) holds it, so the
# full curve is fitted. The fit is DENSS, so no reference curve and no refChi2.
#
# Instrument and conditions (SASBDB): National Synchrotron Light Source II (NSLS-II),
# Upton, NY, beamline 16-ID (LiX), X-ray synchrotron, detector Pilatus 1M; wavelength
# 0.08188 nm = 0.8188 Å (the `wavelength` field is in nm; `xray_energy` is null, so the
# energy is hc/λ ≈ 15142 eV); cell temperature 11.0 °C; sample-detector distance 3.571 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.005 to 2.099 1/A, 699 points) and is
# in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 2
# points have I ≤ 0. No q cut: the whole curve is kept.
#
# Model and depositor fit: fit 1 of the entry is DENSS (chi_square_value 1.215); model:
# SASBDB model software: GROMACS. SASDZW5_fit1_model1.pdb: 14980 ATOM records (926
# residues, chains AB), 7582 heavy atoms, 7398 hydrogens (replaced by pdb2pqr/PROPKA); one
# structure only.
# The depositor's DENSS curve (SASDZW5_fit1.fit, 4 columns, χ² 1.215) is kept in the
# fixtures but not drawn: DENSS output has a different layout, so this entry is wired
# WITHOUT a reference curve and WITHOUT `refChi2` (`results` is called without
# `references`).
#
# Flags: full curve to 2.099 Å⁻¹ (sanity range raised); paper not
# retrievable; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.8188   # ≈ 15142 eV, SASBDB wavelength 0.8188 Å
const TEMPERATURE_C = 11.0   # SASBDB cell temperature

# Buffer "10mM HEPES pH 7.5, 50mM NaCl, 0.2mM TCEP", pH 7.5 (SASBDB). HEPES pK 7.564 (25
# °C, ΔH 20.4 kJ/mol, dpK/dT -0.012, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 7.600; Davies (A = 0.509) at the self-consistent ionic strength I = 0.055 M
# gives pK' = 7.512. The deprotonated (anionic) fraction of 10 mM is 0.493; with NaOH
# titration the counter-ion is sodium 4.93 mM (σ 0.65 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "hepes"),   # 10 mM HEPES, ±2%
    NonBiological(0.05, 0.001, "sodium chloride"),   # 50 mM, ±2%
    # counter-ion of the NaOH titration, 4.93 mM
    NonBiological(0.004932, 0.000649, "sodium"),
    NonBiological(0.0002, 4e-06, "tcep"),   # 0.2 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has hydrogens, replaced here: pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `runSasdzw5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdzw5` below is the whole story (build the seed, then sample it).
function seedSasdzw5()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdzw5(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdzw5()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdzw5()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log.
# No reference curve and no refChi2 for this entry (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
)

# `@__DIR__` (this SASDZW5/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
