using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Inference: Solute, Protein, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMZ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1.dat")

# Unlike SASDMJ9, `experimental_data/` and `pddf/` are EMPTY for this case;
# the experimental curve ships directly as `SASDMZ9_fit1.dat` in the case
# root, and no GNOM .out pddf file is bundled.
#
# `SASDMZ9_fit1.dat` header:
#   # SAXS profile: number of points = 1211, q_min = 0.00297234626486897, q_max = 0.345499873161316, ...
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

qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 4])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Cerqueira et al. 2022, J. Biol. Chem. 298(5):101896, "Sas20 is a
# highly flexible starch-binding protein in the Ruminococcus bromii
# cell-surface amylosome".
#
# The paperlists six SASBDB entries: SASDMX9, SASDMY9, SASDMZ9, SASDN22, SASDN32, SASDN42;
# one per construct/ligand condition (p.16). Cross-checking residue coverage against Table 4 
# and the SASBDB entry itself identifies # SASDMZ9 specifically as Sas20d1-2 without ligands.
# SASBDB lists UniProt A0A2N0URA4 residues 27-559 and MW 57.2 kDa for this entry, matching 
# Table 4's Sas20d1-2 (no maltoheptaose) sequence MW of 57.2 kDa, an order of magnitude larger than
# either single domain (Sas20d1 ≈ 25.9 kDa, Sas20d2 ≈ 26.5 kDa). The entry paper also singles it out 
# as highly flexible. The three PDBs are taken to be three representative conformers of the flexible ensemble.
#
# SASBDB entry metadata for SASDMZ9 (sasbdb.org/data/SASDMZ9/):
#   buffer: "phosphate buffered saline, 1 mM TCEP, pH 7"; 5 mg/ml; 23°C;
#   BioCAT 18ID (APS, Argonne); wavelength λ = 0.1033 nm; sample-detector
#   distance 3.6 m; Pilatus3 X 1M detector.
#
# p.14: "PBS (137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, and 1.8 mM KH2PO4 [pH = 7.4])". 

# pH: the PBS recipe quoted above (p.14, pH 7.4) is from the paper's cell-washing / mass-spec methods, not
# the SAXS section, which names no buffer. The SAXS buffer is only given by SASBDB ('phosphate buffered
# saline, 1 mM TCEP, pH 7'), so pH 7.0 is used. The recipe's NaCl/KCl and total phosphate (11.8 mM) are
# kept; the phosphate is re-split at pH 7.0 (HPO4²⁻ fraction 0.592): pK2 from Goldberg, Kishore & Lennen
# 2002 (DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C, Davies-corrected at I ≈
# 0.166 M (pK2' ≈ 6.84). The 1.8 mM KH2PO4 is kept as the K⁺ carrier and the rest is sodium phosphate.
const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB

const ENERGY_EV        = HC_EV_ANGSTROM / 1.033 # ≈ 12001 eV, from SASBDB's stated λ = 0.1033 nm = 1.033 Å
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
const SAS20D1_2_MW = 56385.18   # g/mol
const SAS20D1_2_CONC_MG_ML = 5.0   # SASBDB: 5 mg/ml
const SAS20D1_2_MOLARITY   = SAS20D1_2_CONC_MG_ML / SAS20D1_2_MW   # ≈ 8.87e-5 M ≈ 0.0887 mM
const SAS20D1_2_MOLARITY_σ = MOLARITY_REL_SIGMA * SAS20D1_2_MOLARITY

# Buffer components: PBS + 1 mM TCEP
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Inference.Solute).
    NonBiological(0.137,  0.00137,   "sodium chloride"),                # 137 mM NaCl, ±1%
    NonBiological(0.0027, 0.000027,  "potassium chloride"),             # 2.7 mM KCl, ±1%
    NonBiological(0.001800, 0.000036, "potassium dihydrogen phosphate"),   # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.003014, 0.000988, "sodium dihydrogen phosphate"),   # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.006986, 0.000993, "disodium hydrogen phosphate"),   # PBS phosphate at pH 7.0, HPO4²⁻ part
    NonBiological(0.001,  0.00002,   "tcep"),                           # 1 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT    = 0.3
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

"""
    _positive_log_floor(values)

Return a strictly positive plotting floor based on the smallest finite,
positive value in `values`.

This is used only for visualization on logarithmic axes.
"""
function _positive_log_floor(values)
    positive = values[
        isfinite.(values) .&
        (values .> 0)
    ]
    if isempty(positive)
        return eps(Float64)
    end
    return max(minimum(positive) / 2, eps(Float64))
