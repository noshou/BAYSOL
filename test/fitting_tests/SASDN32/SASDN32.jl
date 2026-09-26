using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

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
# (q, exp_intensity, model_intensity, error) -- this is itself a CRYSOL/FoXS-
# style four-column fit file (SASBDB's own reference fit), reused here as the
# plain experimental-curve source: we read columns 1/2/4 (q, exp_intensity,
# error) and ignore column 3 (model_intensity, someone else's fit, not ours).
# No separate CRYSOL/FoXS reference-fit file is bundled for this case (unlike
# SASDMJ9's `.fit`), so -- as instructed -- there is no CRYSOL-comparison
# plot/function below (column 3 of this same .dat *is* someone else's model
# curve, but we deliberately don't build a comparison figure around it).
# q is already in Å⁻¹ (q_max ≈ 0.3455 Å⁻¹, consistent with the paper's stated
# SEC-SAXS q range of 0.005-0.35 Å⁻¹, see below) -- no nm⁻¹→Å⁻¹ conversion
# needed, unlike SASDMJ9.
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
# This is the SAME paper backing sibling case SASDMZ9 (test/fitting_tests/SASDMZ9/),
# but a DIFFERENT one of its six SASBDB entries and a DIFFERENT construct.
#
# The paper's "Data availability" paragraph (p.16) lists six SASBDB
# accessions for its SEC-SAXS runs -- SASDMX9, SASDMY9, SASDMZ9, SASDN22,
# SASDN32, SASDN42 -- one per construct/ligand condition. SASDMZ9 was
# identified (see that script) as Sas20d1-2 apo (the full two-domain
# construct, no ligand). SASDN32 is a DISTINCT entry/construct, identified
# here as **Sas20d2 (domain 2 of Sas20) WITH 5 mM maltoheptaose bound**:
#
#   * Sequence match: the 245-residue sequence read off
#     SASDN32_fit1_model1.pdb (below) is an EXACT substring of the tail of
#     SASDMZ9's own Sas20d1-2 sequence (SASDMZ9_fit1_model1.pdb chain A,
#     residues 32-555) -- i.e. this construct is the C-terminal domain of
#     the same two-domain protein, matching the paper's own domain split
#     (Sas20d1 = N-terminal CBM26-like domain, Sas20d2 = C-terminal domain;
#     "Discussion", p.11-12).
#   * Structural extent: the maximum pairwise heavy-atom distance computed
#     directly from SASDN32_fit1_model1.pdb's own coordinates is ≈ 74.1 Å
#     (see LMAX below), matching Table 4's (p.10) "Sas20d2 + maltoheptaose"
#     row almost exactly: Rg = 20.8 ± 0.04 Å, D_max(solution) = 74 Å,
#     D_max(model) = 67.5 Å, SAXS MW = 25.9 kDa -- as against the apo
#     "Sas20d2" row's D_max(solution) = 78 Å / Rg = 23.1 Å. (Sas20d2 itself
#     was never crystallized -- the paper instead fit the SAXS data with a
#     Phyre2-generated homology model built from the Sca5X25-2 crystal
#     structure, p.9-10 -- which is presumably the origin of this bundled
#     PDB "model1"; the absence of HETATM ligand atoms in the file just
#     reflects that it's a protein-only structural model, NOT that the
#     underlying SAXS sample was ligand-free.)
#   * SASBDB entry metadata itself (sasbdb.org/data/SASDN32/, fetched
#     directly): "Dockerin domain-containing protein, starch adherence
#     system 20 (Sas20), domain 2"; UniProt A0A2N0URA4; monomer; MW 25.9 kDa
#     (experimental ≈ 26 kDa); buffer "phosphate buffered saline, 1 mM
#     TCEP, pH 7"; 23°C; protein concentration 10.00 mg/ml; ligand
#     maltoheptaose; BioCAT 18ID (APS, Argonne), λ = 0.1033 nm,
#     sample-detector distance 3.6 m; Rg = 2.1 nm (21 Å), D_max = 7.4 nm
#     (74 Å) -- all consistent with the "+ maltoheptaose" row above, not the
#     apo row.
#   * The paper's own text confirms the 5 mM maltoheptaose concentration
#     used for this specific SEC-SAXS run, in the Figure 5 caption (p.11):
#     "SAXS scattering profile (points) and MultiFoXS fit (black line) for
#     ... Sas20d2 with 5 mM maltoheptaose"; and separately (p.9-10,
#     "Sas20 domains are flexible and extended in solution") states the SEC-
#     SAXS experiments were run "with and without maltoheptaose" for both
#     Sas20d1 and Sas20d2 (Table S4, not bundled).
#
# Buffer: same generic SEC-SAXS Materials & Methods paragraph as SASDMZ9
# (p.16, "SEC–SAXS experiments") applies -- BioCAT 18ID, in-line SEC-SAXS,
# Superdex 200 Increase 10/300 GL, 0.6 ml/min, q range 0.005-0.35 Å⁻¹
# (matching this file's q_max above). The buffer composition itself comes
# from SASBDB's "phosphate buffered saline, 1 mM TCEP, pH 7" (see above),
# combined with the paper's own explicit PBS recipe stated elsewhere (p.14,
# "Growth and proteomic analysis of R. bromii"): "PBS (137 mM NaCl, 2.7 mM
# KCl, 10 mM Na2HPO4, and 1.8 mM KH2PO4 [pH = 7.4])" -- SASBDB rounds this
# to "pH 7" for the SAXS sample specifically; pH = 7.0 (SASBDB's stated
# value) is used here over the paper's generic PBS-recipe pH 7.4, since
# it's the more specific figure for this measurement (same reasoning as
# SASDMZ9).

