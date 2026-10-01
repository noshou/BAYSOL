using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDN32")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDN32_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDN32_fit1_model1.pdb")

# As with SASDMZ9, `experimental_data/` and `pddf/` are EMPTY for this case;
# the experimental curve ships directly as `SASDN32_fit1.dat` in the case
# root, and no GNOM .out pddf file is bundled (see LMAX discussion below).
#
# `SASDN32_fit1.dat` header:
#   # SAXS profile: number of points = 1211, q_min = 0.00297234626486897, q_max = 0.345499873161316, ...
#   # offset = ..., scaling c = ..., Chi^2 = ...
#   #  q       exp_intensity   model_intensity error
# i.e. 3 comment/header lines, then 1211 data rows in columns
raw = readdlm(_DATA_PATH; skipstart = 3)

qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 4])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Cerqueira et al. 2022, J. Biol. Chem. 298(5):101896, "Sas20 is a
# highly flexible starch-binding protein in the Ruminococcus bromii
# cell-surface amylosome", test/fixtures/experiments/SASDN32/PIIS0021925822003362.pdf.
#
# The paper's "Data availability" paragraph (p.16) lists six SASBDB
# accessions for its SEC-SAXS runs: SASDMX9, SASDMY9, SASDMZ9, SASDN22,
# SASDN32, SASDN42.
#
# Buffer: same generic SEC-SAXS Materials & Methods paragraph as SASDMZ9
# (p.16, "SEC–SAXS experiments") applies.

# pH: the PBS recipe quoted above (p.14, pH 7.4) is from the paper's cell-washing / mass-spec methods, not
# the SAXS section, which names no buffer. The SAXS buffer is only given by SASBDB ('phosphate buffered
# saline, 1 mM TCEP, pH 7'), so pH 7.0 is used. The recipe's NaCl/KCl and total phosphate (11.8 mM) are
# kept; the phosphate is re-split at pH 7.0 (HPO4²⁻ fraction 0.592): pK2 from Goldberg, Kishore & Lennen
# 2002 (DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C, Davies-corrected at I ≈
# 0.166 M (pK2' ≈ 6.84). The 1.8 mM KH2PO4 is kept as the K⁺ carrier and the rest is sodium phosphate.
const PH, σ_PH = 7.0, 0.1   # SASBDB; ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV       = 12398.42 / 1.033 # ≈ 12001 eV, from SASBDB's stated λ = 0.1033 nm = 1.033 Å
const TEMPERATURE_C    = 23.0            # 23°C, SASBDB
const IONIC_STRENGTH_M = 0.171           # PBS ionic strength, identical buffer recipe to SASDMZ9 

# Sas20d2 sequence, read directly off SASDN32_fit1_model1.pdb
const SAS20D2_SEQ = 
    "ADATQYVVAGVESLTGYEWQGSPALAPENVMTKSGDVYTKTFTAVPVGKSYQLKVVANTG" *
    "DEQKWIGLDGTDNNVTFDVESACDVTVTFNPATNEIAVTGDGVKMVTDLEINSITVVGNG" *
    "ENSWLNGVAWGVDAEVNHMTQIADKVYQITYTGVESADAAYQFKFAVNDDWAANWGLPEQ" *
    "SAATIGEDFDLTFNGENMLLNTVSAGYPEDSLVDVTITLDLTKFDYPSRSGAKANIKIDG" *
    "NRVLL"

# Average mass from SAS20D2_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH); ≈ 26.32 kDa, matching Table 4's Sas20d2 sequence
# MW of 26.5 kDa (small difference from the exact modelled span vs. the
# paper's own construct boundary) and SASBDB's own stated MW (25.9 kDa).
const SAS20D2_MW = 26319.06   # g/mol
const SAS20D2_CONC_MG_ML = 10.0   # SASBDB: 10.00 mg/ml
const SAS20D2_MOLARITY   = SAS20D2_CONC_MG_ML / SAS20D2_MW   # ≈ 3.80e-4 M ≈ 0.380 mM
const SAS20D2_MOLARITY_σ = 0.05 * SAS20D2_MOLARITY           # 5% relative: typical A280/mg-ml

