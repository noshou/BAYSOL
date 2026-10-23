using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDU29")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDU29.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDU29_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDU29_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 2)

# has 2 lines of headers, and 2 lines of trailer (range-from/range-to) at the end; need to
# skip.
qvals = Float64.(raw[1:1227, 1])
I_exp = Float64.(raw[1:1227, 2])
σ_exp = Float64.(raw[1:1227, 3])

# q is already in Å⁻¹ (range 0.00417-0.3571, SASBDB "1/A", APS BioCAT 18ID); no unit
# conversion is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# The .dat is the SASBDB display copy, "scaled by a factor of 10000000" (its I(q) is
# ≈ 3 at the lowest q), while the depositor's .fit file holds the original, unscaled
# intensities (≈ 3e-7): the ratio of the two is 1e7 at every shared q. The fit does not
# depend on the scale (a free scale is profiled), but the reference curve of the
# comparison figure is brought onto the .dat's scale with this factor.
const FIT_FILE_SCALE = 1e7

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDU29/); paper: Srivastava D et al.
# 2024, Structure ("Molecular basis of CRX/DNA recognition and stoichiometry at the Ret4
# response element"), DOI 10.1016/j.str.2024.07.004.
#
#   Sample:   the homeodomain of cone-rod homeobox protein (CRX, UniProt O43186, 2 x
#             9.763 kDa) bound to the 20-bp Ret4 element of the rhodopsin promoter (sense
#             CAGGAGCTTAGGAGGGGGAG, antisense CTCCCCCTCCTAAGCTCCTG): a 2:1 CRX:DNA
#             complex of 31.9 kDa; SEC-SAXS (Superdex 75 10/300), 4.6 mg/mL injected
#   Buffer:   "20 mM Tris, 150 mM KCl, 5 % glycerol, 1 mM TCEP", pH 7.5
#   Temp.:    22 °C (cell; storage 4 °C)
#   Beamline: APS BioCAT 18ID, Pilatus3 X 1M, "wavelength of λ = 0.1033 nm" => 1.033 Å
#             => energy = hc/λ ≈ 12002 eV
#   Model:    SASDU29_fit1_model1.pdb (a Coot-built crystal model: CRYST1 and ANISOU
#             records are present), chains A and B (CRX homeodomain copies, residues
#             39-201 numbering), E and F (the two DNA strands, 20 nt each), 1899 ATOM
#             atoms, no hydrogens, plus 6 glycerol atoms (HETATM GOL), which are not
#             nucleotides and are dropped by the loader (nucleotide_selector keeps ATOM
#             records and HETATM nucleotides only). The deposited fit1 (χ² 1.546) is a
#             Pepsi-SAXS-style output whose header ("Convex: Concave: Inner:") is the
#             depositor's own contrast tool.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 22.0                     # 22 °C, SASBDB (cell)

# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.8573 (pK(22 °C) = 8.156; ΔH
# 47.45 kJ/mol). The pH is taken as set at room temperature (22 ± 3 °C), which fixes the
# counter-ion amount whatever the measurement temperature. pK(T) from Goldberg, Kishore &
# Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the
# fraction is Davies-corrected at I ≈ 0.167 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.150, 0.0015, "potassium chloride"),   # 150 mM KCl, ±1%
    NonBiological(0.020, 0.0004, "tris"),                  # 20 mM Tris, ±2%
    # 5 % v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL) and MW
    # (92.094 g/mol): 5 mL glycerol/100 mL soln * 1.2613 g/mL / 92.094 g/mol * 1000 ≈
    # 0.685 M. ±5 % as for SASDJ72's glycerol (a v/v -> molarity approximation, ignores
    # mixing non-ideality).
    NonBiological(0.685, 0.0342, "glycerol"),
    NonBiological(0.001, 0.00002, "tcep"),                 # 1 mM TCEP, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017146, 0.000851, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.3: the data reach 0.357 Å⁻¹, but 115 of the 1227 points are ≤ 0 and the curve of this
# 32 kDa complex is at the noise floor above ≈ 0.3 Å⁻¹.
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

# Builds the Seed that `run_sasdu29_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdu29_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdu29_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdu29_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdu29_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdu29_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDU29/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit1.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

# Plotting is loaded after the fits: loading GLMakie first invalidates compiled BAYSOL
# methods, which every fit would then recompile (about 40 % of a fit's wall clock).
using GLMakie

"""
    sasdu29_fit1_figure(result, data) -> Figure

Plots the the CRX homeodomain / Ret4 DNA complex (SASDU29 fit1) fit: the
experimental data (`data = (q_fit, I_fit, σ_fit)`) with its per-point
standard errors, the MAP predicted curve, and (when not all draws
diverged) the quantile-curve envelope.
"""
function sasdu29_fit1_figure(result, data)
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
    sasdu29_fit1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
similarly re-centred on the MAP curve.
"""
function sasdu29_fit1_residuals_figure(result, data)
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
    sasdu29_fit1_hist(result) -> Figure


"""
function sasdu29_fit1_hist(result)
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
    sasdu29_fit1_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the depositor's fit curve (SASBDB fit file).
"""
function sasdu29_fit1_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero)
    # are left out of the plot only; the fit itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    crysol   = readdlm(_FIT_PATH; skipstart = 1)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = FIT_FILE_SCALE .* Float64.(crysol[:, 4])
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
        label = "SASBDB fit1",
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

fig = sasdu29_fit1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdu29_fit1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdu29_fit1_hist(result)
save(joinpath(@__DIR__, "res_fit1_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)

fig_crysol = sasdu29_fit1_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_comparison.png"), fig_crysol; px_per_unit = PX_PER_UNIT)

"Display the SASDU29 fit1 figure. Blocks until the window is closed."
vis_sasdu29_fit1() = wait(display(fig))