end

"""
    _valid_log_xy(x, y)

Return a mask selecting finite, strictly positive x/y values.
"""
function _valid_log_xy(x, y)
    return (
        isfinite.(x) .&
        isfinite.(y) .&
        (x .> 0) .&
        (y .> 0)
    )
end

# ---------------------------------------------------------------------------
#                         Generic run model function
# ---------------------------------------------------------------------------

# Builds the Seed that `run_sasdmz9_model` samples. It is separate only because the developer tools in test/utils/ build
# a fit's Seed without running the fit; if you are reading this script as an example you can skip it:
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

function run_sasdmz9_model(pdb_path::String; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    s, data = seed_sasdmz9_model(pdb_path; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

# ---------------------------------------------------------------------------
#                         Generic fit figure
# ---------------------------------------------------------------------------

function sasdmz9_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    valid_data =
        isfinite.(q_fit) .&
        isfinite.(I_fit) .&
        isfinite.(σ_fit) .&
        (q_fit .> 0) .&
        (I_fit .> 0) .&
        (σ_fit .>= 0)

    q_plot = q_fit[valid_data]
    I_plot = I_fit[valid_data]
    σ_plot = σ_fit[valid_data]

    if isempty(I_plot)
        error("No positive finite experimental intensities available for log plot.")
    end

    y_floor = _positive_log_floor(I_plot)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Quantile/bounds envelope
    if quantile_result !== nothing
        _, curves = quantile_result
        bounds = curves["bounds"]
        quantiles = curves["quantiles"]

        q_bounds = bounds[:, 1]
        lo_bounds = bounds[:, 2]
        hi_bounds = bounds[:, 3]
        lo_bounds = max.(lo_bounds, y_floor)
        hi_bounds = max.(hi_bounds, y_floor)

        valid_bounds =
            isfinite.(q_bounds) .&
            isfinite.(lo_bounds) .&
            isfinite.(hi_bounds) .&
            (q_bounds .> 0)

        if any(valid_bounds)
            band!(
                ax,
                q_bounds[valid_bounds],
                lo_bounds[valid_bounds],
                hi_bounds[valid_bounds];
                color = COLOR_BAND,
                label = "bounds",
            )
        end

        q_quant = quantiles[:, 1]
        lo_quant = quantiles[:, 2]
        hi_quant = quantiles[:, 3]
        lo_quant = max.(lo_quant, y_floor)
        hi_quant = max.(hi_quant, y_floor)

        valid_quant =
            isfinite.(q_quant) .&
            isfinite.(lo_quant) .&
            isfinite.(hi_quant) .&
            (q_quant .> 0)

        if any(valid_quant)
            lines!(
                ax,
                q_quant[valid_quant],
                lo_quant[valid_quant];
                linestyle = :dot,
                color = COLOR_POSTERIOR,
                linewidth = LW_QUANTILE,
                label = "quantiles",
            )
            lines!(
                ax,
                q_quant[valid_quant],
                hi_quant[valid_quant];
                linestyle = :dot,
                color = COLOR_POSTERIOR,
                linewidth = LW_QUANTILE,
            )
        end
    end

    # Experimental error bars (delta method in log10 space)
    log_I = log10.(I_plot)
    log_σ = σ_plot ./ (I_plot .* log(10))
    err_lo = exp10.(log_I .- log_σ)
    err_hi = exp10.(log_I .+ log_σ)
    err_lo = max.(err_lo, y_floor)
    err_hi = max.(err_hi, y_floor)

    valid_errors =
        isfinite.(q_plot) .&
        isfinite.(err_lo) .&
        isfinite.(err_hi) .&
        (q_plot .> 0) .&
        (err_lo .> 0) .&
        (err_hi .> 0)

    if any(valid_errors)
        rangebars!(
            ax,
            q_plot[valid_errors],
            err_lo[valid_errors],
            err_hi[valid_errors];
            whiskerwidth = WHISKERWIDTH,
            color = COLOR_ERRORBAR,
        )
    end

    scatter!(ax, q_plot, I_plot; markersize = MARKERSIZE, color = COLOR_DATA, label = "data")

    # MAP curve
    if map_result !== nothing
        _, map_curve = map_result
        q_map = map_curve[:, 1]
        I_map = map_curve[:, 2]

        valid_map =
            isfinite.(q_map) .&
            isfinite.(I_map) .&
            (q_map .> 0) .&
            (I_map .> 0)

        if any(valid_map)
            lines!(
                ax,
                q_map[valid_map],
                max.(I_map[valid_map], y_floor);
                color = COLOR_MAP,
                linewidth = LW_MAP,
                label = "MAP",
            )
        end
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_plot)
    lo = max(lo, y_floor)
    hi = max(hi, lo * 1.3)
    ymin = max(lo * YLIM_LOG_LO, eps(Float64))
    ymax = max(hi * YLIM_LOG_HI, ymin * 1.01)
    ylims!(ax, ymin, ymax)

    return fig
end

# ---------------------------------------------------------------------------
#                         Generic residual figure
# ---------------------------------------------------------------------------

function sasdmz9_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = FIG_SIZE_RESIDUALS)
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)")

    map_curve = map_result === nothing ? nothing : map_result[2]

    if map_curve !== nothing
        I_map = map_curve[:, 2]

        if quantile_result !== nothing
            _, curves = quantile_result
            bounds = curves["bounds"]
            quantiles = curves["quantiles"]

            q_bounds = bounds[:, 1]
            lo_bounds = bounds[:, 2]
            hi_bounds = bounds[:, 3]

            valid_bounds =
                isfinite.(q_bounds) .&
                isfinite.(lo_bounds) .&
                isfinite.(hi_bounds) .&
                isfinite.(I_map)

            if any(valid_bounds)
                band!(
                    ax,
                    q_bounds[valid_bounds],
                    lo_bounds[valid_bounds] .- I_map[valid_bounds],
                    hi_bounds[valid_bounds] .- I_map[valid_bounds];
                    color = COLOR_BAND_RESID,
                    label = "bounds",
                )
            end

            q_quant = quantiles[:, 1]
            lo_quant = quantiles[:, 2]
            hi_quant = quantiles[:, 3]

            valid_quant =
                isfinite.(q_quant) .&
                isfinite.(lo_quant) .&
                isfinite.(hi_quant) .&
                isfinite.(I_map)

            if any(valid_quant)
                lines!(
                    ax,
                    q_quant[valid_quant],
                    lo_quant[valid_quant] .- I_map[valid_quant];
                    linestyle = :dot,
                    color = COLOR_POSTERIOR,
                    linewidth = LW_QUANTILE_RESID,
                    label = "quantiles",
                )
                lines!(
                    ax,
                    q_quant[valid_quant],
                    hi_quant[valid_quant] .- I_map[valid_quant];
                    linestyle = :dot,
                    color = COLOR_POSTERIOR,
                    linewidth = LW_QUANTILE_RESID,
                )
            end
        end

        resid = I_fit .- I_map
        valid_resid =
            isfinite.(q_fit) .&
            isfinite.(I_fit) .&
            isfinite.(σ_fit) .&
            isfinite.(resid) .&
            (q_fit .> 0) .&
            (σ_fit .>= 0)

        if any(valid_resid)
            errorbars!(
                ax,
                q_fit[valid_resid],
                resid[valid_resid],
                σ_fit[valid_resid];
                whiskerwidth = WHISKERWIDTH,
                color = COLOR_ERRORBAR,
            )
            scatter!(
                ax,
                q_fit[valid_resid],
                resid[valid_resid];
                markersize = MARKERSIZE,
                color = COLOR_DATA,
                label = "data - MAP",
            )
            hlines!(ax, [0.0]; color = COLOR_MAP, linewidth = LW_ZERO_LINE)

            lo, hi = extrema(resid[valid_resid])
            if lo == hi
                pad = max(abs(lo) * 0.3, 1.0)
            else
                pad = YLIM_LIN_PAD_FRAC * (hi - lo)
            end
            ylims!(ax, lo - pad, hi + pad)
        end
    end

    axislegend(ax; position = :rt, framevisible = false)
    return fig
