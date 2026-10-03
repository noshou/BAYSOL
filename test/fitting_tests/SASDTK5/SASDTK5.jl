using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDTK5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTK5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTK5: Heme-substituted protein assembly bridged by synthetic porphyrin: achieving
# controlled configuration while maintaining rotational freedom
#
# Paper: Inaba H, Shisaka Y, Ariyasu S, et al., RSC Advances (2024), DOI 10.1039/D4RA01042F.
# Open access (CC BY); PDF filed with the data: test/fixtures/experiments/SASDTK5/inaba-et-
# al-2024-heme-substituted-protein-assembly-bridged-by-synthetic-porphyrin-achieving-controlled-
# conf.pdf (PMC PMC10941265).
# SASBDB entry: https://www.sasbdb.org/data/SASDTK5/
#
# Sample: HasApf5 (dimer, 19.034 kDa/chain); measured at up to 8.0 mg/ml (SEC-SAS).
# Instrument: Photon Factory (PF), High Energy Accelerator Research Organization (KEK) (X-ray
# synchrotron), wavelength 0.1 nm = 1 Å => energy = hc/λ ≈ 12398 eV (hc = 12398.42 eV·Å). Sample
# temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "50 mM CHES, 5 % glycerol", pH 9.5. Only the components with a partial-
# molar-volume entry and a stated concentration are modelled below; the measured macromolecule
# is deliberately NOT a solute (see Fitting.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹. The reference fit files are read from the same
# folder; each run's comparison curve is the depositor's fit for that model.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 9.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1   # ≈ 12398 eV, from the stated 0.1 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the buffer's electron density).
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 50 mM CHES titrated with KOH -> K⁺ = C·0.560 (pK(22 °C) = 9.464). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.028 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: CHES–KOH stated in the paper.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "ches"),   # 50 mM, ±2%
    NonBiological(0.6846265772, 0.01369253154, "glycerol"),   # 684.6 mM, ±2%
    NonBiological(0.027985, 0.003620, "potassium(1+)"),   # K⁺ counter-ion from KOH titration of CHES (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# lMax follows the usual q·D_max multipole-resolution rule of thumb, lMax = ceil(Q_MAX_FIT * D_max), with D_max the
# farthest atom pair of the model (convex-hull); for the existing scripts this rule reproduces their LMAX to within
# 3% (ratio 0.97-1.02) at Q_MAX_FIT up to 0.5.

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (tag = "fit2_model1", pdb = "SASDTK5_fit2_model1.pdb", fit = "SASDTK5_fit2.fit", fit_scale = 1.0, fit_col = 3, rescale = false, software = "CRYSOL", lmax = 28),   # D_max ≈ 93 Å; deposited χ² = 1.138
    (tag = "fit3_model1", pdb = "SASDTK5_fit3_model1.pdb", fit = "SASDTK5_fit3.fit", fit_scale = 1.0, fit_col = 3, rescale = false, software = "CRYSOL", lmax = 25),   # D_max ≈ 81 Å; deposited χ² = 1.167
    (tag = "fit4_model1", pdb = "SASDTK5_fit4_model1.pdb", fit = "SASDTK5_fit4.fit", fit_scale = 1.0, fit_col = 3, rescale = false, software = "CRYSOL", lmax = 33),   # D_max ≈ 110 Å; deposited χ² = 5.221
    (tag = "fit5_model1", pdb = "SASDTK5_fit5_model1.pdb", fit = "SASDTK5_fit5.fit", fit_scale = 1.0, fit_col = 3, rescale = false, software = "CRYSOL", lmax = 28),   # D_max ≈ 91 Å; deposited χ² = 1.805
    (tag = "fit6_model1", pdb = "SASDTK5_fit6_model1.pdb", fit = "SASDTK5_fit6.fit", fit_scale = 1.0, fit_col = 3, rescale = false, software = "CRYSOL", lmax = 29),   # D_max ≈ 94 Å; deposited χ² = 1.026
    (tag = "fit7_model1", pdb = "SASDTK5_fit7_model1.pdb", fit = "SASDTK5_fit7.fit", fit_scale = 1.0, fit_col = 3, rescale = false, software = "CRYSOL", lmax = 34),   # D_max ≈ 110 Å; deposited χ² = 6.085
]

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`, `I_exp > 0` and `σ_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0 && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdtk5(run; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), run.lmax, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

"""
    sasdtk5_figure(result, data) -> Figure

Plots the SASDTK5 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdtk5_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
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
            color = COLOR_BAND, label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 2], y_floor);
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 3], y_floor);
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE,
        )
    end

    # A linear/additive I(q) ± σ(q) interval isn't symmetric on a log10
    # axis; the lower whisker compresses toward 0 while the upper one
    # looks comparatively short, so the point visually rides near the top
    # of its own errorbar instead of centred (and I - σ can go
    # non-positive outright once σ > I, near the noise floor). Standard
    # SAXS log-I plotting convention (PRIMUS/SASBDB-style) instead
    # propagates σ into log-space via the delta method
    # (d/dx log10(x) = 1/(x·ln10)) and plots a log-symmetric interval, which
    # stays well-defined and visually centred no matter how large σ gets
    # relative to I.
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

    # Centre the view on the actual data (I_fit), not on however far the
    # errorbar whiskers/bounds band happen to extend
    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end

"""
    sasdtk5_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdtk5_residuals_figure(result, data)
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
            color = COLOR_BAND_RESID, label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE_RESID, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE_RESID,
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
    sasdtk5_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
"""
function sasdtk5_hist(result)
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

"""
    sasdtk5_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the depositor's reference fit (`fit_curve = (q, I)`, or
`nothing` if the fit file could not be parsed, in which case no figure is made).
"""
function sasdtk5_comparison_figure(result, data, fit_curve, label)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    fit_curve === nothing && return nothing
    q_crysol, I_crysol = fit_curve
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdtk5_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR,
    )
    scatter!(ax, q_fit, I_fit; markersize = MARKERSIZE, color = COLOR_DATA, label = "data")

    lines!(
        ax, q_crysol[keep], I_crysol[keep];
        color = COLOR_REFERENCE, linewidth = LW_REFERENCE, linestyle = :dash, label = label,
    )

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map(v -> v > 0 ? v : NaN, map_curve[:, 2]); color = COLOR_MAP, linewidth = LW_MAP, label = "BAYSOL MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdtk5(run)

    # `@__DIR__` (this SASDTK5/ folder), not the caller's cwd.
    open(joinpath(@__DIR__, "res$(suffix).txt"), "w") do io
        BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
    end

    data = (q_fit, I_fit, σ_fit)

    fig = sasdtk5_figure(result, data)
    save(joinpath(@__DIR__, "res$(suffix).png"), fig; px_per_unit = PX_PER_UNIT)

    fig_residuals = sasdtk5_residuals_figure(result, data)
    save(joinpath(@__DIR__, "res$(suffix)_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

    fig_hist = sasdtk5_hist(result)
    save(joinpath(@__DIR__, "res$(suffix)_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

    fit_curve = try
        fc = _read_fit(joinpath(_FIXTURE_DIR, run.fit), run.fit_scale, run.fit_col)
        fc !== nothing && run.rescale ? _rescale_fit(fc, q_fit, I_fit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    fig_cmp = sasdtk5_comparison_figure(result, data, fit_curve, run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""))
    fig_cmp === nothing || save(joinpath(@__DIR__, "res$(suffix)_comparison.png"), fig_cmp; px_per_unit = PX_PER_UNIT)
end
