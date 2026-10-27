using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDZC6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDZC6_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDZC6_fit1_model1.pdb")

# ---------------------------------------------------------------------------
#                             Experimental data
# ---------------------------------------------------------------------------
#
# SASDZC6_fit1.dat's header:
#
#   # SAXS profile: number of points = 1287, q_min = 0.00627815257757902,
#     q_max = 0.299867391586304, delta_q = 0.000228296453350486
#   # offset = 0.00000000000000, scaling c = 4.04022206112393e-10,
#     Chi^2 = 1.67566640325040
#   #  q       exp_intensity   model_intensity error
#
# i.e. this is a FoXS-style fit1 dump (q, experimental I, FoXS-model I,
# error), already in Å⁻¹ (q_max ≈ 0.30 Å⁻¹ matches the paper's stated
# "~0.006-0.5 Å⁻¹" detector range, clipped by reduction)
# so no nm⁻¹ → Å⁻¹ conversion is needed here.
raw = readdlm(_DATA_PATH; skipstart = 3)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 4])   # column 3 is FoXS's own model curve, not used

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: bioRxiv preprint 2026.04.01.715611v3 (posted 2026-07-30,
# doi:10.64898/2026.04.01.715611),
# "SAXS sample preparation" and "SAXS data collection and analysis"
# paragraphs (Materials & Methods).
#
# SEC buffer immediately preceding the SAXS samples ("SAXS sample
# preparation" paragraph):
#
#     25 mM Tris pH 8.0, 100 mM NaCl, 2 mM MgCl2, 2% glycerol
#
# The paper studies the same PDE6/GαT* system under three conditions
# (apo/no-ligand, +8-Br-cGMP substrate analog, +udenafil inhibitor); the
# bundled structure SASDZC6_fit1_model1.pdb is PDB 7JSN, which
# the paper's identifies as "the previously solved cryoEM structure (PDB: 7jsn) 
# i.e. 7JSN is the rigid model for the udenafil-bound "symmetric staging" state, 
# not the 8-Br-cGMP or apo conditions. So SASDZC6 is taken to be the udenafil sample:
#
#     "Samples of PDE6 at 0.3 mg/mL with 2-fold excess GαT* containing
#      either 3 μM udenafil or 1 mM 8-Br-cGMP" ("SAXS sample preparation")
#
# using the udenafil branch (3 μM udenafil; Fig. 5's legend separately
# calls this "3-fold excess udenafil" relative to PDE6; the two
# descriptions are roughly consistent given PDE6's ~1.4 μM molarity
# at 0.3 mg/mL, so we take the explicit "3 μM" figure from Methods as authoritative).
#
# Beamline: CHESS 7A1 station, x-ray energy stated directly as 11.3 keV ("SAXS data
# collection and analysis" paragraph. Temperature: "continuously oscillated at room
# temperature"; 25°C used. SASBDB's cell_temperature is 4 °C, but the paper's SAXS Methods
# ("SAXS data collection and analysis") explicitly describe acquisition at room temperature,
# so the paper is followed (4 °C is most likely the sample-storage temperature).

const PH, σ_PH = 8.0, PH_METER_SIGMA

const ENERGY_EV        = 11_300.0   # 11.3 keV, stated directly (CHESS 7A1)
const TEMPERATURE_C    = 25.0      # "room temperature"; no exact value stated
const IONIC_STRENGTH_M = 0.100 + 3 * 0.002
# 100 mM NaCl (1:1, contributes its own molarity to I) + 2 mM MgCl2
# (2:1 salt, I = 1/2 Σ cᵢzᵢ² = 1/2·(0.002·2² + 0.004·1²) = 0.006 M, i.e. 3×
# its molarity) ≈ 0.106 M. Tris itself (a nonionic buffer near pH 8, mostly
# neutral free-base at this pH) is not counted.

# ---------------------------------------------------------------------------
#                    Sequences and complex stoichiometry
# ---------------------------------------------------------------------------
#
# SASDZC6_fit1_model1.pdb == PDB 7JSN, "the 2GαT*-PDE6 complex" (the
# paper's own name for this assembly): a heterohexamer of
#   chain A: PDE6α  (DBREF UNP P11541, 1-859)
#   chain B: PDE6β  (DBREF UNP P23439, 1-853)
#   chain C, D: PDE6γ, two identical copies (DBREF UNP P04972, 1-87)
#   chain E, F: GαT* (activated transducin-α mutant, His-tagged
#       construct), two identical copies (DBREF UNP P04695 1-215 +
#       216-294 engineered + 295-350 UNP)
# Sequences read off file's SEQRES records.
# PDE6γ (C) and GαT* (E) SEQRES are identical in their two chains, so
# each unique chain is represented by one Protein solute below, at a
# molarity that accounts for its per-complex number (see PDE6G_MOLARITY, GAT_MOLARITY).

const PDE6A_SEQ =
    "MGEVTAEEVEKFLDSNVSFAKQYYNLRYRAKVISDLLGPREAAVDFSNYHALNSVEESEI" *
    "IFDLLRDFQDNLQAEKCVFNVMKKLCFLLQADRMSLFMYRARNGIAELATRLFNVHKDAV" *
    "LEECLVAPDSEIVFPLDMGVVGHVALSKKIVNVPNTEEDEHFCDFVDTLTEYQTKNILAS" *
    "PIMNGKDVVAIIMVVNKVDGPHFTENDEEILLKYLNFANLIMKVFHLSYLHNCETRRGQI" *
    "LLWSGSKVFEELTDIERQFHKALYTVRAFLNCDRYSVGLLDMTKQKEFFDVWPVLMGEAP" *
    "PYAGPRTPDGREINFYKVIDYILHGKEDIKVIPNPPPDHWALVSGLPTYVAQNGLICNIM" *
    "NAPSEDFFAFQKEPLDESGWMIKNVLSMPIVNKKEEIVGVATFYNRKDGKPFDEMDETLM" *
    "ESLTQFLGWSVLNPDTYELMNKLENRKDIFQDMVKYHVKCDNEEIQTILKTREVYGKEPW" *
    "ECEEEELAEILQGELPDADKYEINKFHFSDLPLTELELVKCGIQMYYELKVVDKFHIPQE" *
    "ALVRFMYSLSKGYRRITYHNWRHGFNVGQTMFSLLVTGKLKRYFTDLEALAMVTAAFCHD" *
    "IDHRGTNNLYQMKSQNPLAKLHGSSILERHHLEFGKTLLRDESLNIFQNLNRRQHEHAIH" *
    "MMDIAIIATDLALYFKKRTMFQKIVDQSKTYETQQEWTQYMMLDQTRKEIVMAMMMTACD" *
    "LSAITKPWEVQSKVALLVAAEFWEQGDLERTVLQQNPIPMMDRNKADELPKLQVGFIDFV" *
    "CTFVYKEFSRFHEEITPMLDGITNNRKEWKALADEYETKMKGLEEEKQKQQAANQAAAGS" *
    "QHGGKQPGGGPASKSCCVQ"

const PDE6B_SEQ =
    "MSLSEGQVHRFLDQNPGFADQYFGRKLSPEDVANACEDGCPEGCTSFRELCQVEESAALF" *
    "ELVQDMQENVNMERVVFKILRRLCSILHADRCSLFMYRQRNGVAELATRLFSVQPDSVLE" *
    "DCLVPPDSEIVFPLDIGVVGHVAQTKKMVNVQDVMECPHFSSFADELTDYVTRNILATPI" *
    "MNGKDVVAVIMAVNKLDGPCFTSEDEDVFLKYLNFGTLNLKIYHLSYLHNCETRRGQVLL" *
    "WSANKVFEELTDIERQFHKAFYTVRAYLNCDRYSVGLLDMTKEKEFFDVWPVLMGEAQAY" *
    "SGPRTPDGREILFYKVIDYILHGKEDIKVIPSPPADHWALASGLPTYVAESGFICNIMNA" *
    "PADEMFNFQEGPLDDSGWIVKNVLSMPIVNKKEEIVGVATFYNRKDGKPFDEQDEVLMES" *
    "LTQFLGWSVLNTDTYDKMNKLENRKDIAQDMVLYHVRCDREEIQLILPTRERLGKEPADC" *
    "EEDELGKILKEVLPGPAKFDIYEFHFSDLECTELELVKCGIQMYYELGVVRKFQIPQEVL" *
    "VRFLFSVSKGYRRITYHNWRHGFNVAQTMFTLLMTGKLKSYYTDLEAFAMVTAGLCHDID" *
    "HRGTNNLYQMKSQNPLAKLHGSSILERHHLEFGKFLLSEETLNIYQNLNRRQHEHVIHLM" *
    "DIAIIATDLALYFKKRTMFQKIVDESKNYEDRKSWVEYLSLETTRKEIVMAMMMTACDLS" *
    "AITKPWEVQSKVALLVAAEFWEQGDLERTVLDQQPIPMMDRNKAAELPKLQVGFIDFVCT" *
    "FVYKEFSRFHEEILPMFDRLQNNRKEWKALADEYEAKVKALEEDQKKETTAKKVGTEICN" *
    "GGPAPRSSTCRIL"

const PDE6G_SEQ =
    "MNLEPPKAEIRSATRVMGGPVTPRKGPPKFKQRQTRQFKSKPPKKGVQGFGDDIPGMEGL" *
    "GTDITVICPWEAFNHLELHELAQYGII"

const GAT_SEQ =
    "MAHHHHHHAMGAGASAEEKHSRELEKKLKEDAEKDARTVKLLLLGAGESGKSTIVKQMKI" *
    "IHQDGYSLEECLEFIAIIYGNTLQSILAIVRAMTTLNIQYGDSARQDDARKLMHMADTIE" *
    "EGTMPKEMSDIIQRLWKDSGIQACFDRASEYQLNDSAGYYLSDLERLVTPGYVPTEQDVL" *
    "RSCVKTTGIIETQFSFKDLNFRMFDVGGLRSERKKWIHCFEGVTAIIFCVALSDYDMVLV" *
    "EDDEVNRMHESMHLFNSICNNKWFTDTSIILFLNKKDLFEEKIKKSPLSICFPDYAGSNT" *
    "YEEAGNYIKVQFLELNMRRDVKEIYSHMTCATDTQNVKFVFDAVTDIIIKENLKDCGLFA" *
    "AATETSQVAPA"

# Average masses from each *_SEQ (ExPASy average residue masses + one
# water for the terminal H/OH), same convention as SASDMJ9.
const PDE6A_MW = 99_340.97   # g/mol
const PDE6B_MW = 98_330.79   # g/mol
const PDE6G_MW = 9_669.23   # g/mol  (per PDE6γ monomer)
const GAT_MW   = 42_163.08   # g/mol  (per GαT* monomer)

# One PDE6 holoenzyme complex = PDE6α + PDE6β + 2×PDE6γ.
const PDE6_COMPLEX_MW = PDE6A_MW + PDE6B_MW + 2 * PDE6G_MW   # ≈ 217010 g/mol

const PDE6_CONC_MG_ML = 0.3
# mg/mL numerically equals g/L, so molarity = (mg/mL) / (MW g/mol).
const PDE6_MOLARITY = PDE6_CONC_MG_ML / PDE6_COMPLEX_MW   # ≈ 1.38 μM

# "2-fold excess GαT*" (SAXS sample preparation paragraph): total GαT*
# protein molarity in the tube, whether bound to PDE6 or free.
const GAT_MOLARITY = 2 * PDE6_MOLARITY   # ≈ 2.77 μM

# PDE6γ appears as 2 copies per PDE6 holoenzyme, so its total protein
# molarity is likewise 2× the complex molarity.
const PDE6G_MOLARITY = 2 * PDE6_MOLARITY   # ≈ 2.77 μM

const PDE6_MOLARITY_σ  = MOLARITY_REL_SIGMA * PDE6_MOLARITY
const PDE6G_MOLARITY_σ = MOLARITY_REL_SIGMA * PDE6G_MOLARITY
const GAT_MOLARITY_σ   = MOLARITY_REL_SIGMA * GAT_MOLARITY

# udenafil (the 3 μM small-molecule PDE6 inhibitor in this sample): no
# measured V0 exists, so the table entry is our own estimate,
# 399.6 ± 16.0 cm³/mol (basis=predicted; RDKit vdW-volume + polar-site
# regression, method and validation in BulkElectronDensity/README.md,
# "Adding a missing solute"). At 3 μM (roughly 2000× more dilute than the
# 100 mM NaCl / 25 mM Tris buffer components) its contribution to the bulk
# electron density is negligible regardless, so the estimate's ±4 % error
# is irrelevant here; it is included so the solute list is complete.

# Buffer components. Tris/NaCl/MgCl2/glycerol all resolve against
# src/BulkElectronDensity/NonBiological/nonbio_lookup.json. Counter-ions (added
# 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 25 mM Tris titrated with HCl -> Cl⁻ = C·0.650 (pK(22 °C) =
# 8.156). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg,
# Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902)
# pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.122 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled;
# the volume change of the buffer's own (de)protonation is not. Titrant: not stated;
# HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.100, 0.001, "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.025, 0.0005, "tris"),              # 25 mM Tris pH 8.0, ±2%
    NonBiological(0.002, 0.00004, "magnesium chloride"),# 2 mM MgCl2, ±2%
    # 2% v/v ≈ 0.274 M (ρ=1.261 g/mL, MW=92.09 g/mol), ±2%
    NonBiological(0.274, 0.0055, "glycerol"),
    NonBiological(0.000003, 0.00000015, "udenafil"),    # 3 μM udenafil (Methods), ±5%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.016258, 0.001823, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3   # SASDZC6_fit1.dat's q_max (≈0.2999 Å⁻¹)

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# PDB 7JSN's four chains each start with a different free
# N-terminal residue (chain A/PDE6α: Glu8, chain B/PDE6β: Ala19, chains
# C,D/PDE6γ: Ile10, chains E,F/GαT*: Ala27. PROPKA splits these
# termini's protonation-state decisions at PH = 8.0.
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

# Builds the Seed that `run_sasdzc6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdzc6` below is the whole story (build the seed, then sample it).
function seed_sasdzc6(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdzc6(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdzc6(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdzc6()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res",
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "FoXS 1.68",
    run_log = true,
)

# `@__DIR__` (this SASDZC6/ folder), not the caller's cwd.

BAYSOL.print_summary(result)