end

# ---------------------------------------------------------------------------
#                         Generic histogram figure
# ---------------------------------------------------------------------------

function sasdmz9_hist(result)
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
            fig[row, col],
            xlabel = label,
            ylabel = "count",
            xticklabelrotation = π / 2,
        )
        values = if label == "c1"
            c1_draws
        elseif label == "scale"
            scale_draws
        elseif label == "bkgrnd_corr"
            bkgrnd_draws
        else
            getindex.(samples, i)
        end
        valid = isfinite.(values)
        values = values[valid]
        if !isempty(values)
            hist!(ax, values; bins = HIST_BINS, color = COLOR_HIST)
        end
        if map_params !== nothing
            map_value = map_params[map_key]
            if isfinite(map_value)
                vlines!(ax, [map_value]; color = COLOR_MAP, linewidth = LW_MAP)
            end
        end
    end
    return fig
end

# ---------------------------------------------------------------------------
#                               Model 1
# ---------------------------------------------------------------------------

const _PDB_PATH1 = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model1.pdb")

# Model 1 is the intermediate-extent one of the three flexible-ensemble conformers described above (see
# solution-conditions discussion); the paper's own solution-SAXS D_max for unliganded Sas20d1-2 (Table 4:
# D_max ≈ 190-203 Å depending on method) is an average/envelope over this same flexible ensemble.
# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from the diameter of the
# scatterer cloud and the largest fitted q (ceil(q_max * D)), and bins the curve to the Shannon channels
# that diameter allows (see `rebin` there).

