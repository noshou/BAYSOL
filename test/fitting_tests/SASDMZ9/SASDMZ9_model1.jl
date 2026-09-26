using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMZ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDMZ9_fit1_model1.pdb")

# Unlike SASDMJ9, `experimental_data/` and `pddf/` are EMPTY for this case;
# the experimental curve ships directly as `SASDMZ9_fit1.dat` in the case
# root, and no GNOM .out pddf file is bundled (see LMAX discussion below).
#
# `SASDMZ9_fit1.dat` header:
#   # SAXS profile: number of points = 1211, q_min = 0.00297234626486897, q_max = 0.345499873161316, ...
#   # offset = ..., scaling c = ..., Chi^2 = ...
#   #  q       exp_intensity   model_intensity error
# i.e. 3 comment/header lines, then 1211 data rows in columns
# (q, exp_intensity, model_intensity, error) -- this is itself a CRYSOL/FoXS-
# style four-column fit file (SASBDB's own reference fit), reused here as the
# plain experimental-curve source: we read columns 1/2/4 (q, exp_intensity,
# error) and ignore column 3 (model_intensity, someone else's fit, not ours).
# q is already in Å⁻¹ (q_max ≈ 0.345 Å⁻¹, consistent with the SASBDB entry's
# stated q range of 0.005-0.35 Å⁻¹ below) -- no nm⁻¹→Å⁻¹ conversion needed,
# unlike SASDMJ9.
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
# cell-surface amylosome", test/fixtures/experiments/SASDMZ9/PIIS0021925822003362.pdf.
#
# The paper's "Data availability" paragraph lists six SASBDB accessions for
# its SEC-SAXS runs -- SASDMX9, SASDMY9, SASDMZ9, SASDN22, SASDN32, SASDN42 --
# one per construct/ligand condition (p.16). Cross-checking residue coverage
# (below) against the paper's own Table 4 ("Small-angle X-ray data") and the
# SASBDB entry itself (fetched from sasbdb.org/data/SASDMZ9/) identifies
# SASDMZ9 specifically as **Sas20d1-2 without ligand** (the full two-domain
# construct, apo/unliganded): SASBDB lists UniProt A0A2N0URA4 residues 27-559
# and MW 57.2 kDa for this entry, matching Table 4's Sas20d1-2 (no
# maltoheptaose) sequence MW of 57.2 kDa -- an order of magnitude larger than
# either single domain alone (Sas20d1 ≈ 25.9 kDa, Sas20d2 ≈ 26.5 kDa). This is
# also the entry the paper singles out as highly flexible: "Sas20d1-2 shows a
# range of conformations from very compact to very extended... exists in the
# most compact state only ~11% of the time" (p.11, "Sas20 domains are
# flexible and extended in solution" / discussion of the 3-state MultiFoXS
# ensemble in Fig. 6, D-F: Rg ≈ 53 Å / 78 Å / 37 Å at weights 60% / 29% / 11%).
# The three bundled PDBs (`SASDMZ9_fit1_model{1,2,3}.pdb`) are read here as
# three representative conformers spanning that flexible ensemble (see LMAX
# below for how differently extended they are).
#
# SASBDB entry metadata for SASDMZ9 (sasbdb.org/data/SASDMZ9/):
#   buffer: "phosphate buffered saline, 1 mM TCEP, pH 7"; 5 mg/ml; 23°C;
#   BioCAT 18ID (APS, Argonne); wavelength λ = 0.1033 nm; sample-detector
#   distance 3.6 m; Pilatus3 X 1M detector -- all consistent with the paper's
#   own "SEC-SAXS experiments" Materials & Methods paragraph (p.16), which
#   additionally gives the q range (0.005-0.35 Å⁻¹, matching this file's
#   q_max above) and confirms in-line SEC (Superdex 200 Increase 10/300 GL,
#   0.6 ml/min).
#
# The paper spells out PBS explicitly elsewhere (p.14, "Growth and proteomic
# analysis of R. bromii"): "PBS (137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, and
# 1.8 mM KH2PO4 [pH = 7.4])". SASBDB's own metadata rounds this to "pH 7" for
# the SAXS sample buffer specifically; we use pH = 7.0 (SASBDB's stated value
# for this entry) over the paper's generic pH 7.4 PBS recipe, since it's the
# more specific figure for this measurement.

const PH, σ_PH = 7.0, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV       = 12398.42 / 1.033   # ≈ 12001 eV, from SASBDB's stated λ = 0.1033 nm = 1.033 Å
const TEMPERATURE_C    = 25.0              # 23°C stated (SASBDB); 25 used, close enough and matches BAYSOL's defaults
const IONIC_STRENGTH_M = 0.171             # PBS ionic strength, computed below

# Ionic strength of the PBS+TCEP buffer, I = 0.5 * Σ cᵢzᵢ², from the explicit
# PBS recipe above (Na2HPO4/KH2PO4 treated as fully dissociated at their
# formal ionic charges; TCEP's own ionic contribution is small and omitted):
#   Na⁺ (NaCl):        0.137 * 1²         = 0.1370
#   Cl⁻ (NaCl):        0.137 * 1²         = 0.1370
#   K⁺  (KCl):         0.0027 * 1²        = 0.0027
#   Cl⁻ (KCl):         0.0027 * 1²        = 0.0027
#   Na⁺ (Na2HPO4, ×2): 0.020 * 1²         = 0.0200
#   HPO4²⁻ (Na2HPO4):  0.010 * 2²         = 0.0400
#   K⁺  (KH2PO4):      0.0018 * 1²        = 0.0018
#   H2PO4⁻ (KH2PO4):   0.0018 * 1²        = 0.0018
#   sum = 0.3430  =>  I = 0.5 * 0.3430 ≈ 0.1715 M

