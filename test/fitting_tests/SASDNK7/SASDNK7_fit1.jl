using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDNK7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNK7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNK7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNK7_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 212)

# has 212 lines of header (a REMARK-like "# ..." block ending in "# Number of DATA: 841"),
# and no trailer: skip the block, then all 841 data rows follow.
qvals = Float64.(raw[1:841, 1])
I_exp = Float64.(raw[1:841, 2])
σ_exp = Float64.(raw[1:841, 3])

# q is already in Å⁻¹ (range 0.0087-0.5654, SASBDB "1/A", PF BL-10C); no unit conversion
# is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDNK7/); paper: Miyauchi K, Imamura H,
# Yamaoki Y, Kato M 2022, Data in Brief ("Small-angle X-ray scattering data of a
# guanine-rich DNA derived from the promoter region of c-MYC gene in solution"), DOI
# 10.1016/j.dib.2022.108285.
#
#   Sample:   MYC22-G14T/G23T (Pu22), a 22-mer guanine-rich DNA from the c-MYC promoter
#             (TGAGGGTGGGTAGGGTGGGTAA, 7.071 kDa, G-quadruplex with K⁺), 1.80 mg/mL
#             (one concentration), 30 x 2 s frames
#   Buffer:   "50 mM Tris, 30 mM KCl", pH 8.0
#   Temp.:    25 °C ("One solute concentration of 1.80 mg/ml was measured at 25°C")
#   Beamline: Photon Factory BL-10C (KEK), Pilatus3 2M, "wavelength of λ = 0.15 nm"
#             => 1.5 Å => energy = hc/λ ≈ 8265.6 eV
#   Model:    SASDNK7_fit1_model1.pdb (derived from PDB 1XAV), chain A, 22 nucleotides
#             with 249 hydrogens, plus two K⁺ ions as HETATM residues "K" (residues 30 and
#             31; 718 atoms in all); deposited with the CRYSOL fit1 (χ² 1.391)

const PH, σ_PH = 8.0, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8265.6 eV, from the stated 0.15 nm
const TEMPERATURE_C = 25.0                   # 25 °C, SASBDB

# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 50 mM Tris titrated with HCl -> Cl⁻ = C·0.6393 (pK(22 °C) = 8.156; ΔH
# 47.45 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.062 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.030, 0.0003, "potassium chloride"),   # 30 mM KCl, ±1%
    NonBiological(0.050, 0.001, "tris"),                   # 50 mM Tris, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.031963, 0.003652, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.5: the depositor's own fit (and its CRYSOL curve) stops at 0.5006 Å⁻¹; the data
# continue to 0.5654 Å⁻¹ but 54 of its 841 points are ≤ 0 and the tail is noise.
const Q_MAX_FIT = 0.5

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true although the model already carries 249 hydrogens, as for SASDWZ9:
# Pdb2pqr rebuilds the hydrogens from the heavy atoms.
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdnk7_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdnk7_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdnk7_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdnk7_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdnk7_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdnk7_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDNK7/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit1.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL
# methods, which every fit would then recompile (about 40 % of a fit's wall clock).
using GLMakie

"""
    sasdnk7_fit1_figure(result, data) -> Figure

Plots the the c-MYC Pu22 G-quadruplex (SASDNK7 fit1) fit: the
experimental data (`data = (q_fit, I_fit, σ_fit)`) with its per-point
standard errors, the MAP predicted curve, and (when not all draws
diverged) the quantile-curve envelope.
"""
function sasdnk7_fit1_figure(result, data)
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
    sasdnk7_fit1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
similarly re-centred on the MAP curve.
"""
function sasdnk7_fit1_residuals_figure(result, data)
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
            # NB: shared COLOR_BAND_RESID is (:darkorange,
            # 1); this script's plot style is kept as-is
            color = (:darkorange, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5,
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
    sasdnk7_fit1_hist(result) -> Figure


"""
function sasdnk7_fit1_hist(result)
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
    sasdnk7_fit1_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the depositor's CRYSOL fit.
"""
function sasdnk7_fit1_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    crysol   = readdlm(_FIT_PATH; skipstart = 1)
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
        label = "CRYSOL fit1",
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

fig = sasdnk7_fit1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdnk7_fit1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdnk7_fit1_hist(result)
save(joinpath(@__DIR__, "res_fit1_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

fig_crysol = sasdnk7_fit1_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_comparison.png"), fig_crysol; px_per_unit = PX_PER_UNIT)

"Display the SASDNK7 fit1 figure. Blocks until the window is closed."
vis_sasdnk7_fit1() = wait(display(fig))
