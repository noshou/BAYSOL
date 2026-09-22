using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BayeSol
using   BayeSol.MolecularStructure: LocalPathSource
using   BayeSol.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMJ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMJ9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDMJ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDMJ9_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 5)

# has 5 lines of headers, and some beam info at the end; need to skip.
qvals   = Float64.(raw[1:2048, 1])
I_exp   = Float64.(raw[1:2048, 2])
σ_exp   = Float64.(raw[1:2048, 3])

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ 10

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Xiao et al. 2012, J. Virol. 86(6):3144-3157 ("FCoV Nsp7 and Nsp8
# Form a 2:1 Heterotrimer..."), test/fixtures/experiments/SASDMJ9/xiao-et-al-2012-*.pdf.
#
# The buffer that matters here is the one used for the SEC step immediately
# preceding SAXS ("SEC" paragraph, Materials and Methods):
#
#     10 mM Tris-HCl (pH 7.5), 200 mM NaCl, 5 mM DTT
#
# The paper's SAXS concentration series for Nsp7  was 1.2, 2.4, 4.7,
# 9.4 mg/ml ("SAXS" paragraph), with "the SAXS data from the most
# concentrated sample ... used for further analysis" but SASBDB's 
# entry metadata for SASDMJ9 (sasbdb.org/data/SASDMJ9/) states only one
# concentration was measured for the curve: 4.70 mg/ml, eight
# successive 15 s frames. 
#
# X33 (EMBL BioSAXS, DORIS storage ring, DESY Hamburg) recorded at a stated
# wavelength of 1.54 Å ("SAXS" paragraph) => energy = hc/λ ≈ 8051 eV
# (hc = 12398.42 eV·Å). Sample temperature was stated explicitly as 20°C;
# but we use 25 since 20 is not supported.

const PH, σ_PH = 7.5, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV      = 12398.42 / 1.54   # ≈ 8051 eV, from X33's stated 1.54 Å wavelength
const TEMPERATURE_C   = 25.0             # 20C is given in paper, but version only supports 20C
const IONIC_STRENGTH_M = 0.200           # 200 mM NaCl, matches the SEC/SAXS buffer above

# Nsp7 sequence, read directly off SASDMJ9_fit1_model1.pdb chain B (residues
# 2-83, 82 residues). Chain C models the identical sequence plus a 2-residue
# Gly-Ser cloning-tag remnant at residues 0-1 that's disordered (not modeled)
# in chain B; the tag-free chain B sequence is used here as the dominant,
# biologically relevant species (the paper itself describes the mature
# protein, not the tag, as "Nsp7").
const NSP7_SEQ = "KLTEMKCTNVVLLGLLSKMHVESNSKEWNYCVGLHNEINLCDDPDAVLEKLLALIAFFLSKHNTCDLSDLIESYFENTTILQ"

# Average mass from NSP7_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH).
const NSP7_MW = 9331.77   # g/mol
const NSP7_CONC_MG_ML = 4.70
const NSP7_MOLARITY   = NSP7_CONC_MG_ML / NSP7_MW   # ≈ 0.504 mM
const NSP7_MOLARITY_σ = 0.05 * NSP7_MOLARITY        # 5% relative: typical A280/mg-ml

# Buffer components
const SOLUTES = Solute[
    Protein(NSP7_MOLARITY, NSP7_MOLARITY_σ, NSP7_SEQ),
    NonBiological(0.200, 0.002,   "sodium chloride"),   # 200 mM NaCl, ±1%
    NonBiological(0.010, 0.0002,  "tris"),              # 10 mM Tris-HCl, ±2%
    NonBiological(0.005, 0.0001,  "dtt"),               # 5 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT    = 0.5

# lMax follows the usual q·D_max multipole-resolution rule of thumb: D_max
# for a roughly globular dimer with Rg = 19.11 Å is ~45-65 Å, and
# Q_MAX_FIT * D_max ≈ 0.5 * 50 ≈ 25. (Tested lMax=50 to check whether the
# q≈0.2-0.3 Å⁻¹ secondary maximum GNOM's fit shows.
const LMAX = 25

const ADD_HYDROGENS = true   # runs PDB2PQR at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] <= Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdmj9(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s, μ_χ, σ_χ = BayeSol.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        ionic_strength_M = IONIC_STRENGTH_M, T = TEMPERATURE_C + 273.15,
    )
    res = BayeSol.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, μ_χ, σ_χ, s.fw.form_factor_log, (q_fit, I_fit, σ_fit)
end

result, μ_χ, σ_χ, form_factor_log, (q_fit, I_fit, σ_fit) = run_sasdmj9()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDMJ9/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BayeSol.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log)
end

"""
    sasdmj9_figure(result, data) -> Figure

Plots the SASDMJ9 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdmj9_figure(result, data)
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

    # A linear/additive I(q) ± σ(q) interval isn't symmetric on a log10
    # axis; the lower whisker compresses toward 0 while the upper one
    # looks comparatively short, so the point visually rides near the top
    # of its own errorbar instead of centered (and I - σ can go
    # non-positive outright once σ > I, near the noise floor). Standard
    # SAXS log-I plotting convention (PRIMUS/SASBDB-style) instead
    # propagates σ into log-space via the delta method
    # (d/dx log10(x) = 1/(x·ln10)) and plots a log-symmetric interval, which
    # stays well-defined and visually centered no matter how large σ gets
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
        lines!(ax, map_curve[:, 1], map_curve[:, 2]; color = :crimson, linewidth = 2, label = "MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    # Center the view on the actual data (I_fit), not on however far the
    # errorbar whiskers/bounds band happen to extend
    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

"""
    sasdmj9_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centered on the MAP curve.
"""
function sasdmj9_residuals_figure(result, data)
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
    sasdmj9_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdmj9_posterior_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = (900, 550))
    for (i, (label, map_key)) in enumerate(_HIST_PARAMS)
        row, col = fldmod1(i, 3)
        ax = Axis(fig[row, col], xlabel = label, ylabel = "count")
        hist!(ax, getindex.(samples, i); bins = 40, color = (:dodgerblue, 0.6))
        if map_params !== nothing
            vlines!(ax, [map_params[map_key]]; color = :crimson, linewidth = 2)
        end
    end

    return fig
end

"""
    sasdmj9_gnom_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference GNOM fit (`SASDMJ9_fit1.fit`,
column 4 -- the paper's own P(r)-regularized fit to this same data) on the
same log-log axes as `sasdmj9_figure`, restricted to `q ≤ Q_MAX_FIT`
(GNOM's own q=0 extrapolation rows and any non-positive values are dropped,
since both are invalid on a log axis).
"""
function sasdmj9_gnom_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data

    gnom   = readdlm(_FIT_PATH; skipstart = 1)
    q_gnom = Float64.(gnom[:, 1])
    I_gnom = Float64.(gnom[:, 4])
    keep   = (q_gnom .> 0) .& (q_gnom .<= Q_MAX_FIT) .& (I_gnom .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "BayeSol MAP vs. GNOM fit1 (paper)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdmj9_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, q_gnom[keep], I_gnom[keep];
        color = :seagreen, linewidth = 2, linestyle = :dash, label = "GNOM fit1 (paper)",
    )

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map_curve[:, 2]; color = :crimson, linewidth = 2, label = "BayeSol MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

fig = sasdmj9_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig)

fig_residuals = sasdmj9_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals)

fig_hist = sasdmj9_posterior_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist)

fig_gnom = sasdmj9_gnom_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_gnom_comparison.png"), fig_gnom)

"Display the SASDMJ9 fit figure. Blocks until the window is closed."
vis_sasdmj9() = wait(display(fig))
