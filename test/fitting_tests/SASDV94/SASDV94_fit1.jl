using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDV94")
const _FIT_PATH     = joinpath(_FIXTURE_DIR, "SASDV94_fit1.fit")

# `SASDV94_fit1_model1.pdb`'s own ATOM records mix two kinds of chain: real
# atomistic chains (B = PLC H, D = PLC R2, both with full backbone + side
# chains) and two CA-only, single-residue-type ("GLY") dummy chains (A:
# residues 1-40; C: residues 745-772) that are plainly rigid-body-modelling
# filler beads for disordered termini, not resolved density (confirmed: they
# carry no N/C/O atoms at all, unlike every real residue in chains B/D).
# Passing those beads through to the forward model/PDB2PQR would both (a)
# corrupt the scattering calculation with un-hydrogenated placeholder mass
# that was never actually observed, and (b) likely crash pdb2pqr, which
# expects real per-residue backbone chemistry it cannot reconstruct from CA
# alone -- the same reason this repo's dummy-atom-bead-model scripts
# (fit2's, see below) were removed rather than kept running with
# add_hydrogens=false. `awk` was used to write
# `SASDV94_fit1_model1_PLCH_R2.pdb`, containing only chains B and D's ATOM
# records -- this file, not the original 4-chain PDB, is used below.
const _PDB_PATH     = joinpath(_FIXTURE_DIR, "SASDV94_fit1_model1_PLCH_R2.pdb")

# ---------------------------------------------------------------------------
#                            Experimental data
# ---------------------------------------------------------------------------
#
# `experimental_data/` and `pddf/` are both EMPTY for this fixture. SASDV94_fit1.fit's
# own header line:
#
#   CrPL4.pd  Dro:0.015  Ra:1.800  RGT:31.46  Vol:136085.  Chi^2: 1.284
#
# is a CRYSOL rigid-body-fit header (Dro/Ra/RGT/Vol are CRYSOL's own
# hydration-shell-contrast/atomic-radius/Rg/volume outputs), followed by 4
# data columns: q, I_exp, σ_exp, I_fit(CRYSOL model against
# SASDV94_fit1_model1.pdb). q is already in Å⁻¹ (max ≈0.434, consistent with
# a synchrotron SEC-SAXS q-range); no unit conversion needed.
raw = readdlm(_FIT_PATH; skipstart = 1)

