using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

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
#   [DEFAULT]   this package's own default (BAYSOL_Utils/Constants.jl),
#               used because nothing case-specific was available.
#   [PLACEHOLDER] a best-effort, UNVERIFIED guess with no direct source at
#               all -- flagged loudly inline.
#
# This case needs more scrutiny before being trusted than any of its siblings.
# =============================================================================

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDX52")
const _PDB_PATH     = joinpath(_FIXTURE_DIR, "SASDX52_fit1_model1.pdb")
const _FIT_PATH     = joinpath(_FIXTURE_DIR, "SASDX52_fit1.fit")

# No experimental_data/*.dat bundled: SASDX52_fit1.fit is the ONLY source of
# q/I/σ. Its header (inspected directly):
#
#   # SAXS profile: number of points = 409, q_min = 0.0101155983284116, q_max = 0.169964402914047, delta_q = 0.000391786285749107
#   # offset = 0.00000000000000, scaling c = 3.05570716557694e-09, Chi^2 = 0.698835430001557
#   #  q       exp_intensity   error model_intensity
#
# i.e. 3 '#' header lines, 4 columns: q, exp_intensity, error, model_intensity.
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
#                 (Not bundled here; not independently checked against this
#                 script's values.)
#
# Crystallization-vs-SAXS-buffer caveat does not apply here (no crystal
# structure/crystallization buffer involved -- the model is AlphaFold, and
# SASBDB's listed buffer is explicitly the SAXS sample buffer), but the page
# metadata itself is still unverified against the primary paper.

const PH, σ_PH = 7.5, 0.1   # [SASBDB] ±0.1 is a typical benchtop pH-meter precision (not stated by SASBDB)

# [SASBDB] wavelength 0.09537 nm = 0.9537 Å => energy = hc/λ ≈ 13000.3 eV
# (hc = 12398.42 eV·Å).
const ENERGY_EV = 12398.42 / 0.9537   # ≈ 13000.3 eV

# [DEFAULT] Real experimental temperature was 4°C [SASBDB], but
# `t`/DEFAULT_TEMPERATURE_C drives BAYSOL_Utils.Constants._ρₑ's bulk
# solvent-electron-density calculation, which is explicitly documented
# (Constants.jl, DEFAULT_TEMPERATURE_C docstring) as *only* supporting
# water's density at 25°C in this version -- "do not change". So t=25.0
# here, NOT the real 4°C.
const TEMPERATURE_C = 25.0

# [SASBDB] `T` (Debye screening temperature, Kelvin) is a *separate*
# parameter from `t` above -- Constants.jl's DEBYE_TEMPERATURE_K docstring
# states explicitly the two "aren't currently reconciled to the same
# value" and each keeps its own default. Unlike `t`, nothing restricts `T`
# to 25°C, so the real measured temperature (4°C) is used here rather than
# defaulting/reconciling to TEMPERATURE_C, as done for the Debye
# screening-length calculation.
const DEBYE_T_K = 4.0 + 273.15   # 277.15 K

# [SASBDB] buffer-derived ionic strength: I = 1/2 Σ cᵢzᵢ².
#   500 mM NaCl:  1/2*(0.500*1² + 0.500*1²)          = 0.500
#   5 mM MgCl2:   1/2*(0.005*2² + 0.010*1²)          = 0.015
#   HEPES (zwitterionic near pH 7.5) and 1 mM BME (nonionic) contribute
#   negligibly and are omitted.
const IONIC_STRENGTH_M = 0.515

# FadD5 sequence, read directly off SASDX52_fit1_model1.pdb chain A SEQRES
# (554 residues). The model contains two chains, A and B, with IDENTICAL
# sequence/length (554 residues each) -- consistent with SASBDB's listed
# dimer oligomeric state, i.e. two copies of the same AlphaFold monomer
# prediction docked together by the depositors. Chain A is used here as the
# representative protomer sequence (arbitrary choice between two identical
# chains).
const FADD5_SEQ = "MTAQLASHLTRALTLAQQQPYLARRQNWVNQLERHAMMQPDAPALRFVGNTMTWADLRRRVAALAGALSGRGVGFGDRVMILMLNRTEFVESVLAANMIGAIAVPLNFRLTPTEIAVLVEDCVAHVMLTEAALAPVAIGVRNIQPLLSVIVVAGGSSQDSVFGYEDLLNEAGDVHEPVDIPNDSPALIMYTSGTTGRPKGAVLTHANLTGQAMTALYTSGANINSDVGFVGVPLFHIAGIGNMLTGLLLGLPTVIYPLGAFDPGQLLDVLEAEKVTGIFLVPAQWQAVCTEQQARPRDLRLRVLSWGAAPAPDALLRQMSATFPETQILAAFGQTEMSPVTCMLLGEDAIAKRGSVGRVIPTVAARVVDQNMNDVPVGEVGEIVYRAPTLMSCYWNNPEATAEAFAGGWFHSGDLVRMDSDGYVWVVDRKKDMIISGGENIYCAELENVLASHPDIAEVAVIGRADEKWGEVPIAVAAVTNDDLRIEDLGEFLTDRLARYKHPKALEIVDALPRNPAGKVLKTELRLRYGACVNVERRSASAGFTERRENRQKL"

