using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDNH7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNH7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNH7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNH7_fit1.fit")

# The .dat has 2 lines of header (the first one empty) and 87 lines of processing history
# at the end (merge scales, parent frames), which break `readdlm`, so `_read_curve`
# (common.jl, numeric rows only) reads it: 1374 points.
qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
@assert length(qvals) == 1374

# qvals are already in Å⁻¹ (range 0.0059-0.4770, SASBDB "1/A", BioCAT SEC-SAXS); no unit
# conversion is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDNH7 (sasbdb.org/data/SASDNH7/); paper: Montaño SP
# et al. 2022, Nucleic Acids Res., "Structural basis for topological regulation of Tn3
# resolvase", DOI 10.1093/nar/gkac733 (PMID 36100255). The paper's methods text was not
# consulted (the PDF is not bundled).
#
#     25 mM Tris, 150 mM NaCl, 10 mM MgCl2, 1% glycerol, pH 7.5
#
# Tn3 resolvase dimer (2 x 21.5 kDa) bound to the 52 bp site II DNA (32.1 kDa), 75.2 kDa
# in total; in-line SEC-SAXS (Superdex 200 10/300) of a 3 mg/mL injection, cell at
# 22 °C (storage 4 °C), BioCAT 18ID (APS), Pilatus 100K, wavelength 0.103 nm = 1.03 Å =>
# energy = hc/λ ≈ 12.04 keV (hc = 12398.42 eV·Å). The measured complex is deliberately
# NOT a solute (see BulkElectronDensity.Solute).
#
# Model: SASDNH7_fit1_model1.pdb, chains C and D (resolvase, 1415 and 1433 atoms) and Y
# and Z (the two DNA strands, 1065 and 1067 atoms); 4980 atoms, no hydrogens, no HETATM.
#
# Comparison curve: the entry's API link for the fit file returns 404, so
# `SASDNH7_fit1.fit` was fetched from https://www.sasbdb.org/media/fitting_files/
# SASDNH7_fit1.fit. It is a FoXS profile ("# SAXS profile" header, 3 comment lines;
# columns q, I_exp, error, model_intensity; q 0.0083-0.1997 Å⁻¹, 559 points) whose
# I_exp column equals this .dat to 1e-7 and whose own χ² (16.465, with FoXS offset
# 0.264) is the depositor's value in the entry; the model column is already scaled to
# the data (c = 4.0e-7, offset subtracted), so it is overlaid as it is.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12037 eV, from the stated 0.103 nm
const TEMPERATURE_C = 22.0                    # 22 °C, SASBDB (cell)

# Buffer components (the measured complex is deliberately NOT listed). Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# Assumed: 25 mM Tris titrated with HCl -> Cl⁻ = C·0.8586 (pK(22 °C) = 8.156). The pH is
# taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion amount
# whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-
# corrected at I ≈ 0.201 M (10 mM MgCl2 included). σ combines σ_PH, ±3 °C, ±0.02 pK, 30 %
# of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change
# of the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases
# (Tris, imidazole, histidine, Bis-Tris), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),                 # 25 mM Tris, ±2%
    NonBiological(0.150, 0.0015, "sodium chloride"),      # 150 mM NaCl, ±1%
    NonBiological(0.010, 0.0001, "magnesium chloride"),   # 10 mM MgCl2, ±1%
    # 1 % v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL) and MW
    # (92.094 g/mol): 1 mL glycerol/100 mL soln * 1.2613 g/mL / 92.094 g/mol * 1000
    # ≈ 0.1370 M. 5 % relative uncertainty as for the v/v glycerol of SASDJ72.jl.
    NonBiological(0.1370, 0.00685, "glycerol"),
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.021466, 0.001067, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .dat runs to 0.48 Å⁻¹ and the depositor's fit to 0.20 Å⁻¹; the 75 kDa SEC-SAXS
# curve is at the noise floor early (437 of its 1374 points are ≤ 0), so the fit is cut
# at 0.15 Å⁻¹.
const Q_MAX_FIT = 0.15

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE; PROPKA for the protein
# chains, none for the DNA)
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

# Builds the Seed that `run_sasdnh7_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdnh7_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdnh7_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdnh7_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdnh7_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdnh7_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDNH7/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit1.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL
# methods, which every fit would then recompile (about 40 % of a fit's wall clock).
using GLMakie

"""
    sasdnh7_fit1_figure(result, data) -> Figure

Plots the SASDNH7 fit1 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdnh7_fit1_figure(result, data)
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
    sasdnh7_fit1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdnh7_fit1_residuals_figure(result, data)
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
    sasdnh7_fit1_hist(result) -> Figure
"""
function sasdnh7_fit1_hist(result)
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
    sasdnh7_fit1_comparison_figure(result, data) -> Figure
"""
function sasdnh7_fit1_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    crysol   = readdlm(_FIT_PATH; skipstart = 3)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep     = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

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
        label = "FoXS fit1",
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

fig_fit1 = sasdnh7_fit1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1.png"), fig_fit1; px_per_unit = PX_PER_UNIT)

fig_fit1_residuals = sasdnh7_fit1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(
    joinpath(@__DIR__, "res_fit1_residuals.png"),
    fig_fit1_residuals;
    px_per_unit = PX_PER_UNIT,
)

fig_fit1_hist = sasdnh7_fit1_hist(result)
save(joinpath(@__DIR__, "res_fit1_hist.png"), fig_fit1_hist; px_per_unit = PX_PER_UNIT)

fig_fit1_crysol = sasdnh7_fit1_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(
    joinpath(@__DIR__, "res_fit1_comparison.png"),
    fig_fit1_crysol;
    px_per_unit = PX_PER_UNIT,
)

"Display the SASDNH7 fit1 figure. Blocks until the window is closed."
vis_sasdnh7_fit1() = wait(display(fig_fit1))
