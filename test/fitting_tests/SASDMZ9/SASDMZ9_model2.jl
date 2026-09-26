using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMZ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model2.pdb")

# Unlike SASDMJ9, `experimental_data/` and `pddf/` are EMPTY for this case;
# the experimental curve ships directly as `SASDMZ9_fit1.dat` in the case
# root, and no GNOM .out pddf file is bundled.
#
# SASDMZ9_fit1.dat:
#   3 comment/header lines, then 1211 data rows:
#   q, exp_intensity, model_intensity, error
#
# q is already in Å⁻¹.
raw = readdlm(_DATA_PATH; skipstart = 3)

qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 4])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, 0.1

const ENERGY_EV = 12398.42 / 1.033
const TEMPERATURE_C = 25.0
const IONIC_STRENGTH_M = 0.171

# PBS ionic strength:
#
# I = 0.5 * Σ cᵢ zᵢ²
#
# NaCl:                 0.137
# KCl:                  0.0027
# Na2HPO4:              0.010
# KH2PO4:               0.0018
#
# gives I ≈ 0.1715 M.
#
# TCEP contribution is neglected here.

# Sas20d1-2 sequence, read from SASDMZ9_fit1_model2.pdb chain A.
const SAS20D1_2_SEQ =
    "EETDTKIYFDASNLPAEWGTTKTVYCHLYAVAGDDLPETSWQGKAEKCKKDTATGLYYFDTAKLKSADGTNHGGLKDNADYAVIFSTIDTKSQSHQTCNVTLGKPCLGDTIYLTGGTVENTEDSSKRDFAATWKNNSDNYGPKAAITSLGHVTEGRFPIYLSRAEMVAQAIFNWAVKNPKNYTPETVADICAQVEAEPMDVYNAYAEMYATELADPAAYPDCAPLTTVATLLGVDPSGTTAPATEEPTTVEPTTVEPTTVEPTTVEPTTEPTTEPATEPADATQYVVAGVESLTGYEWQGSPALAPENVMTKSGDVYTKTFTAVPVGKSYQLKVVANTGDEQKWIGLDGTDNNVTFDVESACDVTVTFNPATNEIAVTGDGVKMVTDLEINSITVVGNGENSWLNGVAWGVDAEVNHMTQIADKVYQITYTGVESADAAYQFKFAVNDDWAANWGLPEQSAATIGEDFDLTFNGENMLLNTVSAGYPEDSLVDVTITLDLTKFDYPSRSGAKANIKIDGNRVLL"

const SAS20D1_2_MW = 56385.18
const SAS20D1_2_CONC_MG_ML = 5.0
const SAS20D1_2_MOLARITY =
    SAS20D1_2_CONC_MG_ML / SAS20D1_2_MW

const SAS20D1_2_MOLARITY_σ =
    0.05 * SAS20D1_2_MOLARITY

