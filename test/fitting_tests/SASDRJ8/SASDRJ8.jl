# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDRJ8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRJ8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRJ8: de novo enterobactin esterase Syn-F4 (K4T variant), a dimer of 2 x
# 12.453 kDa = 24.9 kDa. fit2 is the atomic crystal structure (PDB 8H7D, built in COOT:
# chains A and B, 1596 heavy atoms, no hydrogens and no waters; residues 1-2, 49-56 and
# 101-102 of each chain are not located, REMARK 465) with the depositor's CRYSOL fit, chi²
# 0.060 (Dro 0.025 e/Å³, Ra 1.800 Å, from the .fit header). fit1 is a DAMMIN dummy-atom
# model (no atomic coordinates) and is not used. SASBDB lists no PDB link for the models;
# the model file is the one SASBDB serves as SASDRJ8_fit2_model1.pdb.
#
# Paper: Kurihara K, Umezawa K, Donnelly AE, Sperling B, Liao G, Hecht MH, Arai R,
# Proc Natl Acad Sci U S A 120 (2023), DOI 10.1073/pnas.2218281120 (not bundled; the
# conditions below are SASBDB's entry metadata, https://www.sasbdb.org/data/SASDRJ8/).
# SAXS at BL-10C (Photon Factory, KEK), Pilatus3 2M, wavelength 0.12 nm = 1.2 Å =>
# energy = hc/λ ≈ 10332 eV, 4.50 mg/ml, 20 °C (SASBDB cell temperature), 30 frames of
# 5 s. The measured dimer is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Buffer as deposited (SASBDB sample buffer and experiment text):
#
#     25 mM MES, 100 mM NaCl, 10% glycerol, 200 mM Arg-HCl, pH 6.5
#
# Curve units: the SASBDB .dat is in nm⁻¹ (its trailer says "X axis OutputType: Q [nm-1]";
# the entry's angular unit is 1/nm) with a one-line header and 20 trailing lines of beam
# information; it is converted to Å⁻¹ (÷10). The depositor's .fit file is in Å⁻¹ (columns
# q, I_exp, σ, I_fit; the rows below the first data point have σ = 0 and fall outside
# the plotted range). The depositor's chi² of 0.06 comes from errors that SASBDB's entry
# describes as "severely overestimated", so it is not comparable with a chi² near 1.
# The deposited CRYSOL fit used the default hydration-shell radius Ra = 1.8 Å.
#
# This is an amino-acid-additive test: 200 mM arginine (as the hydrochloride) is a large
# co-solute.

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - acid or base setting pH 6.5 is not stated: NaOH assumed for MES (modelled below)
#   - glycerol "10%" is not stated as v/v or w/v: v/v assumed (modelled below)

const PH, σ_PH      = 6.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # ≈ 10332 eV, from the stated 0.12 nm = 1.2 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer components (the measured dimer is deliberately NOT listed). Every solute is a row
# of the bundled tables: "mes", "sodium chloride", "glycerol", "arginine" (neutral amino
# acid, 127.4 mL/mol) and "chloride" / "sodium(1+)" (ions).
#
# Arg-HCl: arginine hydrochloride is the arginium cation (net +1 at pH 6.5, the side chain
# pK ≈ 12.5 and the α-amino pK ≈ 9) with one chloride, so 200 mM Arg-HCl is modelled as
# 200 mM arginine (the table's neutral amino acid, as in SASDT55) plus 200 mM chloride as
# the counter-anion (the chloride row, as the Tris-HCl counter-ion of SASDJ72). ±2 % on
# both.
#
# Glycerol 10 % (v/v assumed, as in SASDJ72): 10 mL/100 mL * 1.2613 g/mL / 92.094 g/mol
# * 1000 ≈ 1.369 M, ±5 % because the v/v -> molarity step is an approximation.
#
# MES counter-ion (titrant not stated; NaOH for Good's buffers, as in SASDF42): 25 mM MES
# titrated to pH 6.5 with NaOH -> Na⁺ = C·f. The deprotonated fraction is
# f = r/(1 + r) with r = 10^(pH - pK)/γ₁, pK(22 °C) = 6.296 (Goldberg, Kishore & Lennen
# 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902), pH taken as set at room
# temperature, and the Davies activity coefficient γ₁ of a monovalent ion at the ionic
# strength I (A = 0.509). I is solved self-consistently from Na⁺ (100 mM NaCl + the
# NaOH), Cl⁻ (100 mM NaCl + 200 mM Arg-HCl), arginium⁺ (200 mM) and MES⁻: I ≈ 0.317 M,
# γ₁ = 0.733, f = 0.686, Na⁺ = 17.14 mM. σ combines σ_PH, the temperature term (±0.027 pK,
# the ±3 °C of SASDF42), ±0.02 pK, 30 % of the Davies shift and ±2 % on C, as in SASDF42.
# Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not. The Arg-HCl solution itself needs no further titrant: its
# chloride is already counted.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.025, 0.0005, "mes"),               # 25 mM MES, ±2%
    NonBiological(0.100, 0.001, "sodium chloride"),    # 100 mM NaCl, ±1%
    NonBiological(1.369, 0.0685, "glycerol"),          # 10 % v/v glycerol (assumed), ±5%
    NonBiological(0.200, 0.004, "arginine"),           # 200 mM Arg-HCl: the arginine, ±2%
    NonBiological(0.200, 0.004, "chloride"),           # 200 mM Arg-HCl: the chloride, ±2%
    # Na⁺ counter-ion from NaOH titration of MES (see note above)
    NonBiological(0.017144, 0.001443, "sodium(1+)"),
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "acid or base setting pH 6.5 not stated: NaOH assumed for MES (modelled)",
    "glycerol 10% not stated as v/v or w/v: v/v assumed (modelled, ±5 %)",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDRJ8: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0125-0.7459 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.5 Å⁻¹ was used before, but the 281 points above 0.5
# Å⁻¹ (σ > 0) have a median I/σ of 0.50 and 0 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 0.50 ≥ 0.5; I ≤ 0 share 0 % < 25 %; rule in
# README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has heavy atoms only; pdb2pqr rebuilds the hydrogens (PROPKA at PH).
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    refChi2 = "CRYSOL 0.06",
    pdb = "SASDRJ8_fit2_model1.pdb",
    fit = "SASDRJ8_fit2.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 0.06 (CRYSOL, Ra 1.8; inflated errors)
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

# Builds the Seed that `runSasdrj8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdrj8` below is the whole story (build the seed, then sample it).
function seedSasdrj8(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdrj8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdrj8(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdrj8(run)

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

    # `@__DIR__` (this SASDRJ8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
