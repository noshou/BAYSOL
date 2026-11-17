# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMU4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMU4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMU4 (fit1): the ligand-binding domain of human retinoid X receptor α
# (RXRα LBD, 25.5 kDa per chain, a homodimer, SASBDB experimental MW 45 kDa), a single
# concentration (5.6 mg/mL) measured at EMBL X33. Publication: Belorusova A. et al.,
# "Solution Behavior of the Intrinsically Disordered N-Terminal Domain of Retinoid X
# Receptor α in the Context of the Full-Length Protein", Biochemistry 2016, 55, 2084,
# DOI 10.1021/acs.biochem.5b01122 (the entry is the LBD alone, which the paper uses as a
# reference for the constructs). Entry: https://www.sasbdb.org/data/SASDMU4/.
#
# Instrument (SASBDB): EMBL beamline X33, DORIS III (DESY, Hamburg), Pilatus 2M,
# wavelength 0.15 nm (SASBDB `xray_energy` is null, so hc/λ ≈ 8266 eV); the .dat header
# reads "dino_043.dat - 1.0*Aver(dino_042.dat,dino_044.dat) / 5.60" (a buffer average of
# two frames subtracted and scaled by the concentration, 07-Oct-2010). Cell temperature
# 10 °C (SASBDB; no storage temperature); the paper gives no temperature, so the SASBDB
# value is used and flagged.
#
# Buffer: SASBDB "20 mM Tris, 100 mM NaCl, 100 mM KCl, 5% glycerol, 2 mM Chaps, and 5 mM
# DTT", pH 7.5. The paper's Methods give the same two recipes, "20 mM Tris (pH 7.5), 100 mM
# NaCl, 100 mM KCl, 5% glycerol, 2 mM Chaps, and 5 mM DTT for the complexes without DNA"
# (and 50 mM NaCl/50 mM KCl for those with DNA); this entry has no DNA, so the first one.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; REST s_min 0.196 and s_max
# 6.016 nm⁻¹), converted to Å⁻¹ (÷10): q 0.0196-0.6016 Å⁻¹, 2130 rows, 8 with a
# non-positive intensity. No q cut: the median I/σ of the points above 0.3 Å⁻¹ is 2.8 and
# only 1 % are non-positive (the noise-floor rule is far from met). The depositor's CRYSOL
# curve ends at 0.350 Å⁻¹, so refChi2 is not like for like (the data to 0.60 Å⁻¹ are
# fitted here).
#
# Model and depositor fit: fit1 is a CRYSOL fit ("Custom in-house" model, type "atomic")
# against SASDMU4_fit1_model1.pdb, the RXRα LBD homodimer in two chains (A: residues
# 231-547 with 1809 atoms, B: residues 231-560 with 1837 atoms) plus 183 crystal waters
# (HETATM HOH, dropped by the loader: the hydration shell stands for them), 3646 records
# in all, no hydrogens, 3463 protein heavy atoms. The .fit layout is CRYSOL's with three
# columns, `q (Å⁻¹), I_exp, I_fit` (no σ column; the experimental column is the data
# scaled by 1/10 below q = 0.0196 as a placeholder), so the reference curve is column 3.
# The header reads "rxrlbd.p  Dro:0.000  Ra:1.800  RGE:24.06  RGT:24.16  Vol: 57347.
# Chi:1.410" and the SASBDB chi_square_value is 1.9881. They DISAGREE only in what they
# are: 1.410² = 1.988, so the header "Chi:" is χ and SASBDB's number is χ². The χ² is
# the comparable one: refChi2 is 1.988 (the header value 1.410 is a χ, not comparable).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, SASBDB wavelength 0.15 nm
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the
# deposited recipe does not list. 20 mM Tris titrated with HCl -> Cl⁻ = C·0.859 = 17.18 mM
# (pK(22 °C) = 8.157, I ≈ 0.217 M: 0.1 M NaCl, 0.1 M KCl and the protonated Tris with its
# chloride; the same numbers as SASDP74 apart from the split salt). Titrant: HCl (the
# SASBDB name gives no acid; the paper says only "Tris (pH 7.5)"; HCl is the ordinary
# choice and is assumed). The pH is taken as set at room temperature (22 ± 3 °C), although
# the sample was measured at 10 °C; the Tris pH shifts by -0.03 per K, the σ of 0.847 mM
# already carries the ±3 °C. Method, see SASDP74. Only the counter-ion is modelled.
#
# Glycerol 5 %: v/v is assumed (w/v is not excluded): 0.05 L/L x 1261 g/L / 92.094 g/mol =
# 0.6846 M, ±5 %. CHAPS 2 mM and DTT 5 mM as stated (±2 %). The solute table's CHAPS row is
# a 3D-RISM estimate (basis "estimated"), not a measured volume. Every solute below is
# in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM NaCl, ±2%
    NonBiological(0.1, 0.002, "potassium chloride"),   # 100 mM KCl, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.01718, 0.000847, "chloride"),
    NonBiological(0.6846, 0.0342, "glycerol"),   # 5 % v/v glycerol, ±5%
    NonBiological(0.002, 0.00004, "chaps"),   # 2 mM CHAPS, ±2%
    NonBiological(0.005, 0.0001, "dtt"),   # 5 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut (see the Source): the data run to 0.6016 Å⁻¹ with a median I/σ of 2.8 above
# 0.3 Å⁻¹, and the depositor's fit stops at 0.350 Å⁻¹.
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH. The 183 HOH
# records are waters, which the loader drops.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.988",
    pdb = "SASDMU4_fit1_model1.pdb",
    fit = "SASDMU4_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
    rescale = false,
    software = "CRYSOL",
),   # RXRα LBD homodimer, no H, 183 waters; deposited χ² = 1.988 (header χ 1.410)
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut: `Q_MAX_FIT` is infinite).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdmu4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdmu4` below is the whole story (build the seed, then sample it).
function seedSasdmu4(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdmu4(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdmu4(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdmu4(run)

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

    # `@__DIR__` (this SASDMU4/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
