# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVE7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVE7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVE7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVE7_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVE7: SaIlvA (L-threonine dehydratase biosynthetic IlvA; Staphylococcus aureus
# (strain USA300); 48.002 kDa SASBDB molecule MW, hexamer) in the SASBDB buffer "20 mM
# KPO4, 200 mM NaCl, 0.1 mM TCEP,", pH 7.5. Sample: Hexameric L-threonine dehydratase
# biosynthetic (IlvA) from Staphylococcus aureus.
#
# Publication: Yun MK, Subramanian C, Miller K, Jackson P, Radka CD, Rock CO, "Isoleucine
# Binding and Regulation of Escherichia coli and Staphylococcus aureus Threonine
# Dehydratase (IlvA).", Biochemistry (2025 Jun 10), DOI 10.1021/acs.biochem.5c00168.
# Entry: https://www.sasbdb.org/data/SASDVE7/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Advanced Photon Source (APS), Argonne National
# Laboratory, Lemont, IL, beamline BioCAT 18ID, X-ray synchrotron, detector Eiger2 XE 9M;
# wavelength 0.1033 nm = 1.033 Å (the `wavelength` field is in nm; `xray_energy` is null,
# so the energy is hc/λ ≈ 12002 eV); cell temperature 20.0 °C; sample-detector distance
# 3.663 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.002921 to 0.4201 1/A, 1698 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 335 points have I ≤ 0. q cut at 0.09719 Å⁻¹ (README rule): above it there are 950 points
# with a median I/σ of 0.30, 35 % of them non-positive, and the lowest-q quarter of them
# has a median I/σ of 0.99.
#
# Model and depositor fit: fit 1 of the entry is FoXS (chi_square_value 1.370191); model:
# SASBDB model software: Chimera. SASDVE7_fit1_model1.pdb: 19818 ATOM records (2532
# residues, chains ABCDEF), 19818 heavy atoms, no hydrogens; one structure only.
# The depositor's FoXS curve (SASDVE7_fit1.fit, 4 columns, χ² 1.370191) is kept in the
# fixtures but not drawn: FoXS output has a different layout, so this entry is wired
# WITHOUT a reference curve and WITHOUT `refChi2` (`results` is called without
# `references`).
#
# Flags: large structure (19818 heavy atoms); buffer from SASBDB only (paper not read);
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, SASBDB wavelength 1.033 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM KPO4, 200 mM NaCl, 0.1 mM TCEP,", pH 7.5 (SASBDB). Phosphate 20 mM is
# split into HPO₄²⁻ and H₂PO₄⁻ (pK₂ 7.198 at 25 °C, ΔH 3.6 kJ/mol, van't Hoff to 22 °C,
# Davies at I = 0.253 M: pK₂' = 6.809); HPO₄²⁻ fraction 0.831; the counter-cations are
# taken as the Na⁺/K⁺ of the salts. σ 1.12 mM (σ_pH 0.1, ±0.02 pK, 30 % of the Davies
# shift, ±2 %).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.016614, 0.00112, "dipotassium hydrogen phosphate"),   # HPO₄²⁻, 16.61 mM
    NonBiological(0.003386, 0.00112, "potassium dihydrogen phosphate"),   # H₂PO₄⁻, 3.39 mM
    NonBiological(0.2, 0.004, "sodium chloride"),   # 200 mM, ±2%
    NonBiological(0.0001, 2e-06, "tcep"),   # 0.1 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.09719 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.30, 35 % of the points non-positive).
const Q_MAX_FIT = 0.09719

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`iExp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdve7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdve7` below is the whole story (build the seed, then sample it).
function seedSasdve7()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdve7(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdve7()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdve7()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log.
# No reference curve and no refChi2 for this entry (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
)

# `@__DIR__` (this SASDVE7/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
