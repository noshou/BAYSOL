using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJ62")
# The experimental curve lives directly in the case root for SASDJ62 (not
# under experimental_data/, which is empty for this case).
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDJ62_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJ62_fit1_model1.pdb")
# No separate CRYSOL .fit/.fir reference file is bundled for this case.

raw = readdlm(_DATA_PATH; skipstart = 3)

# SASDJ62_fit1.dat's own header:
#   # SAXS profile: number of points = 876, q_min = 0.01199, q_max = 0.49959, ...
#   # offset = ..., scaling c = ..., Chi = ...
#   #  q       exp_intensity   model_intensity
# i.e. 3 comment lines, then 876 rows of 4 whitespace-separated columns:
# q, exp_intensity, model_intensity, error.
qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 4])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# <https://www.sasbdb.org/data/SASDJ62/>:
#
#   Citation: Hammel M, Rashid I, Sverzhinsky A, et al. "An atypical
#   BRCT-BRCT interaction with the XRCC1 scaffold protein compacts human
#   DNA Ligase IIIα within a flexible DNA repair complex." Nucleic Acids
#   Res (2020).
#
#   Protein: DNA repair protein XRCC1 (UniProt P18887, residues 1-633),
#   monomeric MW 69.5 kDa, Homo sapiens.
#
#   Buffer/solution: "200 mM NaCl, 20 mM Tris-HCl, pH 7.5, 2% glycerol"
#   at 20°C.
#
#   Sample: 50 μL at 5.9 mg/mL injected onto a SEC column.
#
#   Beam: ALS SIBYLS beamline 12.3.1, wavelength 0.1127 nm, Pilatus3 X 2M
#   detector, 2.1 m sample-detector distance, 600x 3s frames.
#
#   Rg(Guinier) 6.3 nm, Rg(p(r)) 7.4 nm, Dmax 26.9 nm,
#   experimental MW 110 kDa (suggesting a dimer in solution).
#
# These values ARE paper/SASBDB-sourced (not package-default best-effort
# fallbacks) since the WebFetch succeeded.

const PH, σ_PH = 7.5, PH_METER_SIGMA

# wavelength 0.1127 nm = 1.127 Å => energy = hc/λ (hc = 12398.42 eV·Å)
const ENERGY_EV        = HC_EV_ANGSTROM / 1.127   # ≈ 11001.2 eV
const TEMPERATURE_C     = 20.0              # 20°C, paper/SASBDB
                                            # (Fitting.jl); see seed_model's t= docstring note.
const IONIC_STRENGTH_M  = 0.200             # 200 mM NaCl, matches the SEC/SAXS buffer above

# XRCC1 sequence (P18887, residues 1-633), read directly off this model's
# ATOM CA records (no SEQRES present in these fixture PDBs; they carry
# only HELIX/SHEET/ATOM/CONECT/END records, CHARMM-style with explicit
# hydrogens and no chain-ID column). model1 is a single unlabeled chain
# (633 residues, segid "1"); its CA trace was converted 3-letter -> 1-letter
# to recover the sequence below.
const XRCC1_SEQ = 
    "MPEIRLRHVVSCSSQDSTHCAENLLKADTYRKWRAAKAGEKTISVVLQLEKEEQIHSVDI" *
    "GNDGSAFVEVLVGSSAGGAGEQDYEVLLVTSSFMSPSESRSGSNPNRVRMFGPDKLVRAA" *
    "AEKRWDRVKIVCSQPYSKDSPFGLSFVRFHSPPDKDEAEAPSQKVTVTKLGQFRVKEEDE" *
    "SANSLRPGALFFSRINKTSPVTASDPAGPSYAAATLQASSAASSASPVSRAIGSTSKPQE" *
    "SPKGKRKLDLNQEEKKTPSKPPAQLSPSVPKRPKLPAPTRTPATAPVPARAQGAVTGKPR" *
    "GEGTEPRRPRAGPEELGKILQGVVVVLSGFQNPFRSELRDKALELGAKYRPDWTRDSTHL" *
    "ICAFANTPKYSQVLGLGGRIVRKEWVLDCHRMRRRLPSQRYLMAGPGSSSEEDEASHSGG" *
    "SGDEAPKLPQKQPQTKTKPTQAAGPSSPQKPPTPEETKAASPVLQEDIDIEGVQSEGQDN" *
    "GAEDSGDTEDELRRVAEQKEHRLPPGQEENGEDPYAGSTDENTDSEEHQEPPDLPVPELP" *
    "DFFQGKHFFLYGEFPGDERRKLIRYVTAFNGELEDYMSDRVQFVITAQEWDPSFEEALMD" *
    "NPSLAFVRPRWIYSCNEKQKLLPHQLYGVVPQA"

