using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

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
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Xiao et al. 2012, J. Virol. 86(8):4444-4454 ("FCoV Nsp7 and Nsp8
# Form a 2:1 Heterotrimer..."), DOI 10.1128/JVI.06635-11. Not open access
# (© ASM, all rights reserved), so the PDF is not bundled with the fixtures.
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
# (hc = 12398.42 eV·Å). Sample temperature was stated explicitly as 20°C.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV      = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, from X33's stated 1.54 Å wavelength
const TEMPERATURE_C   = 20.0             # 20°C, stated in the paper
const IONIC_STRENGTH_M = 0.200           # 200 mM NaCl, matches the SEC/SAXS buffer above

# Nsp7 sequence, read directly off SASDMJ9_fit1_model1.pdb chain B (residues
# 2-83, 82 residues). Chain C models the identical sequence plus a 2-residue
# Gly-Ser cloning-tag remnant at residues 0-1 that's disordered (not modelled)
# in chain B; the tag-free chain B sequence is used here as the dominant,
# biologically relevant species (the paper itself describes the mature
# protein, not the tag, as "Nsp7").
const NSP7_SEQ = 
    "KLTEMKCTNVVLLGLLSKMHVESNSKEWNYCVGLHNEINLCDDPDAVLEKLLALIAFFLS" *
    "KHNTCDLSDLIESYFENTTILQ"

# Average mass from NSP7_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH).
const NSP7_MW = 9331.77   # g/mol
const NSP7_CONC_MG_ML = 4.70
const NSP7_MOLARITY   = NSP7_CONC_MG_ML / NSP7_MW   # ≈ 0.504 mM
const NSP7_MOLARITY_σ = MOLARITY_REL_SIGMA * NSP7_MOLARITY

# Buffer components
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 10 mM Tris titrated with HCl -> Cl⁻ = C·0.859 (pK(22 °C) = 8.156). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.209 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.200, 0.002,   "sodium chloride"),   # 200 mM NaCl, ±1%
    NonBiological(0.010, 0.0002,  "tris"),              # 10 mM Tris-HCl, ±2%
    NonBiological(0.005, 0.0001,  "dtt"),               # 5 mM DTT, ±2%
    NonBiological(0.008588, 0.000422, "chloride"),   # Cl⁻ counter-ion from HCl titration of Tris (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT    = 0.5

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from the diameter of the
# scatterer cloud and the largest fitted q (ceil(q_max * D)), and bins the curve to the Shannon channels
# that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`. (`seed_model` bins the curve and drops the
bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(≤(Q_MAX_FIT), qvals)
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdmj9` samples. It is separate only because the developer tools in test/utils/ build
# a fit's Seed without running the fit; if you are reading this script as an example you can skip it:
# `run_sasdmj9` below is the whole story (build the seed, then sample it).
function seed_sasdmj9(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdmj9(; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    s, data = seed_sasdmj9(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdmj9()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDMJ9/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

# Plotting is loaded after the fit: loading GLMakie first invalidates compiled BAYSOL methods, which the fit then recompiles.
using GLMakie

"""
    sasdmj9_figure(result, data) -> Figure

Plots the SASDMJ9 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdmj9_figure(result, data)
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
    sasdmj9_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdmj9_residuals_figure(result, data)
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
    sasdmj9_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
"""
function sasdmj9_hist(result)
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
    sasdmj9_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit.
"""
function sasdmj9_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    crysol   = readdlm(_FIT_PATH; skipstart = 1)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdmj9_figure` -- see its
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
        color = COLOR_REFERENCE, linewidth = LW_REFERENCE, linestyle = :dash, label = "CRYSOL fit1",
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

fig = sasdmj9_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdmj9_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdmj9_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

fig_crysol = sasdmj9_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_comparison.png"), fig_crysol; px_per_unit = PX_PER_UNIT)

"Display the SASDMJ9 fit figure. Blocks until the window is closed."
vis_sasdmj9() = wait(display(fig))
