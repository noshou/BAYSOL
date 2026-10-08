using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

# =============================================================================
#                                *** CAUTION ***
# =============================================================================
# SASDX52 is the LEAST-documented case in this test family: no bundled paper
# PDF, no experimental_data/*.dat, no GNOM pddf. The ONLY fixture files are
# SASDX52_fit1.fit (the sole source of q/I/σ *and* the reference fit curve)
# and SASDX52_fit1_model1.pdb (an AlphaFold-monomer-derived, depositor-docked
# dimer model). All solution-condition metadata below comes from ONE of three
# tiers, marked explicitly at each declaration:
#
#   [SASBDB]    fetched from https://www.sasbdb.org/data/SASDX52/ via WebFetch
#               in this session -- NOT cross-checked against the underlying
#               paper (Rahman, Dalwani & Venkatesan 2025, Biochem Biophys Res
#               Commun 769:151960) because no PDF is bundled here. Treat as
#               provisional, SASBDB-page-sourced metadata, not paper-verified.
#   [DEFAULT]   this package's own default (a module-level constant of the owning module),
#               used because nothing case-specific was available.
#   [PLACEHOLDER] a best-effort, UNVERIFIED guess with no direct source at
#               all -- flagged loudly inline.
#
# This case needs more scrutiny before being trusted than any of its siblings.
# =============================================================================

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDX52")
const _PDB_PATH     = joinpath(_FIXTURE_DIR, "SASDX52_fit1_model1.pdb")
const _FIT_PATH     = joinpath(_FIXTURE_DIR, "SASDX52_fit1.fit")

# No experimental_data/*.dat bundled: SASDX52_fit1.fit is the only source of
# q/I/σ. 3 '#' header lines, 4 columns: q, exp_intensity, error, model_intensity.
# q is already in Å⁻¹ (SASBDB .fit outputs are Å⁻¹, unlike some raw .dat
# files which come in nm⁻¹ and need /10 -- no such conversion here).
raw = readdlm(_FIT_PATH; skipstart = 3)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# [SASBDB] WebFetch of https://www.sasbdb.org/data/SASDX52/ in this session
# returned (no bundled paper PDF to cross-verify against):
#
#   Protein:      Fatty acyl-CoA synthetase FadD5 (probable fatty-acid-CoA
#                 ligase), Mycobacterium tuberculosis (H37Rv); dimer;
#                 monomer MW ≈ 61.7 kDa (SASBDB's own figure; the
#                 sequence-derived MW computed below, ≈59.9 kDa, is used for
#                 the molarity conversion instead -- see FADD5_MW).
#   Buffer:       20 mM HEPES, 500 mM NaCl, 5 mM MgCl2, 1 mM
#                 beta-mercaptoethanol, pH 7.5
#   Conc.:        4.00 mg/ml, 20 successive 1 s frames
#   Temperature:  4 °C
#   Beamline:     Diamond Light Source B21, Eiger 4M, wavelength 0.09537 nm,
#                 sample-detector distance 3.72 m
#   Publication:  Rahman MA, Dalwani S, Venkatesan R (2025), "Structural
#                 enzymological studies of the long chain fatty acyl-CoA
#                 synthetase FadD5 from the mce1 operon of Mycobacterium
#                 tuberculosis", Biochem Biophys Res Commun 769:151960.

const PH, σ_PH = 7.5, PH_METER_SIGMA   # [SASBDB]; σ not stated by SASBDB

# [SASBDB] wavelength 0.09537 nm = 0.9537 Å => energy = hc/λ ≈ 13000.3 eV
# (hc = 12398.42 eV·Å).
const ENERGY_EV = HC_EV_ANGSTROM / 0.9537   # ≈ 13000.3 eV

# [SASBDB] 4°C.
const TEMPERATURE_C = 4.0

const DEBYE_T_K = 4.0 + 273.15   # 277.15 K

# [SASBDB] buffer-derived ionic strength: I = 1/2 Σ cᵢzᵢ².
#   500 mM NaCl:  1/2*(0.500*1² + 0.500*1²)          = 0.500
#   5 mM MgCl2:   1/2*(0.005*2² + 0.010*1²)          = 0.015
#   HEPES (zwitterionic near pH 7.5) and 1 mM BME (nonionic) contribute
#   negligibly and are omitted.
const IONIC_STRENGTH_M = 0.515

# FadD5 sequence, read directly off SASDX52_fit1_model1.pdb chain A SEQRES
# (554 residues). 
const FADD5_SEQ = 
    "MTAQLASHLTRALTLAQQQPYLARRQNWVNQLERHAMMQPDAPALRFVGNTMTWADLRRR" *
    "VAALAGALSGRGVGFGDRVMILMLNRTEFVESVLAANMIGAIAVPLNFRLTPTEIAVLVE" *
    "DCVAHVMLTEAALAPVAIGVRNIQPLLSVIVVAGGSSQDSVFGYEDLLNEAGDVHEPVDI" *
    "PNDSPALIMYTSGTTGRPKGAVLTHANLTGQAMTALYTSGANINSDVGFVGVPLFHIAGI" *
    "GNMLTGLLLGLPTVIYPLGAFDPGQLLDVLEAEKVTGIFLVPAQWQAVCTEQQARPRDLR" *
    "LRVLSWGAAPAPDALLRQMSATFPETQILAAFGQTEMSPVTCMLLGEDAIAKRGSVGRVI" *
    "PTVAARVVDQNMNDVPVGEVGEIVYRAPTLMSCYWNNPEATAEAFAGGWFHSGDLVRMDS" *
    "DGYVWVVDRKKDMIISGGENIYCAELENVLASHPDIAEVAVIGRADEKWGEVPIAVAAVT" *
    "NDDLRIEDLGEFLTDRLARYKHPKALEIVDALPRNPAGKVLKTELRLRYGACVNVERRSA" *
    "SAGFTERRENRQKL"

