# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDK94")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDK94.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDK94_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDK94_fit1.fit")

# The .dat has 2 lines of header (CRLF line endings) and 11 lines of processing history at
# the end, which break `readdlm` (padded to many columns), so `_readCurve` (common.jl,
# numeric rows only) reads it: 2136 points.
qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 2136

# qvals are in nm⁻¹ (0.0896-6.00); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
# The curve runs to 0.60 Å⁻¹, so the whole range lies inside `Q_SANITY_RANGE`. No q cut: no
# point has I ≤ 0 and mean I/σ is about 3 up to the end, so the whole curve is fitted
# (the depositor's Pepsi-SAXS curve covers the same range, 0.009-0.60 Å⁻¹).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDK94 (sasbdb.org/data/SASDK94/); paper: Bandera AM
# et al. 2021, Nucleic Acids Res., "BusR senses bipartite DNA binding motifs by a unique
# molecular ruler architecture", DOI 10.1093/nar/gkab736 (PMID 34432045). The paper's
# methods text was not consulted (the PDF is not bundled).
#
#     20mM HEPES, pH6.5, 100mM NaCl, 3% glycerol (v/v)     (SASBDB: "BusR SEC buffer")
#
# BusR (Streptococcus agalactiae, 4 x 23.9 kDa) bound to a 46 bp dsDNA (2 x 28.4 kDa),
# 152.3 kDa in total; in-line SEC-SAXS (Superdex 200 Increase 10/300) of a 10 mg/mL
# injection at 20 °C, EMBL P12 (PETRA III), Pilatus 6M, wavelength 0.123981 nm =
# 1.23981 Å => energy = hc/λ ≈ 10 keV (hc = 12398.42 eV·Å). The measured complex is
# deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Model: SASDK94_fit1_model1.pdb, chains A, B, C, D (BusR, 4 x ~1600 atoms) and E, F (the
# two DNA strands, 46 nt); 8371 atoms, no hydrogens. It also holds 88 HETATM atoms
# (residues 2BA 1 and 2 of chain L, two cyclic-di-AMP molecules): 2BA is a non-polymer
# in the component table, so the loader is expected to drop it like the glycerol of
# SASDU29 (8283 atoms then enter the Seed). The buffer text lists no c-di-AMP, so it is
# not a solute.
#
# Curve units: the SASBDB .dat is in nm⁻¹ and is converted to Å⁻¹ (÷10). The comparison
# curve is the depositor's fit1 (columns q, I_exp, σ, I_fit; χ² 5.635 in the entry, 5.820
# in the file header), a Pepsi-SAXS-style output whose header ("Convex: Concave: Inner:")
# is the depositor's own contrast tool, as in SASDU29.

const PH, σ_PH = 6.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.23981   # ≈ 10000 eV, from the stated 0.123981 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB (cell)

# Buffer components (the measured complex is deliberately NOT listed). Counter-ion:
# setting the pH adds a titrant that the deposited recipe does not list. Assumed: 20 mM
# HEPES titrated with NaOH -> Na⁺ = C·0.0921 (pK(22 °C) = 7.601; pH 6.5 is well below the
# pK, so only 9 % of the HEPES is deprotonated). The pH is taken as set at room temperature
# (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature.
# pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902; HEPES 7.564, ΔH 21.0 kJ/mol); the fraction is Davies-corrected at
# I ≈ 0.102 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C.
# Only the counter-ion is modelled; the volume change of the buffer's own (de)protonation
# is not. Titrant: not stated; NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.020, 0.0004, "hepes"),              # 20 mM HEPES, ±2%
    NonBiological(0.100, 0.001, "sodium chloride"),     # 100 mM NaCl, ±1%
    # 3 % v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL) and MW
    # (92.094 g/mol): 3 mL glycerol/100 mL soln * 1.2613 g/mL / 92.094 g/mol * 1000
    # ≈ 0.4109 M. 5 % relative uncertainty as for the v/v glycerol of SASDJ72.jl.
    NonBiological(0.4109, 0.0205, "glycerol"),
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.001842, 0.000437, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE; PROPKA for the protein
# chains, none for the DNA)
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`. (`seedModel`
bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdk94Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdk94Fit1` below is the whole story (build the seed, then sample it).
function seedSasdk94Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdk94Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdk94Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdk94Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "Pepsi-SAXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "Pepsi-SAXS-style 5.635 (software not stated)",
    runLog = true,
)

# `@__DIR__` (this SASDK94/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