# Buffer components: PBS + 1 mM TCEP (identical recipe to SASDMZ9, see
# solution-conditions discussion above) plus the 5 mM maltoheptaose ligand
# this entry was collected with.
#
# maltoheptaose: V0 = 694.8 ± 5.8 cm³/mol (Hourston 1967 PhD thesis,
# Table 6.1, 25 °C, measured from the partial specific volume 0.600 ±
# 0.005 mL/g); it now resolves in src/PartialMolarVolumes/NonBiological.
# 5 mM is not negligible next to the 137 mM NaCl / 10 mM phosphate buffer
# components, so it is included (previously omitted because no entry existed).
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.137,  0.00137,   "sodium chloride"),               # 137 mM NaCl, ±1%
    NonBiological(0.0027, 0.000027,  "potassium chloride"),            # 2.7 mM KCl, ±1%
    NonBiological(0.001800, 0.000036, "potassium dihydrogen phosphate"),   # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.003014, 0.000988, "sodium dihydrogen phosphate"),   # PBS phosphate at pH 7.0, H2PO4⁻ part
    NonBiological(0.006986, 0.000993, "disodium hydrogen phosphate"),   # PBS phosphate at pH 7.0, HPO4²⁻ part
    NonBiological(0.001,  0.00002,   "tcep"),                          # 1 mM TCEP, ±2%
    NonBiological(0.005,  0.0001,    "maltoheptaose"),                 # 5 mM maltoheptaose ligand, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT    = 0.3

# lMax follows the usual q·D_max multipole-resolution rule of thumb. No GNOM
# pddf is bundled for this case (pddf/ is empty), so D_max is instead
# estimated directly from this PDB's own coordinate extent: the maximum
# pairwise heavy-atom (all-ATOM, no waters/HETATM present) distance in
# SASDN32_fit1_model1.pdb is ≈ 74.1 Å (computed once offline over its 1854
# atoms) -- in close agreement with both the paper's own Table 4 D_max
# (solution) = 74 Å and SASBDB's own stated D_max = 7.4 nm for this entry
# (see solution-conditions discussion above). Q_MAX_FIT * D_max ≈
# 0.3 * 74.1 ≈ 22.2.
const LMAX = 22

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdn32(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdn32()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDN32/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdn32_figure(result, data) -> Figure

Plots the SASDN32 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdn32_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",

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
            ax, bounds[:, 1], max.(bounds[:, 2], y_floor), max.(bounds[:, 3], y_floor);
            color = (:darkorange, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 2], y_floor);
            linestyle = :dot, color = :darkorange, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 3], y_floor);
            linestyle = :dot, color = :darkorange, linewidth = 1.5,
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
        lines!(ax, map_curve[:, 1], map(v -> v > 0 ? v : NaN, map_curve[:, 2]); color = :crimson, linewidth = 2, label = "MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    # Centre the view on the actual data (I_fit), not on however far the
    # errorbar whiskers/bounds band happen to extend
    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

"""
    sasdn32_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdn32_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)")

    map_curve = map_result === nothing ? nothing : map_result[2]

    if quantile_result !== nothing && map_curve !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]
        I_map     = map_curve[:, 2]

        band!(
            ax, bounds[:, 1], bounds[:, 2] .- I_map, bounds[:, 3] .- I_map;
            color = (:darkorange, 1), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 2.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 2.5,
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

    axislegend(ax; position = :rt, framevisible = false)

    return fig
end

const _HIST_PARAMS = [
    ("ρₑ", "slvnt_e_dns"), ("δρ₁", "delta_rho_1"), ("δρ₂", "delta_rho_2"),
    ("δρ₃", "delta_rho_3"),
    ("scale", "scale"), ("bkgrnd_corr", "bkgrnd_corr"),
    ("c1", "excl_vol_corr"),
]

"""
    sasdn32_hist(result) -> Figure
"""
function sasdn32_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    c1_draws = fit.c1[ok]
    scale_draws = fit.scale[ok]
    bkgrnd_draws = fit.bkgrnd_corr[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = (900, 550))
    for (i, (label, map_key)) in enumerate(_HIST_PARAMS)
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
        hist!(ax, draws; bins = 40, color = (:darkorange, 0.6))
        if map_params !== nothing
            vlines!(ax, [map_params[map_key]]; color = :crimson, linewidth = 2)
        end
    end

    return fig
end

# No CRYSOL-comparison plot for this case: unlike SASDMJ9's bundled
# `.fit` reference file, SASDN32 has no separate CRYSOL/FoXS reference fit
# shipped alongside it (`SASDN32_fit1.dat`'s own "model_intensity" column is
# itself just someone else's fit curve, not a distinct reference file to
# overlay), so `sasdn32_comparison_figure` is intentionally omitted.

fig = sasdn32_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig; px_per_unit = 3.5)

fig_residuals = sasdn32_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals; px_per_unit = 3.5)

fig_hist = sasdn32_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist; px_per_unit = 3.5)

"Display the SASDN32 fit figure. Blocks until the window is closed."
vis_sasdn32() = wait(display(fig))
