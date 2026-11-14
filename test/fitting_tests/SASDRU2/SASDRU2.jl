# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDRU2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRU2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRU2: A solution structure analysis reveals a bent collagen triple helix in the
# complement activation recognition molecule mannan-binding lectin (peptide MBL-E).
#
# Paper: Iqbal H, Fung KW, Gor J, et al., J Biol Chem (2023), DOI
# 10.1016/j.jbc.2022.102799. Open access (CC BY); PDF not in the repository (PMC
# PMC9898670), CONSULTED 2026-11-13 via Europe PMC (full text, Methods "X-ray and neutron
# scattering data", Table 1, Experimental procedures for the AUC buffers). SASBDB entry:
# https://www.sasbdb.org/data/SASDRU2/
#
# Sample: collagen peptide MBL-E, Ac-(POG)5-EOGQGLRG-(POG)3-NH2 (paper Table 1, MBL EOG:
# the glutamate sits in the Xaa position of an EOG triplet). Trimer, 4.085 kDa/chain
# (SASBDB; paper 9019 Da/trimer), SASBDB model_mw 12.49 kDa. Collected at 0.25-8 mg/ml in
# 20 mM L-histidine buffer at 20 °C (paper; the concentration of this single curve is not
# stated per entry). The deposited model is the MBL sequence with Pro hydroxylated in the
# GLU triplet: a 3-chain all-atom MD snapshot (AMBER99sb-ILDN-P, TIP3P, GROMACS; paper)
# with hydrogens; ARG/GLU/GLN/LEU/GLY/PRO/HYP residues, ACE/NH2 caps; no HETATM groups.
# Instrument: B21, Diamond Light Source (X-ray synchrotron), Pilatus 2M, sample-detector
# distance 4.014 m (paper), wavelength 0.12 nm = 1.2 Å (SASBDB record; the paper does not
# state it) => energy = hc/λ ≈ 10332 eV (hc = 12398.42 eV·Å). Sample temperature: 20.0 °C
# (SASBDB cell temperature = paper).
#
# Buffer as deposited: "20 mM L-histidine, 138 mM NaCl, 2.7 mM KCL,", pH 6.0; the paper
# gives the same composition (20 mM L-histidine, 138 mM NaCl, 2.7 mM KCl, pH 6.0, in the
# AUC section; SAXS "20 mM L-histidine buffer"). Same buffer, pH and temperature as all
# siblings (SASDRS2, SASDRW2), so the solute list is the same. Curve units: the SASBDB
# .dat is already in Å⁻¹ (angular unit "1/A", q 0.0065-0.37 Å⁻¹). The depositor's CRYSOL
# fit (q up to 0.37 Å⁻¹, fitted curve in column 4, on the data's scale: no rescale) is the
# comparison curve. Its header "Chi^2: 3.915" is chi², not chi: recomputed from the .fit
# columns (mean of ((I - fit)/σ)² over the rows with σ > 0) it reproduces 3.915 (equal to
# the SASBDB REST chi_square_value). CRYSOL parameters (.fit header): Dro 0.000, Ra 1.580.
# SASBDB P(r) D_max 10.0 nm.
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
    refChi2 = "CRYSOL 3.915",
    pdb = "SASDRU2_fit1_model1.pdb",
    fit = "SASDRU2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # D_max ≈ 10.0 nm (SASBDB P(r)); deposited χ² = 3.915
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

# Builds the Seed that `runSasdru2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdru2` below is the whole story (build the seed, then sample it).
function seedSasdru2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdru2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdru2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdru2(run)

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

    # `@__DIR__` (this SASDRU2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
