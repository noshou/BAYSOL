# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDB48")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDB48.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDB48: HSV-1 ICP4 N-terminal DNA-binding domain (ICP4N, 24.3 kDa) dimer
# on the 19-bp IE3 DNA (two strands of 5.8 kDa), 60.3 kDa in total; a rigid-body model
# (chains G, H protein and C, D DNA; 3735 atoms, no hydrogens; the protein residues are
# written as HETATM records).
#
# Paper: Tunnicliffe RB, Lockhart-Cairns MP, Levy C, et al., Nucleic Acids Res (2017),
# DOI 10.1093/nar/gkx419 (PMID 28505309). Not bundled; the conditions below are SASBDB's
# entry metadata (https://www.sasbdb.org/data/SASDB48/).
#
# Buffer as deposited: "20 mM HEPES, 150 mM NaCl", pH 7.4. HPLC SEC-SAXS at B21 (Diamond),
# Pilatus 2M, wavelength 0.1 nm = 1.0 Å => energy = hc/λ ≈ 12398 eV; 20 °C. The measured
# complex is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (52 REMARK header lines, CRLF line endings; q,
# I, σ). The comparison file `SASDB48_fit1.dat` is a FoXS-style profile whose columns are
# q, I_exp, I_model, σ: the fitted intensity is column 3 (not 4). Its header says Chi =
# 1.545, SASBDB 2.4; column 3 against this .dat gives 2.41.

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.01-0.44, is checked below).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the stated 0.1 nm = 1.0 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer components (the measured complex is deliberately NOT listed). Counter-ion:
# setting the pH adds a titrant that the deposited recipe does not list. Assumed: 20 mM
# HEPES titrated with NaOH -> Na⁺ = C·0.4538 (pK(22 °C) = 7.6). Same method as
# SASDKQ8.jl (pH set at 22 ± 3 °C; pK(T) from Goldberg, Kishore & Lennen 2002, J. Phys.
# Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; Davies correction at I ≈ 0.159 M; σ
# combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C). Only the
# counter-ion is modelled. Titrant not stated; NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),                # 20 mM HEPES, ±2%
    NonBiological(0.150, 0.0015, "sodium chloride"),     # 150 mM NaCl, ±1%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.009075, 0.001319, "sodium(1+)"),
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
    refChi2 = "FoXS 2.4",
    pdb = "SASDB48_fit1_model1.pdb",
    fit = "SASDB48_fit1.dat",
    fitScale = 1.0,
    fitCol = 3,
    rescale = false,
    software = "FoXS",
),   # deposited χ² = 2.4 (FoXS); I_model is column 3
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

# Builds the Seed that `runSasdb48` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdb48` below is the whole story (build the seed, then sample it).
function seedSasdb48(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdb48(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdb48(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdb48(run)

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

    # `@__DIR__` (this SASDB48/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
