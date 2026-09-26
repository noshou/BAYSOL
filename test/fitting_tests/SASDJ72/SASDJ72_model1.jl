using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJ72")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJ72_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJ72_fit1.fit")

# SASDJ72 ships no experimental_data/ or pddf/ fixture (both directories are
# present but empty); SASDJ72_fit1.fit is the ONLY source of experimental
# data for this case, and it is shared by both candidate models (model1,
# model2), since both are CRYSOL fits of the same measured curve. Header is
# 3 '#' comment lines:
#   # SAXS profile: number of points = 517, q_min = ..., q_max = 0.3256..., delta_q = ...
#   # offset = ..., scaling c = ..., Chi^2 = ...
#   #  q       exp_intensity   error model_intensity
# followed by 517 data rows, columns (q, I_exp, σ_exp, I_crysol_fit). q is
# already in Å⁻¹ (q_max ≈ 0.326 Å⁻¹, typical SIBYLS-beamline protein SAXS
# range) -- no nm→Å conversion needed here, unlike SASDMJ9's .dat file.
raw = readdlm(_FIT_PATH; skipstart = 3)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDJ72 (sasbdb.org/data/SASDJ72/,
# fetched via WebFetch -- succeeded, no paper PDF was bundled in the fixture
# dir for this case). Associated publication per SASBDB: Hammel M, Rashid I,
# Sverzhinsky A, et al., "An atypical BRCT-BRCT interaction with the XRCC1
# scaffold protein compacts human DNA Ligase IIIα within a flexible DNA
# repair complex", Nucleic Acids Res, 2020 -- no PDF text was fetched (only
# SASBDB's own metadata page/API), so buffer/instrument details below are
# taken from SASBDB directly, not cross-checked against the paper's own
# Materials and Methods wording.
#
# Sample: human DNA Ligase IIIα (LigIIIα), monomer/dimer per SASBDB's own
# entry title -- SASBDB reports a Porod/sequence-derived monomer MW of
# 102.69 kDa but an experimental (I(0)-derived) MW of ~150 kDa, suggestive of
# partial dimerization in solution. Both candidate PDB models here
# (SASDJ72_fit1_model1.pdb, SASDJ72_fit1_model2.pdb) are single-chain,
# single-copy structures (922 residues each, see below), so no multimer
# scaffolding is attempted -- this script fits the monomer structure as-is
# and flags the MW/oligomeric-state discrepancy as a caveat rather than
# modeling it.
#
# Buffer (SASBDB "Sample buffer"): 25 mM Tris-HCl, 150 mM NaCl, 10%
# glycerol, 2 mM DTT, pH 7.5.
#
# Instrument: SIBYLS beamline 12.3.1 (Advanced Light Source, Berkeley),
# MAR 165 CCD, stated wavelength λ = 0.11 nm = 1.1 Å
# => energy = hc/λ ≈ 12398.42/1.1 ≈ 11271.29 eV (hc = 12398.42 eV·Å).
#
# Temperature: SASBDB states 20°C measurement (10°C storage); as in the
# SASDMJ9 case, 20°C is not a supported forward-model temperature here, so
# 25°C is used instead.
#
# Sample concentration: SASBDB states a 1-5 mg/ml range, with "low-angle
# data collected at lower concentration merged with the highest
# concentration high-angle data" -- i.e. SASDJ72_fit1.fit is itself a
# concentration-merged curve, not a single-concentration measurement. No
# single mg/ml figure is exactly correct; 3.0 mg/ml (midpoint of the stated
# range) is used with a wide (40%) relative uncertainty on molarity to
# reflect that ambiguity, rather than fabricating a precise number.

const PH, σ_PH = 7.5, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV        = 12398.42 / 1.1   # ≈ 11271.29 eV, from stated λ = 0.11 nm
const TEMPERATURE_C     = 25.0            # 20°C given by SASBDB, but unsupported here
const IONIC_STRENGTH_M  = 0.150           # 150 mM NaCl

# LigIIIα sequence, read directly off SASDJ72_fit1_model1.pdb (MODEL 1 --
# the file contains two MODEL records; load_molecule only reads struc[1],
# i.e. MODEL 1, so that's what's transcribed here). No chain ID is present
# in either PDB file (column is blank); single continuous chain, 922
# residues, CA-verified against SASDJ72_fit1_model2.pdb (identical
# sequence, confirming both candidate models represent the same construct).
const LIGIII_SEQ = "MAEQRFCVDYAKRGTAGCKKCKEKIVKGVCRIGKVVPNPFSESGGDMKEWYHIKCMFEKLERARATTKKIEDLTELEGWEELEDNEKEQITQHIADLSSKAAGTPKKKAVVQAKLTTTGQVTSPVKGASFVTSTNPRKFSGFSAKPNNSGEAPSSPTPKRSLSSSKCDPRHKDCLLREFRKLCAMVADNPSYNTKTQIIQDFLRKGSAGDGFHGDVYLTVKLLLPGVIKTVYNLNDKQIVKLFSRIFNCNPDDMARDLEQGDVSETIRVFFEQSKSFPPAAKSLLTIQEVDEFLLRLSKLTKEDEQQQALQDIASRCTANDLKCIIRLIKHDLKMNSGAKHVLDALDPNAYEAFKASRNLQDVVERVLHNAQEVEKEPGQRRALSVQASLMTPVQPMLAEACKSVEYAMKKCPNGMFSEIKYDGERVQVHKNGDHFSYFSRSLKPVLPHKVAHFKDYIPQAFPGGHSMILDSEVLLIDNKTGKPLPFGTLGVHKKAAFQDANVCLFVFDCIYFNDVSLMDRPLCERRKFLHDNMVEIPNRIMFSEMKRVTKALDLADMITRVIQEGLEGLVLKDVKGTYEPGKRHWLKVKKDYLNEGAMADTADLVVLGAFYGQGSKGGMMSIFLMGCYDPGSQKWCTVTKCAGGHDDATLARLQNELDMVKISKDPSKIPSWLKVNKIYYPDFIVPDPKKAAVWEITGAEFSKSEAHTADGISIRFPRCTRIRDDKDWKSATNLPQLKELYQLSKEKADFTVVAGDEGSSTTGGSSEENKGPSGSAVSRKAPSKPSASTKKAEGKLSNSNSKDGNMQTAKPSAMKVGEKLATKSSPVKVGEKRKAADETLCQTKVLLDIFTGVRLYLPPSTPDFSRLRRYFVAFDGDLVQEFDMTSATHVLGSRDKNPAAQQVSPEWIWACIRKRRLVAPC"

# Average mass from LIGIII_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH) = 102690.9 Da, matching SASBDB's own reported
# 102.69 kDa monomer MW almost exactly -- good cross-check on the extracted
# sequence.
const LIGIII_MW = 102690.9   # g/mol
const LIGIII_CONC_MG_ML = 3.0   # midpoint of SASBDB's stated 1-5 mg/ml range; see note above
const LIGIII_MOLARITY   = LIGIII_CONC_MG_ML / LIGIII_MW   # ≈ 2.92e-5 M (≈ 0.0292 mM)
const LIGIII_MOLARITY_σ = 0.40 * LIGIII_MOLARITY          # 40% relative: concentration is a merged-curve estimate, not a single measured value

# Buffer components. All four cross-checked (case-insensitively) against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json and the sibling
# .tsv -- "sodium chloride", "tris", "dtt", and "glycerol" are all present;
# none missing.
const SOLUTES = Solute[
    Protein(LIGIII_MOLARITY, LIGIII_MOLARITY_σ, LIGIII_SEQ),
    NonBiological(0.150, 0.0015,  "sodium chloride"),   # 150 mM NaCl, ±1%
    NonBiological(0.025, 0.0005,  "tris"),              # 25 mM Tris-HCl, ±2%
    NonBiological(0.002, 0.00004, "dtt"),                # 2 mM DTT, ±2%
    # 10% v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL)
    # and MW (92.094 g/mol): 10 mL glycerol/100 mL soln * 1.2613 g/mL /
    # 92.094 g/mol * 1000 ≈ 1.369 M. Wider (5%) relative uncertainty than
    # the other components since this is a v/v -> molarity approximation
    # (ignores mixing non-ideality), not a directly-stated molar
    # concentration.
    NonBiological(1.369, 0.0685,  "glycerol"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No GNOM pddf was bundled for this case (pddf/ directory exists but is
# empty), so Dmax is estimated directly from this model's own PDB
# coordinates instead: the maximum pairwise distance among the 922 Cα atoms
# of MODEL 1 in SASDJ72_fit1_model1.pdb is ≈176.4 Å (computed offline;
# reasonably close to, if somewhat below, SASBDB's own reported Dmax of
# 21 nm = 210 Å for this entry -- consistent with model1 being a more
# compact conformer than model2, see SASDJ72_model2.jl). Restricting the
# fit to q ≤ Q_MAX_FIT = 0.30 Å⁻¹ (dropping the noisiest tail points above
# that, where relative errors balloon to 20-40%) and applying the usual
# q·D_max multipole-resolution rule of thumb: lMax ≈ 0.30 * 176.4 ≈ 53.
const Q_MAX_FIT = 0.30
const LMAX      = 53

const ADD_HYDROGENS = true   # runs PDB2PQR at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdj72_model1(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
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

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdj72_model1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDJ72/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_model1.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdj72_model1_figure(result, data) -> Figure

Plots the SASDJ72 model1 fit: the experimental data (`data = (q_fit, I_fit,
σ_fit)`) with its per-point standard errors, the MAP predicted curve, and
(when not all draws diverged) the quantile-curve envelope.
"""
function sasdj72_model1_figure(result, data)
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
    sasdj72_model1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdj72_model1_residuals_figure(result, data)
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
    sasdj72_model1_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdj72_model1_posterior_hist(result)
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
    sasdj72_model1_crysol_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit
(SASDJ72_fit1.fit's 4th column, `I_crysol_fit`).
"""
function sasdj72_model1_crysol_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data

    crysol   = readdlm(_FIT_PATH; skipstart = 3)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "BAYSOL MAP vs. CRYSOL fit1 (model1)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdj72_model1_figure` --
    # see its comment for why a raw additive I ± σ interval isn't used here.
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

fig = sasdj72_model1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1.png"), fig)

fig_residuals = sasdj72_model1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1_residuals.png"), fig_residuals)

fig_hist = sasdj72_model1_posterior_hist(result)
save(joinpath(@__DIR__, "res_model1_hist.png"), fig_hist)

fig_crysol = sasdj72_model1_crysol_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1_crysol_comparison.png"), fig_crysol)

"Display the SASDJ72 model1 fit figure. Blocks until the window is closed."
vis_sasdj72_model1() = wait(display(fig))
