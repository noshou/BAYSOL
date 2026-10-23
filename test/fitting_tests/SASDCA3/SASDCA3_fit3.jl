using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDCA3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCA3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDCA3_fit3_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDCA3_fit3.fit")

raw = readdlm(_DATA_PATH; skipstart = 0)

# has no header and no trailer: all 248 rows are data.
qvals = Float64.(raw[1:248, 1])
I_exp = Float64.(raw[1:248, 2])
σ_exp = Float64.(raw[1:248, 3])

# qvals are in nm⁻¹ (range 0.081-3.362; the depositor's .fit file is in Å⁻¹); must convert
# to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDCA3/); paper: Pozner A, Hudson NO,
# Trewhella J, Terooatea TW, Miller SA, Buck-Koehntop BA 2018, J. Mol. Biol.
# ("The C-Terminal Zinc Fingers of ZBTB38 are Novel Selective Readers of DNA Methylation"),
# DOI 10.1016/j.jmb.2017.12.014.
#
#   Sample:   1:1 complex of ZBTB38(1006-1153) (zinc fingers 6-10, 147 residues, 17.337
#             kDa) with the 27-bp methylated CZ38BS DNA duplex (54 nt, 16.705 kDa), 34.0
#             kDa; 3.4 mg/mL (estimated, error ≈ 30 %), 120 x 30 s frames
#   Buffer:   "10 mM Tris, 1 mM tris(2-carboxy-ethyl)phosphine (TCEP), 0.05% NaN3, 10% D2O",
#             pH 6.8; no salt is stated
#   Temp.:    22 °C (cell)
#   Source:   in-house Anton Paar SAXSess (Univ. of Utah, line focus), Mythen 1K detector,
#             wavelength 0.154 nm = 1.54 Å => energy = hc/λ ≈ 8051 eV. The data are
#             desmeared and on an absolute scale (cm⁻¹).
#   Models:   SASBDB lists three fits for this entry; only fit3 is bundled: the HADDOCK /
#             SASREF atomistic model (the initial model of the paper, χ² 1.643 with CRYSOL,
#             "fit3 model built with HADDOCK") is SASDCA3_fit3_model1.pdb. The DNA
#             methylation is not represented in the model (no 5CM residue).
#   Chains:   A (the 54-nt DNA, both strands in one chain, residue names G/C/A/T without
#             the D prefix), B (zinc fingers 6-9 with four zincs, ATOM records "ZN") and
#             C (ZF10, with one zinc ATOM residue "ZN2"); 2299 atoms, no hydrogens. The
#             depositor's fit3 is a single-conformer CRYSOL fit.

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):

const PH, σ_PH = 6.8, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, from the stated 0.154 nm
const TEMPERATURE_C = 22.0                    # 22 °C, SASBDB (cell)

# The solvent contains 10 % D2O (v/v): 0.1 L/L × 1.1044 g/mL / 20.0276 g/mol = 5.514 M,
# listed as a solute with ϕ° 18.132 cm³/mol (derived from M/ρ), which displaces 99.98 mL
# of water per litre and adds the same 10 electrons per molecule. ±5 % on the fraction.
#
# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 10 mM Tris titrated with HCl -> Cl⁻ = C·0.9628 (pK(22 °C) = 8.156; ΔH
# 47.45 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.017 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
#
# 0.05 % NaN3 (w/v) = 0.5 g/L; MW(NaN3) = 65.01 g/mol => ≈ 7.69 mM. TCEP is taken as the
# free acid/base without its own HCl (TCEP·HCl would add up to 1 mM chloride).
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.010, 0.0002, "tris"),             # 10 mM Tris, ±2%
    NonBiological(0.001, 0.00002, "tcep"),            # 1 mM TCEP, ±2%
    NonBiological(0.007691, 0.000154, "sodium azide"),   # 0.05 % w/v NaN3, ±2%
    NonBiological(5.514, 0.276, "d2o"),                   # 10 % v/v D2O, ±5%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.009628, 0.000222, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.3: the data reach 0.336 Å⁻¹ (the depositor's fit file ends there too); beyond 0.3 Å⁻¹
# the desmeared in-house curve is noise (5 points ≤ 0 in the last decade).
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: a mixed protein + DNA model, so the pipeline runs Pdb2pqr
# with PROPKA at PH for the protein (nucleotides are taken as supplied, not titrated).
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdca3_fit3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdca3_fit3` below is the whole story (build the seed, then sample it).
function seed_sasdca3_fit3(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdca3_fit3(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdca3_fit3(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdca3_fit3()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDCA3/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit3.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL
# methods, which every fit would then recompile (about 40 % of a fit's wall clock).
using GLMakie

"""
    sasdca3_fit3_figure(result, data) -> Figure

Plots the the ZBTB38 zinc fingers / methylated DNA complex (SASDCA3 fit3) fit: the
experimental data (`data = (q_fit, I_fit, σ_fit)`) with its per-point
standard errors, the MAP predicted curve, and (when not all draws
diverged) the quantile-curve envelope.
"""
function sasdca3_fit3_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
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
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE,
            label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 3], y_floor);
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = LW_QUANTILE,
        )
    end

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
            map(v -> v > 0 ? v : NaN, map_curve[:, 2]);
            color = COLOR_MAP,
            linewidth = LW_MAP,
            label = "MAP",
        )
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end

"""
    sasdca3_fit3_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
similarly re-centred on the MAP curve.
"""
function sasdca3_fit3_residuals_figure(result, data)
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
            # NB: shared COLOR_BAND_RESID is (:darkorange,
            # 1); this script's plot style is kept as-is
            color = (:darkorange, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            # NB: shared LW_QUANTILE_RESID is 2.5; this script's plot style is kept as-is
            linestyle = :dot, color = COLOR_POSTERIOR, linewidth = 1.5,
        )
    end

    if map_curve !== nothing
        resid = I_fit .- map_curve[:, 2]
        errorbars!(
            ax,
            q_fit,
            resid,
            σ_fit;
            whiskerwidth = WHISKERWIDTH,
            color = COLOR_ERRORBAR,
        )
        scatter!(
            ax,
            q_fit,
            resid;
            markersize = MARKERSIZE,
            color = COLOR_DATA,
            label = "data - MAP",
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
    sasdca3_fit3_hist(result) -> Figure


"""
function sasdca3_fit3_hist(result)
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
    sasdca3_fit3_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the depositor's CRYSOL fit.
"""
function sasdca3_fit3_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    crysol   = readdlm(_FIT_PATH; skipstart = 1)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep     = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

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
        ax, q_crysol[keep], I_crysol[keep];
        color = COLOR_REFERENCE, linewidth = LW_REFERENCE, linestyle = :dash,
        label = "CRYSOL fit3",
    )

    if map_result !== nothing
        _, map_curve = map_result
        lines!(
            ax,
            map_curve[:, 1],
            map(v -> v > 0 ? v : NaN, map_curve[:, 2]);
            color = COLOR_MAP,
            linewidth = LW_MAP,
            label = "BAYSOL MAP",
        )
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end

fig = sasdca3_fit3_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit3.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdca3_fit3_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit3_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdca3_fit3_hist(result)
save(joinpath(@__DIR__, "res_fit3_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

fig_crysol = sasdca3_fit3_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit3_comparison.png"), fig_crysol; px_per_unit = PX_PER_UNIT)

"Display the SASDCA3 fit3 figure. Blocks until the window is closed."
vis_sasdca3_fit3() = wait(display(fig))
