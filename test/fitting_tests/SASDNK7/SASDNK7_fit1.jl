using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDNK7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNK7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNK7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNK7_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 212)

# has 212 lines of header (a REMARK-like "# ..." block ending in "# Number of DATA: 841"),
# and no trailer: skip the block, then all 841 data rows follow.
qvals = Float64.(raw[1:841, 1])
I_exp = Float64.(raw[1:841, 2])
σ_exp = Float64.(raw[1:841, 3])

# q is already in Å⁻¹ (range 0.0087-0.5654, SASBDB "1/A", PF BL-10C); no unit conversion
# is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDNK7/); paper: Miyauchi K, Imamura H,
# Yamaoki Y, Kato M 2022, Data in Brief ("Small-angle X-ray scattering data of a
# guanine-rich DNA derived from the promoter region of c-MYC gene in solution"), DOI
# 10.1016/j.dib.2022.108285.
#
#   Sample:   MYC22-G14T/G23T (Pu22), a 22-mer guanine-rich DNA from the c-MYC promoter
#             (TGAGGGTGGGTAGGGTGGGTAA, 7.071 kDa, G-quadruplex with K⁺), 1.80 mg/mL
#             (one concentration), 30 x 2 s frames
#   Buffer:   "50 mM Tris, 30 mM KCl", pH 8.0
#   Temp.:    25 °C ("One solute concentration of 1.80 mg/ml was measured at 25°C")
#   Beamline: Photon Factory BL-10C (KEK), Pilatus3 2M, "wavelength of λ = 0.15 nm"
#             => 1.5 Å => energy = hc/λ ≈ 8265.6 eV
#   Model:    SASDNK7_fit1_model1.pdb (derived from PDB 1XAV), chain A, 22 nucleotides
#             with 249 hydrogens, plus two K⁺ ions as HETATM residues "K" (residues 30 and
#             31; 718 atoms in all); deposited with the CRYSOL fit1 (χ² 1.391)

const PH, σ_PH = 8.0, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8265.6 eV, from the stated 0.15 nm
const TEMPERATURE_C = 25.0                   # 25 °C, SASBDB

# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 50 mM Tris titrated with HCl -> Cl⁻ = C·0.6393 (pK(22 °C) = 8.156; ΔH
# 47.45 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.062 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.030, 0.0003, "potassium chloride"),   # 30 mM KCl, ±1%
    NonBiological(0.050, 0.001, "tris"),                   # 50 mM Tris, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.031963, 0.003652, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.5: the depositor's own fit (and its CRYSOL curve) stops at 0.5006 Å⁻¹; the data
# continue to 0.5654 Å⁻¹ but 54 of its 841 points are ≤ 0 and the tail is noise.
const Q_MAX_FIT = 0.5

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true although the model already carries 249 hydrogens, as for SASDWZ9:
# Pdb2pqr rebuilds the hydrogens from the heavy atoms.
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdnk7_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdnk7_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdnk7_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdnk7_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdnk7_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdnk7_fit1()

fit, divergence_rate, map_result, quantile_result = result

# The figures (terminal plots, pgfplots .tex, TSV) go before the report, so
# that their time is in its timing section.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
)

# `@__DIR__` (this SASDNK7/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