const PH, σ_PH = 7.0, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV       = 12398.42 / 1.033   # ≈ 12001 eV, from SASBDB's stated λ = 0.1033 nm = 1.033 Å
const TEMPERATURE_C    = 25.0              # 23°C stated (SASBDB); 25 used, close enough and matches BAYSOL's defaults
const IONIC_STRENGTH_M = 0.171             # PBS ionic strength, identical buffer recipe to SASDMZ9 -- see its
                                            # comment for the I = 0.5 * Σ cᵢzᵢ² derivation (≈ 0.1715 M)

# Sas20d2 sequence, read directly off SASDN32_fit1_model1.pdb (single,
# unlabeled chain -- the ATOM records carry a blank chain identifier, and
# there is exactly one MODEL/ENDMDL block), residues 311-555 (full-length
# Sas20d1-2 numbering, 245 contiguous residues, no gaps, no HETATM). This
# span is an exact substring of SASDMZ9's SAS20D1_2_SEQ tail (confirmed by
# direct string comparison), i.e. this construct is domain 2 of the same
# two-domain protein modelled in full by SASDMZ9.
const SAS20D2_SEQ = "ADATQYVVAGVESLTGYEWQGSPALAPENVMTKSGDVYTKTFTAVPVGKSYQLKVVANTGDEQKWIGLDGTDNNVTFDVESACDVTVTFNPATNEIAVTGDGVKMVTDLEINSITVVGNGENSWLNGVAWGVDAEVNHMTQIADKVYQITYTGVESADAAYQFKFAVNDDWAANWGLPEQSAATIGEDFDLTFNGENMLLNTVSAGYPEDSLVDVTITLDLTKFDYPSRSGAKANIKIDGNRVLL"

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
# All buffer salts cross-checked against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json (case-
# insensitive) and its sibling .tsv -- "sodium chloride", "potassium
# chloride", "disodium hydrogen phosphate", "potassium dihydrogen
# phosphate", and "tcep" are all present with real data.
#
# MISSING FROM PMV LOOKUP: maltoheptaose. Neither "maltoheptaose" nor any
# synonym appears in common_to_iupac.json or the sibling .tsv (only
# "maltose" and "maltotriose" are present -- no 7-unit malto-oligosaccharide
# entry). Adding it as a NonBiological solute would error out of
# PartialMolarVolumes.ϕ°, so -- following the same precedent as SASDZC6's
# omitted udenafil -- it is simply left out of SOLUTES below rather than
# stubbed in. Unlike SASDZC6's 3 μM inhibitor, 5 mM maltoheptaose is not
# negligible next to the 137 mM NaCl / 10 mM phosphate buffer components,
# so this is a real, if unavoidable, gap in the excluded-volume accounting
# for this case (no PMV data exists for this ligand to do otherwise).
const SOLUTES = Solute[
    Protein(SAS20D2_MOLARITY, SAS20D2_MOLARITY_σ, SAS20D2_SEQ),
    NonBiological(0.137,  0.00137,   "sodium chloride"),               # 137 mM NaCl, ±1%
    NonBiological(0.0027, 0.000027,  "potassium chloride"),            # 2.7 mM KCl, ±1%
    NonBiological(0.010,  0.0002,    "disodium hydrogen phosphate"),   # 10 mM Na2HPO4, ±2%
    NonBiological(0.0018, 0.000036,  "potassium dihydrogen phosphate"),# 1.8 mM KH2PO4, ±2%
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
# SASDN32_fit1_model1.pdb is ≈ 74.1 Å (computed once offline over its 1854
# atoms) -- in close agreement with both the paper's own Table 4 D_max
# (solution) = 74 Å and SASBDB's own stated D_max = 7.4 nm for this entry
# (see solution-conditions discussion above). Q_MAX_FIT * D_max ≈
# 0.3 * 74.1 ≈ 22.2.
const LMAX = 22

const ADD_HYDROGENS = true   # runs PDB2PQR at PH

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
    s, μ_χ, σ_χ = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        ionic_strength_M = IONIC_STRENGTH_M, T = TEMPERATURE_C + 273.15,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, μ_χ, σ_χ, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdn32()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDN32/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
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
    sasdn32_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdn32_residuals_figure(result, data)
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
    sasdn32_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdn32_posterior_hist(result)
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

# No CRYSOL-comparison plot for this case: unlike SASDMJ9's bundled
# `.fit` reference file, SASDN32 has no separate CRYSOL/FoXS reference fit
# shipped alongside it (`SASDN32_fit1.dat`'s own "model_intensity" column is
# itself just someone else's fit curve, not a distinct reference file to
# overlay), so `sasdn32_crysol_comparison_figure` is intentionally omitted.

fig = sasdn32_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig)

fig_residuals = sasdn32_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals)

fig_hist = sasdn32_posterior_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist)

"Display the SASDN32 fit figure. Blocks until the window is closed."
vis_sasdn32() = wait(display(fig))
