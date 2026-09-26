using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDZZ9")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDZZ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDZZ9_fit1.fit")

# `experimental_data/` and `pddf/` are both EMPTY for this fixture (no bundled
# .dat, no bundled GNOM .out) -- unlike SASDMJ9. The .fit file bundles its own
# experimental columns (standard ATSAS/CRYSOL .fit layout: q, I_exp, σ_exp,
# I_fit), so that IS the experimental curve here; there is no separate .dat.
raw = readdlm(_FIT_PATH; skipstart = 1)

qvals_all = Float64.(raw[:, 1])
I_all     = Float64.(raw[:, 2])
σ_all     = Float64.(raw[:, 3])
I_crysol_all = Float64.(raw[:, 4])

# Units: the file's own header line ("RGT:23.93", i.e. Rg = 23.93 Å) is
# consistent with Dmax ≈ 3-4×Rg landing right on the coordinate-derived Dmax
# computed below (≈70.6 Å, 23.93*3 ≈ 71.8) only if q is already in Å⁻¹ (CRYSOL's
# native unit, same reciprocal space as the .pdb's own Å coordinates) --
# so, unlike SASDMJ9's separate .dat file, NO nm⁻¹ -> Å⁻¹ conversion is applied here.
qvals = qvals_all
I_exp = I_all
σ_exp = σ_all

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: WebFetch of https://www.sasbdb.org/data/SASDZZ9/ (succeeded).
# No paper PDF is bundled with this fixture (unlike SASDMJ9); the entry
# metadata itself gives:
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
#   Models: two fits are given for this entry -- fit1 (rigid-body/crystal
#       PDB model, χ²≈34.5, this script) and fit2 (an ab initio DAMMIF/
#       DAMAVER dummy-atom bead model, χ²≈0.002). fit2 is not wired up here:
#       a dummy-bead model has no real per-residue chemistry, which makes
#       pdb2pqr/PROPKA hydrogenation and the excluded-volume/electrostatics
#       physics unreliable for it (see the removed SASDZZ9_fit2.jl's
#       reasoning, no longer present in this repo).

const PH, σ_PH = 7.5, 0.1   # ±0.1 typical benchtop pH-meter precision

const ENERGY_EV       = 12398.42 / 1.37 # ≈ 9049.9 eV, from 0.137 nm wavelength
const TEMPERATURE_C    = 25.0           # 16°C stated in SASBDB entry, but
                                        # this version only supports 25°C
                                        # (only water's T-dependence is modelled)
const IONIC_STRENGTH_M = 0.100          # 100 mM NaCl, SASBDB's own stated ~100 mM

# NodB sequence, read directly off SASDZZ9_fit1_model1.pdb chain A (the only
# protein chain present; residues 2-405, 404 residues). This matches
# UniProt A7MSF4 residues 23-427 (the file's own numbering starts after an
# N-terminal His-tag/signal-peptide region not modelled in the crystal
# structure) -- confirmed by exact substring match against the UniProt
# A7MSF4 FASTA fetched separately. A single Zn²⁺ HETATM (chain C, a
# catalytic-site ion typical of this deacetylase family) is present in the
# .pdb but is not itself a solute in the buffer list below (it's part of
# the fixed structural model, not a free buffer component).
const NODB_SEQ = "TAPKGTIYLTFDDGPINASIDVINVLNEQGVKGTFYFNAWHLDGIGDENEDRALEALKLALDTGHVVANHSYAHMVHNCVDEFGPTSGAECNATGDHQINAYQDPVYDASTFADNLVVFERYLPNINSYPNYFGEELARLPYTNGWRITKDFKADGLCATSDDLKPWEPGYVCDLDNPSNSVKASIEVQNILANKGYQTHGWDVDWSPENWGIPMPANSLTEAEAFLGYVDAALNSCAPTTINPINSKAHGFPCGTPLHADKVVVLTHEFLYEDGKRGMGATQNLPKLAKFLRIAKEAGYVFDTIDNYTPVWQVGNAYAAGDYVTHSGTVYKAVTAHIAQQDWAPSSTSSLWTNADPATNWTLNVSYEAGDVVTYQGLRYLVNVPHVSQADWTPNTQNTLFTAL"

