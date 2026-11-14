# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDP74")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDP74.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDP74: Structure of SALL4 zinc finger domain reveals link between AT-rich DNA
# binding and Okihiro syndrome (the entry is the free AT-rich dsDNA of that study: the
# self-complementary 12-mer GATATTAATATC annealed to itself, 24 nt, 7.4 kDa).
#
# Paper: Watson JA, Pantier R, Jayachandran U, et al., Life Sci Alliance (2023), DOI
# 10.26508/lsa.202201588 (PMC9838217; open access). Audited against the full text (round
# 5, 2026-11-13; the supplementary file, Table S3 with the SAXS parameters, was not
# available). Life Sci Alliance 6(3):e202201588, Materials and Methods, "SAXS" (p. 10):
# "SEC-SAXS experiments were performed at Diamond Light Source on the B21 beamline.
# Samples at 5-7 mg/ml were injected onto a Superdex S200 Increase 3.2/300 size
# exclusion chromatography column in 20 mM Tris, pH 7.5; 200 mM NaCl at 0.1 ml/min.";
# Results (p. 3): "We measured SAXS scattering curves for ZFC4 alone, dsDNA alone, and
# ZFC4-DNA complexes as they eluted from size exclusion chromatography", this entry
# being the dsDNA alone. Same Methods (p. 9) for the protein purification: "size
# exclusion chromatography (Superdex S75) in 20 mM Tris-HCl, pH 7.5; 200 mM NaCl" and
# the crystallised oligonucleotide "palindromic oligonucleotide (5'-GATATTAATATC-3')"
# (written without a 5' phosphate, as in the model). Model: "These models were also
# fitted to the experimental SAXS data using CRYSOL (launched from PRIMUS)"; the
# deposited fit2 is the 8A4I duplex (chains C and D), the paper's Fig S1D/E not available.
# SASBDB entry: https://www.sasbdb.org/data/SASDP74/. Temperature and wavelength: SASBDB
# only (the paper gives neither and does not contradict them).
#
# Sample: SEC-SAXS, 5-7 mg/mL injected on a Superdex S200 Increase 3.2/300 column at
# 0.1 mL/min (paper); SASBDB: concentration_max 5.0 mg/mL, 619 frames of 3 s. Instrument:
# Diamond Light Source B21, Eiger 4M, sample-detector distance 4.014 m, wavelength
# 0.09998 nm = 0.9998 Å => energy = hc/λ ≈ 12401 eV (hc = 12398.42 eV·Å). Sample
# temperature: 22 °C (SASBDB cell temperature; storage 4 °C). The paper gives no
# measurement temperature, so the SASBDB value is used.
#
# Buffer: the SASBDB field says "20 mM Tris-HCl, pH 7.5, 200 mM NaCl"; the paper says "20
# mM Tris, pH 7.5; 200 mM NaCl" (SAXS paragraph), and "20 mM Tris-HCl, pH 7.5; 200 mM
# NaCl" for the protein SEC of the same Methods. The concentrations and the HCl titrant
# are therefore stated by both sources.
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q 0.0026-0.34 Å⁻¹, 2566 rows, two
# free-text header lines, a trailer of frame bookkeeping; `_readCurve` keeps the numeric
# rows). 246 rows have a non-positive intensity (noisy low q, σ ~ 0.08 at q = 0.0026),
# dropped by `seedModel` after binning; the fit uses q ≤ 0.3 Å⁻¹ (evidence at
# `Q_MAX_FIT`), the .fit reaches 0.34.
#
# Model (fit2_model1, "PyMOL", type "atomic", symmetry P1; SASBDB comment "PDB:8A4I. Chains
# C,D used."): the RCSB 8A4I crystal structure restricted to its chains C and D (the two
# 12-nt strands of the duplex; the coordinates were checked identical to the RCSB atoms of
# chains C and D, which are also kept in the fixture folder as 8A4I.pdb). 486 heavy atoms,
# no hydrogens, no HETATM/water, DG DA DT DC with primed sugar atoms, no 5'-phosphate on
# the first residue of each strand, B-factors ~ 92. The file is used as downloaded
# (nothing was cleaned); its REMARK 3 lines are the PHENIX refinement header of 8A4I.
#
# The other deposited fit (fit1, DAMMIN, dummy-atom model, chi2 1.032) is not an atomic
# model and is not used; only fit2 is wired.
#
# Depositor fit: SASDP74_fit2.fit, CRYSOL (no version stated), header "Chi^2: 1.271"
# (Dro:0.075, Ra:1.40, RGT 14.28 Å), the SASBDB REST chi_square_value is also 1.271.
# Recomputing (1/N) Σ ((I_exp − I_fit)/σ)² from the .fit columns (2566 rows) gives
# 1.2712 (N − 1: 1.2717), so the header value is reproduced; 1.271 is used.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9998   # ≈ 12401 eV, from the stated 0.09998 nm
const TEMPERATURE_C = 22.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the
# deposited recipe does not list. 20 mM Tris titrated with HCl -> Cl⁻ = C·0.859
# = 17.18 mM (pK(22 °C) = 8.156, I ≈ 0.217 M: 0.2 M NaCl and the protonated Tris with its
# chloride; γ₁ = 0.744). Titrant: HCl (paper: "Tris-HCl" in the purification
# buffers of the same Methods; SASBDB buffer name: Tris-HCl). pK(T) basis: Goldberg,
# Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902);
# the pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount. The fraction is Davies-corrected (A = 0.509) at
# the self-consistent ionic strength. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift and ±2 % on C, as in SASDL27 and SASDL37 (recomputed here for 20 mM / 0.2 M:
# 0.00084 M). Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not. Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.2, 0.002, "sodium chloride"),   # 200 mM NaCl, ±1%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017179, 0.000843, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.340 Å⁻¹,
# but the 305 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.22 and 38 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.31 Å⁻¹) has a median I/σ of 0.23.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model (8A4I chains C and D) has no hydrogens: pdb2pqr places them from the
# heavy atoms, as for the other DNA entries (the DNA names DG DA DT DC are the standard
# ones, with primed sugar atoms).
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    refChi2 = "CRYSOL 1.271",
    pdb = "SASDP74_fit2_model1.pdb",
    fit = "SASDP74_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # 8A4I chains C,D (12-bp AT-rich duplex), no H; deposited χ² = 1.271
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdp74` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdp74` below is the whole story (build the seed, then sample it).
function seedSasdp74(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdp74(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdp74(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdp74(run)

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
                fitCurve...; qMax = Q_MAX_FIT,
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

    # `@__DIR__` (this SASDP74/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
