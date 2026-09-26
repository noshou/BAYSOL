using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR_FIT1 = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDA52")
const _DATA_PATH_FIT1   = joinpath(_FIXTURE_DIR_FIT1, "experimental_data", "SASDA52.dat")
const _PDB_PATH_FIT1    = joinpath(_FIXTURE_DIR_FIT1, "SASDA52_fit1_model1.pdb")
const _FIT_PATH_FIT1    = joinpath(_FIXTURE_DIR_FIT1, "SASDA52_fit1.fit")

raw_fit1 = readdlm(_DATA_PATH_FIT1; skipstart = 4)

# 4 lines of headers (date/title line + 3 "<file> Conc = ... N1 = ... N2 = ..."
# lines), then 2168 data rows (matches "N2 = 2168" in the header), followed by
# a text footer (per-frame processing metadata for the sample and the two
# buffer frames it was averaged/subtracted against) that we simply don't slice
# into.
qvals_fit1   = Float64.(raw_fit1[1:2168, 1])
I_exp_fit1   = Float64.(raw_fit1[1:2168, 2])
σ_exp_fit1   = Float64.(raw_fit1[1:2168, 3])

# qvals are in nm⁻¹ (SASBDB REMARK 265 in SASDA52_fit2_model1.pdb states
# "ANGLE RANGE(MIN-MAX) (INVERSE NANOMETERS): 0.087-6.014", matching this
# file's raw range exactly); must convert to Å⁻¹.
qvals_fit1 = qvals_fit1 ./ 10

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Structure source: Raj, Ramaswamy & Plapp 2014, Biochemistry 53(37):5791-5803
# ("Yeast Alcohol Dehydrogenase Structure and Catalysis"),
# test/fixtures/experiments/SASDA52/bi5006442.pdf. This is a pure X-ray
# crystallography paper (PDB entry 4W6Z, the structure behind
# SASDA52_fit1_model1.pdb) -- grepping the extracted text confirms it never
# mentions SAXS/scattering, so it is cited here only for the protein's
# identity/sequence/oligomeric state, not for the solution conditions below.
#
# Solution-conditions source: the SASBDB REMARK 265 metadata block embedded in
# SASDA52_fit2_model1.pdb's own PDB header (that file, unlike fit1's, retains
# the full SASBDB header; both fits share the one SASDA52 experimental curve
# and were measured under the same conditions). Relevant fields:
#
#     BEAMLINE NAME                    : X33 (EMBL BioSAXS, DORIS, DESY Hamburg)
#     WAVE LENGHT (A)                  : 0.15
#     CELL/STORAGE TEMPERATURE(CELSIUS): 10
#     CONCENTRATION RANGE(MG/ML)       : None-24.89
#     BUFFER NAME                      : PBS
#     BUFFER PH-PK                     : 7.400-7.000
#
# "WAVE LENGHT (A): 0.15" is read as a units slip (Å entered in nm): X33 on
# DORIS operated at the well-documented ~1.5 Å (0.15 nm), and 0.15 Å would be
# ~83 keV, absurd for a bending-magnet SAXS beamline of this era -- so we use
# λ = 1.5 Å => energy = hc/λ ≈ 8266 eV (hc = 12398.42 eV·Å).
#
# The experimental_data/SASDA52.dat file's own per-sample header records
# "Sample: adh_1_high c= 24.890 mg/ml" -- the top of the reported
# concentration series ("None-24.89"), i.e. the curve used for this fit.
#
# "BUFFER PH-PK: 7.400-7.000" is read as pH 7.4 (standard PBS pH) with the
# second figure an adjacent (mislabeled) pKa-ish field, not a second pH.

const PH_FIT1, σ_PH_FIT1 = 7.4, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV_FIT1       = 12398.42 / 1.5   # ≈ 8266 eV, X33 at (corrected) 1.5 Å
const TEMPERATURE_C_FIT1   = 25.0             # 10°C is given in metadata, but not supported; matches SASDMJ9.jl convention
const IONIC_STRENGTH_M_FIT1 = 0.172           # standard 1x PBS, see SOLUTES_FIT1 below

