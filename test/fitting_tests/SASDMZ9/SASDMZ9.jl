# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMZ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1.dat")

# Unlike SASDMJ9, `experimental_data/` and `pddf/` are EMPTY for this case;
# the experimental curve ships directly as `SASDMZ9_fit1.dat` in the case
# root, and no GNOM .out pddf file is bundled.
#
# `SASDMZ9_fit1.dat` header:
#   # SAXS profile: number of points = 1211, q_min = 0.00297234626486897,
#   #   q_max = 0.345499873161316, ...
#   # offset = ..., scaling c = ..., Chi^2 = ...
#   #  q       exp_intensity   model_intensity error
# i.e. 3 comment/header lines, then 1211 data rows in columns
# (q, exp_intensity, model_intensity, error) -- this is itself a CRYSOL/FoXS-
# style four-column fit file (SASBDB's own reference fit), reused here as the
# plain experimental-curve source: we read columns 1/2/4 (q, exp_intensity,
# error) and ignore column 3 (model_intensity, someone else's fit, not ours).
# q is already in Å⁻¹ (q_max ≈ 0.345 Å⁻¹, consistent with the SASBDB entry's
# stated q range of 0.005-0.35 Å⁻¹ below) -- no nm⁻¹→Å⁻¹ conversion needed,
# unlike SASDMJ9.
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
# cell-surface amylosome".
#
# The paperlists six SASBDB entries: SASDMX9, SASDMY9, SASDMZ9, SASDN22, SASDN32,
# SASDN42; one per construct/ligand condition (p.16). Cross-checking residue coverage
# against Table 4 and the SASBDB entry itself identifies # SASDMZ9 specifically as
# Sas20d1-2 without ligands. SASBDB lists UniProt A0A2N0URA4 residues 27-559 and MW
# 57.2 kDa for this entry, matching Table 4's Sas20d1-2 (no maltoheptaose) sequence MW
# of 57.2 kDa, an order of magnitude larger than either single domain (Sas20d1 ≈ 25.9
# kDa, Sas20d2 ≈ 26.5 kDa). The entry paper also singles it out as highly flexible. The
# three PDBs are taken to be three representative conformers of the flexible ensemble.
#
# SASBDB entry metadata for SASDMZ9 (sasbdb.org/data/SASDMZ9/):
#   buffer: "phosphate buffered saline, 1 mM TCEP, pH 7"; 5 mg/ml; 23°C;
#   BioCAT 18ID (APS, Argonne); wavelength λ = 0.1033 nm; sample-detector
#   distance 3.6 m; Pilatus3 X 1M detector.
#
# p.14: "PBS (137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, and 1.8 mM KH2PO4 [pH = 7.4])". 

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
const ENERGY_EV        = HC_EV_ANGSTROM / 1.033
const TEMPERATURE_C    = 23.0            # 23°C, SASBDB
const IONIC_STRENGTH_M = 0.171           # PBS ionic strength, computed below

# Ionic strength of the PBS+TCEP buffer, I = 0.5 * Σ cᵢzᵢ², from the 
# PBS recipe above (Na2HPO4/KH2PO4 treated as fully dissociated at their
# formal ionic charges; TCEP's ionic contribution is small and omitted):
#   Na⁺ (NaCl):        0.137  * 1² = 0.1370
#   Cl⁻ (NaCl):        0.137  * 1² = 0.1370
#   K⁺  (KCl):         0.0027 * 1² = 0.0027
#   Cl⁻ (KCl):         0.0027 * 1² = 0.0027
#   Na⁺ (Na2HPO4, ×2): 0.020  * 1² = 0.0200
#   HPO4²⁻ (Na2HPO4):  0.010  * 2² = 0.0400
#   K⁺  (KH2PO4):      0.0018 * 1² = 0.0018
#   H2PO4⁻ (KH2PO4):   0.0018 * 1² = 0.0018
#   sum = 0.3430  =>  I = 0.5 * 0.3430 ≈ 0.1715 M

# Sas20d1-2 sequence, read from SASDMZ9_fit1_model1.pdb chain A
# (residues 32-555, 524 contiguous residues, no gaps). All three model PDBs
# share this exact sequence. This is a truncated span of the full Sas20d1-2 construct
# (UniProt A0A2N0URA4 residues 27-559 per SASBDB); the missing N-/C-terminal
# residues are presumably disordered/unmodelled in this structure.
const SAS20D1_2_SEQ =
    "EETDTKIYFDASNLPAEWGTTKTVYCHLYAVAGDDLPETSWQGKAEKCKKDTATGLYYFD" *
    "TAKLKSADGTNHGGLKDNADYAVIFSTIDTKSQSHQTCNVTLGKPCLGDTIYLTGGTVEN" *
    "TEDSSKRDFAATWKNNSDNYGPKAAITSLGHVTEGRFPIYLSRAEMVAQAIFNWAVKNPK" *
    "NYTPETVADICAQVEAEPMDVYNAYAEMYATELADPAAYPDCAPLTTVATLLGVDPSGTT" *
    "APATEEPTTVEPTTVEPTTVEPTTVEPTTEPTTEPATEPADATQYVVAGVESLTGYEWQG" *
    "SPALAPENVMTKSGDVYTKTFTAVPVGKSYQLKVVANTGDEQKWIGLDGTDNNVTFDVES" *
    "ACDVTVTFNPATNEIAVTGDGVKMVTDLEINSITVVGNGENSWLNGVAWGVDAEVNHMTQ" *
    "IADKVYQITYTGVESADAAYQFKFAVNDDWAANWGLPEQSAATIGEDFDLTFNGENMLLN" *
    "TVSAGYPEDSLVDVTITLDLTKFDYPSRSGAKANIKIDGNRVLL"

