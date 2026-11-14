# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDRS2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRS2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRS2: A solution structure analysis reveals a bent collagen triple helix in the
# complement activation recognition molecule mannan-binding lectin.
#
# Paper: Iqbal H, Fung KW, Gor J, et al., J Biol Chem (2023), DOI
# 10.1016/j.jbc.2022.102799. Open access (CC BY); PDF not in the
# repository, see test/fixtures/experiments/SASDRS2/README.txt (PMC
# PMC9898670). SASBDB entry: https://www.sasbdb.org/data/SASDRS2/
#
# Sample: the collagen-like peptide Ac-(POG)4-QG-(POG)5-NH2 (POG = Pro-Hyp-Gly; 29
# residues per chain, one Gln-Gly pair in the middle, N-terminal acetyl and C-terminal
# amide caps; trimer, 3.726 kDa/chain, SASBDB model_mw 7.896 kDa for the deposited model),
# measured at 2.00 mg/ml (single concentration). The model has hydroxyproline as HYP
# residues (a modified amino acid) and ACE/NH2 caps. Instrument: B21, Diamond Light Source
# (X-ray synchrotron), Pilatus 2M, wavelength 0.12 nm = 1.2 Å => energy = hc/λ ≈ 10332 eV
# (hc = 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB cell temperature).
#
# Buffer as deposited: "20 mM L-histidine, 138 mM NaCl, 2.7 mM KCL,", pH 6.0 (SASBDB
# entry metadata; the paper was not consulted for them). Same buffer, pH and temperature
# as SASDRW2, so the solute list is the same. Curve units: the SASBDB .dat is already in
# Å⁻¹ (angular unit "1/A", q 0.016-0.37 Å⁻¹). The depositor's CRYSOL fit (q = 0-0.37 Å⁻¹,
# fitted curve in column 4, on the data's scale: no rescale) is the comparison curve.
# Not stated by SASBDB and so not used: X-ray energy and the SASBDB sample/purification
# fields; the CRYSOL parameters are only in the .fit header (Dro 0.018, Ra 1.400).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # ≈ 10332 eV, from the stated 0.12 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 20 mM L-histidine titrated
# with HCl -> Cl⁻ = C·0.636 (pK(22 °C) = 6.123). The pH is taken as set at room temperature
# (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature.
# pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.153 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "l-histidine"),   # 20 mM, ±2%
    NonBiological(0.138, 0.00276, "sodium chloride"),   # 138 mM, ±2%
    NonBiological(0.0027, 5.4e-05, "potassium chloride"),   # 2.7 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of L-histidine (see note above)
    NonBiological(0.012725, 0.001313, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.446",
    pdb = "SASDRS2_fit1_model1.pdb",
    fit = "SASDRS2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # trimer, D_max ≈ 8.7 nm (SASBDB P(r)); deposited χ² = 1.446
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdrs2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdrs2` below is the whole story (build the seed, then sample it).
function seedSasdrs2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdrs2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdrs2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdrs2(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

    # run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
    fitCurve = try
        fc = _readFit(joinpath(_FIXTURE_DIR, run.fit), run.fitScale, run.fitCol)
        fc !== nothing && run.rescale ? _rescaleFit(fc, qFit, iFit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    references = BAYSOL.Reference[]
    if fitCurve !== nothing
        push!(
            references,
            BAYSOL.Reference(
                run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""),
                fitCurve...,
            ),
        )
    end
    BAYSOL.results(
        result, (qFit, iFit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        formFactorLog = formFactorLog, nAtoms = nAtoms,
        refChi2 = run.refChi2,
        runLog = true,
    )

    # `@__DIR__` (this SASDRS2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