# ADH1 sequence, read directly off SASDA52_fit1_model1.pdb chain A, residues
# 1-347 (CA atoms only). Chain A's 694 CA records are two concatenated copies
# of the same 347-residue protomer (residues 1-347, then 348-694 repeating the
# identical sequence); chain B repeats the pattern -- i.e. this PDB models the
# biological tetramer (paper: "Yeast ADH1 is a tetramer of four identical
# subunits with 347 amino acid residues each") as two chains of two protomers
# each. We use one protomer's sequence (residues 1-347 of chain A) as the
# single dissolved Protein species, following the same one-Solute-per-distinct
# -sequence convention as SASDMJ9.jl.
const ADH1_SEQ_FIT1 = "SIPETQKGVIFYESHGKLEYKDIPVPKPKANELLINVKYSGVCHTDLHAWHGDWPLPVKLPLVGGHEGAGVVVGMGENVKGWKIGDYAGIKWLNGSCMACEYCELGNESNCPHADLSGYTHDGSFQQYATADAVQAAHIPQGTDLAQVAPILCAGITVYKALKSANLMAGHWVAISGAAGGLGSLAVQYAKAMGYRVLGIDGGEGKEELFRSIGGEVFIDFTKEKDIVGAVLKATDGGAHGVINVSVSEAAIEASTRYVRANGTTVLVGMPAGAKCCSDVFNQVVKSISIVGSYVGNRADTREALDFFARGLVKSPIKVVGLSTLPEIYEKMEKGQIVGRYVVDTSK"

# Monomer mass from the paper's own stated tetramer mass ("a calculated mass
# of 147396 Da" for the four identical 347-residue subunits, Introduction,
# p.5791) divided by 4.
const ADH1_MW_FIT1 = 147396.0 / 4   # ≈ 36849 g/mol
const ADH1_CONC_MG_ML_FIT1 = 24.890
const ADH1_MOLARITY_FIT1   = ADH1_CONC_MG_ML_FIT1 / ADH1_MW_FIT1   # ≈ 0.676 mM
const ADH1_MOLARITY_σ_FIT1 = 0.05 * ADH1_MOLARITY_FIT1             # 5% relative: typical A280/mg-ml

