# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWS5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWS5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWS5: A protein-dependent riboswitch activates ribosomal frameshifting in
# cardioviruses (the 2A protein of Theiler's murine encephalomyelitis virus bound to its
# 37-nt stimulatory-element RNA pseudoknot, 1:1 complex, 28.8 kDa).
#
# Paper: Betts J, et al., Molecular Cell (2026). The bioRxiv preprint of the same work
# (10.1101/2025.07.17.665365) WAS consulted: its Table 2 and the SEC-SAXS and CORAL
# methods give the sample, buffer and model below.
# SASBDB entry: https://www.sasbdb.org/data/SASDWS5/
#
# Sample: 2A-RNA complex at 7.95 mg/ml, 50 µl injected on an in-line SEC column
# (Superdex 75 Increase 5/150), 41 frames of 0.25 s averaged; SASBDB cell temperature
# 20.0 °C. Instrument: PETRA III EMBL P12, Pilatus 6M, 3 m, wavelength 0.123983 nm =
# 1.23983 Å => energy = hc/λ ≈ 10000 eV (hc = 12398.42 eV·Å).
#
# Buffer: the paper says the complex was prepared "in an identical buffer" to the
# RNA-only sample, "20 mM HEPES pH 7.4, 400 mM KCl, 2% v/v glycerol, 1 mM DTT" (Table 2;
# the SASBDB buffer field is empty). That is the buffer of SASDWS5 and it is used as is.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (`_readCurve` keeps the numeric rows) and is
# converted to Å⁻¹ (÷10). Rows with a non-positive intensity are dropped by `seedModel`
# after binning.
#
# Model (fit1, CORAL "mix" model, PDB 9RVP derived): the protein (chain A) and the RNA
# (chain B, 37 nt) are all-atom, taken from the 9RVP crystal structure; CORAL represented
# the flexible N- and C-terminal extensions as 29 dummy residues (`UNK`, one C-alpha
# each), which BAYSOL cannot treat as atoms (`dummyLikeResidues`: undefined behaviour).
# The fitted file `SASDWS5_fit1_model1_atomistic.pdb` is the SASBDB model with exactly
# those 29 `ATOM ... UNK` lines removed (1822 -> 1793 atoms, nothing else touched, no
# hydrogens in either); the original `SASDWS5_fit1_model1.pdb` stays beside it. The
# depositor's CRYSOL fit includes the 29 dummy atoms, so the two curves differ by the
# missing extensions (about 3 kDa of the 28.8 kDa). The RCSB file 9RVP.pdb is kept for
# comparison and is not fitted. Round 7 (AUDIT7): every solution condition is stated by
# the preprint or SASBDB, so the entry is restored; the missing extensions (about 10 % of
# the mass, one C-alpha per residue in the depositor's curve) are a KNOWN model deficiency
# and the χ² can be expected to exceed the depositor's 1.114 for that reason.
#
# Depositor fit: CRYSOL, header "Chi^2: 1.114"; the SASBDB REST value is also 1.114, and
# recomputing the reduced χ² from the .fit columns (q, I_exp, σ, I_fit) gives 1.1137, so
# 1.114 is used. Rows at q = 0 with σ = 0 are dropped by the comparison. The entry's
# fit2 (MONSA) is a dummy-bead model and is not fitted.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.23983   # ≈ 10000 eV, from the stated 0.123983 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed:
# 20 mM HEPES titrated with NaOH ->
# Na⁺ = C·0.463 (pK(22 °C) = 7.600; the titrant could equally be KOH, the difference is
# negligible).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.409 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
# 2 % v/v glycerol = 0.2738 M (ρ = 1.261 g/mL, MW = 92.094 g/mol), ±5 % because it is a
# v/v -> molarity conversion (as SASDJ72).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM, ±2%
    NonBiological(0.4, 0.004, "potassium chloride"),   # 400 mM, ±1%
    NonBiological(0.2738, 0.01369, "glycerol"),   # 2 % v/v, ±5%
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.009262, 0.001339, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole curve is fitted. The data reach 0.742 Å⁻¹ but the depositor's
# CRYSOL fit stops at 0.40 Å⁻¹, so the refChi2 is not like for like. Above 0.4 Å⁻¹ the
# median I/σ is 2.3 (4 % of the points have I ≤ 0).

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has no hydrogens; pdb2pqr places them on the protein and the RNA.
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.114 (CORAL mix model, with dummy residues)",
    pdb = "SASDWS5_fit1_model1_atomistic.pdb",
    fit = "SASDWS5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 1.114 (CRYSOL, CORAL model incl. 29 dummy residues)
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdws5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdws5` below is the whole story (build the seed, then sample it).
function seedSasdws5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdws5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdws5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdws5(run)

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

    # `@__DIR__` (this SASDWS5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
