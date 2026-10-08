using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJ72")
const _PDB_PATHS = (
    model1 = joinpath(_FIXTURE_DIR, "SASDJ72_fit1_model1.pdb"),
    model2 = joinpath(_FIXTURE_DIR, "SASDJ72_fit1_model2.pdb"),
)
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJ72_fit1.fit")

# SASDJ72 ships no experimental_data/ or pddf/ fixture (both directories are
# present but empty); SASDJ72_fit1.fit
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
# Hammel M, Rashid I, Sverzhinsky A, et al., "An atypical BRCT-BRCT interaction 
# with the XRCC1 scaffold protein compacts human DNA Ligase IIIα within a flexible DNA
# repair complex", Nucleic Acids Res, 2020.
#
# Sample: human DNA Ligase IIIα (LigIIIα), monomer/dimer;
# SASBDB reports a Porod/sequence-derived monomer MW of
# 102.69 kDa but an experimental (I(0)-derived) MW of ~150 kDa, suggestive of
# partial dimerization in solution. Both candidate PDB models here
# (SASDJ72_fit1_model1.pdb, SASDJ72_fit1_model2.pdb) are single-chain,
# single-copy structures (922 residues each, see below), so no multimer
# scaffolding is attempted.
#
# Buffer (SASBDB "Sample buffer"): 25 mM Tris-HCl, 150 mM NaCl, 10%
# glycerol, 2 mM DTT, pH 7.5.
#
# Instrument: SIBYLS beamline 12.3.1 (Advanced Light Source, Berkeley),
# MAR 165 CCD, stated wavelength λ = 0.11 nm = 1.1 Å
# => energy = hc/λ ≈ HC_EV_ANGSTROM / 1.1 ≈ 11271.29 eV (hc = 12398.42 eV·Å).
#
# Temperature: SASBDB states 20°C measurement (10°C storage); 20°C is used.
#
# Sample concentration: SASBDB states a 1-5 mg/ml range, with "low-angle
# data collected at lower concentration merged with the highest
# concentration high-angle data" i.e. SASDJ72_fit1.fit is a
# concentration-merged curve, not a single-concentration measurement. No
# single mg/ml figure is exactly correct; 3.0 mg/ml (midpoint of the stated
# range) is used with a wide (40%) relative uncertainty on molarity to
# reflect that ambiguity, rather than fabricating a precise number.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV        = HC_EV_ANGSTROM / 1.1   # ≈ 11271.29 eV, from stated λ = 0.11 nm
const TEMPERATURE_C     = 20.0            # 20°C measurement, SASBDB
const IONIC_STRENGTH_M  = 0.150           # 150 mM NaCl

# LigIIIα sequence, read off SASDJ72_fit1_model1.pdb (MODEL 1;
# the file contains two MODEL records; load_molecule only reads struc[1],
# i.e. MODEL 1, so that's what's transcribed here). No chain ID is present
# in either PDB file (column is blank); single continuous chain, 922
# residues, CA-verified against SASDJ72_fit1_model2.pdb (identical
# sequence, confirming both candidate models represent the same construct).
const LIGIII_SEQ = 
    "MAEQRFCVDYAKRGTAGCKKCKEKIVKGVCRIGKVVPNPFSESGGDMKEWYHIKCMFEKL" *
    "ERARATTKKIEDLTELEGWEELEDNEKEQITQHIADLSSKAAGTPKKKAVVQAKLTTTGQ" *
    "VTSPVKGASFVTSTNPRKFSGFSAKPNNSGEAPSSPTPKRSLSSSKCDPRHKDCLLREFR" *
    "KLCAMVADNPSYNTKTQIIQDFLRKGSAGDGFHGDVYLTVKLLLPGVIKTVYNLNDKQIV" *
    "KLFSRIFNCNPDDMARDLEQGDVSETIRVFFEQSKSFPPAAKSLLTIQEVDEFLLRLSKL" *
    "TKEDEQQQALQDIASRCTANDLKCIIRLIKHDLKMNSGAKHVLDALDPNAYEAFKASRNL" *
    "QDVVERVLHNAQEVEKEPGQRRALSVQASLMTPVQPMLAEACKSVEYAMKKCPNGMFSEI" *
    "KYDGERVQVHKNGDHFSYFSRSLKPVLPHKVAHFKDYIPQAFPGGHSMILDSEVLLIDNK" *
    "TGKPLPFGTLGVHKKAAFQDANVCLFVFDCIYFNDVSLMDRPLCERRKFLHDNMVEIPNR" *
    "IMFSEMKRVTKALDLADMITRVIQEGLEGLVLKDVKGTYEPGKRHWLKVKKDYLNEGAMA" *
    "DTADLVVLGAFYGQGSKGGMMSIFLMGCYDPGSQKWCTVTKCAGGHDDATLARLQNELDM" *
    "VKISKDPSKIPSWLKVNKIYYPDFIVPDPKKAAVWEITGAEFSKSEAHTADGISIRFPRC" *
    "TRIRDDKDWKSATNLPQLKELYQLSKEKADFTVVAGDEGSSTTGGSSEENKGPSGSAVSR" *
    "KAPSKPSASTKKAEGKLSNSNSKDGNMQTAKPSAMKVGEKLATKSSPVKVGEKRKAADET" *
    "LCQTKVLLDIFTGVRLYLPPSTPDFSRLRRYFVAFDGDLVQEFDMTSATHVLGSRDKNPA" *
    "AQQVSPEWIWACIRKRRLVAPC"

