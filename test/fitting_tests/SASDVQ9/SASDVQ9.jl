# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVQ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVQ9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVQ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVQ9_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVQ9: Full-length mature human mitochondrial ATP synthase subunit O
# (Oligomycin Sensitivity Conferral Protein or Complex V subunit O) (ATP synthase subunit
# O, mitochondrial; Homo sapiens; 20.875 kDa SASBDB molecule MW, dimer) in the SASBDB
# buffer "50 mM Na2HPO4, 300 mM NaCl", pH 7.0. Sample: Full-length mature human
# mitochondrial ATP synthase subunit O (Oligomycin Sensitivity Conferral Protein or
# Complex V subunit O).
#
# Publication: Fabbian S, Gabbatore L, Morbiato L, Zotti M, Giorgio V, Battisutta R,
# Giachin G, Sosic A, Bellanda M, "The OSCP Subunit of ATP Synthase is a Dimer in
# Solution: Strategy to Induce the Monomeric Protein as a New Tool for Drug Discovery.", J
# Mol Biol (2025 Jun 6), DOI 10.1016/j.jmb.2025.169267. Entry:
# https://www.sasbdb.org/data/SASDVQ9/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus3 2M; wavelength 0.099 nm = 0.99 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 12524 eV); cell temperature 20.0 °C;
# sample-detector distance 2.867 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.06264 to 3.143 1/nm, 595 points)
# and is converted to Å⁻¹ (÷10); 0 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.232); model:
# SASBDB model software: AlphaFold. SASDVQ9_fit1_model1.pdb: 2928 ATOM records (380
# residues, chains AB), 2928 heavy atoms, no hydrogens; one structure only.
# The fit file SASDVQ9_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.053
# Rg: 36.32 Vol:  53233. Chi^2: 1.232"; χ² recomputed from the file with the data's σ is
# 1.230 (label 1.232), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); phosphate titrant not stated, HCl assumed; whole entry wired from the files
# above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB pH 7.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12524 eV, SASBDB wavelength 0.99 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "50 mM Na2HPO4, 300 mM NaCl", pH 7.0 (SASBDB). Na₂HPO₄ 50 mM titrated to pH 7.0
# (taken as HCl; the titrant is not stated): pK₂ 7.198 at 25 °C, ΔH 3.6 kJ/mol, van't
# Hoff to 22 °C, Davies at I = 0.431 M: pK₂' = 6.797, HPO₄²⁻ fraction 0.615. The sodium
# stays 2 x 50 mM, so the H₂PO₄⁻ part (19.25 mM) comes with an extra 19.25 mM NaCl (Na⁺
# and Cl⁻); σ 4.47 mM.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.030748, 0.00447, "disodium hydrogen phosphate"),   # HPO₄²⁻, 30.75 mM
    NonBiological(0.019252, 0.00447, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 19.25 mM
    # 300 mM, ±2% + Na⁺ and Cl⁻ of the titration of Na₂HPO₄ with HCl, 19.25 mM
    NonBiological(0.31925, 0.00748, "sodium chloride"),
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

# Builds the Seed that `runSasdvq9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvq9` below is the whole story (build the seed, then sample it).
function seedSasdvq9(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvq9(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvq9(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvq9()

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
    refChi2 = "CRYSOL 1.232",
)

# `@__DIR__` (this SASDVQ9/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
