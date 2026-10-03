using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDZZ9")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDZZ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDZZ9_fit1.fit")

# `experimental_data/` and `pddf/` are both empty for this fixture.
raw = readdlm(_FIT_PATH; skipstart = 1)

qvals_all = Float64.(raw[:, 1])
I_all     = Float64.(raw[:, 2])
σ_all     = Float64.(raw[:, 3])
I_crysol_all = Float64.(raw[:, 4])

# Units: the file's header line ("RGT:23.93", i.e. Rg = 23.93 Å) is
# consistent with Dmax ≈ 3-4×Rg landing right on the coordinate-derived Dmax
# computed below (≈70.6 Å, 23.93*3 ≈ 71.8) only if q is already in Å⁻¹.
qvals = qvals_all
I_exp = I_all
σ_exp = σ_all

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: WebFetch of <https://www.sasbdb.org/data/SASDZZ9/>
#
#   Sample: "Chitooligosaccharide deacetylase (NodB) from the marine
#            bacterium Vibrio campbellii (VhCOD), native form"
#   Organism: Vibrio campbellii (strain ATCC BAA-1116)
#   Oligomeric state: monomer; UniProt A7MSF4 (residues 23-427); PDB 8YFP
#   Buffer: 20 mM Tris, 100 mM NaCl, pH 7.5
#   Temperature: 16°C; sample concentration: 4.00 mg/ml
#   Beamline: SLRI (Thailand) BL1.3W, wavelength 0.137 nm => energy =
#       hc/λ = 12398.42 eV·Å / 1.37 Å ≈ 9049.9 eV
#   Associated publication: Pongnan S, Robinson RC, Kamonsutthipaijit N,
#       Fukamizo T, Suginta W. Biophys Rep (N Y) 2026. PMID 42341985.
#   Models: two fits are given for this entry fit1 (rigid-body/crystal
#       PDB model, χ²≈34.5, this script) and fit2 (an ab initio DAMMIF/
#       DAMAVER dummy-atom bead model, χ²≈0.002).

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV        = HC_EV_ANGSTROM / 1.37  # ≈ 9049.9 eV, from 0.137 nm wavelength
const TEMPERATURE_C    = 16.0           # 16°C, SASBDB
                                        # (only water's T-dependence is modelled)
const IONIC_STRENGTH_M = 0.100          # 100 mM NaCl, SASBDB's stated ~100 mM

# NodB sequence, SASDZZ9_fit1_model1.pdb chain A (the only
# protein chain present; residues 2-405, 404 residues).
const NODB_SEQ = 
    "TAPKGTIYLTFDDGPINASIDVINVLNEQGVKGTFYFNAWHLDGIGDENEDRALEALKLA" *
    "LDTGHVVANHSYAHMVHNCVDEFGPTSGAECNATGDHQINAYQDPVYDASTFADNLVVFE" *
    "RYLPNINSYPNYFGEELARLPYTNGWRITKDFKADGLCATSDDLKPWEPGYVCDLDNPSN" *
    "SVKASIEVQNILANKGYQTHGWDVDWSPENWGIPMPANSLTEAEAFLGYVDAALNSCAPT" *
    "TINPINSKAHGFPCGTPLHADKVVVLTHEFLYEDGKRGMGATQNLPKLAKFLRIAKEAGY" *
    "VFDTIDNYTPVWQVGNAYAAGDYVTHSGTVYKAVTAHIAQQDWAPSSTSSLWTNADPATN" *
    "WTLNVSYEAGDVVTYQGLRYLVNVPHVSQADWTPNTQNTLFTAL"

# Average mass from NODB_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH); ≈44.36 kDa, close to SASBDB's stated 45 kDa.
const NODB_MW = 44360.06   # g/mol
const NODB_CONC_MG_ML = 4.00
const NODB_MOLARITY   = NODB_CONC_MG_ML / NODB_MW   # ≈ 9.02e-5 M
const NODB_MOLARITY_σ = MOLARITY_REL_SIGMA * NODB_MOLARITY

