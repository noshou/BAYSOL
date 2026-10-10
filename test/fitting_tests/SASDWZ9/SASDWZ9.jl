using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
using BAYSOL.Inference: PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWZ9")
const _PDB_PATH = joinpath(_FIXTURE_DIR, "SASDWZ9_fit1_model1.pdb")
const _FIT_PATH = joinpath(_FIXTURE_DIR, "SASDWZ9_fit1.fit")

# `experimental_data/` and `pddf/` are both empty for this fixture (no
# standalone .dat and no GNOM .out were bundled).
raw = readdlm(_FIT_PATH; skipstart = 6)

qvals       = Float64.(raw[:, 1])
I_exp       = Float64.(raw[:, 2])
σ_exp       = Float64.(raw[:, 3])
I_pepsi_fit = Float64.(raw[:, 4])   # Pepsi-SAXS's own fitted curve, for the comparison plot

# q is already in Å⁻¹ here (range ≈ 0.0083-0.3501, the usual protein-SAXS
# scale) -- unlike SASDMJ9's SASBDB .dat export, no nm⁻¹ -> Å⁻¹ conversion
# is needed.

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Huang et al. 2026, ACS Omega 11:2614-2627 ("pH Sensitivity of the
# SERF1a Conformational Ensemble"), doi:10.1021/acsomega.5c07620,
# "Materials and Methods" / "Purification and Preparation of Samples" (the
# only Methods paragraph in the bundled main-text PDF; a separate
# Supporting Information PDF with further experimental detail is referenced
# but not bundled in this fixture).
#
# The paper states the final SEC running buffer used immediately before
# SAXS is "a size-exclusion column, Superdex 75 Increase 10/300 (Cytiva) in
# 20 mM NaPi (pH 6.0 or pH 6.8), 20 mM NaCl, and 0.02% NaN3." SASDWZ9 (vs.
# its sibling SASDWY9, the pH 6 dataset from the same paper) is the pH 6.8
# entry: confirmed both by the .fit file's own embedded Pepsi-SAXS command
# line (`S7_pH68_...`) and by the SASBDB metadata page for SASDWZ9
# (sasbdb.org/data/SASDWZ9/), which additionally gives the sample details
# the bundled main-text PDF itself doesn't state:
#
#     protein concentration: 15.00 mg/ml
#     buffer:                20 mM sodium phosphate, 20 mM NaCl, pH 6.8
#     temperature:            10°C
#     beamline:                TPS 13A, NSRRC (Hsinchu, Taiwan), Eiger X 9M
#     wavelength:              0.08266 nm = 0.8266 Å  => energy = hc/λ ≈ 15.0 keV
#
# consistent with TPS 13A's published nominal ~15 keV configuration
# (Shih et al. 2022, J. Appl. Crystallogr. 55:340-352, cited as ref. 62 in
# the paper for the beamline itself).

const PH, σ_PH = 6.8, PH_METER_SIGMA

# ≈ 15000 eV, from SASBDB's stated 0.08266 nm wavelength
const ENERGY_EV     = HC_EV_ANGSTROM / 0.8266
const TEMPERATURE_C = 10.0   # 10°C, SASBDB
# unused by the fit; derived from the old pKa2 = 7.2 split (see below)
const IONIC_STRENGTH_M = 0.0545

# SERF1a sequence, read directly off SASDWZ9_fit1_model1.pdb chain A
# (residues 1-62, all 62 residues modelled -- this is a single filtered
# NMR/TAiBP-CYANA conformer, MODEL 37 of the deposited ensemble, not a
# crystal structure). MW below is computed from this sequence and matches
# SASBDB's stated "7.3 kDa (monomer)" to within rounding.
const SERF1A_SEQ = "MARGNQRELARQKNMKKTQEISKGKRKEDSLTASQRKQRDSEIMQEKQKAANEKKSMQTREK"

# Average mass from SERF1A_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH).
const SERF1A_MW = 7336.37   # g/mol
# SASBDB metadata (not stated in the bundled main-text PDF)
const SERF1A_CONC_MG_ML = 15.00
const SERF1A_MOLARITY   = SERF1A_CONC_MG_ML / SERF1A_MW   # ≈ 2.045 mM
const SERF1A_MOLARITY_σ = MOLARITY_REL_SIGMA * SERF1A_MOLARITY   # σ not stated

# Buffer components.
#
# "20 mM NaPi" is not itself a single species: at pH 6.8 it is a mix of NaH2PO4 and
# Na2HPO4. The HPO4²⁻ fraction is 0.425: pK2 from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230
# J/K/mol) at 22 °C (pH set at room temperature), Davies-corrected at I ≈ 0.060 M, giving
# an effective pK2' ≈ 6.93. This replaces the earlier flat pKa2 = 7.2, which ignored ionic
# strength. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
#
# 0.02% NaN3 (w/v) = 0.2 g/L; MW(NaN3) = 65.01 g/mol => ≈ 3.08 mM.
#
# IONIC_STRENGTH_M above is I = ½Σ cᵢzᵢ² over all these species (Na⁺, Cl⁻,
# H2PO4⁻, HPO4²⁻ [z=-2, so it enters with weight 4], N3⁻) rather than just
# the 20 mM NaCl term (as the simpler SASDMJ9 buffer used), since the
# doubly-charged HPO4²⁻ fraction is a non-negligible contributor here:
#
#     Na⁺ total = 0.020 + 0.01431 + 2·0.00569 + 0.00308 ≈ 0.04877 M
#     I = ½·[0.04877·1 + 0.020·1 + 0.01431·1 + 0.00569·4 + 0.00308·1] ≈ 0.0545 M
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.020, 0.0002, "sodium chloride"),             # 20 mM NaCl, ±1%
    # 20 mM NaPi, H2PO4⁻ part
    NonBiological(0.011494, 0.001491, "sodium dihydrogen phosphate"),
    # 20 mM NaPi, HPO4²⁻ part
    NonBiological(0.008506, 0.001483, "disodium hydrogen phosphate"),
    NonBiological(0.003076, 0.0000615, "sodium azide"),                # 0.02% w/v NaN3, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.35   # the .fit file's own full q-range (≈0.0083-0.3501 Å⁻¹)

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true  # runs Pdb2pqr at PH; the NMR structure already carries
# modelled hydrogens, but Pdb2pqr recomputes pH-consistent
# protonation states from the heavy-atom positions regardless.

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdwz9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdwz9` below is the whole story (build the seed, then sample it).
function seed_sasdwz9(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdwz9(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdwz9(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdwz9()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDWZ9/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL
# methods, which every fit would then recompile (about 40 % of a fit's wall clock).
using GLMakie

"""
    sasdwz9_figure(result, data) -> Figure

Plots the SASDWZ9 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdwz9_figure(result, data)
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
    sasdwz9_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdwz9_residuals_figure(result, data)
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

# ξ = (ρₑ, δρ₁, δρ₂, δρ₃)
"""
    sasdwz9_hist(result) -> Figure
"""
function sasdwz9_hist(result)
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
    sasdwz9_comparison_figure(result, data) -> Figure


"""
function sasdwz9_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    keep = (qvals .> 0) .& (qvals .≤ Q_MAX_FIT) .& (I_pepsi_fit .> 0)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdwz9_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR,
    )
    scatter!(ax, q_fit, I_fit; markersize = MARKERSIZE, color = COLOR_DATA, label = "data")

    lines!(
        ax, qvals[keep], I_pepsi_fit[keep];
        color = COLOR_REFERENCE, linewidth = LW_REFERENCE, linestyle = :dash,
        label = "Pepsi-SAXS fit1",
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

fig = sasdwz9_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdwz9_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdwz9_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

fig_pepsi = sasdwz9_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_comparison.png"), fig_pepsi; px_per_unit = PX_PER_UNIT)

"Display the SASDWZ9 fit figure. Blocks until the window is closed."
vis_sasdwz9() = wait(display(fig))
