using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDUN5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUN5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUN5: Deciphering the allosteric regulation of mycobacterial
# inosine-5′-monophosphate dehydrogenase
#
# Paper: Bulvas O, Knejzlík Z, Sýs J, et al., Nature Communications (2024), DOI
# 10.1038/s41467-024-50933-6.
# Open access (CC BY); PDF filed with the data:
# test/fixtures/experiments/SASDUN5/s41467-024-50933-6.pdf (PMC PMC11303537).
# SASBDB entry: https://www.sasbdb.org/data/SASDUN5/
#
# Sample: IMPDH (tetramer, 53.257 kDa/chain); measured at up to 3.0 mg/ml (Single
# concentration).
# Instrument: Institute of Biotechnology, Czech Academy of Sciences/Centre of Molecular
# Structure (X-ray in house), wavelength 0.134 nm = 1.34 Å => energy = hc/λ ≈ 9253 eV (hc =
# 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "50 mM HEPES, 200 mM KCl, 2 mM MgCl2, 0.5 mM TCEP", pH 7.5.
#
# The deposited string omits the ligand. This is the IMP-bound dataset: the .dat header's buffer
# blank is "10_buffer_onlyIMP10mM.dat", and the paper (s41467-024-50933-6.pdf, Methods, "Small
# angle X-ray scattering") states the samples were measured with nucleotide (0-10 mM) "and a
# 2 mM molar excess of MgCl2 over the nucleotide concentration. Buffer-solution datasets were
# collected under the same conditions, including the respective nucleotides." So the blank holds
# 10 mM IMP and 2 + 10 = 12 mM MgCl2 (the deposited "2 mM MgCl2" is the excess only). IMP is
# taken as the disodium salt (PMV: 'inosine 5'-monophosphate disodium salt', a predicted value,
# see PartialMolarVolumes/README.md).
#
# Curve units: the SASBDB .dat is in nm⁻¹ and is converted to Å⁻¹ (÷10). The reference fit files
# are read from the same folder; each run's comparison curve is the depositor's fit for that
# model.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, from the stated 0.134 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the buffer's electron density).
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 50 mM HEPES titrated with NaOH -> Na⁺ = C·0.519 (pK(22 °C) = 7.6). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.292 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM, ±2%
    NonBiological(0.2, 0.004, "potassium chloride"),   # 200 mM, ±2%
    NonBiological(0.012, 0.00024, "magnesium chloride"),   # 2 mM excess + 10 mM (= [IMP]), ±2%
    NonBiological(0.010, 0.0002, "imp disodium salt"),   # 10 mM IMP (buffer blank), ±2%
    NonBiological(0.0005, 1e-05, "tcep"),   # 0.5 mM, ±2%
    NonBiological(0.025963, 0.003365, "sodium(1+)"),   # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from the diameter of the
# scatterer cloud and the largest fitted q (ceil(q_max * D)), and bins the curve to the Shannon channels
# that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (tag = "fit1_model1", pdb = "SASDUN5_fit1_model1.pdb", fit = "SASDUN5_fit1.fit", fit_scale = 1.0, fit_col = 4, rescale = false, software = "OLIGOMER 2-state"),   # D_max ≈ 160 Å; deposited χ² = 2.21
    (tag = "fit1_model2", pdb = "SASDUN5_fit1_model2.pdb", fit = "SASDUN5_fit1.fit", fit_scale = 1.0, fit_col = 4, rescale = false, software = "OLIGOMER 2-state"),   # D_max ≈ 167 Å; deposited χ² = 2.21
]

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`. (`seed_model` bins the curve and drops the bins
with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdun5` samples. It is separate only because the developer tools in test/utils/ build
# a fit's Seed without running the fit; if you are reading this script as an example you can skip it:
# `run_sasdun5` below is the whole story (build the seed, then sample it).
function seed_sasdun5(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdun5(run; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    s, data = seed_sasdun5(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

"""
    sasdun5_figure(result, data) -> Figure

Plots the SASDUN5 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdun5_figure(result, data)
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
    sasdun5_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdun5_residuals_figure(result, data)
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
    sasdun5_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
"""
function sasdun5_hist(result)
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
    sasdun5_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the depositor's reference fit (`fit_curve = (q, I)`, or
`nothing` if the fit file could not be parsed, in which case no figure is made).
"""
function sasdun5_comparison_figure(result, data, fit_curve, label)
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

    # Same log-symmetric errorbar treatment as `sasdun5_figure` -- see its
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


# the results of every run, kept for the figures below
fits = Dict{String,Any}()

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdun5(run)

    # `@__DIR__` (this SASDUN5/ folder), not the caller's cwd.
    open(joinpath(@__DIR__, "res$(suffix).txt"), "w") do io
        BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
    end

    fits[run.tag] = (result, (q_fit, I_fit, σ_fit))
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL methods, which every fit would
# then recompile (about 40 % of a fit's wall clock).
using GLMakie

for run in RUNS
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag
    result, data = fits[run.tag]
    q_fit, I_fit, σ_fit = data

    fig = sasdun5_figure(result, data)
    save(joinpath(@__DIR__, "res$(suffix).png"), fig; px_per_unit = PX_PER_UNIT)

    fig_residuals = sasdun5_residuals_figure(result, data)
    save(joinpath(@__DIR__, "res$(suffix)_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

    fig_hist = sasdun5_hist(result)
    save(joinpath(@__DIR__, "res$(suffix)_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

    fit_curve = try
        fc = _read_fit(joinpath(_FIXTURE_DIR, run.fit), run.fit_scale, run.fit_col)
        fc !== nothing && run.rescale ? _rescale_fit(fc, q_fit, I_fit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    fig_cmp = sasdun5_comparison_figure(result, data, fit_curve, run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""))
    fig_cmp === nothing || save(joinpath(@__DIR__, "res$(suffix)_comparison.png"), fig_cmp; px_per_unit = PX_PER_UNIT)
end
