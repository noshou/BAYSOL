# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR_FIT1 =
joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDA52")
const _DATA_PATH_FIT1   = joinpath(_FIXTURE_DIR_FIT1, "experimental_data", "SASDA52.dat")
const _PDB_PATH_FIT1    = joinpath(_FIXTURE_DIR_FIT1, "SASDA52_fit1_model1.pdb")
const _FIT_PATH_FIT1    = joinpath(_FIXTURE_DIR_FIT1, "SASDA52_fit1.fit")

raw_fit1 = readdlm(_DATA_PATH_FIT1; skipstart = 4)

# 4 lines of headers (date/title line + 3 "<file> Conc = ... N1 = ... N2 = ..."
# lines), then 2168 data rows (matches "N2 = 2168" in the header), followed by
# a text footer (per-frame processing metadata for the sample and the two
# buffer frames it was averaged/subtracted against) that we simply don't slice
# into.
qvals_fit1 = Float64.(raw_fit1[1:2168, 1])
I_exp_fit1 = Float64.(raw_fit1[1:2168, 2])
σ_exp_fit1 = Float64.(raw_fit1[1:2168, 3])

# qvals are in nm⁻¹ (SASBDB REMARK 265 in SASDA52_fit2_model1.pdb states
# "ANGLE RANGE(MIN-MAX) (INVERSE NANOMETERS): 0.087-6.014", matching this
# file's raw range exactly); must convert to Å⁻¹.
qvals_fit1 = qvals_fit1 ./ NM_INV_PER_ANGSTROM_INV

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Structure source: Raj, Ramaswamy & Plapp 2014, Biochemistry 53(37):5791-5803
# ("Yeast Alcohol Dehydrogenase Structure and Catalysis"),
# doi:10.1021/bi5006442. This is a pure X-ray
# crystallography paper (PDB entry 4W6Z, the structure behind
# SASDA52_fit1_model1.pdb).
#
#     BEAMLINE NAME                     : X33 (EMBL BioSAXS, DORIS, DESY Hamburg)
#     WAVE LENGHT (A)                   : 0.15
#     CELL/STORAGE TEMPERATURE(CELSIUS) : 10
#     CONCENTRATION RANGE(MG/ML)        : None-24.89
#     BUFFER NAME                       : PBS
#     BUFFER PH-PK                      : 7.400-7.000
#
# "WAVE LENGHT (A): 0.15" is read as a units slip (Å entered in nm): X33 on
# DORIS operated at  ~1.5 Å (0.15 nm), and 0.15 Å would be
# ~83 keV, absurd for a bending-magnet SAXS beamline so we use
# λ = 1.5 Å => energy = hc/λ ≈ 8266 eV (hc = 12398.42 eV·Å).
#
# The experimental_data/SASDA52.dat file's header records
# "Sample: adh_1_high c= 24.890 mg/ml".
#
# "BUFFER PH-PK: 7.400-7.000" is read as pH 7.4 (standard PBS pH) with the
# second figure an adjacent (mislabeled) pKa-ish field, not a second pH.

const PH_FIT1, σ_PH_FIT1 = 7.4, PH_METER_SIGMA

const ENERGY_EV_FIT1        = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, X33 at (corrected) 1.5 Å
const TEMPERATURE_C_FIT1    = 10.0             # 10°C, SASBDB metadata
const IONIC_STRENGTH_M_FIT1 = 0.172           # standard 1x PBS, see SOLUTES_FIT1 below

# ADH1 sequence, read  off SASDA52_fit1_model1.pdb chain A, residues
# 1-347 (CA atoms only). Chain A's 694 CA records are two concatenated copies
# of the same 347-residue protomer (residues 1-347, then 348-694 repeating the
# identical sequence); chain B repeats the pattern, i.e. this PDB models the
# biological tetramer (paper: "Yeast ADH1 is a tetramer of four identical
# subunits with 347 amino acid residues each") as two chains of two protomers each.
const ADH1_SEQ_FIT1 =
    "SIPETQKGVIFYESHGKLEYKDIPVPKPKANELLINVKYSGVCHTDLHAWHGDWPLPVKL" *
    "PLVGGHEGAGVVVGMGENVKGWKIGDYAGIKWLNGSCMACEYCELGNESNCPHADLSGYT" *
    "HDGSFQQYATADAVQAAHIPQGTDLAQVAPILCAGITVYKALKSANLMAGHWVAISGAAG" *
    "GLGSLAVQYAKAMGYRVLGIDGGEGKEELFRSIGGEVFIDFTKEKDIVGAVLKATDGGAH" *
    "GVINVSVSEAAIEASTRYVRANGTTVLVGMPAGAKCCSDVFNQVVKSISIVGSYVGNRAD" *
    "TREALDFFARGLVKSPIKVVGLSTLPEIYEKMEKGQIVGRYVVDTSK"