const SOLUTES = Solute[
    Protein(
        SAS20D1_2_MOLARITY,
        SAS20D1_2_MOLARITY_σ,
        SAS20D1_2_SEQ,
    ),

    NonBiological(
        0.137,
        0.00137,
        "sodium chloride",
    ),

    NonBiological(
        0.0027,
        0.000027,
        "potassium chloride",
    ),

    NonBiological(
        0.010,
        0.0002,
        "disodium hydrogen phosphate",
    ),

    NonBiological(
        0.0018,
        0.000036,
        "potassium dihydrogen phosphate",
    ),

    NonBiological(
        0.001,
        0.00002,
        "tcep",
    ),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# Dmax estimated from SASDMZ9_fit1_model2.pdb:
#
# Dmax ≈ 227.7 Å
# Q_MAX_FIT * Dmax ≈ 68
#
# No GNOM pddf is bundled for this case.

const LMAX = 68

const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

Return the experimental data restricted to q <= Q_MAX_FIT and
strictly positive intensity.

Non-finite values are also excluded.
"""
function fit_subset()
    keep = findall(
        i ->
            isfinite(qvals[i]) &&
            isfinite(I_exp[i]) &&
            isfinite(σ_exp[i]) &&
            qvals[i] > 0 &&
            qvals[i] ≤ Q_MAX_FIT &&
            I_exp[i] > 0,
        eachindex(qvals),
    )

    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdmz9_model2(
    ;
    n_samples::Int = 2000,
    n_adapt::Int = 1000,
    seed::Integer = 0,
)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)

    s, μ_χ, σ_χ = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH),
        LMAX,
        ENERGY_EV,
        q_fit,
        I_fit,
        σ_fit,
        PH,
        σ_PH,
        SOLUTES;
        add_hydrogens = ADD_HYDROGENS,
        t = TEMPERATURE_C,
        ionic_strength_M = IONIC_STRENGTH_M,
        T = TEMPERATURE_C + 273.15,
    )

    res = BAYSOL.run_model(
        s,
        n_samples,
        n_adapt;
        l = PROFILE(),
    )

    return (
        res,
        μ_χ,
        σ_χ,
        s.fw.form_factor_log,
        s.fw.n_atoms,
        (q_fit, I_fit, σ_fit),
    )
end

result, μ_χ, σ_χ, form_factor_log, n_atoms,
(q_fit, I_fit, σ_fit) = run_sasdmz9_model2()

fit, divergence_rate, map_result, quantile_result = result

# ---------------------------------------------------------------------------
#                               Report
# ---------------------------------------------------------------------------

open(joinpath(@__DIR__, "res_model2.txt"), "w") do io
    BAYSOL.write_report(
        io,
        result;
        μ_χ = μ_χ,
        σ_χ = σ_χ,
        form_factor_log = form_factor_log,
        n_atoms = n_atoms,
    )
end

# ---------------------------------------------------------------------------
#                        Plotting helpers
# ---------------------------------------------------------------------------

"""
    _positive_log_floor(values)

Return a strictly positive plotting floor based on the smallest finite
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

Return a boolean mask selecting finite, strictly positive x/y values.
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
#                            Fit figure
# ---------------------------------------------------------------------------

"""
    sasdmz9_model2_figure(result, data) -> Figure

Plots the SASDMZ9 model2 fit.

The plot uses logarithmic x/y axes and is robust against:
- zero intensities,
- negative intensities,
- NaN values,
- Inf values,
- non-positive MAP predictions,
- non-positive quantile/bound predictions,
- error bars whose lower edge would otherwise cross zero.
"""
function sasdmz9_model2_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result

    q_fit, I_fit, σ_fit = data

    # -----------------------------------------------------------------------
    # Experimental data
    # -----------------------------------------------------------------------

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

    # Strictly positive floor.
    y_floor = _positive_log_floor(I_plot)

    fig = Figure(size = (700, 500))

    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title = "divergence rate = $(round(divergence_rate; digits = 3))",
        xscale = log10,
        yscale = log10,
    )

    # -----------------------------------------------------------------------
    # Quantile/bounds envelope
    # -----------------------------------------------------------------------

    if quantile_result !== nothing
        _, curves = quantile_result

        bounds = curves["bounds"]
        quantiles = curves["quantiles"]

        # Bounds
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
                color = (:dodgerblue, 0.15),
                label = "bounds",
            )
        end

        # Quantiles
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
                color = :dodgerblue,
                linewidth = 1.5,
                label = "quantiles",
            )

            lines!(
                ax,
                q_quant[valid_quant],
                hi_quant[valid_quant];
                linestyle = :dot,
                color = :dodgerblue,
                linewidth = 1.5,
            )
        end
    end

    # -----------------------------------------------------------------------
    # Experimental error bars
    # -----------------------------------------------------------------------
    #
    # Convert σ(I) to an approximate symmetric uncertainty in log10(I):
    #
    #     σ_log10(I) ≈ σ(I) / (I ln(10))
    #
    # Then convert back to intensity for Makie's rangebars.
    #
    # The lower endpoint is explicitly clipped to y_floor so that the
    # logarithmic axis never receives <= 0.

    log_I = log10.(I_plot)

    log_σ =
        σ_plot ./ (I_plot .* log(10))

    err_lo =
        exp10.(log_I .- log_σ)

    err_hi =
        exp10.(log_I .+ log_σ)

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
            whiskerwidth = 4,
            color = (:gray40, 0.6),
        )
    end

    # Experimental points
    scatter!(
        ax,
        q_plot,
        I_plot;
        markersize = 4,
        color = :gray20,
        label = "data",
    )

    # -----------------------------------------------------------------------
    # MAP curve
    # -----------------------------------------------------------------------

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
                color = :crimson,
                linewidth = 2,
                label = "MAP",
            )
        end
    end

    axislegend(
        ax;
        position = :lb,
        framevisible = false,
    )

    # -----------------------------------------------------------------------
    # Y limits
    # -----------------------------------------------------------------------
    #
    # Use experimental data rather than errorbar/envelope extrema.
    # Both limits are guaranteed to be > 0.

    lo, hi = extrema(I_plot)

    lo = max(lo, y_floor)
    hi = max(hi, lo * 1.3)

    ymin = max(lo * 0.7, eps(Float64))
    ymax = max(hi * 1.3, ymin * 1.01)

    ylims!(ax, ymin, ymax)

    return fig
end

# ---------------------------------------------------------------------------
#                           Residual figure
# ---------------------------------------------------------------------------

