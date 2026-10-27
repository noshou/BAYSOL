using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDF95")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDF95.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDF95_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDF95_fit2.fit")

raw = readdlm(_DATA_PATH; skipstart = 2)

# has 2 lines of headers (a blank line and "Sample: ..."), and 2 lines of trailer
# ("range-from"/"range-to") at the end; need to skip. CRLF line endings. The trailer rows
# pad `readdlm` with strings, so only the numeric rows 1-844 are converted (columns 1-3).
qvals = Float64.(raw[1:844, 1])
I_exp = Float64.(raw[1:844, 2])
σ_exp = Float64.(raw[1:844, 3])

# q is already in Å⁻¹ (range 0.0070-0.3348, SASBDB "1/A", SSRF BL19U2 merged curve); no unit
# conversion is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDF95/); paper: Liu Y, Gao Z, Liu G,
# Geng Z, Dong Y, Zhang H 2020, Front. Microbiol. 10:3158 ("Structural Insights Into the
# Transcriptional Regulation of HigBA Toxin-Antitoxin System by Antitoxin HigA in
# Pseudomonas aeruginosa"), DOI 10.3389/fmicb.2019.03158. No PDF is bundled, so every
# number below is SASBDB's.
#
#   Sample:   PaHigA-DNA complex: antitoxin HigA dimer (2 x 11.248 kDa) bound to a 32-bp
#             DNA duplex (2 x 10.006 kDa), 42.5 kDa in total; 1-5 mg/mL, merged curve
#   Buffer:   "20 mM Tris, 300 mM NaCl, 5% (v/v) glycerol, and 1 mM PMSF", pH 8.0
#   Temp.:    23 °C (cell; storage 10 °C)
#   Beamline: SSRF BL19U2, Pilatus 1M, wavelength 0.103 nm = 1.03 Å => energy =
#             hc/λ = 12398.42 eV·Å / 1.03 Å ≈ 12037 eV
#   Model:    SASDF95_fit2_model1.pdb, the model of the depositor's CRYSOL fit2 (χ² 6.229):
#             chains A, B, E, F (HigA protein) and C, D (the DNA duplex), 4073 atoms, no
#             hydrogens, no HETATM; the CRYSOL curve stops at 0.330 Å⁻¹

const PH, σ_PH = 8.0, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12037 eV, from SASBDB's 0.103 nm
const TEMPERATURE_C = 23.0                    # 23 °C, SASBDB cell temperature

# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.661 (pK(22 °C) = 8.156).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.313 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
# Glycerol: 5 % v/v taken as 0.6846 M (as in SASDJ62, SASDJ72). PMSF: our own estimated
# table entry, as in SASDYW6 (it hydrolyzes in water; its ρₑ impact at 1 mM is minimal).
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.020, 0.0004, "tris"),                     # 20 mM Tris, ±2%
    NonBiological(0.300, 0.003, "sodium chloride"),           # 300 mM NaCl, ±1%
    NonBiological(0.6846265772, 0.01369253154, "glycerol"),   # 5 % v/v = 684.6 mM, ±2%
    NonBiological(0.001, 0.00005, "pmsf"),                    # 1 mM PMSF, ±5% (unstable)
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.013234, 0.001459, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.3: the depositor's CRYSOL fit2 stops at 0.330 Å⁻¹ and the merged .dat at 0.335; the
# cut keeps the well-measured part of the curve (3 of the 844 points are ≤ 0).
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has no hydrogens. It holds protein and DNA, so
# `seed_model` runs PROPKA for the protein at PH and takes the nucleotides as supplied.
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

# Builds the Seed that `run_sasdf95_fit2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdf95_fit2` below is the whole story (build the seed, then sample it).
function seed_sasdf95_fit2(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdf95_fit2(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdf95_fit2(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdf95_fit2()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit2", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "CRYSOL 6.229",
    run_log = true,
)

# `@__DIR__` (this SASDF95/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