# Monomer mass from the paper's tetramer mass ("a calculated mass
# of 147396 Da" for the four identical 347-residue subunits, Introduction,
# p.5791) divided by 4.
const ADH1_MW_FIT1         = 147396.0 / 4   # ≈ 36849 g/mol
const ADH1_CONC_MG_ML_FIT1 = 24.890
const ADH1_MOLARITY_FIT1   = ADH1_CONC_MG_ML_FIT1 / ADH1_MW_FIT1  # ≈ 0.676 mM
const ADH1_MOLARITY_σ_FIT1 = MOLARITY_REL_SIGMA * ADH1_MOLARITY_FIT1

# Buffer components. "PBS" is named in the SASBDB metadata with no explicit
# recipe given (and the structure paper doesn't describe the SAXS buffer at
# all), so we use the standard 1x PBS formulation (137 mM NaCl, 2.7 mM KCl,
# 10 mM Na2HPO4, 1.8 mM KH2PO4, pH ≈ 7.4).
const SOLUTES_FIT1 = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    # 137 mM, standard 1x PBS, ±5% (assumed recipe)
    NonBiological(0.137, 0.00685, "sodium chloride"),
    # 2.7 mM, standard 1x PBS, ±5%
    NonBiological(0.0027, 0.000135, "potassium chloride"),
    # 10 mM Na2HPO4, standard 1x PBS, ±5%
    NonBiological(0.010, 0.0005, "disodium hydrogen phosphate"),
    # 1.8 mM KH2PO4, standard 1x PBS, ±5%
    NonBiological(0.0018, 0.00009, "potassium dihydrogen phosphate"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT_FIT1 = 0.5   # matches SASDA52_fit1.fit's q-range (0 to 0.5 Å⁻¹)

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS_FIT1 = true   # runs Pdb2pqr at PH_FIT1

"""
    fit_subset_fit1() -> (q, I, σ)

`qvals_fit1`/`I_exp_fit1`/`σ_exp_fit1` restricted to `q ≤ Q_MAX_FIT_FIT1` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset_fit1()
    keep = findall(
        i -> qvals_fit1[i] ≤ Q_MAX_FIT_FIT1 && σ_exp_fit1[i] > 0,
        eachindex(qvals_fit1),
    )
    return qvals_fit1[keep], I_exp_fit1[keep], σ_exp_fit1[keep]
end

# Builds the Seed that `run_sasda52_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasda52_fit1` below is the whole story (build the seed, then sample it).
function seed_sasda52_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset_fit1()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH_FIT1), ENERGY_EV_FIT1, q_fit, I_fit, σ_fit,
        PH_FIT1, σ_PH_FIT1, SOLUTES_FIT1;
        add_hydrogens = ADD_HYDROGENS_FIT1, t = TEMPERATURE_C_FIT1,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasda52_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasda52_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

resf1, fflogf1, natmsf1, (qf1, If1, σf1) = run_sasda52_fit1()

fit_fit1, divergence_rate_fit1, map_resf1, quantile_resf1 = resf1

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH_FIT1; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT_FIT1,
)
BAYSOL.results(
    resf1, (qf1, If1, σf1);
    dir = @__DIR__,
    name = "res_fit1",
    references = reference,
    form_factor_log = fflogf1,
    n_atoms = natmsf1,
    ref_chi2 = "CRYSOL χ² 2.48 (χ² ≈ 6.2)",
    run_log = true,
)

# `@__DIR__` (this SASDA52/ folder), not the caller's cwd.
BAYSOL.print_summary(resf1)