"""
    sasdmz9_model2_residuals_figure(result, data) -> Figure

Plot data-minus-MAP residuals against q.

This plot uses linear axes, so zero and negative residuals are valid.
NaN/Inf values are excluded.
"""
function sasdmz9_model2_residuals_figure(result, data)
    _, _, map_result, quantile_result = result

    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))

    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q) - I_MAP(q)",
        title = "fit residuals",
    )

    map_curve =
        map_result === nothing ?
        nothing :
        map_result[2]

    if map_curve !== nothing

        q_map = map_curve[:, 1]
        I_map = map_curve[:, 2]

        # -------------------------------------------------------------------
        # Quantile envelope
        # -------------------------------------------------------------------

        if quantile_result !== nothing

            _, curves = quantile_result

            bounds = curves["bounds"]
            quantiles = curves["quantiles"]

            I_map_interp = I_map

            q_bounds = bounds[:, 1]
            lo_bounds = bounds[:, 2]
            hi_bounds = bounds[:, 3]

            valid_bounds =
                isfinite.(q_bounds) .&
                isfinite.(lo_bounds) .&
                isfinite.(hi_bounds) .&
                isfinite.(I_map_interp)

            if any(valid_bounds)

                band!(
                    ax,
                    q_bounds[valid_bounds],
                    lo_bounds[valid_bounds] .-
                        I_map_interp[valid_bounds],
                    hi_bounds[valid_bounds] .-
                        I_map_interp[valid_bounds];
                    color = (:dodgerblue, 0.15),
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
                isfinite.(I_map_interp)

            if any(valid_quant)

                lines!(
                    ax,
                    q_quant[valid_quant],
                    lo_quant[valid_quant] .-
                        I_map_interp[valid_quant];
                    linestyle = :dot,
                    color = :dodgerblue,
                    linewidth = 1.5,
                    label = "quantiles",
                )

                lines!(
                    ax,
                    q_quant[valid_quant],
                    hi_quant[valid_quant] .-
                        I_map_interp[valid_quant];
                    linestyle = :dot,
                    color = :dodgerblue,
                    linewidth = 1.5,
                )
            end
        end

        # -------------------------------------------------------------------
        # Residuals
        # -------------------------------------------------------------------

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
                whiskerwidth = 4,
                color = (:gray40, 0.6),
            )

            scatter!(
                ax,
                q_fit[valid_resid],
                resid[valid_resid];
                markersize = 4,
                color = :gray20,
                label = "data - MAP",
            )

            hlines!(
                ax,
                [0.0];
                color = :crimson,
                linewidth = 1.5,
            )

            lo, hi = extrema(resid[valid_resid])

            if lo == hi
                pad = max(abs(lo) * 0.3, 1.0)
            else
                pad = 0.3 * (hi - lo)
            end

            ylims!(
                ax,
                lo - pad,
                hi + pad,
            )
        end
    end

    axislegend(
        ax;
        position = :lb,
        framevisible = false,
    )

    return fig
end

# ---------------------------------------------------------------------------
#                         Posterior histograms
# ---------------------------------------------------------------------------

const _HIST_PARAMS = [
    ("dns", "slvnt_e_dns"),
    ("δρ1", "delta_rho_1"),
    ("δρ2", "delta_rho_2"),
    ("δρ3", "delta_rho_3"),
    ("c1", "excl_vol_corr"),
]

"""
    sasdmz9_model2_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for:

    ξ = (dns, δρ1, δρ2, δρ3, c1)

The MAP draw is marked in red when available.
"""
function sasdmz9_model2_posterior_hist(result)

    fit, _, map_result, _ = result

    ok =
        .!getproperty.(fit.stats, :numerical_error)

    samples =
        fit.samples[ok]

    map_params =
        map_result === nothing ?
        nothing :
        map_result[1]

    fig = Figure(size = (900, 550))

    for (i, (label, map_key)) in enumerate(_HIST_PARAMS)

        row, col = fldmod1(i, 3)

        ax = Axis(
            fig[row, col],
            xlabel = label,
            ylabel = "count",
            xticklabelrotation =
                label == "dns" ? π / 2 : 0.0,
        )

        values = getindex.(samples, i)

        # Remove NaN/Inf before histogramming.
        valid =
            isfinite.(values)

        values = values[valid]

        if !isempty(values)
            hist!(
                ax,
                values;
                bins = 40,
                color = (:dodgerblue, 0.6),
            )
        end

        if map_params !== nothing
            map_value = map_params[map_key]

            if isfinite(map_value)
                vlines!(
                    ax,
                    [map_value];
                    color = :crimson,
                    linewidth = 2,
                )
            end
        end
    end

    return fig
end

# ---------------------------------------------------------------------------
#                         Save output figures
# ---------------------------------------------------------------------------

fig = sasdmz9_model2_figure(
    result,
    (q_fit, I_fit, σ_fit),
)

save(
    joinpath(@__DIR__, "res_model2.png"),
    fig,
)

fig_residuals = sasdmz9_model2_residuals_figure(
    result,
    (q_fit, I_fit, σ_fit),
)

save(
    joinpath(@__DIR__, "res_model2_residuals.png"),
    fig_residuals,
)

fig_hist = sasdmz9_model2_posterior_hist(
    result,
)

save(
    joinpath(@__DIR__, "res_model2_hist.png"),
    fig_hist,
)

# ---------------------------------------------------------------------------
#                              Interactive view
# ---------------------------------------------------------------------------

"""
    vis_sasdmz9_model2()

Display the SASDMZ9 model2 fit figure.
Blocks until the window is closed.
"""
vis_sasdmz9_model2() = wait(display(fig))
