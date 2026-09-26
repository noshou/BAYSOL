using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJ62")
# The experimental curve lives directly in the case root for SASDJ62 (not
# under experimental_data/, which is empty for this case).
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDJ62_fit1.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJ62_fit1_model1.pdb")
# No separate CRYSOL .fit/.fir reference file is bundled for this case (the
# _fit1.dat file itself carries a "model_intensity" column, but that's not a
# CRYSOL reference curve we were given provenance for, so it's not used for
# a comparison plot) -- the CRYSOL-comparison figure is omitted entirely for
# all three SASDJ62 model scripts.

raw = readdlm(_DATA_PATH; skipstart = 3)

# SASDJ62_fit1.dat's own header:
#   # SAXS profile: number of points = 876, q_min = 0.01199, q_max = 0.49959, ...
#   # offset = ..., scaling c = ..., Chi = ...
#   #  q       exp_intensity   model_intensity
# i.e. 3 comment lines, then 876 rows of 4 whitespace-separated columns:
# q, exp_intensity, model_intensity, error. Column 3 (model_intensity) is
# some pre-existing fit (provenance unknown -- not used here). q's own
# range (0.012-0.50) is already consistent with Å⁻¹ (a nm⁻¹ reading would
# put qmin at an implausible ~524 nm real-space feature size for a Guinier
# region), so -- unlike SASDMJ9's raw nm⁻¹ file -- no /10 conversion is
# applied here.
qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 4])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# No paper PDF is bundled in the fixtures for this case. WebFetch against
# https://www.sasbdb.org/data/SASDJ62/ SUCCEEDED and returned:
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
#   Structural parameters (paper/SASBDB, NOT used for lMax here -- see the
#   lMax section below): Rg(Guinier) 6.3 nm, Rg(p(r)) 7.4 nm, Dmax 26.9 nm,
#   experimental MW 110 kDa (suggesting a dimer in solution).
#
# These values ARE paper/SASBDB-sourced (not package-default best-effort
# fallbacks) since the WebFetch succeeded.

const PH, σ_PH = 7.5, 0.1   # ±0.1 is a typical benchtop pH-meter precision

# wavelength 0.1127 nm = 1.127 Å => energy = hc/λ (hc = 12398.42 eV·Å)
const ENERGY_EV        = 12398.42 / 1.127   # ≈ 11001.2 eV
const TEMPERATURE_C     = 25.0               # 20°C given in paper/SASBDB, but this
                                              # version only supports T = DEFAULT_TEMPERATURE_C
                                              # (Constants.jl); see seed_model's t= docstring note.
const IONIC_STRENGTH_M  = 0.200              # 200 mM NaCl, matches the SEC/SAXS buffer above

# XRCC1 sequence (P18887, residues 1-633), read directly off this model's
# own ATOM CA records (no SEQRES present in these fixture PDBs; they carry
# only HELIX/SHEET/ATOM/CONECT/END records, CHARMM-style with explicit
# hydrogens and no chain-ID column). model1 is a single unlabeled chain
# (633 residues, segid "1"); its CA trace was converted 3-letter -> 1-letter
# to recover the sequence below.
const XRCC1_SEQ = "MPEIRLRHVVSCSSQDSTHCAENLLKADTYRKWRAAKAGEKTISVVLQLEKEEQIHSVDIGNDGSAFVEVLVGSSAGGAGEQDYEVLLVTSSFMSPSESRSGSNPNRVRMFGPDKLVRAAAEKRWDRVKIVCSQPYSKDSPFGLSFVRFHSPPDKDEAEAPSQKVTVTKLGQFRVKEEDESANSLRPGALFFSRINKTSPVTASDPAGPSYAAATLQASSAASSASPVSRAIGSTSKPQESPKGKRKLDLNQEEKKTPSKPPAQLSPSVPKRPKLPAPTRTPATAPVPARAQGAVTGKPRGEGTEPRRPRAGPEELGKILQGVVVVLSGFQNPFRSELRDKALELGAKYRPDWTRDSTHLICAFANTPKYSQVLGLGGRIVRKEWVLDCHRMRRRLPSQRYLMAGPGSSSEEDEASHSGGSGDEAPKLPQKQPQTKTKPTQAAGPSSPQKPPTPEETKAASPVLQEDIDIEGVQSEGQDNGAEDSGDTEDELRRVAEQKEHRLPPGQEENGEDPYAGSTDENTDSEEHQEPPDLPVPELPDFFQGKHFFLYGEFPGDERRKLIRYVTAFNGELEDYMSDRVQFVITAQEWDPSFEEALMDNPSLAFVRPRWIYSCNEKQKLLPHQLYGVVPQA"