# Average mass from NODB_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH); ≈44.36 kDa, close to SASBDB's stated 45 kDa.
const NODB_MW = 44360.06   # g/mol
const NODB_CONC_MG_ML = 4.00
const NODB_MOLARITY   = NODB_CONC_MG_ML / NODB_MW   # ≈ 9.02e-5 M
const NODB_MOLARITY_σ = 0.05 * NODB_MOLARITY        # 5% relative: typical A280/mg-ml

# Buffer components. "sodium chloride" / "tris" both present verbatim in
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json -- no missing
# lookups for this fixture.
const SOLUTES = Solute[
    Protein(NODB_MOLARITY, NODB_MOLARITY_σ, NODB_SEQ),
    NonBiological(0.100, 0.001,   "sodium chloride"),   # 100 mM NaCl, ±1%
    NonBiological(0.020, 0.0004,  "tris"),              # 20 mM Tris, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No GNOM pddf was bundled with this fixture (pddf/ is empty), so lMax can't
# be read off a P(r) Dmax. Instead Dmax is estimated directly from the .pdb's
# own coordinate extent: max pairwise heavy-atom distance among chain-A ATOM
# records (Python/itertools brute force over all pairs) = 70.63 Å. Q_MAX_FIT
# is set to just above the file's own q_max (0.387528). lMax then follows the
# same q·D_max rule of thumb used for SASDMJ9: Q_MAX_FIT * D_max ≈ 0.39 * 70.6
# ≈ 27.5, rounded up to 28.
const Q_MAX_FIT = 0.39
const LMAX      = 28

const ADD_HYDROGENS = true   # runs PDB2PQR at PH

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

function run_sasdzz9_fit1(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
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

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdzz9_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDZZ9/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit1.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdzz9_fit1_figure(result, data) -> Figure

Plots the SASDZZ9 fit1 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdzz9_fit1_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "SASDZZ9 fit1 (PDB model); divergence rate = $(round(divergence_rate; digits = 3))",
        xscale = log10,
        yscale = log10,
    )

    # Floor for the quantile/bounds curve's lower edge on this log10 y-axis;
    # see SASDMJ9.jl's sasdmj9_figure for the reasoning.
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

    # Log-symmetric errorbar via the delta method; see SASDMJ9.jl's
    # sasdmj9_figure for why a raw additive I ± σ interval isn't used.
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

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

"""
    sasdzz9_fit1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdzz9_fit1_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)", title = "SASDZZ9 fit1 residuals")

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
    sasdzz9_fit1_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdzz9_fit1_posterior_hist(result)
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
    sasdzz9_fit1_crysol_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit1 curve (column 4 of
SASDZZ9_fit1.fit).
"""
function sasdzz9_fit1_crysol_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data

    keep = (qvals_all .> 0) .& (qvals_all .≤ Q_MAX_FIT) .& (I_crysol_all .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "BAYSOL MAP vs. CRYSOL fit1 (SASBDB)",
        xscale = log10,
        yscale = log10,
    )

    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, qvals_all[keep], I_crysol_all[keep];
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

fig_fit1 = sasdzz9_fit1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1.png"), fig_fit1)

fig_fit1_residuals = sasdzz9_fit1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_residuals.png"), fig_fit1_residuals)

fig_fit1_hist = sasdzz9_fit1_posterior_hist(result)
save(joinpath(@__DIR__, "res_fit1_hist.png"), fig_fit1_hist)

fig_fit1_crysol = sasdzz9_fit1_crysol_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_crysol_comparison.png"), fig_fit1_crysol)

"Display the SASDZZ9 fit1 figure. Blocks until the window is closed."
vis_sasdzz9_fit1() = wait(display(fig_fit1))
