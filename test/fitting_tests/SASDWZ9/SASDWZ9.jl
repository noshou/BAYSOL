using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWZ9")
const _PDB_PATH     = joinpath(_FIXTURE_DIR, "SASDWZ9_fit1_model1.pdb")
const _FIT_PATH     = joinpath(_FIXTURE_DIR, "SASDWZ9_fit1.fit")

# `experimental_data/` and `pddf/` are both empty for this fixture (no
# standalone .dat and no GNOM .out were bundled) -- SASDWZ9_fit1.fit is the
# *only* source of experimental q/I/σ we have, and it doubles as the
# reference fit curve (see below). Header is 6 `#`-prefixed lines
# (Pepsi-SAXS version/run/command-line/units/r0-d_rho-Chi2/column-names),
# then columns q, I_exp, dI_exp, I_fit (Pepsi-SAXS's own fitted curve).
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
# SERF1a Conformational Ensemble"), test/fixtures/experiments/SASDWZ9/ao5c07620.pdf,
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

const PH, σ_PH = 6.8, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV       = 12398.42 / 0.8266   # ≈ 15000 eV, from SASBDB's stated 0.08266 nm wavelength
const TEMPERATURE_C    = 25.0   # SASBDB states 10°C, but (as in SASDMJ9) this version pins water's
                                 # density/dielectric to DEFAULT_TEMPERATURE_C = 25.0 -- "should NOT
                                 # be changed, since only water is temperature-dependent in this version."
const IONIC_STRENGTH_M = 0.0545 # see derivation below

# SERF1a sequence, read directly off SASDWZ9_fit1_model1.pdb chain A
# (residues 1-62, all 62 residues modelled -- this is a single filtered
# NMR/TAiBP-CYANA conformer, MODEL 37 of the deposited ensemble, not a
# crystal structure). MW below is computed from this sequence and matches
# SASBDB's stated "7.3 kDa (monomer)" to within rounding.
const SERF1A_SEQ = "MARGNQRELARQKNMKKTQEISKGKRKEDSLTASQRKQRDSEIMQEKQKAANEKKSMQTREK"

# Average mass from SERF1A_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH).
const SERF1A_MW = 7336.37   # g/mol
const SERF1A_CONC_MG_ML = 15.00   # SASBDB metadata (not stated in the bundled main-text PDF)
const SERF1A_MOLARITY   = SERF1A_CONC_MG_ML / SERF1A_MW   # ≈ 2.045 mM
const SERF1A_MOLARITY_σ = 0.05 * SERF1A_MOLARITY          # 5% relative: typical A280/mg-ml, not stated

# Buffer components.
#
# "20 mM NaPi" is not itself a single species: at pH 6.8, with phosphoric
# acid's second pKa ≈ 7.2 (Henderson-Hasselbalch), it is a mix of
# dihydrogen phosphate (H2PO4⁻) and hydrogen phosphate (HPO4²⁻):
#
#     [HPO4²⁻]/[H2PO4⁻] = 10^(pH - pKa2) = 10^(6.8 - 7.2) ≈ 0.398
#     => H2PO4⁻ fraction ≈ 0.715, HPO4²⁻ fraction ≈ 0.285
#     => [NaH2PO4] ≈ 0.0143 M, [Na2HPO4] ≈ 0.0057 M  (of the 20 mM total)
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
    Protein(SERF1A_MOLARITY, SERF1A_MOLARITY_σ, SERF1A_SEQ),
    NonBiological(0.020,      0.0002,   "sodium chloride"),             # 20 mM NaCl, ±1%
    NonBiological(0.014305,   0.000286, "sodium dihydrogen phosphate"), # NaPi, H2PO4⁻ fraction, ±2%
    NonBiological(0.005695,   0.000114, "disodium hydrogen phosphate"), # NaPi, HPO4²⁻ fraction, ±2%
    NonBiological(0.003076,   0.0000615,"sodium azide"),                # 0.02% w/v NaN3, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.35   # the .fit file's own full q-range (≈0.0083-0.3501 Å⁻¹)

# No GNOM pddf was bundled for this case (pddf/ is empty), so there is no
# fitted D_max to read off. Instead, D_max is estimated directly from the
# only structure we have: the maximum pairwise distance between any two
# heavy (non-hydrogen) atoms in SASDWZ9_fit1_model1.pdb (a single filtered
# NMR/TAiBP-CYANA conformer of this intrinsically disordered protein,
# MODEL 37) -- ≈101.2 Å (the Cα-only max pairwise distance is close,
# ≈94.7 Å; heavy atoms including side chains extend it a bit further).
# This is necessarily just this one conformer's own extent, not an
# ensemble-averaged D_max for the IDP as a whole, but it's the only
# structural information this fixture provides.
#
# lMax follows the same q·D_max multipole-resolution rule of thumb used in
# SASDMJ9: Q_MAX_FIT * D_max ≈ 0.35 * 101.2 ≈ 35.4.
const LMAX = 35

const ADD_HYDROGENS = true   # runs PDB2PQR at PH; the NMR structure already carries
                              # modelled hydrogens, but PDB2PQR recomputes pH-consistent
                              # protonation states from the heavy-atom positions regardless.

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdwz9(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s, μ_χ, σ_χ = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        ionic_strength_M = IONIC_STRENGTH_M, T = TEMPERATURE_C + 273.15,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, μ_χ, σ_χ, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdwz9()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDWZ9/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdwz9_figure(result, data) -> Figure

Plots the SASDWZ9 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdwz9_figure(result, data)
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
    sasdwz9_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdwz9_residuals_figure(result, data)
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
    sasdwz9_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdwz9_posterior_hist(result)
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
    sasdwz9_pepsi_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference Pepsi-SAXS fit bundled in
SASDWZ9_fit1.fit (the paper used Pepsi-SAXS, not CRYSOL, to filter/fit
candidate conformations -- see "Filtering by SEC-SAXS Data..." in the
paper).
"""
function sasdwz9_pepsi_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data

    keep = (qvals .> 0) .& (qvals .≤ Q_MAX_FIT) .& (I_pepsi_fit .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "BAYSOL MAP vs. Pepsi-SAXS fit1 (paper)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdwz9_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, qvals[keep], I_pepsi_fit[keep];
        color = :seagreen, linewidth = 2, linestyle = :dash, label = "Pepsi-SAXS fit1",
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

fig = sasdwz9_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig)

fig_residuals = sasdwz9_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals)

fig_hist = sasdwz9_posterior_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist)

fig_pepsi = sasdwz9_pepsi_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_crysol_comparison.png"), fig_pepsi)

"Display the SASDWZ9 fit figure. Blocks until the window is closed."
vis_sasdwz9() = wait(display(fig))
