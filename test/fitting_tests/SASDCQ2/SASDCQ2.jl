using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDCQ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCQ2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDCQ2: 2017 publication guidelines for structural modelling of small-angle scattering
# data from biomolecules in solution: an update.
#
# Paper: Trewhella J, Duff AP, Durand D, et al., Acta Crystallogr D Struct Biol (2017), DOI
# 10.1107/S2059798317011597.
# Open access (CC BY); PDF filed with the data: test/fixtures/experiments/SASDCQ2/trewhella-et-
# al-2017-2017-publication-guidelines-for-structural-modelling-of-small-angle-scattering-data-
# from-b.pdf (PMC PMC5586245).
# SASBDB entry: https://www.sasbdb.org/data/SASDCQ2/
#
# Sample: CaM (monomer, 16.706 kDa/chain); measured at up to 1.1 mg/ml (Other).
# Instrument: Australian  Synchrotron (X-ray synchrotron), wavelength 0.10332 nm = 1.033 Å =>
# energy = hc/λ ≈ 12000 eV (hc = 12398.42 eV·Å). Sample temperature: 22.0 °C (SASBDB record).
#
# Buffer as deposited: "25 mM MOPS, 250 mM NaCl, 50 mM KCl, 2 mM TCEP, 0.1% NaN3", pH 7.5. Only
# the components with a partial-molar-volume entry and a stated concentration are modelled
# below; the measured macromolecule is deliberately NOT a solute (see Fitting.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹. The reference fit files are read from the same
# folder; each run's comparison curve is the depositor's fit for that model.
# ---------------------------------------------------------------------------

"""
    _read_curve(path) -> (q, I, σ)

Reads the numeric rows (three or more columns) of a SASBDB `.dat`, skipping the free-text header
and any trailing beam information. The first three columns are q, I(q) and σ(q).
"""
function _read_curve(path)
    q = Float64[]; I = Float64[]; σ = Float64[]
    for line in eachline(path)
        t = split(replace(strip(line), ',' => ' '))
        length(t) ≥ 3 || continue
        v = tryparse.(Float64, t[1:3])
        any(isnothing, v) && continue
        push!(q, v[1]); push!(I, v[2]); push!(σ, v[3])
    end
    return q, I, σ
end

"""
    _read_fit(path, q_scale, col) -> (q, I_fit) or nothing

Reads a depositor fit file: the numeric rows with at least `col` columns, taking q from column 1 (scaled to Å⁻¹ by
`q_scale`) and the fitted intensity from column `col` (the layout differs between CRYSOL, FoXS, OLIGOMER and EOM
files). Returns `nothing` if there are no such rows.
"""
function _read_fit(path, q_scale, col)
    q = Float64[]; I = Float64[]
    for line in eachline(path)
        t = split(replace(strip(line), ',' => ' '))
        length(t) ≥ max(col, 3) || continue
        v = tryparse.(Float64, t[1:col])
        any(isnothing, v) && continue
        push!(q, v[1] * q_scale); push!(I, v[col])
    end
    return isempty(q) ? nothing : (q, I)
end

"""
    _rescale_fit((q, I), q_data, I_data) -> (q, c·I)

Least-squares scale of a normalized fit curve onto the data (linear interpolation of the fit at the data's q).
"""
function _rescale_fit(fit_curve, q_data, I_data)
    qf, If = fit_curve
    p = sortperm(qf); qf = qf[p]; If = If[p]
    Ii = zeros(length(q_data)); ok = falses(length(q_data))
    for (k, x) in enumerate(q_data)
        (qf[1] ≤ x ≤ qf[end]) || continue
        j = clamp(searchsortedlast(qf, x), 1, length(qf) - 1)
        w = qf[j+1] > qf[j] ? (x - qf[j]) / (qf[j+1] - qf[j]) : 0.0
        Ii[k] = If[j] * (1 - w) + If[j+1] * w
        ok[k] = true
    end
    any(ok) || return fit_curve
    c = sum(I_data[ok] .* Ii[ok]) / sum(Ii[ok] .^ 2)
    return qf, If .* c
end


qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
@assert 0.05 < maximum(qvals) < 2.0 "q range looks wrong (expected Å⁻¹ after conversion): $(extrema(qvals))"

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, 0.1   # ±0.1 is a typical benchtop pH-meter precision
const ENERGY_EV     = 12398.42 / 1.0332   # ≈ 12000 eV, from the stated 0.10332 nm
const TEMPERATURE_C = 22.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the buffer's electron density).
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 25 mM MOPS titrated with NaOH -> Na⁺ = C·0.722 (pK(22 °C) = 7.222). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.333 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "mops"),   # 25 mM, ±2%
    NonBiological(0.25, 0.005, "sodium chloride"),   # 250 mM, ±2%
    NonBiological(0.05, 0.001, "potassium chloride"),   # 50 mM, ±2%
    NonBiological(0.002, 4e-05, "tcep"),   # 2 mM, ±2%
    NonBiological(0.01538224888, 0.0003076449777, "sodium azide"),   # 15.38 mM, ±2%
    NonBiological(0.018041, 0.001391, "sodium(1+)"),   # Na⁺ counter-ion from NaOH titration of MOPS (see note above)
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
    (tag = "fit2_model1", pdb = "SASDCQ2_fit2_model1.pdb", fit = "SASDCQ2_fit2.dat", fit_scale = 1.0, fit_col = 3, rescale = false, software = "MES-FoXS", lmax = 21),   # D_max ≈ 69 Å; deposited χ² = 0.85
    (tag = "fit3_model1", pdb = "SASDCQ2_fit3_model1.pdb", fit = "SASDCQ2_fit3.dat", fit_scale = 1.0, fit_col = 3, rescale = false, software = "MES-FoXS", lmax = 22),   # D_max ≈ 71 Å; deposited χ² = 0.79
    (tag = "fit3_model2", pdb = "SASDCQ2_fit3_model2.pdb", fit = "SASDCQ2_fit3.dat", fit_scale = 1.0, fit_col = 3, rescale = false, software = "MES-FoXS", lmax = 19),   # D_max ≈ 60 Å; deposited χ² = 0.79
]

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`, `I_exp > 0` and `σ_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0 && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdcq2(run; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
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
    sasdcq2_figure(result, data) -> Figure

Plots the SASDCQ2 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdcq2_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",

        xscale = log10,
        yscale = log10,
    )

    # Floor for the quantile/bounds curve's lower edge on this log10 y-axis.
    # The model curve is always > 0 in principle, but can numerically
    # graze 0 near the high-q noise floor, and log10 of a non-positive value
    # errors. Tied to I_fit's own smallest value (halved) rather than an
    # arbitrary tiny constant: clamping down to, say, 1e-6 would plot it
    # many decades below the data's real range, which on a log axis renders
    # as a huge, misleading spike.
    y_floor = minimum(I_fit) / 2

    if quantile_result !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]

        band!(
            ax, bounds[:, 1], max.(bounds[:, 2], y_floor), max.(bounds[:, 3], y_floor);
            color = (:darkorange, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 2], y_floor);
            linestyle = :dot, color = :darkorange, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 3], y_floor);
            linestyle = :dot, color = :darkorange, linewidth = 1.5,
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
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map(v -> v > 0 ? v : NaN, map_curve[:, 2]); color = :crimson, linewidth = 2, label = "MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    # Centre the view on the actual data (I_fit), not on however far the
    # errorbar whiskers/bounds band happen to extend
    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

"""
    sasdcq2_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdcq2_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)")

    map_curve = map_result === nothing ? nothing : map_result[2]

    if quantile_result !== nothing && map_curve !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]
        I_map     = map_curve[:, 2]

        band!(
            ax, bounds[:, 1], bounds[:, 2] .- I_map, bounds[:, 3] .- I_map;
            color = (:darkorange, 1), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 2.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 2.5,
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

    axislegend(ax; position = :rt, framevisible = false)

    return fig
end

const _HIST_PARAMS = [
    ("ρₑ", "slvnt_e_dns"), ("δρ₁", "delta_rho_1"), ("δρ₂", "delta_rho_2"),
    ("δρ₃", "delta_rho_3"),
    ("scale", "scale"), ("bkgrnd_corr", "bkgrnd_corr"),
    ("c1", "excl_vol_corr"),
]

"""
    sasdcq2_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
"""
function sasdcq2_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    c1_draws = fit.c1[ok]
    scale_draws = fit.scale[ok]
    bkgrnd_draws = fit.bkgrnd_corr[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = (900, 550))
    for (i, (label, map_key)) in enumerate(_HIST_PARAMS)
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
        hist!(ax, draws; bins = 40, color = (:darkorange, 0.6))
        if map_params !== nothing
            vlines!(ax, [map_params[map_key]]; color = :crimson, linewidth = 2)
        end
    end

    return fig
end

"""
    sasdcq2_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the depositor's reference fit (`fit_curve = (q, I)`, or
`nothing` if the fit file could not be parsed, in which case no figure is made).
"""
function sasdcq2_comparison_figure(result, data, fit_curve, label)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    fit_curve === nothing && return nothing
    q_crysol, I_crysol = fit_curve
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdcq2_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, q_crysol[keep], I_crysol[keep];
        color = :mediumturquoise, linewidth = 2, linestyle = :dash, label = label,
    )

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map(v -> v > 0 ? v : NaN, map_curve[:, 2]); color = :crimson, linewidth = 2, label = "BAYSOL MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdcq2(run)

    # `@__DIR__` (this SASDCQ2/ folder), not the caller's cwd.
    open(joinpath(@__DIR__, "res$(suffix).txt"), "w") do io
        BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
    end

    data = (q_fit, I_fit, σ_fit)

    fig = sasdcq2_figure(result, data)
    save(joinpath(@__DIR__, "res$(suffix).png"), fig; px_per_unit = 3.5)

    fig_residuals = sasdcq2_residuals_figure(result, data)
    save(joinpath(@__DIR__, "res$(suffix)_residuals.png"), fig_residuals; px_per_unit = 3.5)

    fig_hist = sasdcq2_hist(result)
    save(joinpath(@__DIR__, "res$(suffix)_hist.png"), fig_hist; px_per_unit = 3.5)

    fit_curve = try
        fc = _read_fit(joinpath(_FIXTURE_DIR, run.fit), run.fit_scale, run.fit_col)
        fc !== nothing && run.rescale ? _rescale_fit(fc, q_fit, I_fit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    fig_cmp = sasdcq2_comparison_figure(result, data, fit_curve, run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""))
    fig_cmp === nothing || save(joinpath(@__DIR__, "res$(suffix)_comparison.png"), fig_cmp; px_per_unit = 3.5)
end
