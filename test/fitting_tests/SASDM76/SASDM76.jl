using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDM76")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDM76.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDM76: Long promoter sequences form higher-order G-quadruplexes: an integrative
# structural biology study of c-Myc, k-Ras and c-Kit promoter sequences (the entry is the
# 28-nt G-quadruplex 201D, d(G4T4G4T4G4T4G4), 8.9 kDa).
#
# Paper: Monsen RC, DeLeeuw LW, Dean WL, et al., Nucleic Acids Res (2022),
# DOI 10.1093/nar/gkac182. SASBDB entry: https://www.sasbdb.org/data/SASDM76/ (the buffer,
# pH, temperature and instrument below are the SASBDB entry metadata; the paper was not
# consulted for them).
#
# Sample: 201D at up to 13.1 mg/ml, co-flow SEC-SAXS. Instrument: Advanced Photon Source
# BioCAT 18ID (X-ray synchrotron), Pilatus3 X 1M, wavelength 0.1033 nm = 1.033 Å =>
# energy = hc/λ ≈ 12002 eV (hc = 12398.42 eV·Å). Sample temperature: 22 °C (SASBDB cell
# temperature).
#
# Buffer as deposited (SASBDB comment: "BPEK buffer"): "6 mM Na2HPO4, 2 mM NaH2PO4, 1 mM
# Na2EDTA, 185 mM KCl", pH 7.2. The measured macromolecule is deliberately NOT a solute
# (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q 0.0044-0.3497 Å⁻¹, 4 header lines, 80
# trailer lines; `_read_curve` keeps the numeric rows only); 29 of its 1209 points have a
# non-positive intensity, dropped by `seed_model` after binning. The model (written by
# Maestro; 914 atoms) carries 322 hydrogens and three K⁺ ions as residues `K`.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 22.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). The phosphates are stated as the two species already
# (6 mM Na2HPO4 + 2 mM NaH2PO4), so they are used as deposited: no titrant counter-ion
# is added (nothing in the recipe is titrated with a strong acid or base), although the
# stated 3:1 split would give a pH above the recorded 7.2. "1 mM Na2EDTA" is the
# disodium salt, i.e. H2EDTA²⁻ with two Na⁺ (the table has the H2EDTA ion and the
# sodium ion, not the salt); at pH 7.2 EDTA is mostly HEDTA³⁻, a difference far below the
# uncertainty of such a small contribution.
const SOLUTES = Solute[
    NonBiological(0.185, 0.00185, "potassium chloride"),   # 185 mM, ±1%
    NonBiological(0.006, 0.00012, "disodium hydrogen phosphate"),   # 6 mM Na2HPO4, ±2%
    NonBiological(0.002, 4e-05, "sodium dihydrogen phosphate"),   # 2 mM NaH2PO4, ±2%
    NonBiological(0.001, 2e-05, "H2EDTA"),   # 1 mM Na2EDTA: H2EDTA²⁻ part, ±2%
    NonBiological(0.002, 4e-05, "sodium"),   # 1 mM Na2EDTA: the two Na⁺, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model already carries 322 hydrogens (Maestro names),
# but, as for SASDWZ9, pdb2pqr drops them and places its own from the heavy atoms (324
# hydrogens in the seed build), so the hydrogen set is consistent with the other entries.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    pdb = "SASDM76_fit1_model1.pdb",
    fit = "SASDM76_fit1.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "CRYSOL",
),   # 201D G-quadruplex with 322 H and 3 K; deposited χ² = 1.779
]

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdm76` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdm76` below is the whole story (build the seed, then sample it).
function seed_sasdm76(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdm76(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdm76(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

"""
    sasdm76_figure(result, data) -> Figure

Plots the SASDM76 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdm76_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
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
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE,
            label = "quantiles",
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
        lines!(
            ax,
            map_curve[:, 1],
            map(v -> v > 0 ? v : NaN, map_curve[:, 2]);
            color = COLOR_MAP,
            linewidth = LW_MAP,
            label = "MAP",
        )
    end

    axislegend(ax; position = :lb, framevisible = false)

    # Centre the view on the actual data (I_fit), not on however far the
    # errorbar whiskers/bounds band happen to extend
    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end

"""
    sasdm76_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdm76_residuals_figure(result, data)
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
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE_RESID,
            label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE_RESID,
        )
    end

    if map_curve !== nothing
        resid = I_fit .- map_curve[:, 2]
        errorbars!(
            ax,
            q_fit,
            resid,
            σ_fit;
            whiskerwidth = WHISKERWIDTH,
            color = COLOR_ERRORBAR,
        )
        scatter!(
            ax,
            q_fit,
            resid;
            markersize = MARKERSIZE,
            color = COLOR_DATA,
            label = "data - MAP",
        )
        hlines!(ax, [0.0]; color = COLOR_MAP, linewidth = LW_ZERO_LINE)
        lo, hi = extrema(resid)
        pad = YLIM_LIN_PAD_FRAC * (hi - lo)
        ylims!(ax, lo - pad, hi + pad)
    end

    axislegend(ax; position = :rt, framevisible = false)

    return fig
end

"""
    sasdm76_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
"""
function sasdm76_hist(result)
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
    sasdm76_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the depositor's reference fit (`fit_curve = (q, I)`, or
`nothing` if the fit file could not be parsed, in which case no figure is made).
"""
function sasdm76_comparison_figure(result, data, fit_curve, label)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    fit_curve === nothing && return nothing
    q_crysol, I_crysol = fit_curve
    keep = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdm76_figure` -- see its
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
        lines!(
            ax,
            map_curve[:, 1],
            map(v -> v > 0 ? v : NaN, map_curve[:, 2]);
            color = COLOR_MAP,
            linewidth = LW_MAP,
            label = "BAYSOL MAP",
        )
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end


# the results of every run, kept for the figures below
fits = Dict{String,Any}()

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdm76(run)

    # `@__DIR__` (this SASDM76/ folder), not the caller's cwd.
    open(joinpath(@__DIR__, "res$(suffix).txt"), "w") do io
        BAYSOL.write_report(
            io,
            result;
            form_factor_log = form_factor_log,
            n_atoms = n_atoms,
        )
    end

    fits[run.tag] = (result, (q_fit, I_fit, σ_fit))
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL
# methods, which every fit would then recompile (about 40 % of a fit's wall clock).
using GLMakie

for run in RUNS
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag
    result, data = fits[run.tag]
    q_fit, I_fit, σ_fit = data

    fig = sasdm76_figure(result, data)
    save(joinpath(@__DIR__, "res$(suffix).png"), fig; px_per_unit = PX_PER_UNIT)

    fig_residuals = sasdm76_residuals_figure(result, data)
    save(
        joinpath(@__DIR__, "res$(suffix)_residuals.png"),
        fig_residuals;
        px_per_unit = PX_PER_UNIT,
    )

    fig_hist = sasdm76_hist(result)
    save(joinpath(@__DIR__, "res$(suffix)_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

    fit_curve = try
        fc = _read_fit(joinpath(_FIXTURE_DIR, run.fit), run.fit_scale, run.fit_col)
        fc !== nothing && run.rescale ? _rescale_fit(fc, q_fit, I_fit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    fig_cmp = sasdm76_comparison_figure(
        result,
        data,
        fit_curve,
        run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""),
    )
    fig_cmp === nothing || save(
        joinpath(@__DIR__, "res$(suffix)_comparison.png"),
        fig_cmp;
        px_per_unit = PX_PER_UNIT,
    )
end