qvals   = Float64.(raw[:, 1])
I_exp   = Float64.(raw[:, 2])
σ_exp   = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: pwag062.pdf ("Molecular virulence mechanism of phospholipase C from
# Pseudomonas aeruginosa", Sabharwal et al., submitted to Protein & Cell,
# test/fixtures/experiments/SASDV94/pwag062.pdf) + WebFetch of
# https://www.sasbdb.org/data/SASDV94/ (succeeded) for the quantitative
# buffer/concentration/beamline details the manuscript text itself omits
# (this is a short "Dear Editor" letter with no standalone Materials &
# Methods section in the pages provided -- `pdftotext -layout` over the
# whole 13-page PDF confirms no mg/mL, buffer recipe, wavelength, or
# temperature string appears anywhere in the manuscript body; the only SAXS
# specifics in the text itself are the beamline name/facility, in the
# Footnotes section: "The synchrotron SAXS data was collected at the
# beamline P12, operated by EMBL Hamburg at the PETRA III storage ring
# (DESY, Hamburg, Germany)"). The paper's own SAXS-relevant text (Results,
# 2nd paragraph): "monomeric PLC N in solution and 1:1 stoichiometry of PLC
# H/R2 complex ... confirmed by size-exclusion chromatography coupled with
# small-angle X-ray scattering (SEC-SAXS) and on-line multi angle light
# scattering (MALS) (Fig. 1A, Fig. S7 and Table S1)." -- i.e. the ONLY SAXS
# sample in this paper is the PLC H/R2 complex; SASBDB accession SASDV94 is
# stated explicitly in Footnotes ("Small Angle Scattering ... available at
# the Small Angle Scattering Biological Data Bank with accession code
# SASDV94"), confirming this is that single PLC H/R2 SEC-SAXS entry.
#
# SASBDB metadata (WebFetch of sasbdb.org/data/SASDV94/):
#   Sample: Phospholipase C (PLC H) bound to chaperone PLC R2 complex
#   Buffer: 25 mM Tris pH 7.5, 100 mM NaCl, 3 mM β-mercaptoethanol
#   Temperature: 20°C
#   Concentrations: three sequential SEC-SAXS injections (3.5, 7, 14 mg/mL),
#     merged to mitigate radiation damage at the higher concentrations
#   Beamline: EMBL P12, PETRA III (DESY, Hamburg); λ = 0.12398 nm
#   Column: Cytiva Superdex 200 Increase 10/300, 0.7 mL/min
#
# NOTE: fit1 and fit2 (SASDV94_fit2.fir) are, on inspection, the SAME
# experimental curve -- not two different measurements. Directly comparing
# I_exp at matching q between SASDV94_fit1.fit and SASDV94_fit2.fir (e.g.
# q≈0.05: 0.037785 both files; q≈0.10: 0.0043852 both; q≈0.20: 0.00020545
# both) shows bit-for-bit identical experimental intensities wherever the
# two files' q-grids coincide. fit1 (.fit, CRYSOL format) is this one
# merged SEC-SAXS curve fit against a rigid-body/atomistic model (this
# script); fit2 (.fir, GNOM format, narrower q-range 0.015-0.300 Å⁻¹) is the
# SAME curve fit against two ab initio DAMMIF/DAMAVER dummy-atom bead
# reconstructions -- confirmed independently by SASDV94_fit2_model1.pdb's
# own REMARK 265 block, which names "SASDV94_fit1_model1.pdb" as the
# template structure that its ab initio bead model was superimposed onto
# ("Project description: refinement of PLC PlcR complex"). fit2's two
# dummy-bead-model scripts were wired up and then removed from this repo
# (no real per-residue chemistry for pdb2pqr/PROPKA/excluded-volume to act
# on -- see this file's _PDB_PATH comment above for the same reasoning
# applied to fit1's own placeholder chains A/C); this script is SASDV94's
# sole remaining fitting test.

const PH, σ_PH = 7.5, 0.1   # buffer pH stated directly by SASBDB metadata

const ENERGY_EV        = 12398.42 / 1.2398  # = 10000.0 eV, from λ=0.12398 nm (P12's standard 10 keV setting)
const TEMPERATURE_C    = 25.0               # 20°C stated by SASBDB, but this version only supports 25°C
const IONIC_STRENGTH_M = 0.100              # 100 mM NaCl; Tris (near-neutral free base at pH 7.5) and
                                            # 2-mercaptoethanol (neutral thiol-alcohol) are treated as
                                            # ionic-strength-inert, same convention as SASDMJ9/SASDZC6's
                                            # own Tris/DTT/BME-type buffer components.

# ---------------------------------------------------------------------------
#                    Sequences and complex stoichiometry
# ---------------------------------------------------------------------------
#
# Sequences read directly off SASDV94_fit1_model1_PLCH_R2.pdb's own ATOM
# records (resolved-residue range only, matching the "692 of the protein's
# 730 residues" cryo-EM-refined PLC H model and the disordered-N-terminus
# PLC R2 chaperone described in the paper -- Results, "Cryo-electron
# microscopy analysis" paragraph):
#
#   chain B: PLC H,  residues 27-730 (704 resolved residues)
#   chain D: PLC R2, residues 65-207 (143 resolved residues, the 19 kDa
#            cognate chaperone's disordered N-terminus is not resolved here)
#
# Paper text: "1:1 stoichiometry of PLC H/R2 complex" (Results, 2nd
# paragraph) -- both proteins therefore share one common complex molarity
# below.

const PLC_H_SEQ  = "GLFPETLRRALAIEPDIRTGTIQDVQHVVILMQENRSFDHYFGHLNGVRGFNDPRALKRQDGKPVWYQNYKYEFSPYHWDTKVTSAQWVSSQNHEWSAFHAIWNQGRNDKWMAVQYPEAMGYFKRGDIPYYYALADAFTLCEAYHQSMMGPTNPNRLYHMSGRAAPSGDGKDVHIGNDMGDGTIGASGTVDWTTYPERLSAAGVDWRVYQEGGYRSSSLWYLYVDAYWKYRLQEQNNYDCNALAWFRNFKNAPRDSDLWQRAMLARGVDQLRKDVQENTLPQVSWIVAPYCYCEHPWWGPSFGEYYVTRVLDALTSNPEVWARTVFILNYDEGDGFYDHASAPVPPWKDGVGLSTVSTAGEIEASSGLPIGLGHRVPLIAISPWSKGGKVSAEVFDHTSVLRFLERRFGVVEENISPWRRAVCGDLTSLFDFQDAGDTQVAPDLTNVPQSDARKEDAYWQQFYRPSPKYWSYEPKSLPGQEKGQRPTLAVPYQLHATLALDIAAGKLRLTLGNDGMSLPGNPQGHSAAVFQVQPREVGNPRFYTVTSYPVVQESGEELGRTLNDELDDLLDANGRYAFEVHGPNGFFREFHGNLHLAAQMARPEVSVTYQRNGNLQLNIRNLGRLPCSVTVTPNPAYTQEGSRRYELEPNQAISEVWLLRSSQGWYDLSVTASNTEANYLRRLAGHVETGKPSRSDPLLDIAAT"
const PLC_R2_SEQ = "NLEQQLGEFGRNAGQMSEIERKQAAEGLIEQLKREVAVGADPRQTFEEIQRLTPYVEADARRREALDFEIWMALKDNASVQQQAPTPGEEEQLREYAQESDKVIAEVLASVDGEEQRHAAIDERLKALRKQIFGEENPRLLQR"

# Average masses from each *_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH), same convention as SASDMJ9/SASDZC6.
const PLC_H_MW  = 79_695.78   # g/mol
const PLC_R2_MW = 16_387.22   # g/mol
const COMPLEX_MW = PLC_H_MW + PLC_R2_MW   # ≈ 96_083 g/mol

# SASBDB's three merged injections (3.5, 7, 14 mg/mL) were pooled into one
# curve specifically to remove concentration-dependent (interparticle)
# effects, so no single "the" concentration applies to the deposited/merged
# profile; the series mean is used as the representative concentration, with
# a widened relative uncertainty (20%, vs. the usual 5% A280-style estimate)
# to reflect that ~4x concentration-series spread.
const COMPLEX_CONC_MG_ML = (3.5 + 7.0 + 14.0) / 3   # ≈ 8.17 mg/mL
const COMPLEX_MOLARITY   = COMPLEX_CONC_MG_ML / COMPLEX_MW   # ≈ 8.50e-5 M
const COMPLEX_MOLARITY_σ = 0.20 * COMPLEX_MOLARITY           # 20% relative

# Buffer components. "sodium chloride", "tris", and "2-mercaptoethanol" (the
# IUPAC-lookup key for β-mercaptoethanol/BME) are all present verbatim in
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json -- no missing
# lookups for this fixture.
const SOLUTES = Solute[
    Protein(COMPLEX_MOLARITY, COMPLEX_MOLARITY_σ, PLC_H_SEQ),
    Protein(COMPLEX_MOLARITY, COMPLEX_MOLARITY_σ, PLC_R2_SEQ),
    NonBiological(0.100, 0.001,   "sodium chloride"),      # 100 mM NaCl, ±1%
    NonBiological(0.025, 0.0005,  "tris"),                 # 25 mM Tris pH 7.5, ±2%
    NonBiological(0.003, 0.00006, "2-mercaptoethanol"),    # 3 mM β-mercaptoethanol, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.434   # SASDV94_fit1.fit's own q_max (≈0.434015 Å⁻¹); no truncation needed

# No GNOM pddf was bundled for this fixture (pddf/ is empty). lMax is
# instead sized off Dmax estimated directly from the PDB coordinates: the
# maximum pairwise Cα-Cα distance over SASDV94_fit1_model1_PLCH_R2.pdb's 847
# resolved Cα atoms (chains B+D only, dummy bead chains excluded -- see the
# _PDB_PATH comment above; including the dummy chains inflates this to
# ≈115 Å, an artifact of their placement, not the real particle), computed
# via a convex hull to keep the pairwise search tractable, is ≈88.82 Å.
# Same q·Dmax rule of thumb as SASDMJ9/SASDZC6: Q_MAX_FIT * Dmax ≈
# 0.434 * 88.82 ≈ 38.55, rounded up.
const LMAX = 39

const ADD_HYDROGENS = true   # real atomistic structure (chains B/D only); runs PDB2PQR at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdv94_fit1(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
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

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdv94_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDV94/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit1.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdv94_fit1_figure(result, data) -> Figure

Plots the SASDV94 fit1 fit: the experimental data (`data = (q_fit, I_fit, σ_fit)`)
with its per-point standard errors, the MAP predicted curve, and (when not
all draws diverged) the quantile-curve envelope.
"""
function sasdv94_fit1_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "SASDV94 fit1 (PLC H/R2, rigid body); divergence rate = $(round(divergence_rate; digits = 3))",
        xscale = log10,
        yscale = log10,
    )

    # Floor for the quantile/bounds curve's lower edge on this log10 y-axis
    # (see SASDMJ9_figure's comment for the rationale).
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

    # Log-symmetric errorbars via the delta method (see SASDMJ9_figure's
    # comment for why a raw additive I ± σ interval is not used here).
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
    sasdv94_fit1_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
(`"bounds"`/`"quantiles"`) similarly re-centred on the MAP curve.
"""
function sasdv94_fit1_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)", title = "SASDV94 fit1 residuals")

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
    sasdv94_fit1_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdv94_fit1_posterior_hist(result)
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
    sasdv94_fit1_crysol_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit1 curve (column 4 of
SASDV94_fit1.fit).
"""
function sasdv94_fit1_crysol_comparison_figure(result, data)
    _, _, map_result, _ = result
    q_fit, I_fit, σ_fit = data

    crysol   = readdlm(_FIT_PATH; skipstart = 1)
    q_crysol = Float64.(crysol[:, 1])
    I_crysol = Float64.(crysol[:, 4])
    keep   = (q_crysol .> 0) .& (q_crysol .≤ Q_MAX_FIT) .& (I_crysol .> 0)

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

fig_fit1 = sasdv94_fit1_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1.png"), fig_fit1)

fig_fit1_residuals = sasdv94_fit1_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_residuals.png"), fig_fit1_residuals)

fig_fit1_hist = sasdv94_fit1_posterior_hist(result)
save(joinpath(@__DIR__, "res_fit1_hist.png"), fig_fit1_hist)

fig_fit1_crysol = sasdv94_fit1_crysol_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit1_crysol_comparison.png"), fig_fit1_crysol)

"Display the SASDV94 fit1 figure. Blocks until the window is closed."
vis_sasdv94_fit1() = wait(display(fig_fit1))
