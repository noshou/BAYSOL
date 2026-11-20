# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVW3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVW3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVW3_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVW3_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVW3: NlpI (Lipoprotein NlpI; Escherichia coli (strain K12); 31.641 kDa SASBDB
# molecule MW, dimer) in the SASBDB buffer "0.2 M Na/K phosphate pH 7.0, 2 mM
# 2-mercaptoethanol", pH 7.0. Sample: Lipoprotein NlpI dimer bound to two asymmetrical
# murein DD-endopeptidase mMepS dimers at pH 7.0.
#
# Publication: Wang S, Huang CH, Lin TS, Yeh YQ, Fan YS, Wang SW, Tseng HC, Huang SJ,
# Chang YY, Jeng US, Chang CI, Tzeng SR, "Structural basis for recruitment of
# peptidoglycan endopeptidase MepS by lipoprotein NlpI.", Nat Commun (2024 Jun 27), DOI
# 10.1038/s41467-024-49552-y. Entry: https://www.sasbdb.org/data/SASDVW3/.
#
# BUFFER SOURCE (paper first, SASBDB second): the paper (Nat Commun 2024, see the
# Publication line) and SASBDB both give "0.2 M Na/K phosphate pH 7.0, 2 mM
# 2-mercaptoethanol"; the Na/K ratio is not stated, so all the cations are taken as Na+
# (the model does not tell Na+ from K+ apart beyond the table row).
#
# Instrument and conditions (SASBDB): NSRRC, Hsinchu, beamline TPS13A, X-ray synchrotron,
# detector Eiger X 1M & 9M; wavelength 0.0826 nm = 0.826 Å (the `wavelength` field is in
# nm; `xray_energy` is null, so the energy is hc/λ ≈ 15010 eV); cell temperature 10.0 °C;
# sample-detector distance 2.499 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.006615 to 0.6173 1/A, 450 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 0 points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ >
# 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.725); model:
# SASBDB model software: PyMOL. SASDVW3_fit1_model1.pdb: 8870 ATOM records (1095 residues,
# chains ABEGIJ), 8870 heavy atoms, no hydrogens, 18 alternate-location records; one
# structure only.
# The fit file SASDVW3_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "NM_1_2.p
# Dro:0.000  Ra:1.800  RGT:34.74  Vol:119612.  Chi^2: 1.725"; χ² recomputed from the file
# with the data's σ is 1.725 (label 1.725), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: alternate locations in the model; Na/K phosphate ratio not stated, all Na
# assumed; 0.2 M phosphate: ionic strength ≈ 0.5 M, beyond the comfortable range of
# Davies; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB pH 7.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.826   # ≈ 15010 eV, SASBDB wavelength 0.826 Å
const TEMPERATURE_C = 10.0   # SASBDB cell temperature

# Buffer "0.2 M Na/K phosphate pH 7.0, 2 mM 2-mercaptoethanol", pH 7.0 (SASBDB).
# Phosphate 200 mM is split into HPO₄²⁻ and H₂PO₄⁻ (pK₂ 7.198 at 25 °C, ΔH 3.6 kJ/mol,
# van't Hoff to 22 °C, Davies at I = 0.446 M: pK₂' = 6.797); HPO₄²⁻ fraction 0.615; the
# counter-cations are taken as the Na⁺/K⁺ of the salts. σ 17.76 mM (σ_pH 0.1, ±0.02 pK,
# 30 % of the Davies shift, ±2 %).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.12293, 0.0178, "disodium hydrogen phosphate"),   # HPO₄²⁻, 122.92 mM
    NonBiological(0.077075, 0.0178, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 77.08 mM
    NonBiological(0.002, 4e-05, "2-mercaptoethanol"),   # 2 mM 2-mercaptoethanol, ±2%
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

# Builds the Seed that `runSasdvw3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvw3` below is the whole story (build the seed, then sample it).
function seedSasdvw3(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvw3(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvw3(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvw3()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.725",
)

# `@__DIR__` (this SASDVW3/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