# Average mass from FADD5_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH) => ≈59.91 kDa, close to (but not identical to) SASBDB's
# own quoted 61.7 kDa monomer MW; the sequence-derived value is used for
# internal consistency with FADD5_SEQ.
const FADD5_MW = 59905.88   # g/mol

# [SASBDB] 4.00 mg/ml protein concentration / sequence-derived monomer MW.
const FADD5_CONC_MG_ML = 4.00
const FADD5_MOLARITY   = FADD5_CONC_MG_ML / FADD5_MW   # ≈ 6.68e-5 M
const FADD5_MOLARITY_σ = 0.05 * FADD5_MOLARITY         # 5% relative: typical A280/mg-ml (not stated by SASBDB)

# Buffer components. All four species below were cross-checked against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json and found
# present (no MISSING FROM PMV LOOKUP entries for this case):
#   "sodium chloride"    -> "sodium chloride"
#   "magnesium chloride" -> "magnesium dichloride"
#   "hepes"               -> "2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonic acid"
#   "2-mercaptoethanol"   -> "2-mercaptoethanol"
const SOLUTES = Solute[
    Protein(FADD5_MOLARITY, FADD5_MOLARITY_σ, FADD5_SEQ),
    NonBiological(0.500, 0.005,   "sodium chloride"),      # 500 mM NaCl, ±1%
    NonBiological(0.020, 0.0004,  "hepes"),                # 20 mM HEPES, ±2%
    NonBiological(0.005, 0.0001,  "magnesium chloride"),   # 5 mM MgCl2, ±2%
    NonBiological(0.001, 0.00005, "2-mercaptoethanol"),    # 1 mM BME, ±5% (small conc., degrades/evaporates)
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
# thumb: Q_MAX_FIT * D_max ≈ 0.17 * 208 ≈ 35.4 => lMax = 35.
const LMAX = 35

const ADD_HYDROGENS = true   # runs PDB2PQR at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdx52(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s, μ_χ, σ_χ = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        ionic_strength_M = IONIC_STRENGTH_M, T = DEBYE_T_K,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, μ_χ, σ_χ, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdx52()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDX52/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
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
        lines!(ax, map_curve[:, 1], map_curve[:, 2]; color = :crimson, linewidth = 2, label = "MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    # Centre the view on the actual data (I_fit), not on however far the
    # errorbar whiskers/bounds band happen to extend
    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

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
    sasdx52_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdx52_posterior_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = (900, 550))
    for (i, (label, map_key)) in enumerate(_HIST_PARAMS)
        row, col = fldmod1(i, 3)
        ax = Axis(
            fig[row, col], xlabel = label, ylabel = "count",
            xticklabelrotation = label == "dns" ? π/2 : 0.0,
        )
        hist!(ax, getindex.(samples, i); bins = 40, color = (:dodgerblue, 0.6))
        if map_params !== nothing
            vlines!(ax, [map_params[map_key]]; color = :crimson, linewidth = 2)
        end
    end

    return fig
end

"""
    sasdx52_crysol_comparison_figure(result, data) -> Figure

Overlays our MAP curve against SASDX52_fit1.fit's own bundled reference
curve (`model_intensity` column). NOTE: unlike the other cases in this test
family, the fitting *method* behind that reference curve is not confirmed to
be CRYSOL specifically -- there is no bundled paper here to check Methods
against, and `fit1_model1.pdb` is itself a depositor-docked dimer built from
an AlphaFold monomer prediction, so the reference curve may come from a
rigid-body/oligomer fitting tool (e.g. CORAL/SASREF-style) rather than a
plain CRYSOL run. It is labelled "SASBDB fit1" below rather than "CRYSOL"
for that reason.
"""
function sasdx52_crysol_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data

    ref      = readdlm(_FIT_PATH; skipstart = 3)
    q_ref    = Float64.(ref[:, 1])
    I_ref    = Float64.(ref[:, 4])
    keep     = (q_ref .> 0) .& (q_ref .≤ Q_MAX_FIT) .& (I_ref .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "BAYSOL MAP vs. SASBDB fit1 (method unconfirmed)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdx52_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, q_ref[keep], I_ref[keep];
        color = :seagreen, linewidth = 2, linestyle = :dash, label = "SASBDB fit1",
    )

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map_curve[:, 2]; color = :crimson, linewidth = 2, label = "BAYSOL MAP")
    end

    axislegend(ax; position = :lt, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

fig = sasdx52_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig)

fig_residuals = sasdx52_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals)

fig_hist = sasdx52_posterior_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist)

fig_crysol = sasdx52_crysol_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_crysol_comparison.png"), fig_crysol)

"Display the SASDX52 fit figure. Blocks until the window is closed."
vis_sasdx52() = wait(display(fig))
