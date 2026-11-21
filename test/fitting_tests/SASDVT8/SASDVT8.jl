# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVT8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVT8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVT8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVT8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVT8: AnRut (glucan 1,3-beta-glucosidase (W90L, N179H); Aspergillus niger
# (strain ATCC 1015 / CBS 113.46 / FGSC A1144 / LSHB Ac4 / NCTC 3858a / NRRL 328 / USDA
# 3528.7); 41.636 kDa SASBDB molecule MW, dimer) in the SASBDB buffer "McIlvain
# (Na2HPO4/citric acid) buffer", pH 3.5. Sample: Glucosidase/Rutinosidase from Aspergillus
# niger - glycosylated.
#
# Publication: no publication is listed in SASBDB for this entry. Entry:
# https://www.sasbdb.org/data/SASDVT8/.
#
# BUFFER SOURCE: SASBDB buffer fields only (name, pH); SASBDB lists no publication for
# this entry, so there is no paper to check them against. The buffer is the McIlvaine
# buffer of the SASBDB name; no publication, no further data.
#
# Instrument and conditions (SASBDB): Institute of Biotechnology, Czech Academy of
# Sciences/Centre of Molecular Structure, Vestec, beamline Anton Paar SAXSpoint 2.0, X-ray
# in house, detector Eiger R 1M; wavelength 0.134 nm = 1.34 Å (the `wavelength` field is
# in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9253 eV); cell temperature 20.0
# °C; sample-detector distance 0.8256 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.1203 to 3.997 1/nm, 740 points) and
# is converted to Å⁻¹ (÷10); 133 points have I ≤ 0. q cut at 0.2402 Å⁻¹ (README rule):
# above it there are 304 points with a median I/σ of 0.23, 44 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.99.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.884); model:
# pdb 6i1a (identical); SASBDB model software: PDB (Protein Data Bank).
# SASDVT8_fit1_model1.pdb: 5749 ATOM records (716 residues, chains AB), 6698 heavy atoms,
# no hydrogens, 92 alternate-location records; HETATM groups kept as ligands: NAG 140
# atoms, EDO 119 atoms; one structure only. PDB title: "HEADER    HYDROLASE
# 28-OCT-18   6I1A".
# The fit file SASDVT8_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "AnRut_6i
# Dro:0.035  Ra:1.440  RGT:29.97  Vol:113199.  Chi^2: 1.884"; χ² recomputed from the file
# with the data's σ is 1.900 (label 1.884), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.15 Å⁻¹ only while the data run to 0.3997 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: alternate locations in the model; ligand HETATM groups scattered with the
# protein; McIlvaine stock concentrations assumed (0.2 M Na2HPO4, 0.1 M citric acid);
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 3.5, PH_METER_SIGMA   # SASBDB pH 3.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "McIlvain (Na2HPO4/citric acid) buffer", pH 3.5 (SASBDB). McIlvaine buffer (0.2
# M Na2HPO4 mixed with 0.1 M citric acid by volume, pH 3.5): the mixing ratio that gives
# pH 3.5 with the repo buffer model (pK phosphate 2.148, 7.198, 12.35 and citrate 3.128,
# 4.761, 6.396 at 25 °C; Davies, A = 0.509, self-consistent ionic strength 0.123 M;
# electroneutral with the Na+ of the Na2HPO4) is 29.2 % Na2HPO4, i.e. 58.4 mM phosphate
# and 70.8 mM citrate in the mixture, the Na+ 116.8 mM; the species follow from pH 3.5.
# This agrees with the standard McIlvaine table (about 5.9 mL of 0.2 M Na2HPO4 in 20 mL
# at pH 3.5). The concentrations of the stock solutions are an assumption (SASBDB says
# only "McIlvaine"), so each species carries ±10 %.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.00193, 0.0003, "phosphoric acid"),   # H3PO4, 1.93 mM, ±10%
    # H2PO4-, 56.45 mM, ±10%
    NonBiological(0.05645, 0.0056, "sodium dihydrogen phosphate"),
    NonBiological(0.01599, 0.0016, "citric acid"),   # H3Cit, 15.99 mM, ±10%
    NonBiological(0.04891, 0.0049, "sodium dihydrogen citrate"),   # H2Cit-, 48.91 mM, ±10%
    NonBiological(0.00587, 0.0006, "disodium hydrogen citrate"),   # HCit2-, 5.87 mM, ±10%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.2402 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.23, 44 % of the points non-positive).
const Q_MAX_FIT = 0.2402

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

# Builds the Seed that `runSasdvt8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvt8` below is the whole story (build the seed, then sample it).
function seedSasdvt8()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvt8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdvt8()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvt8()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.884",
)

# `@__DIR__` (this SASDVT8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