# Average mass from XRCC1_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH) => 69497.53 g/mol, matching the paper/SASBDB's
# stated monomeric MW of 69.5 kDa almost exactly.
const XRCC1_MW = 69497.53   # g/mol
const XRCC1_CONC_MG_ML = 5.9
const XRCC1_MOLARITY   = XRCC1_CONC_MG_ML / XRCC1_MW   # ≈ 0.0849 mM (monomer-equivalent)
const XRCC1_MOLARITY_σ = MOLARITY_REL_SIGMA * XRCC1_MOLARITY

# Glycerol is stated only as "2% glycerol" (v/v, no further detail):
# converted to molarity assuming 2% v/v (20 mL/L), glycerol density
# 1.261 g/mL, MW 92.094 g/mol: 20 * 1.261 / 92.094 ≈ 0.274 M. 
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.859 (pK(22 °C) = 8.156). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.217 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.200, 0.002,   "sodium chloride"),   # 200 mM NaCl, ±1%
    NonBiological(0.020, 0.0004,  "tris"),              # 20 mM Tris-HCl, ±2%
    NonBiological(0.274, 0.027,   "glycerol"),          # ≈2% v/v glycerol, ±10% (conversion assumption)
    NonBiological(0.017181, 0.000844, "chloride"),   # Cl⁻ counter-ion from HCl titration of Tris (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT    = 0.5

# No GNOM pddf is bundled for this case (pddf/ is empty). Dmax is instead
# estimated by the max pairwise Cα-Cα distance over the convex hull of all 
# Cα atoms which came out to be 212.45 Å. This is notably larger than the 
# paper's GNOM-derived Dmax (26.9 nm = 269 Å is closer to model3's); model1 appears to
# be a more compact/different conformer of the flexible XRCC1 assembly.
# lMax ≈ Q_MAX_FIT * D_max = 0.5 * 212.45 ≈ 107
const LMAX = 107

# ADD_HYDROGENS = false: this PDB already carries explicit hydrogens under
# CHARMM naming (HT1/HT2/HT3 for the N-terminal amine, not PDB-standard
# H/H2/H3), which causes pdb2pqr to crash.
const ADD_HYDROGENS = false

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdj62_model1` samples. It is separate only because the developer tools in test/utils/ build
# a fit's Seed without running the fit; if you are reading this script as an example you can skip it:
# `run_sasdj62_model1` below is the whole story (build the seed, then sample it).
function seed_sasdj62_model1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        blm_chunk = UInt64(512),   # lMax = 107 ran out of memory at the default 2048; results are chunk-invariant
    )
    return s, (q_fit, I_fit, σ_fit)
end

function run_sasdj62_model1(; n_samples::Int = N_SAMPLES, n_adapt::Int = N_ADAPT, seed::Integer = SAMPLER_SEED)
    s, data = seed_sasdj62_model1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdj62_model1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDJ62/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_model1.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdj62_model1_figure(result, data) -> Figure
"""
function sasdj62_model1_figure(result, data)
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

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * YLIM_LOG_LO, hi * YLIM_LOG_HI)

    return fig
end

"""
    sasdj62_model1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
similarly re-centred on the MAP curve.
"""
function sasdj62_model1_residuals_figure(result, data)
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
    sasdj62_model1_hist(result) -> Figure
"""
function sasdj62_model1_hist(result)
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

# No CRYSOL .fit/.fir reference file is bundled for SASDJ62 -- the
# CRYSOL-comparison figure/function from the SASDMJ9.jl template is
# intentionally omitted here.

fig = sasdj62_model1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1.png"), fig; px_per_unit = PX_PER_UNIT)

fig_residuals = sasdj62_model1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1_residuals.png"), fig_residuals; px_per_unit = PX_PER_UNIT)

fig_hist = sasdj62_model1_hist(result)
save(joinpath(@__DIR__, "res_model1_hist.png"), fig_hist; px_per_unit = PX_PER_UNIT)