result1, form_factor_log1, n_atoms1, (q_fit1, I_fit1, σ_fit1) =
    run_sasdmz9_model(_PDB_PATH1)

open(joinpath(@__DIR__, "res_model1.txt"), "w") do io
    BAYSOL.write_report(io, result1; form_factor_log = form_factor_log1, n_atoms = n_atoms1)
end

# ---------------------------------------------------------------------------
#                               Model 2
# ---------------------------------------------------------------------------

const _PDB_PATH2 = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model2.pdb")

# (lMax and the Shannon binning: see model 1.)

result2, form_factor_log2, n_atoms2, (q_fit2, I_fit2, σ_fit2) =
    run_sasdmz9_model(_PDB_PATH2)

open(joinpath(@__DIR__, "res_model2.txt"), "w") do io
    BAYSOL.write_report(io, result2; form_factor_log = form_factor_log2, n_atoms = n_atoms2)
end

# ---------------------------------------------------------------------------
#                               Model 3
# ---------------------------------------------------------------------------

const _PDB_PATH3 = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model3.pdb")

# (lMax and the Shannon binning: see model 1.)

result3, form_factor_log3, n_atoms3, (q_fit3, I_fit3, σ_fit3) =
    run_sasdmz9_model(_PDB_PATH3)

open(joinpath(@__DIR__, "res_model3.txt"), "w") do io
    BAYSOL.write_report(io, result3; form_factor_log = form_factor_log3, n_atoms = n_atoms3)
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL methods, which every fit would
# then recompile (about 40 % of a fit's wall clock).
using GLMakie

fig1 = sasdmz9_figure(result1, (q_fit1, I_fit1, σ_fit1))
save(joinpath(@__DIR__, "res_model1.png"), fig1; px_per_unit = PX_PER_UNIT)

fig_residuals1 = sasdmz9_residuals_figure(result1, (q_fit1, I_fit1, σ_fit1))
save(joinpath(@__DIR__, "res_model1_residuals.png"), fig_residuals1; px_per_unit = PX_PER_UNIT)

fig_hist1 = sasdmz9_hist(result1)
save(joinpath(@__DIR__, "res_model1_hist.png"), fig_hist1; px_per_unit = PX_PER_UNIT)

fig2 = sasdmz9_figure(result2, (q_fit2, I_fit2, σ_fit2))
save(joinpath(@__DIR__, "res_model2.png"), fig2; px_per_unit = PX_PER_UNIT)

fig_residuals2 = sasdmz9_residuals_figure(result2, (q_fit2, I_fit2, σ_fit2))
save(joinpath(@__DIR__, "res_model2_residuals.png"), fig_residuals2; px_per_unit = PX_PER_UNIT)

fig_hist2 = sasdmz9_hist(result2)
save(joinpath(@__DIR__, "res_model2_hist.png"), fig_hist2; px_per_unit = PX_PER_UNIT)

fig3 = sasdmz9_figure(result3, (q_fit3, I_fit3, σ_fit3))
save(joinpath(@__DIR__, "res_model3.png"), fig3; px_per_unit = PX_PER_UNIT)

fig_residuals3 = sasdmz9_residuals_figure(result3, (q_fit3, I_fit3, σ_fit3))
save(joinpath(@__DIR__, "res_model3_residuals.png"), fig_residuals3; px_per_unit = PX_PER_UNIT)

fig_hist3 = sasdmz9_hist(result3)
save(joinpath(@__DIR__, "res_model3_hist.png"), fig_hist3; px_per_unit = PX_PER_UNIT)