# Average mass from SAS20D1_2_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH); close to (but smaller than, since this modelled
# span is shorter than the full UniProt range) the paper's Table 4 sequence
# MW for Sas20d1-2 of 57.2 kDa.
const SAS20D1_2_MW         = 56385.18   # g/mol
const SAS20D1_2_CONC_MG_ML = 5.0   # SASBDB: 5 mg/ml
const SAS20D1_2_MOLARITY   = SAS20D1_2_CONC_MG_ML / SAS20D1_2_MW   # ≈ 8.87e-5 M ≈ 0.0887 mM
const SAS20D1_2_MOLARITY_σ = MOLARITY_REL_SIGMA * SAS20D1_2_MOLARITY

# Buffer components: PBS + 1 mM TCEP
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.137, 0.00137, "sodium chloride"),                # 137 mM NaCl, ±1%
    NonBiological(0.0027, 0.000027, "potassium chloride"),             # 2.7 mM KCl, ±1%
    # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.001800, 0.000036, "potassium dihydrogen phosphate"),
    # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.003014, 0.000988, "sodium dihydrogen phosphate"),
    # PBS phosphate at pH 7.0, HPO4²⁻ part
    NonBiological(0.006986, 0.000993, "disodium hydrogen phosphate"),
    NonBiological(0.001, 0.00002, "tcep"),                           # 1 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

Return the experimental data restricted to q <= Q_MAX_FIT with finite,
strictly positive experimental intensity and finite, non-negative
experimental uncertainty. Non-finite values are also excluded.
"""
function fit_subset()
    keep = findall(
        i ->
            isfinite(qvals[i]) &&
            isfinite(I_exp[i]) &&
            isfinite(σ_exp[i]) &&
            qvals[i] > 0 &&
            qvals[i] ≤ Q_MAX_FIT &&
            I_exp[i] > 0 &&
            σ_exp[i] >= 0,
        eachindex(qvals),
    )
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# ---------------------------------------------------------------------------
#                         Shared plotting helpers
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                         Generic run model function
# ---------------------------------------------------------------------------

# Builds the Seed that `run_sasdmz9_model` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the fit;
# if you are reading this script as an example you can skip it:
# `run_sasdmz9_model` below is the whole story (build the seed, then sample it).
function seed_sasdmz9_model(pdb_path::String; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(pdb_path), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdmz9_model(
    pdb_path::String;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdmz9_model(pdb_path; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

# ---------------------------------------------------------------------------
#                         Generic fit figure
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                         Generic residual figure
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                         Generic histogram figure
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                               Model 1
# ---------------------------------------------------------------------------

const _PDB_PATH1 = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model1.pdb")

# Model 1 is the intermediate-extent one of the three flexible-ensemble conformers
# described above (see solution-conditions discussion); the paper's own
# solution-SAXS D_max for unliganded Sas20d1-2 (Table 4: D_max ≈ 190-203 Å depending
# on method) is an average/envelope over this same flexible ensemble. The
# spherical-harmonic band limit lMax is not set here: `seed_model` takes it from the
# diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

result1, form_factor_log1, n_atoms1, (q_fit1, I_fit1, σ_fit1) =
    run_sasdmz9_model(_PDB_PATH1)

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
BAYSOL.results(
    result1, (q_fit1, I_fit1, σ_fit1);
    dir = @__DIR__, name = "res_model1",
    form_factor_log = form_factor_log1, n_atoms = n_atoms1,
    ref_chi2 = "MultiFoXS 3-state 2.65",
    run_log = true,
)

BAYSOL.print_summary(result1)

# ---------------------------------------------------------------------------
#                               Model 2
# ---------------------------------------------------------------------------

const _PDB_PATH2 = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model2.pdb")

# (lMax and the Shannon binning: see model 1.)

result2, form_factor_log2, n_atoms2, (q_fit2, I_fit2, σ_fit2) =
    run_sasdmz9_model(_PDB_PATH2)

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
BAYSOL.results(
    result2, (q_fit2, I_fit2, σ_fit2);
    dir = @__DIR__, name = "res_model2",
    form_factor_log = form_factor_log2, n_atoms = n_atoms2,
    ref_chi2 = "MultiFoXS 3-state 2.65",
    run_log = true,
)

BAYSOL.print_summary(result2)

# ---------------------------------------------------------------------------
#                               Model 3
# ---------------------------------------------------------------------------

const _PDB_PATH3 = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model3.pdb")

# (lMax and the Shannon binning: see model 1.)

result3, form_factor_log3, n_atoms3, (q_fit3, I_fit3, σ_fit3) =
    run_sasdmz9_model(_PDB_PATH3)

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
BAYSOL.results(
    result3, (q_fit3, I_fit3, σ_fit3);
    dir = @__DIR__, name = "res_model3",
    form_factor_log = form_factor_log3, n_atoms = n_atoms3,
    ref_chi2 = "MultiFoXS 3-state 2.65",
    run_log = true,
)

BAYSOL.print_summary(result3)