# Sas20d1-2 sequence, read directly off SASDMZ9_fit1_model1.pdb chain A
# (residues 32-555, 524 contiguous residues, no gaps). All three model PDBs
# share this exact sequence (they are alternate conformers, not alternate
# constructs) -- confirmed identical residue-by-residue across
# model{1,2,3}.pdb. This is a truncated span of the full Sas20d1-2 construct
# (UniProt A0A2N0URA4 residues 27-559 per SASBDB) -- the missing N-/C-terminal
# residues are presumably disordered/unmodelled in this structure.
const SAS20D1_2_SEQ = "EETDTKIYFDASNLPAEWGTTKTVYCHLYAVAGDDLPETSWQGKAEKCKKDTATGLYYFDTAKLKSADGTNHGGLKDNADYAVIFSTIDTKSQSHQTCNVTLGKPCLGDTIYLTGGTVENTEDSSKRDFAATWKNNSDNYGPKAAITSLGHVTEGRFPIYLSRAEMVAQAIFNWAVKNPKNYTPETVADICAQVEAEPMDVYNAYAEMYATELADPAAYPDCAPLTTVATLLGVDPSGTTAPATEEPTTVEPTTVEPTTVEPTTVEPTTEPTTEPATEPADATQYVVAGVESLTGYEWQGSPALAPENVMTKSGDVYTKTFTAVPVGKSYQLKVVANTGDEQKWIGLDGTDNNVTFDVESACDVTVTFNPATNEIAVTGDGVKMVTDLEINSITVVGNGENSWLNGVAWGVDAEVNHMTQIADKVYQITYTGVESADAAYQFKFAVNDDWAANWGLPEQSAATIGEDFDLTFNGENMLLNTVSAGYPEDSLVDVTITLDLTKFDYPSRSGAKANIKIDGNRVLL"

# Average mass from SAS20D1_2_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH); close to (but smaller than, since this modelled
# span is shorter than the full UniProt range) the paper's Table 4 sequence
# MW for Sas20d1-2 of 57.2 kDa.
const SAS20D1_2_MW = 56385.18   # g/mol
const SAS20D1_2_CONC_MG_ML = 5.0   # SASBDB: 5 mg/ml
const SAS20D1_2_MOLARITY   = SAS20D1_2_CONC_MG_ML / SAS20D1_2_MW   # ≈ 8.87e-5 M ≈ 0.0887 mM
const SAS20D1_2_MOLARITY_σ = 0.05 * SAS20D1_2_MOLARITY             # 5% relative: typical A280/mg-ml

# Buffer components: PBS + 1 mM TCEP (see solution-conditions discussion
# above). All cross-checked against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json (case-insensitive)
# and its sibling .tsv -- all present, nothing missing.
const SOLUTES = Solute[
    Protein(SAS20D1_2_MOLARITY, SAS20D1_2_MOLARITY_σ, SAS20D1_2_SEQ),
    NonBiological(0.137,  0.00137,   "sodium chloride"),              # 137 mM NaCl, ±1%
    NonBiological(0.0027, 0.000027,  "potassium chloride"),           # 2.7 mM KCl, ±1%
    NonBiological(0.010,  0.0002,    "disodium hydrogen phosphate"),  # 10 mM Na2HPO4, ±2%
    NonBiological(0.0018, 0.000036,  "potassium dihydrogen phosphate"), # 1.8 mM KH2PO4, ±2%
    NonBiological(0.001,  0.00002,   "tcep"),                          # 1 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT    = 0.3

# lMax follows the usual q·D_max multipole-resolution rule of thumb. No GNOM
# pddf is bundled for this case (pddf/ is empty), so D_max is instead
# estimated directly from this PDB's own coordinate extent: the maximum
# pairwise heavy-atom (all-ATOM, no waters/HETATM present) distance in
# SASDMZ9_fit1_model1.pdb is ≈ 160.5 Å (computed once offline over its 3968
# atoms). This is one of the three flexible-ensemble conformers described
# above (see solution-conditions discussion) -- it is the intermediate-extent
# one of the three models (model2 ≈ 227.7 Å, model3 ≈ 117.8 Å; see those
# scripts' own LMAX comments), consistent with the paper's own solution-SAXS
# D_max for unliganded Sas20d1-2 (Table 4: D_max ≈ 190-203 Å depending on
# method, itself an average/envelope over this same flexible ensemble).
# Q_MAX_FIT * D_max ≈ 0.3 * 160.5 ≈ 48.
const LMAX = 48

const ADD_HYDROGENS = true   # runs PDB2PQR at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdmz9_model1(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
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

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdmz9_model1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDMZ9/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_model1.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdmz9_model1_figure(result, data) -> Figure

Plots the SASDMZ9 model1 fit: the experimental data (`data = (q_fit, I_fit,
σ_fit)`) with its per-point standard errors, the MAP predicted curve, and
(when not all draws diverged) the quantile-curve envelope.
"""
function sasdmz9_model1_figure(result, data)
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
    sasdmz9_model1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdmz9_model1_residuals_figure(result, data)
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
    sasdmz9_model1_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdmz9_model1_posterior_hist(result)
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

# NOTE: no separate CRYSOL reference-fit file exists for this case (unlike
# SASDMJ9's `SASDMJ9_fit1.fit`), so the CRYSOL-comparison plot/function is
# omitted here.

fig = sasdmz9_model1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1.png"), fig)

fig_residuals = sasdmz9_model1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1_residuals.png"), fig_residuals)

fig_hist = sasdmz9_model1_posterior_hist(result)
save(joinpath(@__DIR__, "res_model1_hist.png"), fig_hist)

"Display the SASDMZ9 model1 fit figure. Blocks until the window is closed."
vis_sasdmz9_model1() = wait(display(fig))
