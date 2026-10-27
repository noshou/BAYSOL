using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological, Polymer
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDN32")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDN32_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDN32_fit1_model1.pdb")

# As with SASDMZ9, `experimental_data/` and `pddf/` are EMPTY for this case;
# the experimental curve ships directly as `SASDN32_fit1.dat` in the case
# root, and no GNOM .out pddf file is bundled.
#
# `SASDN32_fit1.dat` header:
#   # SAXS profile: number of points = 1211, q_min = 0.00297234626486897,
#   #   q_max = 0.345499873161316, ...
#   # offset = ..., scaling c = ..., Chi^2 = ...
#   #  q       exp_intensity   model_intensity error
# i.e. 3 comment/header lines, then 1211 data rows in columns
raw = readdlm(_DATA_PATH; skipstart = 3)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 4])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Cerqueira et al. 2022, J. Biol. Chem. 298(5):101896, "Sas20 is a
# highly flexible starch-binding protein in the Ruminococcus bromii
# cell-surface amylosome", doi:10.1016/j.jbc.2022.101896.
#
# The paper's "Data availability" paragraph (p.16) lists six SASBDB
# accessions for its SEC-SAXS runs: SASDMX9, SASDMY9, SASDMZ9, SASDN22,
# SASDN32, SASDN42.
#
# Buffer: same generic SEC-SAXS Materials & Methods paragraph as SASDMZ9
# (p.16, "SEC–SAXS experiments") applies.

# pH: the PBS recipe quoted above (p.14, pH 7.4) is from the paper's cell-washing
# / mass-spec methods, not the SAXS section, which names no buffer. The SAXS
# buffer is only given by SASBDB ('phosphate buffered saline, 1 mM TCEP, pH 7'),
# so pH 7.0 is used. The recipe's NaCl/KCl and total phosphate (11.8 mM) are
# kept; the phosphate is re-split at pH 7.0 (HPO4²⁻ fraction 0.592): pK2 from
# Goldberg, Kishore & Lennen 2002 (DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol,
# ΔCp −230 J/K/mol) at 22 °C, Davies-corrected at I ≈ 0.166 M (pK2' ≈ 6.84). The
# 1.8 mM KH2PO4 is kept as the K⁺ carrier and the rest is sodium phosphate.
const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB

# ≈ 12001 eV, from SASBDB's stated λ = 0.1033 nm = 1.033 Å
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033
const TEMPERATURE_C = 23.0            # 23°C, SASBDB
# PBS ionic strength, identical buffer recipe to SASDMZ9
const IONIC_STRENGTH_M = 0.171

# Sas20d2 sequence, read directly off SASDN32_fit1_model1.pdb
const SAS20D2_SEQ =
    "ADATQYVVAGVESLTGYEWQGSPALAPENVMTKSGDVYTKTFTAVPVGKSYQLKVVANTG" *
    "DEQKWIGLDGTDNNVTFDVESACDVTVTFNPATNEIAVTGDGVKMVTDLEINSITVVGNG" *
    "ENSWLNGVAWGVDAEVNHMTQIADKVYQITYTGVESADAAYQFKFAVNDDWAANWGLPEQ" *
    "SAATIGEDFDLTFNGENMLLNTVSAGYPEDSLVDVTITLDLTKFDYPSRSGAKANIKIDG" *
    "NRVLL"

# Average mass from SAS20D2_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH); ≈ 26.32 kDa, matching Table 4's Sas20d2 sequence
# MW of 26.5 kDa (small difference from the exact modelled span vs. the
# paper's own construct boundary) and SASBDB's own stated MW (25.9 kDa).
const SAS20D2_MW         = 26319.06   # g/mol
const SAS20D2_CONC_MG_ML = 10.0   # SASBDB: 10.00 mg/ml
const SAS20D2_MOLARITY   = SAS20D2_CONC_MG_ML / SAS20D2_MW   # ≈ 3.80e-4 M ≈ 0.380 mM
const SAS20D2_MOLARITY_σ = MOLARITY_REL_SIGMA * SAS20D2_MOLARITY

# Buffer components: PBS + 1 mM TCEP (identical recipe to SASDMZ9, see
# solution-conditions discussion above) plus the 5 mM maltoheptaose ligand
# this entry was collected with.
#
# maltoheptaose: V0 = 694.8 ± 5.8 cm³/mol (Hourston 1967 PhD thesis,
# Table 6.1, 25 °C, measured from the partial specific volume 0.600 ±
# 0.005 mL/g); an oligomer, so it is a `Polymer` solute (BulkElectronDensity/Polymers).
# 5 mM is not negligible next to the 137 mM NaCl / 10 mM phosphate buffer
# components, so it is included (previously omitted because no entry existed).
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.137, 0.00137, "sodium chloride"),               # 137 mM NaCl, ±1%
    NonBiological(0.0027, 0.000027, "potassium chloride"),            # 2.7 mM KCl, ±1%
    # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.001800, 0.000036, "potassium dihydrogen phosphate"),
    # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.003014, 0.000988, "sodium dihydrogen phosphate"),
    # PBS phosphate at pH 7.0, HPO4²⁻ part
    NonBiological(0.006986, 0.000993, "disodium hydrogen phosphate"),
    NonBiological(0.001, 0.00002, "tcep"),                          # 1 mM TCEP, ±2%
    # 5 mM maltoheptaose ligand, ±2%
    Polymer(0.005, 0.0001, "maltoheptaose"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdn32` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdn32` below is the whole story (build the seed, then sample it).
function seed_sasdn32(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdn32(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdn32(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdn32()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res",
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "FoXS 1.01",
    run_log = true,
)

# `@__DIR__` (this SASDN32/ folder), not the caller's cwd.

BAYSOL.print_summary(result)
