# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDPL6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPL6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPL6: 5'-genomic RNA stem-loops 2 and 3 (SL2+3, 43 nt) of SARS-CoV-2 in
# phosphate conditions.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1038/s41467-023-38882-y (Nat. Commun. 2023, SARS-CoV-2 N protein NTD with
# 5'-genomic RNA elements), read as the PMC full text. Read: "SEC-SAXS measurements were
# performed at 293 K at the EMBL P12 BioSAXS beamline at PETRAIII ... in standard phosphate
# buffer"; "NTD standard buffer (25 mM KPi pH 6.5, 150 mM KCl)"; "The salt concentration of
# the final sample was adjusted to 150 mM KCl prior to further use. 2 mM of TCEP or DTT was
# added for samples to be used in SAXS and MALS"; "All shown data were recorded at 293 K in
# the standard NMR/phosphate buffer conditions". SASBDB names the reductant TCEP. The
# RNA-only SEC-SAXS runs (this entry) are in that buffer. The paper's text does not repeat
# the buffer inside the SAXS paragraph for the RNA runs, so the combination "standard
# phosphate buffer = 25 mM KPi pH 6.5 + 150 mM KCl" is the paper's standard buffer,
# confirmed by the SASBDB buffer line of the entry.
#
# Instrument and conditions: PETRA III EMBL P12 (SASBDB); wavelength 0.124 nm = 1.24 Å,
# energy = hc/λ ≈ 9999 eV; 20 °C = 293 K (paper).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit 1/nm), 2650 points, q from 0.0024 to
# 0.737 Å⁻¹ after dividing by NM_INV_PER_ANGSTROM_INV. The data extend beyond the
# depositor's fit: the depositor's fit ends at 0.4735 Å⁻¹, the curve at 0.737 Å⁻¹; the 950
# points above the fit range (σ > 0) have a median I/σ of 1.50 and 85 of them (9 %) have I ≤
# 0. q cut at 0.70 Å⁻¹ (`Q_MAX_FIT`): the 133 points above it (σ > 0, q 0.700-0.737 Å⁻¹)
# have 41 non-positive intensities (31 %, limit 25 %) and a median I/σ of 0.51, so the tail
# fails the usable-data rule; the 722 points of the 0.50-0.70 Å⁻¹ band just below the cut
# have 44 non-positive (6 %) and a median I/σ of 1.62, so the cut sits where the data become
# unusable, not earlier. The depositor fitted up to 0.473 Å⁻¹.
#
# Model and depositor fit: SASBDB gives one fit, CRYSOL (fit1) against
# SASDPL6_fit1_model1.pdb (one structure; 901 heavy atoms + 457 H; 43 residues). The .fit
# file: 1681 rows, q 0.0077-0.4735 Å⁻¹; the header reads "Chi^2: 1.189" and matches the
# recomputation; recomputed from the .fit columns over the usable rows: 1.1881; the
# depositor's χ² used here is 1.189. The deposited model carries 457 hydrogen records;
# pdb2pqr (AMBER, no PROPKA for the nucleic acid alone; PARSE + PROPKA for protein-nucleic
# acid files) rebuilds them at PH.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # qvals are in nm⁻¹; convert to Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.5, PH_METER_SIGMA   # paper and SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, wavelength 1.24 Å
const TEMPERATURE_C = 20.0   # paper (293 K)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). "25 mM potassium phosphate" is a mix of KH2PO4 and K2HPO4 at
# pH 6.5: the HPO4²⁻ fraction is 0.3196 (pK2 and its temperature dependence from Goldberg,
# Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH
# 3.6 kJ/mol, ΔCp -230 J/K/mol) with the pH taken as set at 22 ± 3 °C (ASSUMPTION: the paper
# does not say at which temperature the pH was set), Davies-corrected at I ≈ 0.191 M (0.15 M
# KCl + the phosphate and its potassium; the 2 mM TCEP is treated as a neutral molecule, as
# in the sibling scripts). σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift
# and ±2 % on C (0.0019 M on each species). The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    # 25 mM KPi, H2PO4⁻ part
    NonBiological(0.01701, 0.0019, "potassium dihydrogen phosphate"),
    # 25 mM KPi, HPO4²⁻ part
    NonBiological(0.00799, 0.0019, "dipotassium hydrogen phosphate"),
    NonBiological(0.15, 0.0015, "potassium chloride"),   # 150 mM, ±1 %
    NonBiological(0.002, 0.00004, "tcep"),   # 2 mM TCEP (SASBDB), ±2 %
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from the
# diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and bins the
# curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the hydrogens are built by pdb2pqr at PH (see the model note above).
const ADD_HYDROGENS = true

# Largest q fitted (Å⁻¹); Inf = the whole curve (see the q note in the header).
const Q_MAX_FIT = 0.7

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.189",
    pdb = "SASDPL6_fit1_model1.pdb",
    fit = "SASDPL6_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = CRYSOL 1.189
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

# Builds the Seed that `runSasdpl6` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdpl6` below is the whole story (build the seed, then
# sample it).
function seedSasdpl6(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpl6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdpl6(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpl6(run)

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
    )

    # `@__DIR__` (this SASDPL6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
