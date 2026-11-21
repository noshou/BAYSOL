# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDDJ6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDDJ6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDDJ6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDDJ6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDDJ6: Methyltransferase (Methyltransferase domain protein; Mycolicibacterium
# hassiacum; 25.409 kDa SASBDB molecule MW, dimer) in the SASBDB buffer "20 mM bis-tris
# propane, 50 mM NaCl, 2 mM DTT, 5% (v/v) glycerol", pH 7.5. Sample: SAM-dependent
# O-Methyltransferase from Mycobacterium hassiacum.
#
# Publication: Ripoll-Rozada J, Costa M, Manso JA, Maranha A, Miranda V, Sequeira A,
# Ventura MR, Macedo-Ribeiro S, Pereira PJB, Empadinhas N, "Biosynthesis of mycobacterial
# methylmannose polysaccharides requires a unique 1-O-methyltransferase specific for
# 3-O-methylated mannosides.", Proc Natl Acad Sci U S A (2019 Jan 15), DOI
# 10.1073/pnas.1813450116. Entry: https://www.sasbdb.org/data/SASDDJ6/.
#
# BUFFER SOURCE: SASBDB buffer fields ("20 mM BTP, 50 mM NaCl, 2 mM DTT, 5 % v/v
# glycerol", pH 7.5). The paper (PNAS 2019, see the Publication line) is not open access
# and could not be retrieved. Bis-tris propane (BTP) is diprotic (pK 6.65 and 9.1 at 25 C,
# both Goldberg-Kishore-Lennen grade D, one study), so at pH 7.5 the buffer is a mixture
# of the three BTP species, written as three rows, as in the bis-tris-propane template of
# the terminal interface (`speciesRows` of `buffer_templates.json`; the titrant is not
# stated and HCl is the template default). The PARTIAL MOLAR VOLUMES of the three BTP
# species ("bis-tris propane dication", "... cation", "bis-tris propane") are 3D-RISM
# ESTIMATES (`estimated`, never measured): the run of 2026-11-18 gives 207.32 / 209.91 /
# 209.14 cm3/mol, uncertainty about 4.1 each (an earlier run gave 225.02 / 223.87 /
# 220.93, about 12 cm3/mol higher for no known reason; the table carries the newer one).
# With 20 mM of BTP the ±4 on each volume is
# a sub-percent effect on the solvent density, far below the 5 % glycerol term.
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus 1M; wavelength 0.09919 nm = 0.9919 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 12500 eV); cell temperature 10.0 °C;
# sample-detector distance 2.867 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.007817 to 0.4939 1/A, 1027 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 11 points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ >
# 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 3.664); model:
# SASBDB model software: MODELLER. SASDDJ6_fit1_model1.pdb: 3598 ATOM records (462
# residues, chains AB), 3598 heavy atoms, no hydrogens; one structure only.
# The fit file SASDDJ6_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "MeT2_mod
# Dro:0.068  Ra:1.580  RGT:25.03  Vol: 58025.  Chi^2: 3.664"; χ² recomputed from the file
# with the data's σ is 3.655 (label 3.664), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.3001 Å⁻¹ only while the data run to 0.4939 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: BTP species volumes are 3D-RISM estimates (see BUFFER SOURCE); pK values grade D;
# paper not retrievable; glycerol percentage unit not stated, v/v assumed; fixtures
# rebuilt from the SASBDB files on 2026-11-18 (the first archive was an empty stub);
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.9919   # ≈ 12500 eV, SASBDB wavelength 0.9919 Å
const TEMPERATURE_C = 10.0   # SASBDB cell temperature

# Buffer "20 mM bis-tris propane, 50 mM NaCl, 2 mM DTT, 5% (v/v) glycerol", pH 7.5
# (SASBDB).
#
# The entry gives total BTP and the pH, not the salts, so the species split is computed
# (the engine of `computeTemplate`, `tui/src/store/buffer-templates.ts`, id
# "bis-tris-propane": 20 mM, pH 7.5, the 50 mM NaCl as the other ions): the ladder
# dication (+2) / cation (+1) / neutral with pK1 6.65 and pK2 9.1 (25 C values; the 10
# °C of the cell would shift pK1 by about +0.2 (slope -0.016 per K), ignored: the pH is
# taken as set at room temperature, at which the engine uses pK1 6.698), Davies
# activities (A = 0.509) at the self-consistent ionic strength I = 0.0791 M. Fractions
# 23.5 % / 75.0 % / 1.5 %: dication 4.708, cation 14.99 and neutral 0.2994 mM. BTP is
# only ever cationic, so the charge it carries (dication 2, cation 1: 24.41 mM) is
# balanced by chloride, the assumed HCl titrant (the entry does not name it). σ is the
# engine's: σ_pH = 0.1, 2 % on the total and 0.3 on both pK (grade D, shifted together),
# 30 % on the Davies term, in quadrature: dication ±2.85, cation ±2.57, neutral ±0.30,
# chloride ±3.18 mM (the four are strongly correlated, which independent σ ignores). The
# measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.004708, 0.002848, "bis-tris propane dication"),   # +2, 4.708 mM
    NonBiological(0.01499, 0.00257, "bis-tris propane cation"),   # +1, 14.99 mM
    NonBiological(0.0002994, 0.0002979, "bis-tris propane"),   # neutral, 0.2994 mM
    NonBiological(0.02441, 0.003179, "chloride"),   # counter-ion of the HCl titrant
    NonBiological(0.05, 0.001, "sodium chloride"),   # 50 mM, ±2%
    NonBiological(0.002, 4e-05, "dtt"),   # 2 mM DTT, ±2%
    NonBiological(0.6848, 0.0342, "glycerol"),   # 5 % v/v glycerol (assumed v/v), ±5%
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

# Builds the Seed that `runSasddj6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasddj6` below is the whole story (build the seed, then sample it).
function seedSasddj6()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasddj6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasddj6()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasddj6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
shown = crysol[:, 1] .> 0   # the q = 0 row cannot be drawn on a log axis
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[shown, 1]),
    Float64.(crysol[shown, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 3.664",
)

# `@__DIR__` (this SASDDJ6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
