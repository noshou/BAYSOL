# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDM63")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDM63.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDM63: structural basis for specific RNA recognition by the alternative
# splicing factor RBM5. The RRM1-ZnF1-RRM2 triple-domain construct of human RBM5 carrying
# the mutations I107T and C191G (25.5 kDa) in complex with the 12-nt caspase-2-derived RNA
# GGCU_12 (UGGCUCUUCUCU, 3.8 kDa); a protein-RNA complex, about 29.3 kDa.
#
# Paper: Soni K, Jagtap PKA, Martínez-Lumbreras S, Bonnal S, Geerlof A, Stehle R, Simon B,
# Valcárcel J, Sattler M, Nature Communications (2023), DOI 10.1038/s41467-023-39961-w.
# Round-5 audit (2026-11-13): the paper WAS read (Methods "Small-angle X-ray scattering",
# "Static light scattering"). It states the temperature, "for the RNA-complex at
# concentrations ranging from 0.6 to 4.8mg/ml were performed at 5°C using Rigaku BIOSAXS
# 1000 ... eight frames with 900sec/ frame" (as SASBDB), the instrument, a final SEC step
# of the complex, and for the same complex the SLS/SEC buffer "20mM MES pH 6.5, 100mM
# NaCl, 1mM DTT at 4°C" (as the SASBDB buffer). It gives no sentence naming the SAXS
# buffer itself, so the SASBDB value (not contradicted) is the stated one; the paper's
# SAXS chi2 for the lowest-energy model is 1.7 (deposited CRYSOL 1.685). Judgement call:
# the zinc ion of the model against the paper's "ZnF1S" construct name is resolved in
# round 6 (2026-11-13): "ZnF1S" is ZnF1 carrying the stabilizing point mutation C191G
# (paper, Results: "both harboring a protein stabilizing point mutation C191G (henceforth
# denoted as RRM1-ZnF1S and RRM1-ZnF1S-RRM2)"), not a zinc-free construct; ZnF1 "adopts a
# canonical RanBP2-type zinc finger fold with ... the Zn2+ ion" (the crystal structure of
# RRM1-ZnF1S + GGCU_10 was solved with Zn2+-SAD phasing). In the model the zinc (residue
# ZN 80, chain D) lies next to the sulfurs of Cys187, Cys190, Cys201 and Cys204, and
# residue 191 is Gly (C191G), residue 107 Thr (I107T of the SASBDB sample description;
# the paper text does not mention I107T), so the model matches the construct. Under the
# owner rule of 2026-11-13 (a value is ambiguous only if neither the paper nor SASBDB
# states it) the SAXS buffer, stated by SASBDB and not contradicted by the paper, is
# not ambiguous.
# Every condition below is the SASBDB entry metadata (https://www.sasbdb.org/data/SASDM63/).
#
# Instrument: SFB 1035 in-house X-ray source, Technische Universität München, Garching
# (Rigaku BioSAXS-1000, point geometry), Pilatus 100K. The entry states both a wavelength
# of 0.15 nm and an X-ray energy of 8.0405 keV (Cu K-alpha, 1.542 Å): the energy is used
# as stated, ENERGY_EV = 8040.5 eV. Measured on 2017-03-01, eight 900 s frames. Cell
# temperature: 5.0 °C (SASBDB cell temperature).
#
# Buffer as deposited: "20 mM MES, 100 mM NaCl, 1 mM DTT", pH 6.5. The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Model (fit1_model1, "Other" software; the REST model mass is 29.84 kDa): 2066 ATOM
# records, heavy atoms only, no hydrogens. Chain D = protein, residues 90-307 (227
# residues in the file's count, as numbered), with ONE zinc ion written as an ATOM record
# (`ZN` of residue `ZN`, the ZnF1 zinc; the loader reads an ion written as ATOM like a
# HETATM one) ; chains B (residues 6-13, 8 nt) and C (residues 14-17, 4 nt) = the 12-nt
# RNA in two pieces, with the plain wwPDB names U C G, O2' present, the 5'-end nucleotide
# with phosphate. Chain-letter and column-80 text ("RNA", "PROT") are the depositor's,
# ignored. Because the zinc-coordinating cysteines are present, PROPKA may treat them as
# titratable thiols; that is a feature of the pipeline, not changed here. The file is used
# as downloaded (nothing was cleaned).
#
# Depositor fit: SASDM63_fit1.fit, CRYSOL (no version), header "Dro:0.000 Ra:1.800
# RGT:20.65 Vol: 33142. Chi^2: 1.685", the REST chi_square_value is 1.685 as well (they
# agree; the entry has a log file "RBM5_1086_chid-BCD00.log"). Recomputed from the columns
# (q, I_exp, σ, I_fit; 216 rows with data): (1/N) Σ ((I_exp − I_fit)/σ)² = 1.685 and with
# N − 1 = 1.693, so the header value is reproduced with the N convention. The .fit covers
# q 0.0095-0.3186 Å⁻¹, the data's own range.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (the entry states angular units 1/A; q
# 0.0095-0.3186 Å⁻¹, 216 rows, a 2-line header and 2 trailer lines, `_readCurve` keeps the
# numeric rows); 1 point has a non-positive intensity, dropped by `seedModel` after
# binning. The .fit is also in Å⁻¹ on the data's scale, I_fit is column 4, unscaled.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.5, PH_METER_SIGMA
const ENERGY_EV     = 8040.5   # eV, the stated X-ray energy (8.0405 keV, Cu K-alpha)
const TEMPERATURE_C = 5.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the
# deposited recipe does not list. Assumed: 20 mM MES titrated with NaOH -> Na⁺ = C·f with
# f = r/(1 + r), r = 10^(pH − pK)/γ₁, pK(22 °C) = 6.296 and I ≈ 0.113 M solved
# self-consistently (100 mM NaCl and the NaOH-neutralised MES): γ₁ = 0.775, f = 0.674, Na⁺
# = 13.475 mM (the same calculation reproduces the Na⁺ of SASDF42 and SASDRJ8). Titrant:
# not stated; NaOH for Good's buffers. The pH is taken as set at room temperature (22 ± 3
# °C), which fixes the counter-ion amount whatever the measurement temperature (here 5
# °C). σ combines σ_PH, ±3 °C (±0.027 pK), ±0.02 pK, 30 % of the Davies shift and ±2 % on
# C, as in SASDF42. Only the counter-ion is modelled; the volume change of the buffer's
# own (de)protonation is not. DTT is taken as the neutral molecule. Every solute below is
# in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "mes"),   # 20 mM MES, ±2%
    NonBiological(0.1, 0.001, "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, ±2%
    # Na⁺ counter-ion from NaOH titration of MES (see note above)
    NonBiological(0.013475, 0.001152, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has heavy atoms only; pdb2pqr builds the
# hydrogens (PROPKA at PH; the file holds protein and RNA, which keeps PARSE and PROPKA).
# The zinc ion is an ATOM record; whether pdb2pqr keeps it (the Balance step puts dropped
# heavy atoms back) was not checked by running. The first run of this entry has not been
# checked by the author: see the entry notes.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.685",
    pdb = "SASDM63_fit1_model1.pdb",
    fit = "SASDM63_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # RBM5 + GGCU_12 RNA with one Zn²⁺; deposited χ² = 1.685
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

# Builds the Seed that `runSasdm63` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdm63` below is the whole story (build the seed, then sample it).
function seedSasdm63(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdm63(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdm63(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdm63(run)

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

    # `@__DIR__` (this SASDM63/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
