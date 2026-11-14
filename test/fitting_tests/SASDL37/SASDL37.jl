# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDL37")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDL37.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDL37: complex with the human DR-alpha (HLA class II) DNA target. The N-Oct-3
# POU domain (POU-specific domain linked to the POU homeodomain, 18.8 kDa) in complex with
# a 24-bp human DR-alpha (AATTGATTTGCATTTTAATGGTCA / TGACCATTAAAATGCAAATCAATT) promoter
# fragment (two 24-mer strands, 14.8 kDa), 1:1; a protein-DNA complex, about 33.6 kDa.
# Entry title: "Fine-tuning of intrinsic N-Oct-3 POU domain allostery by regulatory DNA
# targets".
#
# Paper: Alazard R, Mourey L, Ebel C, Konarev P, Petoukhov M, Svergun D, Erard M, Nucleic
# Acids Research (2007), DOI 10.1093/nar/gkm453 (PMC1935007; open access, the SAXS
# Materials and Methods were consulted through Europe PMC). SASBDB entry:
# https://www.sasbdb.org/data/SASDL37/.
#
# Sample: "equimolecular" complex between 2.5 and 8 mg/ml (the entry states 3.5-3.9
# mg/ml), 60 s frames (15 frames). Instrument: EMBL X33 beamline at DORIS III, DESY (X-ray
# synchrotron), 1D gas detector, sample-detector distance 2.3 m, wavelength 0.15 nm = 1.5
# Å => energy = hc/λ ≈ 8266 eV (hc = 12398.42 eV·Å). Measured on 2004-05-26 (SASBDB).
# Temperature: 12 °C (paper: "The data were collected at 12°C"; the SASBDB cell
# temperature is 12.0).
#
# Buffer as deposited and in the paper: "50 mM Tris pH 7.5, 0.4 M NaCl, 2% glycerol, 2 mM
# DTT". The measured macromolecule is deliberately NOT a solute (see
# BulkElectronDensity.Solute).
#
# Model (fit1_model1, "Custom in-house" atomic model of the complex, written in the
# CRYSOL-era format "ENDR COMPLIES WITH FORMAT V. 2.0"): 4300-odd ATOM records with
# hydrogens (1961 H), no chain ids, no TER. The two DNA strands come first (24 + 24
# nucleotides, plain single-letter wwPDB names G C A T, primed atoms written with a star,
# O5*, and no 5'-phosphate on the first residue of each strand), then the 130 amino acids
# of the protein. The same legacy-name DNA is read by SASDAN8 and SASDRX8. The file is
# used as downloaded (nothing was cleaned; the original is the fixture).
#
# Depositor fit: SASDL37_fit1.fit, CRYSOL (no version), header "DRAL.pdb Dro:0.030
# Ra:1.400 RGT:28.27 Vol: 40020. Chi^2: 1.184", the REST chi_square_value is 1.184 as well
# (they agree). Recomputed from the columns (q, I_exp, σ, I_fit; 478 rows with data, a
# merge of two curves per the file): (1/N) Σ ((I_exp − I_fit)/σ)² = 1.1841 and with N − 1
# = 1.1866, so the header value is reproduced. The fit covers q 0.0136-0.344 Å⁻¹.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (the entry states angular units 1/A; q
# 0.0136-0.3439 Å⁻¹, 478 rows, 3 header lines and 8 trailer lines of merge bookkeeping,
# CRLF line endings; `_readCurve` keeps the numeric rows); 44 points have a non-positive
# intensity, dropped by `seedModel` after binning. The .fit is also in Å⁻¹ on the data's
# scale (I(0) is of the order of the data, not normalized), I_fit is column 4, unscaled.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, from the stated 0.15 nm
const TEMPERATURE_C = 12.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the
# deposited recipe does not list. Assumed: 50 mM Tris titrated with HCl -> Cl⁻ = C·0.861 =
# 43.05 mM (pK(22 °C) = 8.156, I ≈ 0.443 M: 0.4 M NaCl and the protonated Tris with its
# chloride; γ₁ = 0.732). Titrant: not stated; HCl for amine bases (Tris), NaOH for Good's
# buffers. pK(T) basis: Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231,
# DOI 10.1063/1.1416902); the pH is taken as set at room temperature (22 ± 3 °C), which
# fixes the counter-ion amount whatever the measurement temperature. The fraction is
# Davies-corrected (A = 0.509) at the self-consistent ionic strength. σ combines σ_PH, ±3
# °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C, as in SASDAN8 and SASDRX8. Only
# the counter-ion is modelled; the volume change of the buffer's own (de)protonation is
# not. 2 % glycerol is taken as v/v: 2 mL/100 mL · 1.261 g/mL / 92.094 g/mol = 0.2738 M,
# ±5 % because it is a v/v -> molarity conversion (as SASDWR5 and SASDJ72; the paper says
# only "2% glycerol"; owner decision 2026-11-13: a bare "2% glycerol" is v/v). DTT is the
# neutral molecule. Every solute below is in the
# bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.4, 0.004, "sodium chloride"),   # 400 mM NaCl, ±1%
    NonBiological(0.2738, 0.01369, "glycerol"),   # 2 % (v/v assumed) glycerol, ±5%
    NonBiological(0.002, 4e-05, "dtt"),   # 2 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.043047, 0.002103, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.344 Å⁻¹,
# but the 64 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.16 and 39 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.31 Å⁻¹) has a median I/σ of 0.59.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model already carries its hydrogens (old star names
# such as 1H2*, 1961 of them), but pdb2pqr drops them and places its own from the heavy
# atoms, so the hydrogen set is consistent with the other entries. The file holds protein
# and DNA, which keeps PARSE and PROPKA at PH; the DNA is written with legacy names and is
# repaired in the copy pdb2pqr sees (see "Hydrogenation routes" in
# test/fitting_tests/README.md). The first run of this entry has not been checked by the
# author: see the entry notes.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.184",
    pdb = "SASDL37_fit1_model1.pdb",
    fit = "SASDL37_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # POU + human DR-alpha DNA; deposited χ² = 1.184 (CRYSOL header and REST agree)
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

# Builds the Seed that `runSasdl37` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdl37` below is the whole story (build the seed, then sample it).
function seedSasdl37(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdl37(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdl37(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdl37(run)

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

    # `@__DIR__` (this SASDL37/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
