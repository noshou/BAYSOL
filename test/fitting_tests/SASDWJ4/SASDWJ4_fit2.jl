using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWJ4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWJ4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWJ4_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWJ4_fit2.fit")

# The .dat has 3 lines of header and 53 lines of processing history at the end, and the
# latter break `readdlm` (SASDVV4's has quote characters), so `_read_curve` (common.jl,
# numeric rows only) reads it: 2630 points.
qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
@assert length(qvals) == 2630

# qvals are in nm⁻¹ (0.0224-7.33); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDWJ4 (sasbdb.org/data/SASDWJ4/); paper: Stafflinger
# et al. 2025, Nucleic Acids Res., "Crystal structure of the class V GTP-binding RNA
# aptamer bound to its ligand: GTP recognition by a topologically complex intermolecular
# G-quadruplex", DOI 10.1093/nar/gkaf1315 (PMID 41422825). The paper's own methods text
# was not consulted.
#
#     50 mM Bis-Tris, 50 mM KCl, 2 mM MgCl2, pH 6.5
#
# Class V GTP aptamer (68 nt, 22.1 kDa) with GTP, 6.0 mg/mL, one concentration, 20 °C
# (cell and storage), EMBL P12 (PETRA III), wavelength 0.123985 nm => energy =
# hc/λ ≈ 10 keV (hc = 12398.42 eV·Å). The model (SASDWJ4_fit2_model1.pdb) is the crystal
# structure: one RNA chain with two bound GTP, K⁺ and Mn²⁺ ions as HETATM records.
# The GTP concentration of the sample is not stated in the SASBDB record, and GTP is not in
# the bundled solute tables, so the free ligand is not listed as a solute (it is part of the
# model). The macromolecule is deliberately NOT listed either.

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - free GTP: concentration unknown (GTP is in the tables now, tetrasodium salt, measured
#     290 ± 22 cm³/mol); est. +0.026 % per mM

const PH, σ_PH = 6.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.23985   # ≈ 10000 eV, from the stated 0.123985 nm
const TEMPERATURE_C = 20.0                       # 20 °C, SASBDB

# Buffer components. Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# Assumed: 50 mM Bis-Tris titrated with HCl -> Cl⁻ = C·0.578 (Bis-Tris pK 6.484 at 25 °C,
# ΔH 28.4 kJ/mol, ΔCp taken as 0; pK(22 °C) = 6.535). The pH is taken as set at room
# temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31,
# 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.085 M.
# σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the
# counter-ion is modelled; the volume change of the buffer's own (de)protonation is not.
# Titrant: not stated; HCl for amine bases (Tris, imidazole, histidine, Bis-Tris), NaOH
# for Good's buffers.
# (The Bis-Tris pK and ΔH are the Goldberg 2002 values as quoted by a secondary calculator
# page, not read from the paper itself.)
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.050, 0.001, "bis-tris"),              # 50 mM Bis-Tris, ±2%
    NonBiological(0.050, 0.0005, "potassium chloride"),   # 50 mM KCl, ±1%
    NonBiological(0.002, 0.00002, "magnesium chloride"),  # 2 mM MgCl2, ±1%
    # Cl⁻ counter-ion from HCl titration of Bis-Tris (see note above)
    NonBiological(0.028895, 0.003359, "chloride"),
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "free GTP: concentration unknown; est. +0.026 % per mM (tetrasodium salt)",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDWJ4: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .fit file (q to 0.5 Å⁻¹) and the .dat (to 0.73 Å⁻¹) are cut at 0.3 Å⁻¹.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model already carries hydrogens (745 H, ANISOU
# records too); pdb2pqr rebuilds them at PH, as for SASDWZ9.
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`. (`seed_model`
bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(≤(Q_MAX_FIT), qvals)
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdwj4_fit2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdwj4_fit2` below is the whole story (build the seed, then sample it).
function seed_sasdwj4_fit2(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdwj4_fit2(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdwj4_fit2(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdwj4_fit2()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDWJ4/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit2.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL
# methods, which every fit would then recompile (about 40 % of a fit's wall clock).
using GLMakie

"""
    sasdwj4_fit2_figure(result, data) -> Figure

Plots the SASDWJ4 fit2 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdwj4_fit2_figure(result, data)
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

    # Log-symmetric errorbars via the delta method (see SASDMJ9_figure's
    # comment for why a raw additive I ± σ interval is not used here).
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

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end

"""
    sasdwj4_fit2_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdwj4_fit2_residuals_figure(result, data)
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
    sasdwj4_fit2_hist(result) -> Figure
"""
function sasdwj4_fit2_hist(result)
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
    sasdwj4_fit2_comparison_figure(result, data) -> Figure
"""
function sasdwj4_fit2_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    ref = readdlm(_FIT_PATH; skipstart = 1)
    # Pepsi-SAXS wrote I_exp and I_fit divided by the 6.0 mg/mL concentration (the file's
    # I_exp is the .dat's I / 6.0000), so its fit is scaled back onto the data.
    q_crysol, I_crysol = _rescale_fit(
        (Float64.(ref[:, 1]), Float64.(ref[:, 4])), q_fit, I_fit,
    )
    keep = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR,
    )
    scatter!(ax, q_fit, I_fit; markersize = MARKERSIZE, color = COLOR_DATA, label = "data")

    lines!(
        ax, q_crysol[keep], I_crysol[keep];
        color = COLOR_REFERENCE, linewidth = LW_REFERENCE, linestyle = :dash,
        label = "Pepsi-SAXS fit2 (rescaled)",
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

fig_fit2 = sasdwj4_fit2_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit2.png"), fig_fit2; px_per_unit = PX_PER_UNIT)

fig_fit2_residuals = sasdwj4_fit2_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(
    joinpath(@__DIR__, "res_fit2_residuals.png"),
    fig_fit2_residuals;
    px_per_unit = PX_PER_UNIT,
)

fig_fit2_hist = sasdwj4_fit2_hist(result)
save(joinpath(@__DIR__, "res_fit2_hist.png"), fig_fit2_hist; px_per_unit = PX_PER_UNIT)

fig_fit2_crysol = sasdwj4_fit2_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(
    joinpath(@__DIR__, "res_fit2_comparison.png"),
    fig_fit2_crysol;
    px_per_unit = PX_PER_UNIT,
)

"Display the SASDWJ4 fit2 figure. Blocks until the window is closed."
vis_sasdwj4_fit2() = wait(display(fig_fit2))
