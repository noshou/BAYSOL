using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE
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
# Beamline: CHESS 7A1 station, x-ray energy stated directly as 11.3 keV
# ("SAXS data collection and analysis" paragraph.
# Temperature: "continuously oscillated at room temperature"; 25°C used. SASBDB's cell_temperature is 4 °C,
# but the paper's SAXS Methods ("SAXS data collection and analysis") explicitly describe acquisition at room
# temperature, so the paper is followed (4 °C is most likely the sample-storage temperature).

const PH, σ_PH = 8.0, PH_METER_SIGMA

const ENERGY_EV       = 11_300.0   # 11.3 keV, stated directly (CHESS 7A1)
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

const GAT_SEQ   = 
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

const PDE6_MOLARITY_σ  = MOLARITY_REL_SIGMA * PDE6_MOLARITY
const PDE6G_MOLARITY_σ = MOLARITY_REL_SIGMA * PDE6G_MOLARITY
const GAT_MOLARITY_σ   = MOLARITY_REL_SIGMA * GAT_MOLARITY

# udenafil (the 3 μM small-molecule PDE6 inhibitor in this sample): no
# measured V0 exists, so the table entry is our own estimate,
# 399.6 ± 16.0 cm³/mol (basis=predicted; RDKit vdW-volume + polar-site
# regression, method and validation in PartialMolarVolumes/README.md,
# "Adding a missing solute"). At 3 μM (roughly 2000× more dilute than the
# 100 mM NaCl / 25 mM Tris buffer components) its contribution to the bulk
# electron density is negligible regardless, so the estimate's ±4 % error
# is irrelevant here; it is included so the solute list is complete.

# Buffer components. Tris/NaCl/MgCl2/glycerol all resolve against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json.
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 25 mM Tris titrated with HCl -> Cl⁻ = C·0.650 (pK(22 °C) = 8.156). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.122 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.100, 0.001,   "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.025, 0.0005,  "tris"),              # 25 mM Tris pH 8.0, ±2%
    NonBiological(0.002, 0.00004, "magnesium chloride"),# 2 mM MgCl2, ±2%
    NonBiological(0.274, 0.0055,  "glycerol"),          # 2% v/v ≈ 0.274 M (ρ=1.261 g/mL, MW=92.09 g/mol), ±2%
    NonBiological(0.000003, 0.00000015, "udenafil"),    # 3 μM udenafil (Methods), ±5%
    NonBiological(0.016258, 0.001823, "chloride"),   # Cl⁻ counter-ion from HCl titration of Tris (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3   # SASDZC6_fit1.dat's q_max (≈0.2999 Å⁻¹)

# No GNOM pddf was bundled for this case (test/fixtures/experiments/SASDZC6/pddf/
# is empty; the paper used GNOM only to get Dmax for Table S1, and that
# .out file wasn't included in this fixture). lMax is sized off Dmax
# estimated from the PDB coordinates: the maximum pairwise Cα-Cα
# distance over SASDZC6_fit1_model1.pdb's 2401 Cα atoms is ≈163.2 Å, consistent with
# this being a very large (~280 kDa, ~2600-residue). 
# Q_MAX_FIT * Dmax ≈ 0.3 * 163.2 ≈ 49. 
const LMAX = 49

# PDB 7JSN's four chains each start with a different free
# N-terminal residue (chain A/PDE6α: Glu8, chain B/PDE6β: Ala19, chains
# C,D/PDE6γ: Ile10, chains E,F/GαT*: Ala27. PROPKA splits these
# termini's protonation-state decisions at PH = 8.0.
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdzc6(; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdzc6()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDZC6/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdzc6_figure(result, data) -> Figure

Plots the SASDZC6 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdzc6_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",

        xscale = log10,
        yscale = log10,
    )

    y_floor = log_axis_floor(I_fit)   # see log_axis_floor in common.jl

    if quantile_result !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]

        band!(
            ax, bounds[:, 1], max.(bounds[:, 2], y_floor), max.(bounds[:, 3], y_floor);
            color = (:darkorange, 1), label = "bounds",   # NB: shared COLOR_BAND is (:darkorange, 0.15); this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 2], y_floor);
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 2.5, label = "quantiles",   # NB: shared LW_QUANTILE is 1.5; this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 3], y_floor);
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 2.5,   # NB: shared LW_QUANTILE is 1.5; this script's plot style is kept as-is
        )
    end

    # Log-symmetric errorbars (delta method on log10 I).
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR,
    )
    scatter!(ax, q_fit, I_fit; markersize = MARKERSIZE, color = COLOR_DATA, label = "data")

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map(v -> v > 0 ? v : NaN, map_curve[:, 2]); color = COLOR_MAP, linewidth = LW_MAP, label = "MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

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

    fig = Figure(size = FIG_SIZE_RESIDUALS)
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)")

    map_curve = map_result === nothing ? nothing : map_result[2]

    if quantile_result !== nothing && map_curve !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]
        I_map     = map_curve[:, 2]

        band!(
            ax, bounds[:, 1], bounds[:, 2] .- I_map, bounds[:, 3] .- I_map;
            color = (:darkorange, 0.15), label = "bounds",   # NB: shared COLOR_BAND_RESID is (:darkorange, 1); this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5, label = "quantiles",   # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5,   # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
        )
    end

    if map_curve !== nothing
        resid = I_fit .- map_curve[:, 2]
        errorbars!(ax, q_fit, resid, σ_fit; whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR)
        scatter!(ax, q_fit, resid; markersize = MARKERSIZE, color = COLOR_DATA, label = "data - MAP")
        hlines!(ax, [0.0]; color = COLOR_MAP, linewidth = LW_ZERO_LINE)
        lo, hi = extrema(resid)
        pad = YLIM_LIN_PAD_FRAC * (hi - lo)
        ylims!(ax, lo - pad, hi + pad)
    end

    axislegend(ax; position = :rt, framevisible = false)

    return fig
end

"""
    sasdzc6_hist(result) -> Figure
"""
function sasdzc6_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    c1_draws = fit.c1[ok]
    scale_draws = fit.scale[ok]
    bkgrnd_draws = fit.bkgrnd_corr[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = FIG_SIZE_HIST)
    for (i, (label, map_key)) in enumerate(HIST_PARAMS)
        row, col = fldmod1(i, 3)
        ax = Axis(
            fig[row, col], xlabel = label, ylabel = "count",
            xticklabelrotation = π/2,
        )
        draws = if label == "c1"
            c1_draws
        elseif label == "scale"
            scale_draws
        elseif label == "bkgrnd_corr"
            bkgrnd_draws
        else
            getindex.(samples, i)
        end
        hist!(ax, draws; bins = HIST_BINS, color = COLOR_HIST)
        if map_params !== nothing
            vlines!(ax, [map_params[map_key]]; color = COLOR_MAP, linewidth = LW_MAP)
        end
    end

    return fig
end

fig = sasdzc6_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdzc6_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdzc6_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

"Display the SASDZC6 fit figure. Blocks until the window is closed."
vis_sasdzc6() = wait(display(fig))
