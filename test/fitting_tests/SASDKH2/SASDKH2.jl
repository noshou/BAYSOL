# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDKH2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDKH2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDKH2: High conformational flexibility of the E2F1/DP1/DNA complex. The
# heterodimer of the E2F1 (UniProt Q01094 residues 121-301, 20.5 kDa) and DP1 (28.7 kDa)
# DNA-binding/dimerization domains with a 15-bp DNA duplex of the human E2F1 promoter (two
# 15-mer strands GATTTGGCGCGTAAA and CTAAACCGCGCATTT, 9.3 kDa); a protein-DNA complex, 58
# kDa.
#
# Paper: Saad D, Paissoni C, Chaves-Sanjuan A, Nardini M, Mantovani R, Gnesutta N,
# Camilloni C, J Mol Biol (2021), DOI 10.1016/j.jmb.2021.167119. SASBDB entry:
# https://www.sasbdb.org/data/SASDKH2/. The paper was read in full (round-4 audit,
# 2026-11-13): Materials and Methods, "Sample preparation for SEC-SAXS analysis" gives
# Buffer C = 50 mM Tris-Cl pH 8.0, 150 mM NaCl, 2 mM DTT, in which the 4 mg/ml complex
# was run on the in-line SEC column (the same as the SASBDB buffer fields); the model is
# the single-replica SAXS-driven MD model, CRYSOL χ² = 1.26 over 0.009-0.25 Å⁻¹ (the
# depositor's 1.262 and this script's q range). Wavelength and temperature are in the SI
# Table S2, which is not in the PDF: they are the SASBDB entry's values (the paper's
# main text states neither).
#
# Round-5 rescan (2026-11-13): confirmed, nothing new (Buffer C and the 1.26 chi2 are
# the only statements; wavelength and temperature remain SASBDB's, Table S2 not in PDF).
#
# Sample: SEC-SAS at up to 4.0 mg/ml. Instrument: Diamond Light Source B21 (X-ray
# synchrotron), Pilatus 2M, sample-detector distance 3.718 m; wavelength as stated in the
# entry, 0.0946 nm = 0.946 Å (the entry's own value, kept as deposited) => energy = hc/λ ≈
# 13106 eV (hc = 12398.42 eV·Å). Cell temperature: 20.0 °C (SASBDB cell temperature; the
# entry has no storage temperature).
#
# Buffer as deposited: "50 mM Tris-Cl pH 8.0, 150 mM NaCl and 2 mM DTT". The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Model (fit1_model1, "Custom in-house", GROMACS + PLUMED; the file is a trjconv frame of
# an MD run, "Protein in water t= 71750.00000 step= 287", with a CRYST1 box of 147.857 Å
# but NO water or ions in it): 7896 ATOM records, 3831 of them hydrogens; chain A = E2F1,
# residues 1-182; chain B = DP1, residues 183-436; chains C and D = the two DNA strands,
# 15 nucleotides each (437-451, 452-466) with the Amber residue names DA DT DG DC and the
# older atom names (O1P, O2P, H5T, 1H5'). The molecules are whole (no atom pair of a chain
# is farther than 6.2 Å apart consecutively, no periodic break) and the file's radius of
# gyration over all atoms, 37.4 Å, matches the CRYSOL header's RGT 37.83 Å. The file is
# used as downloaded (nothing was cleaned; the original is the fixture).
#
# Depositor fit: SASDKH2_fit1.fit, CRYSOL (software field "CRYSOL", no version), header
# "Dro:0.000 Ra:1.400 RGT:37.83 Vol: 72230. Chi^2: 1.262", the REST chi_square_value is
# 1.262 as well (they agree). Recomputed from the columns (q, I_exp, σ, I_fit; 1354 rows
# with data): (1/N) Σ ((I_exp − I_fit)/σ)² = 1.259 and with N − 1 = 1.259, so the header
# value is reproduced to within the rounding of its own convention. The .fit covers q
# 0.009-0.250 Å⁻¹, the data reach 0.44 Å⁻¹.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (the entry states angular units 1/A; q
# 0.0032-0.4396 Å⁻¹, 2451 rows, a 28-line REMARK header written by SCATTER; `_readCurve`
# keeps the numeric rows); 377 points have a non-positive intensity, dropped by
# `seedModel` after binning. The .fit is also in Å⁻¹ on the data's scale, I_fit is column
# 4, unscaled.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.946   # ≈ 13106 eV, from the stated 0.0946 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: "Tris-Cl" is modelled as Tris plus HCl at the
# molarity derived from the pK, no Tris-HCl salt is added. Assumed: 50 mM Tris titrated
# with HCl -> Cl⁻ = C·0.656 = 32.8 mM (pK(22 °C) = 8.156, I ≈ 0.183 M: 150 mM NaCl and the
# protonated Tris with its chloride; γ₁ = 0.751). Titrant: not stated; HCl for amine bases
# (Tris), NaOH for Good's buffers. pK(T) basis: Goldberg, Kishore & Lennen 2002 (J. Phys.
# Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902); the pH is taken as set at room
# temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. The fraction is Davies-corrected (A = 0.509) at the self-consistent ionic
# strength. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C, as
# in SASDAN8 and SASDRX8. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. DTT is taken as the neutral molecule. Every solute
# below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.15, 0.0015, "sodium chloride"),   # 150 mM NaCl, ±1%
    NonBiological(0.002, 4e-05, "dtt"),   # 2 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.032805, 0.00365, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.25 Å⁻¹. The data run to 0.440 Å⁻¹,
# but the 1065 points above 0.25 Å⁻¹ (σ > 0) have a median I/σ of 0.49 and 31 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.30 Å⁻¹) has a median I/σ of 0.72.
const Q_MAX_FIT = 0.25

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited MD frame already carries its hydrogens
# (Amber/GROMACS names, 3831), but, as for SASDM76 and SASDWZ9, pdb2pqr drops them and
# places its own from the heavy atoms, so the hydrogen set is consistent with the other
# entries. The file holds protein and DNA, which keeps PARSE and PROPKA at PH (the
# Hydrogenator rebuilds the 5' phosphate group and the old O1P/O2P/H5T names; see
# "Hydrogenation routes" in test/fitting_tests/README.md). The first run of this entry has
# not been checked by the author: see the entry notes.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.262",
    pdb = "SASDKH2_fit1_model1.pdb",
    fit = "SASDKH2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # E2F1/DP1 + 15-bp DNA, one MD frame; deposited χ² = 1.262
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

# Builds the Seed that `runSasdkh2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdkh2` below is the whole story (build the seed, then sample it).
function seedSasdkh2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdkh2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdkh2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdkh2(run)

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

    # `@__DIR__` (this SASDKH2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
