using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDZC6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDZC6_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDZC6_fit1_model1.pdb")

# ---------------------------------------------------------------------------
#                             Experimental data
# ---------------------------------------------------------------------------
#
# SASDZC6_fit1.dat's own header (3 comment lines, not 5 like SASDMJ9's):
#
#   # SAXS profile: number of points = 1287, q_min = 0.00627815257757902,
#     q_max = 0.299867391586304, delta_q = 0.000228296453350486
#   # offset = 0.00000000000000, scaling c = 4.04022206112393e-10,
#     Chi^2 = 1.67566640325040
#   #  q       exp_intensity   model_intensity error
#
# i.e. this is a FoXS-style fit1 dump (q, experimental I, FoXS-model I,
# error), already in Å⁻¹ (q_max ≈ 0.30 Å⁻¹ matches the paper's stated
# "~0.006-0.5 Å⁻¹" detector range, clipped by this particular reduction) --
# unlike SASDMJ9's SASBDB .dat, no nm⁻¹ → Å⁻¹ conversion is needed here.
raw = readdlm(_DATA_PATH; skipstart = 3)

qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 4])   # column 3 is FoXS's own model curve, not used

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: bioRxiv preprint 2026.04.01.715611v3 (posted 2026-07-30, this
# fixture: test/fixtures/experiments/SASDZC6/2026.04.01.715611v3.full.pdf),
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
# bundled structure SASDZC6_fit1_model1.pdb is literally PDB 7JSN, which
# the paper's own discussion identifies as "the previously solved cryoEM
# structure (PDB: 7jsn) ... that stabilizes the activating GαT:PDEγ
# moieties ... In the presence of an inhibitor" (Discussion, ~line 665-668
# of the extracted text) -- i.e. 7JSN is the rigid model for the
# udenafil-bound "symmetric staging" state, not the 8-Br-cGMP or apo
# conditions. So SASDZC6 is taken to be the udenafil sample:
#
#     "Samples of PDE6 at 0.3 mg/mL with 2-fold excess GαT* containing
#      either 3 μM udenafil or 1 mM 8-Br-cGMP" ("SAXS sample preparation")
#
# using the udenafil branch (3 μM udenafil; Fig. 5's legend separately
# calls this "3-fold excess udenafil" relative to PDE6 -- the two
# descriptions are roughly consistent given PDE6's own ~1.4 μM molarity
# at 0.3 mg/mL, see PDE6_MOLARITY below -- we take the explicit "3 μM"
# figure from Methods as authoritative).
#
# Beamline: CHESS 7A1 station, x-ray energy stated directly as 11.3 keV
# ("SAXS data collection and analysis" paragraph) -- no wavelength→energy
# conversion needed here (unlike SASDMJ9's X33/1.54 Å case).
# Temperature: "continuously oscillated at room temperature"; 25°C used
# (also the only temperature this BAYSOL version supports).

const PH, σ_PH = 8.0, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV       = 11_300.0   # 11.3 keV, stated directly (CHESS 7A1)
const TEMPERATURE_C    = 25.0      # "room temperature"; only 25°C is supported
const IONIC_STRENGTH_M = 0.100 + 3 * 0.002
# 100 mM NaCl (1:1, contributes its own molarity to I) + 2 mM MgCl2
# (2:1 salt, I = 1/2 Σ cᵢzᵢ² = 1/2·(0.002·2² + 0.004·1²) = 0.006 M, i.e. 3×
# its molarity) ≈ 0.106 M. Tris itself (a nonionic buffer near pH 8, mostly
# neutral free-base at this pH) is not counted, matching SASDMJ9's
# treatment of its own Tris/DTT buffer components as ionic-strength-inert.

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
# Sequences read directly off this file's own SEQRES records (full
# construct as expressed, not just the modelled/resolved ATOM range).
# PDE6γ (C) and GαT* (E) SEQRES are identical between their two chains, so
# each unique chain is represented by ONE Protein solute below, at a
# molarity that already accounts for its per-complex copy number (see
# PDE6G_MOLARITY, GAT_MOLARITY).

const PDE6A_SEQ = "MGEVTAEEVEKFLDSNVSFAKQYYNLRYRAKVISDLLGPREAAVDFSNYHALNSVEESEIIFDLLRDFQDNLQAEKCVFNVMKKLCFLLQADRMSLFMYRARNGIAELATRLFNVHKDAVLEECLVAPDSEIVFPLDMGVVGHVALSKKIVNVPNTEEDEHFCDFVDTLTEYQTKNILASPIMNGKDVVAIIMVVNKVDGPHFTENDEEILLKYLNFANLIMKVFHLSYLHNCETRRGQILLWSGSKVFEELTDIERQFHKALYTVRAFLNCDRYSVGLLDMTKQKEFFDVWPVLMGEAPPYAGPRTPDGREINFYKVIDYILHGKEDIKVIPNPPPDHWALVSGLPTYVAQNGLICNIMNAPSEDFFAFQKEPLDESGWMIKNVLSMPIVNKKEEIVGVATFYNRKDGKPFDEMDETLMESLTQFLGWSVLNPDTYELMNKLENRKDIFQDMVKYHVKCDNEEIQTILKTREVYGKEPWECEEEELAEILQGELPDADKYEINKFHFSDLPLTELELVKCGIQMYYELKVVDKFHIPQEALVRFMYSLSKGYRRITYHNWRHGFNVGQTMFSLLVTGKLKRYFTDLEALAMVTAAFCHDIDHRGTNNLYQMKSQNPLAKLHGSSILERHHLEFGKTLLRDESLNIFQNLNRRQHEHAIHMMDIAIIATDLALYFKKRTMFQKIVDQSKTYETQQEWTQYMMLDQTRKEIVMAMMMTACDLSAITKPWEVQSKVALLVAAEFWEQGDLERTVLQQNPIPMMDRNKADELPKLQVGFIDFVCTFVYKEFSRFHEEITPMLDGITNNRKEWKALADEYETKMKGLEEEKQKQQAANQAAAGSQHGGKQPGGGPASKSCCVQ"
const PDE6B_SEQ = "MSLSEGQVHRFLDQNPGFADQYFGRKLSPEDVANACEDGCPEGCTSFRELCQVEESAALFELVQDMQENVNMERVVFKILRRLCSILHADRCSLFMYRQRNGVAELATRLFSVQPDSVLEDCLVPPDSEIVFPLDIGVVGHVAQTKKMVNVQDVMECPHFSSFADELTDYVTRNILATPIMNGKDVVAVIMAVNKLDGPCFTSEDEDVFLKYLNFGTLNLKIYHLSYLHNCETRRGQVLLWSANKVFEELTDIERQFHKAFYTVRAYLNCDRYSVGLLDMTKEKEFFDVWPVLMGEAQAYSGPRTPDGREILFYKVIDYILHGKEDIKVIPSPPADHWALASGLPTYVAESGFICNIMNAPADEMFNFQEGPLDDSGWIVKNVLSMPIVNKKEEIVGVATFYNRKDGKPFDEQDEVLMESLTQFLGWSVLNTDTYDKMNKLENRKDIAQDMVLYHVRCDREEIQLILPTRERLGKEPADCEEDELGKILKEVLPGPAKFDIYEFHFSDLECTELELVKCGIQMYYELGVVRKFQIPQEVLVRFLFSVSKGYRRITYHNWRHGFNVAQTMFTLLMTGKLKSYYTDLEAFAMVTAGLCHDIDHRGTNNLYQMKSQNPLAKLHGSSILERHHLEFGKFLLSEETLNIYQNLNRRQHEHVIHLMDIAIIATDLALYFKKRTMFQKIVDESKNYEDRKSWVEYLSLETTRKEIVMAMMMTACDLSAITKPWEVQSKVALLVAAEFWEQGDLERTVLDQQPIPMMDRNKAAELPKLQVGFIDFVCTFVYKEFSRFHEEILPMFDRLQNNRKEWKALADEYEAKVKALEEDQKKETTAKKVGTEICNGGPAPRSSTCRIL"
const PDE6G_SEQ = "MNLEPPKAEIRSATRVMGGPVTPRKGPPKFKQRQTRQFKSKPPKKGVQGFGDDIPGMEGLGTDITVICPWEAFNHLELHELAQYGII"
const GAT_SEQ   = "MAHHHHHHAMGAGASAEEKHSRELEKKLKEDAEKDARTVKLLLLGAGESGKSTIVKQMKIIHQDGYSLEECLEFIAIIYGNTLQSILAIVRAMTTLNIQYGDSARQDDARKLMHMADTIEEGTMPKEMSDIIQRLWKDSGIQACFDRASEYQLNDSAGYYLSDLERLVTPGYVPTEQDVLRSCVKTTGIIETQFSFKDLNFRMFDVGGLRSERKKWIHCFEGVTAIIFCVALSDYDMVLVEDDEVNRMHESMHLFNSICNNKWFTDTSIILFLNKKDLFEEKIKKSPLSICFPDYAGSNTYEEAGNYIKVQFLELNMRRDVKEIYSHMTCATDTQNVKFVFDAVTDIIIKENLKDCGLFAAATETSQVAPA"

# Average masses from each *_SEQ (ExPASy average residue masses + one
# water for the terminal H/OH), same convention as SASDMJ9.
const PDE6A_MW = 99_340.97   # g/mol
const PDE6B_MW = 98_330.79   # g/mol
const PDE6G_MW =  9_669.23   # g/mol  (per PDE6γ monomer)
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

const PDE6_MOLARITY_σ  = 0.05 * PDE6_MOLARITY     # 5% relative: typical A280/mg-ml
const PDE6G_MOLARITY_σ = 0.05 * PDE6G_MOLARITY
const GAT_MOLARITY_σ   = 0.05 * GAT_MOLARITY

# MISSING FROM PMV LOOKUP: udenafil (the 3 μM small-molecule PDE6
# inhibitor in this sample) has no entry in
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json (nor the
# sibling .tsv) -- adding it as a NonBiological solute would error out of
# PartialMolarVolumes.ϕ°. At 3 μM (roughly 2000× more dilute than the
# 100 mM NaCl / 25 mM Tris buffer components below) its contribution to
# the bulk electron density is negligible regardless, so it is simply
# omitted from SOLUTES rather than stubbed in.

# Buffer components. Tris/NaCl/MgCl2/glycerol all resolve against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json.
const SOLUTES = Solute[
    Protein(PDE6_MOLARITY,   PDE6_MOLARITY_σ,  PDE6A_SEQ),
    Protein(PDE6_MOLARITY,   PDE6_MOLARITY_σ,  PDE6B_SEQ),
    Protein(PDE6G_MOLARITY,  PDE6G_MOLARITY_σ, PDE6G_SEQ),
    Protein(GAT_MOLARITY,    GAT_MOLARITY_σ,   GAT_SEQ),
    NonBiological(0.100, 0.001,   "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.025, 0.0005,  "tris"),              # 25 mM Tris pH 8.0, ±2%
    NonBiological(0.002, 0.00004, "magnesium chloride"),# 2 mM MgCl2, ±2%
    NonBiological(0.274, 0.0055,  "glycerol"),          # 2% v/v ≈ 0.274 M (ρ=1.261 g/mL, MW=92.09 g/mol), ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3   # SASDZC6_fit1.dat's own q_max (≈0.2999 Å⁻¹); no truncation needed

# No GNOM pddf was bundled for this case (test/fixtures/experiments/SASDZC6/pddf/
# is empty; the paper used GNOM only to get its own Dmax for Table S1, and that
# .out file wasn't included in this fixture). lMax is instead sized off Dmax
# estimated directly from the PDB coordinates: the maximum pairwise Cα-Cα
# distance over SASDZC6_fit1_model1.pdb's 2401 Cα atoms (computed via a convex
# hull to keep the pairwise search tractable) is ≈163.2 Å -- consistent with
# this being a very large (~280 kDa, ~2600-residue) heterohexameric complex.
# Same q·Dmax rule of thumb as SASDMJ9: Q_MAX_FIT * Dmax ≈ 0.3 * 163.2 ≈ 49.
const LMAX = 50

# PDB 7JSN's four unique chains each start with a different free
# N-terminal residue (chain A/PDE6α: Glu8, chain B/PDE6β: Ala19, chains
# C,D/PDE6γ: Ile10, chains E,F/GαT*: Ala27 -- confirmed directly from the
# PDB's own ATOM records), each in its own local structural environment
# within this ~280 kDa hetero-hexamer. PROPKA genuinely splits these
# termini's protonation-state decisions at PH = 8.0 (confirmed directly: an
# early version of this script hit
# PDB2PQRError("multiple free N-termini round to different protonation
# states at pH=8.0...") before MolecularStructure.PDB2PQR.jl's
# resolve_hydrogens/_terminus_groups gained per-chain-group support --
# it now runs pdb2pqr once per distinct flag combination, always on the
# full intact structure so PROPKA keeps seeing the real inter-chain
# context, and merges the correctly-hydrogenated chains back together. See
# _terminus_groups's docstring / src/MolecularStructure/README.md's
# "N+"/"C-" section.
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdzc6(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s, μ_χ, σ_χ = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        ionic_strength_M = IONIC_STRENGTH_M, T = TEMPERATURE_C + 273.15,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, μ_χ, σ_χ, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdzc6()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDZC6/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdzc6_figure(result, data) -> Figure

Plots the SASDZC6 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdzc6_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "divergence rate = $(round(divergence_rate; digits = 3))",
        xscale = log10,
        yscale = log10,
    )

    # Floor for the quantile/bounds curve's lower edge on this log10 y-axis.
    # See SASDMJ9_figure's comment for why this is tied to I_fit's own
    # smallest value rather than an arbitrary tiny constant.
    y_floor = minimum(I_fit) / 2

    if quantile_result !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]

        band!(
            ax, bounds[:, 1], max.(bounds[:, 2], y_floor), bounds[:, 3];
            color = (:dodgerblue, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 2], y_floor);
            linestyle = :dot, color = :dodgerblue, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3];
            linestyle = :dot, color = :dodgerblue, linewidth = 1.5,
        )
    end

    # Log-symmetric errorbars (delta method on log10 I), same convention as
    # SASDMJ9_figure -- see its comment for the rationale.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map_curve[:, 2]; color = :crimson, linewidth = 2, label = "MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

"""
    sasdzc6_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdzc6_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)", title = "fit residuals")

    map_curve = map_result === nothing ? nothing : map_result[2]

    if quantile_result !== nothing && map_curve !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]
        I_map     = map_curve[:, 2]

        band!(
            ax, bounds[:, 1], bounds[:, 2] .- I_map, bounds[:, 3] .- I_map;
            color = (:dodgerblue, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = :dodgerblue, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = :dodgerblue, linewidth = 1.5,
        )
    end

    if map_curve !== nothing
        resid = I_fit .- map_curve[:, 2]
        errorbars!(ax, q_fit, resid, σ_fit; whiskerwidth = 4, color = (:gray40, 0.6))
        scatter!(ax, q_fit, resid; markersize = 4, color = :gray20, label = "data - MAP")
        hlines!(ax, [0.0]; color = :crimson, linewidth = 1.5)
        lo, hi = extrema(resid)
        pad = 0.3 * (hi - lo)
        ylims!(ax, lo - pad, hi + pad)
    end

    axislegend(ax; position = :lb, framevisible = false)

    return fig
end

# ξ = (dns, δρ1, δρ2, δρ3, c1)
const _HIST_PARAMS = [
    ("dns", "slvnt_e_dns"), ("δρ1", "delta_rho_1"), ("δρ2", "delta_rho_2"),
    ("δρ3", "delta_rho_3"), ("c1", "excl_vol_corr"),
]

"""
    sasdzc6_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdzc6_posterior_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = (900, 550))
    for (i, (label, map_key)) in enumerate(_HIST_PARAMS)
        row, col = fldmod1(i, 3)
        ax = Axis(
            fig[row, col], xlabel = label, ylabel = "count",
            xticklabelrotation = label == "dns" ? π/2 : 0.0,
        )
        hist!(ax, getindex.(samples, i); bins = 40, color = (:dodgerblue, 0.6))
        if map_params !== nothing
            vlines!(ax, [map_params[map_key]]; color = :crimson, linewidth = 2)
        end
    end

    return fig
end

# No CRYSOL comparison figure: unlike SASDMJ9, this fixture bundles no
# separate reference CRYSOL fit file (SASDZC6_fit1.dat is itself the FoXS
# fit dump used above as the raw experimental curve, not an independent
# reference to overlay), so the crysol_comparison plotting function from
# the SASDMJ9 template is intentionally omitted here.

fig = sasdzc6_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig)

fig_residuals = sasdzc6_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals)

fig_hist = sasdzc6_posterior_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist)

"Display the SASDZC6 fit figure. Blocks until the window is closed."
vis_sasdzc6() = wait(display(fig))
