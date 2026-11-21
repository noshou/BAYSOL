# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDT65")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDT65.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDT65_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDT65_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDT65: NS1B (Non-structural protein 1; Influenza B virus; 15.851 kDa SASBDB
# molecule MW, monomer) in the SASBDB buffer "40 mM ammonium acetate, pH 5.5, 450 mM NaCl,
# 5 mM CaCl2, 0.02% NaN3, 50 mM arginine", pH 5.5. Sample: Non-structural protein 1 (NS1B,
# C-terminal) plus double stranded RNA.
#
# Publication: Woltz R, Schweibenz B, Tsutakawa S, Zhao C, Ma L, Shurina B, Hura G, John
# R, Vorobiev S, Swapna G, Solotchi M, Tainer J, Krug R, Patel S, Montelione G, "The NS1
# protein of influenza B virus binds 5’-triphosphorylated dsRNA to suppress RIG-I
# activation and the host antiviral response", preprint/unpublished (2024 Jan 24), DOI
# 10.1101/2023.09.25.559316. Entry: https://www.sasbdb.org/data/SASDT65/.
#
# BUFFER SOURCE: SASBDB buffer fields ("40 mM NH4OAc pH 5.5, 450 mM NaCl, 5 mM CaCl2, 0.02
# % NaN3, 50 mM arginine"). The preprint (bioRxiv 2023.09.25.559316) is not available in
# the open full-text service, so the values were not checked against it. Ammonium acetate
# is entered as the salt (both ions are ≈ fully charged at pH 5.5, pK 9.25 and 4.76), 0.02
# % NaN3 as w/v = 0.2 g/L / 65.01 g/mol = 3.08 mM, arginine (pK 12.5 side chain, so mostly
# cationic at pH 5.5) as the neutral row of the table; its charge and counter-ion are not
# stated.
#
# Instrument and conditions (SASBDB): Cornell High Energy Synchrotron Source (CHESS),
# Ithaca, NY, beamline G1, X-ray synchrotron, detector Pilatus 100K; wavelength 0.1249 nm
# = 1.249 Å (the `wavelength` field is in nm; `xray_energy` is null, so the energy is hc/λ
# ≈ 9927 eV); cell temperature 4.0 °C; sample-detector distance None m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.006283 to 0.275 1/A, 472 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 11
# points have I ≤ 0. Rule-(a) cut 0.2619 Å⁻¹ (see Q_MAX_FIT): above it there are 24
# points with a median I/σ of 0.44, 25 % of them non-positive, and the lowest-q quarter of
# them has a median I/σ of 0.56.
#
# Model and depositor fit: fit 1 of the entry is FoXS (chi_square_value 2.741511); model:
# SASBDB model software: HADDOCK. SASDT65_fit1_model1.pdb: 2426 ATOM records (173
# residues, chains AB), 2426 heavy atoms, no hydrogens; one structure only.
# The depositor's FoXS curve (SASDT65_fit1.fit, 4 columns, χ² 2.741511) is kept in the
# fixtures but not drawn: FoXS output has a different layout, so this entry is wired
# WITHOUT a reference curve and WITHOUT `refChi2` (`results` is called without
# `references`).
#
# Flags: paper not retrievable; arginine charge state ignored (neutral row); NaN3 0.02 %
# read as w/v; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 5.5, PH_METER_SIGMA   # SASBDB pH 5.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.249   # ≈ 9927 eV, SASBDB wavelength 1.249 Å
const TEMPERATURE_C = 4.0   # SASBDB cell temperature

# Buffer "40 mM ammonium acetate, pH 5.5, 450 mM NaCl, 5 mM CaCl2, 0.02% NaN3, 50 mM
# arginine", pH 5.5 (SASBDB): no buffering species, only the salts below.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.04, 0.0008, "azanium acetate"),   # 40 mM, ±2%
    NonBiological(0.45, 0.009, "sodium chloride"),   # 450 mM, ±2%
    NonBiological(0.005, 0.0001, "calcium chloride"),   # 5 mM, ±2%
    NonBiological(0.003077, 6.15e-05, "sodium azide"),   # 3.077 mM, ±2%
    # 50 mM arginine, taken as the neutral row, ±2%
    NonBiological(0.05, 0.001, "arginine"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.23 Å⁻¹ (README rule (b)). The rule-(a) cut of the first run, 0.2619 Å⁻¹,
# failed the gates (R̂ 1.58, step size collapsed to 0.0004 at tree depth 10, 0.7 to 3.4 %
# divergent on the lower-δ rungs): the points between 0.23 and 0.2619 Å⁻¹ have a median
# I/σ of 1.9 to 1.2 and add noise, not shape. At 0.23 Å⁻¹ the median I/σ of the window just
# below the cut is about 2.2 (above it: 83 points of the 472, median I/σ 0.9).
const Q_MAX_FIT = 0.23

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

# Builds the Seed that `runSasdt65` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdt65` below is the whole story (build the seed, then sample it).
function seedSasdt65()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdt65(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdt65()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdt65()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log.
# No reference curve and no refChi2 for this entry (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
)

# `@__DIR__` (this SASDT65/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