# Buffer components. "PBS" is named in the SASBDB metadata with no explicit
# recipe given (and the structure paper doesn't describe the SAXS buffer at
# all), so we use the standard 1x PBS formulation (137 mM NaCl, 2.7 mM KCl,
# 10 mM Na2HPO4, 1.8 mM KH2PO4, pH ≈ 7.4) and flag it explicitly as an
# assumption rather than a value read off the source documents. All four
# components are present in src/PartialMolarVolumes/NonBiological/
# common_to_iupac.json under these exact keys.
const SOLUTES_FIT1 = Solute[
    Protein(ADH1_MOLARITY_FIT1, ADH1_MOLARITY_σ_FIT1, ADH1_SEQ_FIT1),
    NonBiological(0.137,  0.00685,  "sodium chloride"),              # 137 mM, standard 1x PBS, ±5% (assumed recipe)
    NonBiological(0.0027, 0.000135, "potassium chloride"),           # 2.7 mM, standard 1x PBS, ±5%
    NonBiological(0.010,  0.0005,   "disodium hydrogen phosphate"),  # 10 mM Na2HPO4, standard 1x PBS, ±5%
    NonBiological(0.0018, 0.00009,  "potassium dihydrogen phosphate"), # 1.8 mM KH2PO4, standard 1x PBS, ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT_FIT1 = 0.5   # matches SASDA52_fit1.fit's own q-range (0 to 0.5 Å⁻¹)

# lMax follows the usual q·D_max multipole-resolution rule of thumb, using
# the GNOM P(r) output directly (test/fixtures/experiments/SASDA52/pddf/SASDA52.out):
# "Real space range: from 0.00 to 8.93" -- GNOM ran on the raw nm⁻¹ data, so
# this is D_max = 8.93 nm = 89.3 Å. Q_MAX_FIT * D_max ≈ 0.5 * 89.3 ≈ 44.65,
# rounded to 45.
const LMAX_FIT1 = 45

const ADD_HYDROGENS_FIT1 = true   # runs PDB2PQR at PH_FIT1

"""
    fit_subset_fit1() -> (q, I, σ)

`qvals_fit1`/`I_exp_fit1`/`σ_exp_fit1` restricted to `q ≤ Q_MAX_FIT_FIT1` and `I_exp > 0`.
"""
function fit_subset_fit1()
    keep = findall(i -> qvals_fit1[i] ≤ Q_MAX_FIT_FIT1 && I_exp_fit1[i] > 0, eachindex(qvals_fit1))
    return qvals_fit1[keep], I_exp_fit1[keep], σ_exp_fit1[keep]
end

function run_sasda52_fit1(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset_fit1()

    Random.seed!(seed)
    s, μ_χ, σ_χ = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH_FIT1), LMAX_FIT1, ENERGY_EV_FIT1, q_fit, I_fit, σ_fit,
        PH_FIT1, σ_PH_FIT1, SOLUTES_FIT1;
        add_hydrogens = ADD_HYDROGENS_FIT1, t = TEMPERATURE_C_FIT1,
        ionic_strength_M = IONIC_STRENGTH_M_FIT1, T = TEMPERATURE_C_FIT1 + 273.15,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, μ_χ, σ_χ, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result_fit1, μ_χ_fit1, σ_χ_fit1, form_factor_log_fit1, n_atoms_fit1, (q_fit_fit1, I_fit_fit1, σ_fit_fit1) = run_sasda52_fit1()

fit_fit1, divergence_rate_fit1, map_result_fit1, quantile_result_fit1 = result_fit1

# `@__DIR__` (this SASDA52/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit1.txt"), "w") do io
    BAYSOL.write_report(io, result_fit1; μ_χ = μ_χ_fit1, σ_χ = σ_χ_fit1, form_factor_log = form_factor_log_fit1, n_atoms = n_atoms_fit1)
end

"""
    sasda52_fit1_figure(result, data) -> Figure

Plots the SASDA52 fit1 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasda52_fit1_figure(result, data)
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
    sasda52_fit1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasda52_fit1_residuals_figure(result, data)
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
const _HIST_PARAMS_FIT1 = [
    ("dns", "slvnt_e_dns"), ("δρ1", "delta_rho_1"), ("δρ2", "delta_rho_2"),
    ("δρ3", "delta_rho_3"), ("c1", "excl_vol_corr"),
]

"""
    sasda52_fit1_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasda52_fit1_posterior_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = (900, 550))
    for (i, (label, map_key)) in enumerate(_HIST_PARAMS_FIT1)
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
    sasda52_fit1_crysol_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL/GNOM fit1 fit.
"""
function sasda52_fit1_crysol_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data

    crysol   = readdlm(_FIT_PATH_FIT1; skipstart = 1)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT_FIT1) .& (I_crysol .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "BAYSOL MAP vs. CRYSOL fit1 (paper)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasda52_fit1_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, q_crysol[keep], I_crysol[keep];
        color = :seagreen, linewidth = 2, linestyle = :dash, label = "CRYSOL fit1",
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

fig_fit1 = sasda52_fit1_figure(result_fit1, (q_fit_fit1, I_fit_fit1, σ_fit_fit1))
save(joinpath(@__DIR__, "res_fit1.png"), fig_fit1)

fig_residuals_fit1 = sasda52_fit1_residuals_figure(result_fit1, (q_fit_fit1, I_fit_fit1, σ_fit_fit1))
save(joinpath(@__DIR__, "res_fit1_residuals.png"), fig_residuals_fit1)

fig_hist_fit1 = sasda52_fit1_posterior_hist(result_fit1)
save(joinpath(@__DIR__, "res_fit1_hist.png"), fig_hist_fit1)

fig_crysol_fit1 = sasda52_fit1_crysol_comparison_figure(result_fit1, (q_fit_fit1, I_fit_fit1, σ_fit_fit1))
save(joinpath(@__DIR__, "res_fit1_crysol_comparison.png"), fig_crysol_fit1)

"Display the SASDA52 fit1 figure. Blocks until the window is closed."
vis_sasda52_fit1() = wait(display(fig_fit1))
