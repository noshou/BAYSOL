# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDHX2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDHX2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDHX2 (fit1): human dehydrodolichyl diphosphate synthase (DHDDS, UniProt
# Q86SQ9; 39.1 kDa per chain, a homodimer, SASBDB experimental MW 78.1 kDa), SEC-SAXS.
# Publication: Lisnyansky Bar-El M. et al., "Structural Characterization of Full-Length
# Human Dehydrodolichyl Diphosphate Synthase Using an Integrative Computational and
# Experimental Approach", Biomolecules 2019, 9, 660, DOI 10.3390/biom9110660. Entry:
# https://www.sasbdb.org/data/SASDHX2/.
#
# Instrument (paper, Methods 2.5 and Table 1; SASBDB agrees): ESRF BM29, Pilatus 1M,
# sample-detector distance 2.867 m, wavelength 1.0 Å (hc/λ ≈ 12398 eV), q 0.0025-0.5 Å⁻¹,
# in-line SEC (Superdex 200 Increase 10/300), 1 s frames, "data were collected in-line at
# 20 ◦C": the cell temperature is 20 °C (paper and SASBDB).
#
# Buffer: SASBDB "Tris-HCl, 150 mM NaCl, 20 mM 2-mercaptoethanol and 0.02% Triton-X100",
# pH 7.5; the paper (Methods 2.5): "pre-equilibrated with Tris-HCl, pH 7.5, 150 mM NaCl,
# 20 mM β-mercaptoethanol, and 0.02% Triton X-100". NEITHER source gives the Tris
# concentration of the SAXS buffer. ASSUMED: 25 mM, the Tris/HCl concentration of the
# other buffers of the same paper (the HDX-MS buffers of its Supplementary Material, "25 mM
# Tris/HCl, pH 7.4, 150 mM NaCl, 10 mM β-mercaptoethanol, 0.02% Triton X-100"), with a
# generous ±20 %. The Triton X-100 percentage is taken as w/v (see the buffer note).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; REST s_min 0.173 and
# s_max 3.0 nm⁻¹), three columns q, I, σ written in scientific notation with three
# significant digits, so 226 of the 604 rows repeat the q of a neighbour (the values at
# the high-q end are rounded to 0.01 nm⁻¹ while the grid step is about 0.0047 nm⁻¹);
# the rows are kept as deposited and in order (`seedModel` bins the curve). q 0.0173-0.30
# Å⁻¹ after the conversion (÷10), the same grid as the depositor's FoXS fit. 74 rows have a
# non-positive intensity. No q cut: above 0.2 Å⁻¹ the median I/σ is 0.72 and 24 % of the
# 213 points are non-positive, so the noise-floor rule (median I/σ < 0.5 and at least 25 %
# non-positive) is not met.
#
# Model and depositor fit: fit1 is FoXS (SASBDB software "FoXS", REST chi_square_value
# 1.03317) against SASDHX2_fit1_model1.pdb, a MODELLER homology model of the dimer (type
# "atomic"; MODELLER objective function 19808.4; templates 5hxn and 6acs plus a
# co-evolution model of the C-terminal domain, see the paper's Figure 5): chains S and T,
# 2752 heavy atoms each (residues -6 to 333), 5504 in all, no hydrogens, no waters, no
# HETATM. The .fit layout (FoXS): `# q exp_intensity error model_intensity`, q in Å⁻¹
# (not nm⁻¹); the header offset is -0.0353 and the scaling c = 4.404e-8; `model_intensity`
# is on the scale of the data (all `Reference` uses). The paper quotes the same value (its
# Figure 5B: χ² = 1.03). refChi2 is 1.033.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, the stated wavelength 1.0 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 25 mM Tris (assumed, see Source) titrated with HCl -> Cl⁻ = C·0.8575 =
# 21.44 mM (pK(22 °C) = 8.157, I ≈ 0.171 M: 0.15 M NaCl and the protonated Tris with its
# chloride). Titrant: HCl (SASBDB and paper: "Tris-HCl"). The σ of the chloride, 4.4 mM,
# follows from the ±20 % on the Tris concentration (the ±0.1 pH, ±3 °C, ±0.02 pK and the
# Davies term add little to it). Method, see SASDP74. Only the counter-ion is modelled.
#
# 2-mercaptoethanol 20 mM (the paper's SAXS buffer; ±2 %). NaCl 150 mM (±2 %).
#
# Triton X-100 0.02 %: v/v or w/v is not stated, taken as w/v: 0.2 g/L / 646.85 g/mol
# (the average molecule, C34H62O11 for 9.5 ethylene oxide units) = 0.309 mM; v/v (density
# 1.07 g/mL) would be 7 % more; ±10 % is used. This is about the critical micelle
# concentration (0.2-0.9 mM); the table value for Triton X-100 is derived (TX-114 plus
# the ethylene-oxide increment, `polymers.tsv`, basis "derived"), not measured. Every
# solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.005, "tris"),   # 25 mM Tris (ASSUMED), ±20%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.02144, 0.004401, "chloride"),
    NonBiological(0.02, 0.0004, "2-mercaptoethanol"),   # 20 mM, ±2%
    Polymer(0.000309, 0.000031, "Triton X-100"),   # 0.02 % (w/v assumed), ±10%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the data end at 0.30 Å⁻¹, the same q as the depositor's fit, and the
# noise-floor rule is not met (see the Source).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "FoXS 1.033",
    pdb = "SASDHX2_fit1_model1.pdb",
    fit = "SASDHX2_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),   # MODELLER dimer, no H; deposited χ² = 1.033
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

# Builds the Seed that `runSasdhx2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdhx2` below is the whole story (build the seed, then sample it).
function seedSasdhx2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdhx2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdhx2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdhx2(run)

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

    # `@__DIR__` (this SASDHX2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
