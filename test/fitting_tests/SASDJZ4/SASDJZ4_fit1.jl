# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJZ4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJZ4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJZ4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJZ4_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJZ4: DNA-PK complex (DNA-PKcs with Ku70/Ku80 and DNA, protein plus DNA; the
# SASBDB entry lists four components of 69.8, 82.7, 468.3 and 2 x 10.6 kDa, model MW 642
# kDa, experimental MW 590 kDa), in 50 mM Tris-HCl, 100 mM NaCl, 5 % glycerol, 0.01 %
# sodium azide, pH 7.5.
#
# Publication: not read (the paper was unreachable: the PMC page answers with a bot
# challenge, other routes with an error). Buffer, pH, temperature and wavelength are the
# SASBDB entry's. Entry: https://www.sasbdb.org/data/SASDJZ4/.
#
# Instrument (SASBDB): wavelength 0.103 nm (SASBDB `xray_energy` is null, so the energy is
# hc/λ ≈ 12038 eV); sample-detector distance 1.5 m; cell temperature 20 °C.
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q from 0.0100 to 0.3226 Å⁻¹; 9 text
# lines that `_readCurve` skips). Intensities are arbitrary units.
#
# Model and depositor fit: the fit file header reads "SAXS profile: number of points =
# 500, q_min = 0.0100, q_max = 0.3226 ... offset = 0.0267, scaling c = 1.173e-07, Chi^2 =
# 3.6547", the format of FoXS/MultiFoXS (SASBDB: MultiFoXS 3.655). The SASBDB page shows
# one model; the fixture SASDJZ4_fit1_model1.pdb is a SINGLE structure (no MODEL records,
# chains A-E: 32904, 8925, 10603, 700 and 733 atoms), but the header's MultiFoXS label
# means the depositor may have fitted a multi-state ensemble (BILBOMD-style flexible
# model) of which only one state is deposited: if so the χ² 3.655 belongs to the ensemble
# and the single-structure fit here is not a like-for-like comparison. This could not be
# confirmed (paper unreachable). The model has 53865 ATOM records: 45126 heavy atoms plus
# 8739 hydrogens (the deposited file already carries hydrogens; with `addHydrogens`
# pdb2pqr re-places them). No HETATM. The nucleic acids are chains D and E (DA/DT/DG/DC,
# 700 and 733 atoms: two DNA strands, 69 P). The label "Chi^2" in the header is χ² (SASBDB
# chi_square_value 3.65469, the same), so no squaring.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A); no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB buffer pH 7.5

const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12038 eV, SASBDB wavelength 0.103 nm
const TEMPERATURE_C = 20.0   # SASBDB cell temperature (storage not given)

# Counter-ion: Tris-HCl at a pH is modelled as Tris base plus HCl (the convention of the
# other scripts), the titrant amount from Goldberg's pK (Tris pK 8.072 at 25 °C, ΔH 47.45
# kJ/mol; Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902), moved to 22 °C (pH set at room temperature, 22 ± 3 °C, whatever the
# measurement temperature) by van't Hoff, Davies-corrected at the self-consistent ionic
# strength. The σ combines σ_pH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
# Only the counter-ion is modelled. Here Tris 50 mM at pH 7.5, I(others) = 0.5 x (NaCl 0.1
# + NaCl 0.1 + azide 2 x 0.001538) = 0.1015 M: protonated fraction 0.856, Cl⁻ = 42.81 mM,
# σ 2.26 mM. Glycerol 5 % is assumed v/v (the SASBDB field gives no unit): 1.261 g/ml,
# 92.09 g/mol, 684.6 mM, ±2 %. Sodium azide 0.01 % is assumed w/v: 0.1 g/l / 65.01 g/mol =
# 1.538 mM.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),                    # 50 mM Tris, ±2%
    NonBiological(0.1, 0.002, "sodium chloride"),          # 100 mM NaCl, ±2%
    NonBiological(0.6846265772, 0.01369253154, "glycerol"), # 5 % (v/v assumed), ±2%
    NonBiological(0.001538, 0.0000308, "sodium azide"),    # 0.01 % (w/v assumed), ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.042807, 0.002262, "chloride"),
]
# The omissions listed above, one line each. Every run of this script, and every
# developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "glycerol 5 % and azide 0.01 % units not stated (v/v and w/v assumed)",
    "deposited model may be one state of a multi-state (MultiFoXS) fit, unconfirmed",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDJZ4: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model already has hydrogens; with `ADD_HYDROGENS` pdb2pqr/PROPKA place
# them at PH (as for the hydrogen-free models of the other scripts).
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdjz4Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdjz4Fit1` below is the whole story (build the seed, then sample it).
function seedSasdjz4Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjz4Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdjz4Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjz4Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is FoXS's (fit1): three '#' header lines, then columns q (Å⁻¹),
# I_exp, σ, I_fit (the fit is the model with FoXS's offset and scale applied).
crysol = readdlm(_FIT_PATH; skipstart = 3)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "FoXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "FoXS 3.655",
    runLog = true,
)

BAYSOL.printSummary(result)
