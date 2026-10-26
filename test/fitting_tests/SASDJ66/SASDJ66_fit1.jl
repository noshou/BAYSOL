using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJ66")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJ66.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJ66_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJ66_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 2)

# has 2 lines of headers, and 5 lines of trailer (frame lists) at the end; need to skip.
# The file also has overlong trailer lines, so `readdlm` pads it to 52 columns; only
# columns 1-3 of the 1029 data rows are used.
qvals = Float64.(raw[1:1029, 1])
I_exp = Float64.(raw[1:1029, 2])
σ_exp = Float64.(raw[1:1029, 3])

# q is already in Å⁻¹ (range 0.0103-0.4946, SASBDB "1/A", ESRF BM29 SEC-SAXS); no unit
# conversion is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDJ66/); paper: Miele AE et al. 2021,
# Eur. Biophys. J. ("Biophysical characterization of the complex between the
# iron-responsive transcription factor Fep1 and DNA"), DOI 10.1007/s00249-020-01489-y.
# Not open access, no PDF is bundled, so every number below is SASBDB's.
#
#   Sample:   "GATA double strand DNA": the GATA element of the Fep1 promoter,
#             24-mer double strand DNA (2 x 6.827 kDa; SASBDB sequence of one strand
#             gattgaactgataattttacta), SEC-SAXS (HPLC-SEC in line), max 1.35 mg/mL
#   Buffer:   "50 mM MOPS, 50 mM NaCl", pH 7.0
#   Temp.:    20 °C (cell and storage)
#   Beamline: ESRF BM29, Pilatus 1M, wavelength 0.09999 nm = 0.9999 Å => energy =
#             hc/λ = 12398.42 eV·Å / 0.9999 Å ≈ 12400 eV
#   Model:    SASDJ66_fit1_model1.pdb, taken from PDB 4L62 (header "PA2196 bound to its
#             operator DNA"): chains Q (residues 1-22) and R (4-25), the two DNA strands
#             (895 atoms, no hydrogens, no HETATM, non-A chain ids), deposited with the
#             CRYSOL fit1 (χ² 1.044)

const PH, σ_PH = 7.0, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 0.9999   # ≈ 12400 eV, from SASBDB's 0.09999 nm
const TEMPERATURE_C = 20.0                      # 20 °C, SASBDB

# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 50 mM MOPS titrated with NaOH -> Na⁺ = C·0.4285 (pK(22 °C) = 7.222;
# ΔH 21.1 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.071 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.050, 0.0005, "sodium chloride"),   # 50 mM NaCl, ±1%
    NonBiological(0.050, 0.001, "mops"),                # 50 mM MOPS, ±2%
    # Na⁺ counter-ion from NaOH titration of MOPS (see note above)
    NonBiological(0.021423, 0.003193, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.45: SASBDB's .dat reaches 0.4946 Å⁻¹, but beyond ≈ 0.45 the SEC-SAXS curve of this
# 6.8 kDa duplex is at the noise floor (151 of its 1029 points are ≤ 0).
const Q_MAX_FIT = 0.45

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# DNA only: Pdb2pqr without PROPKA (nucleotides are taken as supplied, not titrated).
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

# Builds the Seed that `run_sasdj66_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdj66_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdj66_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdj66_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdj66_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdj66_fit1()

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

# `@__DIR__` (this SASDJ66/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