# Average mass from XRCC1_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH) => 69497.53 g/mol, matching the paper/SASBDB's
# stated monomeric MW of 69.5 kDa almost exactly.
const XRCC1_MW = 69497.53   # g/mol
const XRCC1_CONC_MG_ML = 5.9
const XRCC1_MOLARITY   = XRCC1_CONC_MG_ML / XRCC1_MW   # ≈ 0.0849 mM (monomer-equivalent)
const XRCC1_MOLARITY_σ = 0.05 * XRCC1_MOLARITY         # 5% relative: typical A280/mg-ml

# Buffer components. Every non-protein species below is present in
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json (checked by
# grep -i against that file): "sodium chloride", "tris", "glycerol" all
# resolve -- none are flagged missing.
#
# Glycerol is stated only as "2% glycerol" (v/v, no further detail) --
# converted to molarity assuming 2% v/v (20 mL/L), glycerol density
# 1.261 g/mL, MW 92.094 g/mol: 20 * 1.261 / 92.094 ≈ 0.274 M. This
# v/v -> molarity step is a package-input-shape necessity, not a
# paper-stated molarity, hence the wider 10% relative uncertainty below
# (vs. 1-2% for the directly-stated molar buffer components).
const SOLUTES = Solute[
    Protein(XRCC1_MOLARITY, XRCC1_MOLARITY_σ, XRCC1_SEQ),
    NonBiological(0.200, 0.002,   "sodium chloride"),   # 200 mM NaCl, ±1%
    NonBiological(0.020, 0.0004,  "tris"),              # 20 mM Tris-HCl, ±2%
    NonBiological(0.274, 0.027,   "glycerol"),          # ≈2% v/v glycerol, ±10% (conversion assumption)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT    = 0.5

# No GNOM pddf is bundled for this case (pddf/ is empty). Dmax is instead
# estimated directly from this model's own PDB coordinates: max pairwise
# Cα-Cα distance over the convex hull of all Cα atoms (model1, 633
# residues, single chain) = 212.45 Å (computed with a throwaway
# numpy/scipy ConvexHull script; brute-force max over hull vertices).
# This is notably larger than the paper's own GNOM-derived Dmax (26.9 nm
# = 269 Å is closer to model3's own estimate below) -- model1 appears to
# be a more compact/different conformer of the flexible XRCC1 assembly.
# lMax then follows the same q·D_max multipole-resolution rule of thumb
# used for SASDMJ9: lMax ≈ round(Q_MAX_FIT * D_max) = round(0.5 * 212.45).
# NOTE: this is considerably larger than SASDMJ9's lMax=25 because this
# particle is both bigger and (per the paper) conformationally extended;
# it may need to be reduced for practical runtime.
const LMAX = 106

# ADD_HYDROGENS = false: this PDB already carries explicit hydrogens under
# CHARMM naming (HT1/HT2/HT3 for the N-terminal amine, not PDB-standard
# H/H2/H3) -- confirmed by a real run that pdb2pqr's debumper cannot
# reconcile a pre-existing, non-standard-named hydrogen with the topology
# it's trying to build from scratch ("Found gap in biomolecule structure
# for atom ... HT3 MET 1", RuntimeError, ProcessExited(1)). The structure
# doesn't need re-protonating -- its hydrogens are already there (and the
# element column is correctly populated, unlike the earlier legacy-PDB
# cases), so this just runs on the structure as given.
const ADD_HYDROGENS = false

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdj62_model1(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
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

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdj62_model1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDJ62/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_model1.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdj62_model1_figure(result, data) -> Figure

Plots the SASDJ62 model1 fit: the experimental data (`data = (q_fit, I_fit,
σ_fit)`) with its per-point standard errors, the MAP predicted curve, and
(when not all draws diverged) the quantile-curve envelope.
"""
function sasdj62_model1_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "model1: divergence rate = $(round(divergence_rate; digits = 3))",
        xscale = log10,
        yscale = log10,
    )

    # Floor for the quantile/bounds curve's lower edge on this log10 y-axis.
    # See SASDMJ9.jl's sasdmj9_figure for the rationale.
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
    sasdj62_model1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
similarly re-centred on the MAP curve.
"""
function sasdj62_model1_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)", title = "model1: fit residuals")

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
    sasdj62_model1_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdj62_model1_posterior_hist(result)
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

# No CRYSOL .fit/.fir reference file is bundled for SASDJ62 -- the
# CRYSOL-comparison figure/function from the SASDMJ9.jl template is
# intentionally omitted here.

fig = sasdj62_model1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1.png"), fig)

fig_residuals = sasdj62_model1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_model1_residuals.png"), fig_residuals)

fig_hist = sasdj62_model1_posterior_hist(result)
save(joinpath(@__DIR__, "res_model1_hist.png"), fig_hist)

"Display the SASDJ62 model1 fit figure. Blocks until the window is closed."
vis_sasdj62_model1() = wait(display(fig))