# Average mass from FADD5_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH) => ≈59.91 kDa, close to (but not identical to) SASBDB's
# own quoted 61.7 kDa monomer MW; the sequence-derived value is used for
# internal consistency with FADD5_SEQ.
const FADD5_MW = 59905.88   # g/mol

# [SASBDB] 4.00 mg/ml protein concentration / sequence-derived monomer MW.
const FADD5_CONC_MG_ML = 4.00
const FADD5_MOLARITY   = FADD5_CONC_MG_ML / FADD5_MW # ≈ 6.68e-5 M
const FADD5_MOLARITY_σ = MOLARITY_REL_SIGMA * FADD5_MOLARITY   # σ not stated by SASBDB

# Buffer components. All four species below were cross-checked against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json and found
# present (no MISSING FROM PMV LOOKUP entries for this case):
#   "sodium chloride"    -> "sodium chloride"
#   "magnesium chloride" -> "magnesium dichloride"
#   "hepes"               -> "2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonic acid"
#   "2-mercaptoethanol"   -> "2-mercaptoethanol"
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM HEPES titrated with NaOH -> Na⁺ = C·0.519 (pK(22 °C) = 7.6). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.525 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.500, 0.005,   "sodium chloride"),    # 500 mM NaCl, ±1%
    NonBiological(0.020, 0.0004,  "hepes"),              # 20 mM HEPES, ±2%
    NonBiological(0.005, 0.0001,  "magnesium chloride"), # 5 mM MgCl2, ±2%
    NonBiological(0.001, 0.00005, "2-mercaptoethanol"),  # 1 mM BME, ±5% (small conc., degrades/evaporates)
    NonBiological(0.010382, 0.001346, "sodium(1+)"),   # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# Full q-range of the only data source (SASDX52_fit1.fit): q_max ≈ 0.16996.
# No additional high-q truncation is needed (the bundled .fit file is
# already restricted to the fitted range), but Q_MAX_FIT/fit_subset() are
# kept for consistency with the rest of this test family and as a guard
# against any I_exp ≤ 0 points.
const Q_MAX_FIT = 0.17

# No GNOM pddf bundled for this case (no pddf/ directory at all), so lMax is
# estimated from the PDB structure's own coordinate extent instead of a
# GNOM Dmax: max pairwise Cα-Cα distance over all 1108 Cα atoms (both
# chains) = 208.05 Å. Using the usual q·D_max multipole-resolution rule of
# thumb: Q_MAX_FIT * D_max ≈ 0.17 * 208 ≈ 35.4 => lMax = 36.
const LMAX = 36

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdx52` samples. It is separate only because the developer tools in test/utils/ build
# a fit's Seed without running the fit; if you are reading this script as an example you can skip it:
# `run_sasdx52` below is the whole story (build the seed, then sample it).
function seed_sasdx52(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (q_fit, I_fit, σ_fit)
end

function run_sasdx52(; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    s, data = seed_sasdx52(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdx52()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDX52/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdx52_figure(result, data) -> Figure

Plots the SASDX52 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdx52_figure(result, data)
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
    sasdx52_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdx52_residuals_figure(result, data)
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
    sasdx52_hist(result) -> Figure
"""
function sasdx52_hist(result)
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
    sasdx52_comparison_figure(result, data) -> Figure

Overlays our MAP curve against SASDX52_fit1.fit's own reference
curve (`model_intensity` column). 
"""
function sasdx52_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    ref      = readdlm(_FIT_PATH; skipstart = 3)
    q_ref    = Float64.(ref[:, 1])
    I_ref    = Float64.(ref[:, 4])
    keep     = (q_ref .> 0) .& (q_ref .≤ Q_MAX_FIT) .& (I_ref .> 0)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdx52_figure`.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR,
    )
    scatter!(ax, q_fit, I_fit; markersize = MARKERSIZE, color = COLOR_DATA, label = "data")

    lines!(
        ax, q_ref[keep], I_ref[keep];
        color = COLOR_REFERENCE, linewidth = LW_REFERENCE, linestyle = :dash, label = "SASBDB fit1",
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

fig = sasdx52_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdx52_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdx52_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

fig_crysol = sasdx52_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_comparison.png"), fig_crysol; px_per_unit = PX_PER_UNIT)

"Display the SASDX52 fit figure. Blocks until the window is closed."
vis_sasdx52() = wait(display(fig))