# Buffer components. "sodium chloride" / "tris" both present verbatim in
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json.
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.854 (pK(22 °C) = 8.156). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.117 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.100, 0.001,   "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.020, 0.0004,  "tris"),              # 20 mM Tris, ±2%
    NonBiological(0.017086, 0.000856, "chloride"),   # Cl⁻ counter-ion from HCl titration of Tris (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No GNOM pddf was bundled with this fixture (pddf/ is empty), so lMax can't
# be read off a P(r) Dmax. Instead Dmax is estimated directly from the .pdb's
# own coordinate extent: max pairwise heavy-atom distance among chain-A ATOM
# records (Python/itertools brute force over all pairs) = 70.63 Å. Q_MAX_FIT
# is set to just above the file's q_max (0.387528). lmax = Q_MAX_FIT * D_max ≈ 0.39 * 70.6
# ≈ 27.5, rounded up to 28.
const Q_MAX_FIT = 0.39
const LMAX      = 28

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`. The
`I_exp > 0` filter also drops this file's own leading q<0.0213 placeholder
rows (I_exp = σ_exp = 0, no experimental coverage there).
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdzz9_fit1(; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdzz9_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDZZ9/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit1.txt"), "w") do io
    BAYSOL.write_report(
        io, 
        result; 
        form_factor_log = form_factor_log, 
        n_atoms = n_atoms
    )
end

"""
    sasdzz9_fit1_figure(result, data) -> Figure

Plots the SASDZZ9 fit1 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdzz9_fit1_figure(result, data)
    _, _, map_result, quantile_result = result
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
            color = (:darkorange, 1), label = "bounds",   # NB: shared COLOR_BAND is (:darkorange, 0.15); this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 2], y_floor);
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 2.5, label = "quantiles",   # NB: shared LW_QUANTILE is 1.5; this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 3], y_floor);
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 2.5,   # NB: shared LW_QUANTILE is 1.5; this script's plot style is kept as-is
        )
    end

    # Log-symmetric errorbar via the delta method; see SASDMJ9.jl's
    # sasdmj9_figure for why a raw additive I ± σ interval isn't used.
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
            map_curve[:, 2]; 
            color = COLOR_MAP, 
            linewidth = LW_MAP, 
            label = "MAP"
        )
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end

"""
    sasdzz9_fit1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q.
"""
function sasdzz9_fit1_residuals_figure(result, data)
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
            color = (:darkorange, 0.15), label = "bounds",   # NB: shared COLOR_BAND_RESID is (:darkorange, 1); this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5, label = "quantiles",   # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5,   # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
        )
    end

    if map_curve !== nothing
        resid = I_fit .- map_curve[:, 2]
        errorbars!(ax, q_fit, resid, σ_fit; whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR)
        scatter!(
            ax, 
            q_fit, 
            resid; 
            markersize = MARKERSIZE, 
            color = COLOR_DATA, 
            label = "data - MAP"
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
    sasdzz9_fit1_hist(result) -> Figure
"""
function sasdzz9_fit1_hist(result)
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
    sasdzz9_fit1_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit1 curve (column 4 of
SASDZZ9_fit1.fit).
"""
function sasdzz9_fit1_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    keep = (qvals_all .> 0) .& (qvals_all .≤ Q_MAX_FIT) .& (I_crysol_all .> 0)

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
        ax, qvals_all[keep], I_crysol_all[keep];
        color = COLOR_REFERENCE, linewidth = LW_REFERENCE, linestyle = :dash, label = "CRYSOL fit1",
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

fig_fit1 = sasdzz9_fit1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1.png"), fig_fit1; px_per_unit = PX_PER_UNIT)

fig_fit1_residuals = sasdzz9_fit1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_residuals.png"), fig_fit1_residuals; px_per_unit = PX_PER_UNIT)

fig_fit1_hist = sasdzz9_fit1_hist(result)
save(joinpath(@__DIR__, "res_fit1_hist.png"), fig_fit1_hist; px_per_unit = PX_PER_UNIT)

fig_fit1_crysol = sasdzz9_fit1_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_comparison.png"), fig_fit1_crysol; px_per_unit = PX_PER_UNIT)

"Display the SASDZZ9 fit1 figure. Blocks until the window is closed."
vis_sasdzz9_fit1() = wait(display(fig_fit1))