# Average mass from LIGIII_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH) = 102690.9 Da, matching SASBDB's reported
# 102.69 kDa monomer MW almost exactly.
const LIGIII_MW = 102690.9   # g/mol
const LIGIII_CONC_MG_ML = 3.0   # midpoint of SASBDB's stated 1-5 mg/ml range; see note above
const LIGIII_MOLARITY   = LIGIII_CONC_MG_ML / LIGIII_MW # ≈ 2.92e-5 M (≈ 0.0292 mM)
const LIGIII_MOLARITY_σ = 0.40 * LIGIII_MOLARITY        # 40% merged-curve estimate

# Buffer components. 
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 25 mM Tris titrated with HCl -> Cl⁻ = C·0.857 (pK(22 °C) = 8.156). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.171 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.150, 0.0015,  "sodium chloride"), # 150 mM NaCl, ±1%
    NonBiological(0.025, 0.0005,  "tris"),            # 25 mM Tris-HCl, ±2%
    NonBiological(0.002, 0.00004, "dtt"),             # 2 mM DTT, ±2%
    # 10% v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL)
    # and MW (92.094 g/mol): 10 mL glycerol/100 mL soln * 1.2613 g/mL /
    # 92.094 g/mol * 1000 ≈ 1.369 M. Wider (5%) relative uncertainty than
    # the other components since this is a v/v -> molarity approximation
    # (ignores mixing non-ideality), not a directly-stated molar concentration.
    NonBiological(1.369, 0.0685,  "glycerol"),
    NonBiological(0.021436, 0.001060, "chloride"),   # Cl⁻ counter-ion from HCl titration of Tris (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No GNOM pddf was bundled for this case (pddf/ directory exists but is
# empty), so Dmax is estimated directly from this model's PDB
# coordinates instead: the maximum pairwise distance among the 922 Cα atoms
# of MODEL 1 in SASDJ72_fit1_model1.pdb is ≈176.4 Å. Restricting the
# fit to q ≤ Q_MAX_FIT = 0.30 Å⁻¹ (dropping the noisiest tail points above
# that, where relative errors balloon to 20-40%) and applying the usual
# q·D_max multipole-resolution rule of thumb: lMax ≈ 0.30 * 176.4 ≈ 53.
# for model 2, the maximum pairwise distance is ≈212.0 Å and applying the
# multipole-resolution rule of thumb: lMax ≈ 0.30 * 212.0 ≈ 64.

const Q_MAX_FIT = 0.30
const LMAX = (model1 = 53, model2 = 64)

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdj72` samples. It is separate only because the developer tools in test/utils/ build
# a fit's Seed without running the fit; if you are reading this script as an example you can skip it:
# `run_sasdj72` below is the whole story (build the seed, then sample it).
function seed_sasdj72(model::Symbol; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATHS[model]), LMAX[model], ENERGY_EV,
        q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (q_fit, I_fit, σ_fit)
end

function run_sasdj72(
    model::Symbol;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED
)
    s, data = seed_sasdj72(model; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

"""
    sasdj72_figure(result, data) -> Figure

Plots the SASDJ72 fit: the experimental data (`data = (q_fit, I_fit,
σ_fit)`) with its per-point standard errors, the MAP predicted curve, and
(when not all draws diverged) the quantile-curve envelope.
"""
function sasdj72_figure(result, data)
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
    sasdj72_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdj72_residuals_figure(result, data)
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
    sasdj72_hist(result) -> Figure
"""
function sasdj72_hist(result)
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
    sasdj72_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit
(SASDJ72_fit1.fit's 4th column, `I_crysol_fit`).
"""
function sasdj72_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    crysol   = readdlm(_FIT_PATH; skipstart = 3)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = FIG_SIZE_CURVE)
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdj72_figure` --
    # see its comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = WHISKERWIDTH, color = COLOR_ERRORBAR,
    )
    scatter!(ax, q_fit, I_fit; markersize = MARKERSIZE, color = COLOR_DATA, label = "data")

    lines!(
        ax, q_crysol[keep], I_crysol[keep];
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

for model in (:model1, :model2)
    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdj72(model)

    fit, divergence_rate, map_result, quantile_result = result

    # `@__DIR__` (this SASDJ72/ folder), not the caller's cwd.
    open(joinpath(@__DIR__, "res_$(model).txt"), "w") do io
        BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
    end

    fig = sasdj72_figure(result, (q_fit, I_fit, σ_fit))
    save(joinpath(@__DIR__, "res_$(model).png"), fig; px_per_unit = PX_PER_UNIT)

    fig_residuals = sasdj72_residuals_figure(result, (q_fit, I_fit, σ_fit))
    save(joinpath(@__DIR__, "res_$(model)_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

    fig_hist = sasdj72_hist(result)
    save(joinpath(@__DIR__, "res_$(model)_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

    fig_crysol = sasdj72_comparison_figure(result, (q_fit, I_fit, σ_fit))
    save(joinpath(@__DIR__, "res_$(model)_comparison.png"), fig_crysol; px_per_unit = PX_PER_UNIT)
end
