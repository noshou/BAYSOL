using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDF42")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDF42_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDF42_fit1.fit")

# `experimental_data/` and `pddf/` are both empty for this entry
#
#     sExp iExp Err iFit // ChiExp =   1.45
#
# i.e. column 1 = q, column 2 =
# I_exp, column 3 = σ_exp, column 4 = the paper's own fitted/reference
# curve (χ² = 1.45 quoted in the header). Single header line, so
# `skipstart = 1`.
raw = readdlm(_FIT_PATH; skipstart = 1)

qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Johansson et al. 2020, Biochemistry 59:1410-1419 ("Identification
# of Binding Sites on Human Serum Albumin for Somapacitan, a Long-Acting
# Growth Hormone Derivative"), test/fixtures/experiments/SASDF42/acs.biochem.0c00019.pdf.
#
# Table 2 ("SAXS Data") lists three SAXS entries; the third column,
# "HSA:somapacitan" (molar ratio 1:2, 6.3 mg/mL, MicroMax-007 HF (Rigaku),
# λ = 1.54187 Å, 20 °C, exposure 3600 s, Rg = 41 Å, Dmax = 139 Å, MW ≈ 113
# kDa theoretical), carries the SASDB accession code SASDF42.
#
# Buffer: the "HSA:Somapacitan Complex Formation Studied by SEC" paragraph
# describes this as a 1:2 HSA:somapacitan preparation (Figure 3a, "1:2
# molar ratio (gray)"), run on "a Superdex 200 10/300 GL column (GE
# Healthcare) equilibrated with a 100 mM MES, 140 mM sodium chloride, pH
# 6.5 buffer".
#
# X-ray source for this data set (Table 2, third column): MicroMax-007 HF
# (Rigaku) rotating anode, wavelength stated as 1.54187 Å (Cu Kα) =>
# energy = hc/λ ≈ 8043 eV (hc = 12398.42 eV·Å). Table 2 states the sample
# temperature explicitly as 20 °C.

const PH, σ_PH = 6.5, 0.1   # ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV       = 12398.42 / 1.54187 # ≈ 8043 eV, from the stated 1.54187 Å wavelength
const TEMPERATURE_C    = 20.0              # 20°C, Table 2 (SASBDB says 25 °C; the paper's explicit Table 2 value is used)
const IONIC_STRENGTH_M = 0.140             # 140 mM NaCl, matches the SEC/SAXS buffer above

# ---------------------------------------------------------------------------
#                        Sequences (read from the PDB itself)
# ---------------------------------------------------------------------------
#
# SASDF42_fit1_model1.pdb has no SEQRES records, so both sequences
# were read directly off its own ATOM/CA records (three-letter -> one-letter
# translation of each chain's residues, in residue-number order). The
# REMARKs at the top of the file ("Cond Sub Res ... Dist Pen", Euler-angle
# rotation, SASREF-style "Discog/Cross/Anisom/Center" penalty terms) match
# the paper's own description of this entry ("A rigid body refinement using
# a HSA model in complex with octadecanoic acid and two growth hormone
# molecules ... was applied [with] the ATSAS SASREF module [and] 15 Å
# distance constraints from residue 101 of growth hormone to residues 209
# (FA6) and 502 (FA5) of HSA").
#
# Chain A (residues 3-584, 582 residues modelled) is HSA: the extracted
# sequence lines up exactly with mature human serum albumin (UniProt
# P02768, residues 1-585) starting "DAHKSEV..." (chain A starts at residue
# 3 = "H", i.e. D1/A2 are simply not resolved in this model), missing only
# the very last residue (585, Leu). No bound fatty acid (octadecanoic
# acid) is present as HETATM in this file.
#
# Chains B and C (residues 2-190, 186 residues each, identical sequence) 
# are the two growth hormone (somapacitan) copies;
# both have an internal gap at residues 37-39 (a flexible loop not modelled
# in either copy). Chain B's sequence is used below as the representative
# growth-hormone sequence; its second copy (chain C) is folded into the
# solute molarity below (2x) rather than listed twice, since it is
# chemically the same dissolved species.
const HSA_SEQ = 
    "HKSEVAHRFKDLGEENFKALVLIAFAQYLQQCPFEDHVKLVNEVTEFAKTCVADESAENC" *
    "DKSLHTLFGDKLCTVATLRETYGEMADCCAKQEPERNECFLQHKDDNPNLPRLVRPEVDV" *
    "MCTAFHDNEETFLKKYLYEIARRHPYFYAPELLFFAKRYKAAFTECCQAADKAACLLPKL" *
    "DELRDEGKASSAKQRLKCASLQKFGERAFKAWAVARLSQRFPKAEFAEVSKLVTDLTKVH" *
    "TECCHGDLLECADDRADLAKYICENQDSISSKLKECCEKPLLEKSHCIAEVENDEMPADL" *
    "PSLAADFVESKDVCKNYAEAKDVFLGMFLYEYARRHPDYSVVLLLRLAKTYETTLEKCCA" *
    "AADPHECYAKVFDEFKPLVEEPQNLIKQNCELFEQLGEYKFQNALLVRYTKKVPQVSTPT" *
    "LVEVSRNLGKVGSKCCKHPEAKRMPCAEDYLSVVLNQLCVLHEKTPVSDRVTKCCTESLV" *
    "NRRPCFSALEVDETYVPKEFNAETFTFHADICTLSEKERQIKKQTALVELVKHKPKATKE" *
    "QLKAVMDDFAAFVEKCCKADDKETCFAEEGKKLVAASQAALG"

const GH_SEQ = 
    "PTIPLSRLFQNAMLRAHRLHQLAFDTYEEFEEAYIQKYSFLQAPQASLCFSESIPTPSNR" *
    "EQAQQKSNLQLLRISLLLIQSWLEPVGFLRSVFANSCVYGASDSDVYDLLKDLEEGIQTL" *
    "MGRLEDGSPRTGQAFKQTYAKFDANSHNDDALLKNYGLLYCFRKDMDKVETFLRIVQCRS" *
    "VEGSCG"

# Average masses from HSA_SEQ/GH_SEQ (ExPASy average residue masses + one
# water for the terminal H/OH), computed from the PDB-resolved sequences. 
# these are slightly smaller than the full mature-protein
# masses (HSA is missing 3 N-/C-terminal residues; growth hormone is
# missing 5 residues incl. the 37-39 loop), and the growth hormone mass
# in excludes somapacitan's non-protein modification (the
# tetrazole/linker/C18-diacid albumin-binding side chain of Figure 2d),
# since that side chain has no resolved coordinates in this rigid-body
# model. Both are therefore approximations, noted here rather than
# silently assumed exact.
const HSA_MW = 66172.88   # g/mol
const GH_MW  = 21221.05   # g/mol

# Table 2's "HSA:somapacitan" column: total protein concentration 6.3
# mg/mL at a 1:2 (HSA:somapacitan) molar ratio. Treating the dissolved
# material as "1 HSA + 2 GH per complex" with the masses above:
#
#   MW_complex = HSA_MW + 2*GH_MW ≈ 108.6 kDa  (paper's own theoretical
#     MW for this column is 113 kDa; the ~4% gap is attributable to the
#     GH_MW approximation above excluding somapacitan's small-molecule
#     modification and to the few unmodelled terminal/loop residues)
#   [complex] = 6.3 mg/mL / MW_complex ≈ 0.058 mM
#   [HSA]      = [complex]        (1 HSA per complex)
#   [GH]       = 2 * [complex]    (2 growth-hormone copies per complex)
const TOTAL_PROTEIN_CONC_MG_ML = 6.3
const _COMPLEX_MOLARITY        = TOTAL_PROTEIN_CONC_MG_ML / (HSA_MW + 2 * GH_MW)   # mol/L

const HSA_MOLARITY   = _COMPLEX_MOLARITY
const HSA_MOLARITY_σ = 0.05 * HSA_MOLARITY        # 5% relative: typical A280/mg-ml uncertainty
const GH_MOLARITY    = 2 * _COMPLEX_MOLARITY
const GH_MOLARITY_σ  = 0.05 * GH_MOLARITY

# Buffer components
# Counter-ions (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 100 mM MES titrated with NaOH -> Na⁺ = C·0.682 (pK(22 °C) = 6.296). The pH is taken as
# set at room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.208 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of
# the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.140, 0.0014, "sodium chloride"),   # 140 mM NaCl, ±1%
    NonBiological(0.100, 0.002,  "mes"),                # 100 mM MES, ±2%
    NonBiological(0.068195, 0.005764, "sodium(1+)"),   # Na⁺ counter-ion from NaOH titration of MES (see note above)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .fit file's own full q-range (≈0.008-0.5 Å⁻¹); no further truncation
# needed.
const Q_MAX_FIT = 0.5

# No GNOM pddf was bundled for this entry (pddf/ is empty), so Dmax was
# estimated directly from SASDF42_fit1_model1.pdb's coordinate file
# (exact all-atom max pairwise distance over all 7623 ATOM records, brute
# force) rather than from a P(r) inversion: Dmax ≈ 139.29 Å. This lines up
# almost exactly with the paper's GNOM-derived Dmax = 139 Å quoted for
# this entry in Table 2, which is a useful cross-check that the
# coordinate-extent estimate is reasonable here.
# Q_MAX_FIT * Dmax ≈ 0.5 * 139.29 ≈ 69.6, rounded to 70.
const LMAX = 70

const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdf42(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdf42()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDF42/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdf42_figure(result, data) -> Figure

Plots the SASDF42 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdf42_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",

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
            ax, bounds[:, 1], max.(bounds[:, 2], y_floor), max.(bounds[:, 3], y_floor);
            color = (:darkorange, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 2], y_floor);
            linestyle = :dot, color = :darkorange, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], max.(quantiles[:, 3], y_floor);
            linestyle = :dot, color = :darkorange, linewidth = 1.5,
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
        lines!(ax, map_curve[:, 1], map(v -> v > 0 ? v : NaN, map_curve[:, 2]); color = :crimson, linewidth = 2, label = "MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    # Centre the view on the actual data (I_fit), not on however far the
    # errorbar whiskers/bounds band happen to extend
    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

"""
    sasdf42_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdf42_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)")

    map_curve = map_result === nothing ? nothing : map_result[2]

    if quantile_result !== nothing && map_curve !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]
        I_map     = map_curve[:, 2]

        band!(
            ax, bounds[:, 1], bounds[:, 2] .- I_map, bounds[:, 3] .- I_map;
            color = (:darkorange, 1), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 2.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 2.5,
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

    axislegend(ax; position = :rt, framevisible = false)

    return fig
end

const _HIST_PARAMS = [
    ("ρₑ", "slvnt_e_dns"), ("δρ₁", "delta_rho_1"), ("δρ₂", "delta_rho_2"),
    ("δρ₃", "delta_rho_3"),
    ("scale", "scale"), ("bkgrnd_corr", "bkgrnd_corr"),
    ("c1", "excl_vol_corr"),
]

"""
    sasdf42_hist(result) -> Figure
"""
function sasdf42_hist(result)
    fit, _, map_result, _ = result
    ok = .!getproperty.(fit.stats, :numerical_error)
    samples = fit.samples[ok]
    c1_draws = fit.c1[ok]
    scale_draws = fit.scale[ok]
    bkgrnd_draws = fit.bkgrnd_corr[ok]
    map_params = map_result === nothing ? nothing : map_result[1]

    fig = Figure(size = (900, 550))
    for (i, (label, map_key)) in enumerate(_HIST_PARAMS)
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
        hist!(ax, draws; bins = 40, color = (:darkorange, 0.6))
        if map_params !== nothing
            vlines!(ax, [map_params[map_key]]; color = :crimson, linewidth = 2)
        end
    end

    return fig
end

"""
    sasdf42_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference model curve from the paper's
own SASDF42_fit1.fit (column 4, χ² = 1.45 per its header).
"""
function sasdf42_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data
    # Log axes: non-positive intensities (high-q noise around zero) are left out of the plot only; the fit
    # itself uses every point.
    pos = I_fit .> 0
    q_fit, I_fit, σ_fit = q_fit[pos], I_fit[pos], σ_fit[pos]

    crysol   = readdlm(_FIT_PATH; skipstart = 1)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        xscale = log10,
        yscale = log10,
    )

    # Same log-symmetric errorbar treatment as `sasdf42_figure` -- see its
    # comment for why a raw additive I ± σ interval isn't used here.
    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, q_crysol[keep], I_crysol[keep];
        color = :mediumturquoise, linewidth = 2, linestyle = :dash, label = "SASREF fit1",
    )

    if map_result !== nothing
        _, map_curve = map_result
        lines!(ax, map_curve[:, 1], map(v -> v > 0 ? v : NaN, map_curve[:, 2]); color = :crimson, linewidth = 2, label = "BAYSOL MAP")
    end

    axislegend(ax; position = :lb, framevisible = false)

    lo, hi = extrema(I_fit)
    ylims!(ax, lo * 0.7, hi * 1.3)

    return fig
end

fig = sasdf42_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res.png"), fig; px_per_unit = 3.5)

fig_residuals = sasdf42_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_residuals.png"), fig_residuals; px_per_unit = 3.5)

fig_hist = sasdf42_hist(result)
save(joinpath(@__DIR__, "res_hist.png"), fig_hist; px_per_unit = 3.5)

fig_crysol = sasdf42_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_comparison.png"), fig_crysol; px_per_unit = 3.5)
