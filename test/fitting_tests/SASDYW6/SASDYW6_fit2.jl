using   DelimitedFiles
using   Statistics
using   Random
using   GLMakie
using   BAYSOL
using   BAYSOL.MolecularStructure: LocalPathSource
using   BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDYW6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDYW6_fit2.fit")
const _CIF_PATH    = joinpath(_FIXTURE_DIR, "SASDYW6_fit2_model1.cif")
const _FIT_PATH    = _DATA_PATH   # CRYSOL .fit carries the reference fit curve itself (col 4)

# ---------------------------------------------------------------------------
#                       SASDYW6_fit2_model1.cif structure
# ---------------------------------------------------------------------------
#
# Unlike SASDYW6_fit1_model1.cif (a GASBOR dummy-bead ab initio envelope --
# see SASDYW6_fit1.jl's header comment), this file is a real atomistic
# model: an AlphaFold3 prediction (`_software.name AlphaFold`,
# `_software.version "AlphaFold-beta-20231127 ..."`, `_audit_author.name
# "Google DeepMind"/"Isomorphic Labs"`) with full backbone + side-chain
# atoms (5528 ATOM records, no dummy beads). `_entity_poly`/
# `_entity_poly_seq` records list two polypeptide entities, strand IDs A
# and B, 360 residues each, and their `mon_id` sequences are byte-identical
# -- a homodimer, consistent with SASBDB's stated "Oligomeric State: Dimer"
# for this Fba1 entry. Both chains are used here (the full predicted
# dimer), not a single monomer.

raw = readdlm(_DATA_PATH; skipstart = 1)   # 1 header line: " Dro: 0.083 Rg: 28.56 Vol: 97845. Chi^2: 3.737"

# CRYSOL .fit column layout (own inspection, same convention as
# SASDMJ9.jl's _FIT_PATH): q, Iexp, err, Ifit. SASBDB stores this already
# in Å⁻¹ (range ≈0.0079-0.250 Å⁻¹, consistent with B21/Diamond's usable
# q-range) -- no unit conversion applied.
qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# No paper PDF is bundled in the fixture directory for SASDYW6. Metadata
# fetched via WebFetch from https://www.sasbdb.org/data/SASDYW6/ (2026-09-25):
#
#   Sample:      Candida glabrata (Nakaseomyces glabratus) fructose-1,6-
#                bisphosphate aldolase (Fba1), dimer, monomer MW ~37 kDa
#   Dataset 1:   20 mM Tris-HCl, 300 mM NaCl, pH 8
#   Dataset 2:   50 mM sodium phosphate, 500 mM NaCl, 500 mM imidazole,
#                1 mM PMSF, pH 8.5
#   Beamline:    B21, Diamond Light Source (Didcot, UK)
#   Wavelength:  λ = 0.094 nm (dataset 2)
#   Temperature: 15°C (both datasets)
#   Concentration: 1 mg/ml
#   Publication: Cuéllar-Cruz M, Siliqi D, Moreno A (2026), ACS Omega,
#                "Insights into the Solution Structure and Oligomeric State
#                of Fructose-1,6-bisphosphate Aldolase and Pyruvate Kinase
#                from Nakaseomyces glabratus by SAXS and AlphaFold
#                Prediction", DOI 10.1021/acsomega.6c06099
#
# SASBDB explicitly labels "GASBOR model (fit 1)" vs "AlphaFold model
# (fit 2)" as its own two entries, and the two datasets have genuinely
# DIFFERENT buffers (Tris/NaCl pH 8 vs phosphate/NaCl/imidazole/PMSF
# pH 8.5) -- these are two separate SAXS measurements/conditions, not two
# analysis rounds of one curve. The imidazole/PMSF combination in dataset 2
# (typical of an IMAC/His-tag elution buffer, given "500 mM imidazole") is
# a strong hint this is a differently-purified or differently-handled
# sample than dataset 1's plain SEC buffer -- fit2 here uses dataset 2's
# buffer, matching the AlphaFold model's fit curve.

const PH, σ_PH = 8.5, 0.1   # paper/SASBDB: "pH 8.5"; ±0.1 typical benchtop precision

const ENERGY_EV       = 12398.42 / 0.94    # ≈ 13191 eV, from λ = 0.094 nm = 0.94 Å
const TEMPERATURE_C    = 25.0    # SASBDB states 15°C, but t/T should not be changed from the
                                   # package default (DensityOfSolvent.jl: "as of this version,
                                   # this should NOT be changed, since only water is temp
                                   # dependent") -- same resolution SASDMJ9.jl uses for its 20°C.
# I = ½Σcᵢzᵢ² over Na⁺ (NaCl + both NaPi fractions), Cl⁻, H2PO4⁻ (z=1), and
# HPO4²⁻ (z=2, enters with weight 4) -- same careful multi-species treatment
# SASDWZ9.jl uses for its own NaPi buffer, now that phosphate has real PMV
# data (previously missing at wiring time, see SOLUTES above).
# Na⁺ total = 0.500 + 0.002386 + 2·0.047610 ≈ 0.59761 M
# I = ½·[0.59761·1 + 0.500·1 + 0.002386·1 + 0.047610·4] ≈ 0.6452 M
# Imidazole (pKa≈7, mostly neutral free base at pH 8.5) and PMSF (a neutral
# organosulfonyl compound) contribute ~0 and are not separately counted.
const IONIC_STRENGTH_M = 0.6452

# Fba1 monomer sequence, read directly off SASDYW6_fit2_model1.cif's
# `_entity_poly_seq` records (entity 1, chain A, 360 residues; entity 2/
# chain B is byte-identical, confirming the homodimer). Converted from the
# file's 3-letter `mon_id` codes to 1-letter via the standard 20-residue
# table.
const FBA1_SEQ = "MGVQEVLKRKTGVIVGDDVRALFDYAKEHKFAIPAINVTSSSTVVAALEAARDAKSPIILQTSNGGAAYFAGKGVSNDGQNASIRGSIAAAHYIRSIAPAYGIPVVLHSDHCAKKLLPWYDGMLEADEAYFKEHGEPLFSSHMLDLSEETDDENIATCVKYFKRMAAMNQWLEMEIGITGGEEDGVNNEHVDKESLYTKPETVFAVHEALAPISPNFSIAAAFGNVHGVYQAGNVVLSPEILADHQKYAAEKTGAPAGSKPLYLVFHGGSGSTQEEFNTGINNGVVKVNLDTDCQYAYLTGIRDYVLNKKDYIMSMVGNPEGADKPNKKFFDPRVWVREGEKTMSKRISEALDVFHTKNT"

# Average mass from FBA1_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH): 39243.23 g/mol. SASBDB states "~37 kDa" for the
# monomer -- close but not identical, presumably a rounded/construct-
# specific figure; the sequence-derived value is used here for consistency
# with how molarity is computed everywhere else in this file family.
const FBA1_MW = 39243.23   # g/mol (monomer)
const FBA1_CONC_MG_ML = 1.0   # SASBDB: "Sample Concentration: 1 mg/ml"
# Monomer molarity used for the solution's bulk-electron-density term
# (matches SASDMJ9.jl's convention of using the monomer sequence/molarity
# even for an oligomeric species -- the dimer's electron-density
# contribution is the same either way since it's linear in C_j·Z_j; the
# structure file itself, unlike the Solute's molarity, carries the full
# dimer, both chains A and B).
const FBA1_MOLARITY   = FBA1_CONC_MG_ML / FBA1_MW    # ≈ 2.548e-5 M ≈ 25.5 µM
const FBA1_MOLARITY_σ = 0.05 * FBA1_MOLARITY         # 5% relative: typical A280/mg-ml

# Buffer components. Cross-checked against
# src/PartialMolarVolumes/NonBiological/common_to_iupac.json (case-insensitive
# grep) and the sibling nonbiological.tsv.
const SOLUTES = Solute[
    Protein(FBA1_MOLARITY, FBA1_MOLARITY_σ, FBA1_SEQ),
    NonBiological(0.500, 0.005, "sodium chloride"),   # 500 mM NaCl, ±1%
    NonBiological(0.500, 0.010, "imidazole"),          # 500 mM imidazole, ±2%
    # 50 mM sodium phosphate at pH 8.5, split via Henderson-Hasselbalch
    # (pKa2 ≈ 7.2 for H2PO4⁻/HPO4²⁻, same convention as SASDWZ9.jl's NaPi
    # buffer): ratio HPO4²⁻:H2PO4⁻ = 10^(8.5-7.2) ≈ 19.95:1, so
    # HPO4²⁻ ≈ 47.61 mM, H2PO4⁻ ≈ 2.39 mM. "sodium dihydrogen phosphate"/
    # "disodium hydrogen phosphate" now have real PMV data (previously
    # missing at wiring time; the generic "sodium phosphate" key still
    # doesn't exist, hence the split rather than one lookup).
    NonBiological(0.002386,   0.0000477, "sodium dihydrogen phosphate"), # NaPi, H2PO4⁻ fraction, ±2%
    NonBiological(0.047610,   0.0009522, "disodium hydrogen phosphate"), # NaPi, HPO4²⁻ fraction, ±2%
    # MISSING FROM PMV LOOKUP: PMSF / phenylmethylsulfonyl fluoride (1 mM) --
    # no entry under any spelling in common_to_iupac.json/nonbiological.tsv.
    # Omitted from SOLUTES; at 1 mM it is the smallest-concentration
    # component by far, so its omission has the least impact on ρₑ.
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.25   # the .fit file's own max q (0.249981 Å⁻¹); no further cut needed

# No GNOM pddf (.out) was bundled for SASDYW6 (only the .fit fit curve and
# the .cif model), so lMax is instead estimated from the AlphaFold3 dimer
# model's own coordinate extent: max pairwise distance between the 5528
# ATOM-record heavy-atom coordinates, computed via a convex-hull reduction
# (scipy.spatial.ConvexHull + brute-force max pair over the ~108 hull
# vertices -- exact, since the maximal-distance pair of any point set
# always lies on its convex hull):
#
#     Dmax ≈ 97.1 Å
#
# Using the same q·Dmax multipole-resolution rule of thumb as SASDMJ9.jl:
# Q_MAX_FIT * Dmax ≈ 0.25 * 97.1 ≈ 24.3.
const LMAX = 24

const ADD_HYDROGENS = true   # runs PDB2PQR at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `I_exp > 0`.
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && I_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

function run_sasdyw6_fit2(; n_samples::Int = 2000, n_adapt::Int = 1000, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s, μ_χ, σ_χ = BAYSOL.seed_model(
        LocalPathSource(_CIF_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        ionic_strength_M = IONIC_STRENGTH_M, T = TEMPERATURE_C + 273.15,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, μ_χ, σ_χ, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, μ_χ, σ_χ, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdyw6_fit2()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDYW6/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit2.txt"), "w") do io
    BAYSOL.write_report(io, result; μ_χ = μ_χ, σ_χ = σ_χ, form_factor_log = form_factor_log, n_atoms = n_atoms)
end

"""
    sasdyw6_fit2_figure(result, data) -> Figure

Plots the SASDYW6 fit2 (AlphaFold3 dimer model, dataset 2) fit: the
experimental data (`data = (q_fit, I_fit, σ_fit)`) with its per-point
standard errors, the MAP predicted curve, and (when not all draws
diverged) the quantile-curve envelope.
"""
function sasdyw6_fit2_figure(result, data)
    _, divergence_rate, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "q (Å⁻¹)",
        ylabel = "I(q)",
        title  = "SASDYW6 fit2 (AlphaFold3) — divergence rate = $(round(divergence_rate; digits = 3))",
        xscale = log10,
        yscale = log10,
    )

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
    sasdyw6_fit2_residuals_figure(result, data) -> Figure

Data-minus-MAP residuals against q, with the quantile-curve envelope
similarly re-centred on the MAP curve.
"""
function sasdyw6_fit2_residuals_figure(result, data)
    _, _, map_result, quantile_result = result
    q_fit, I_fit, σ_fit = data

    fig = Figure(size = (700, 400))
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)", title = "SASDYW6 fit2 residuals")

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
    sasdyw6_fit2_posterior_hist(result) -> Figure

Histograms of the non-divergent posterior draws for each physical parameter
`ξ = (dns, δρ1, δρ2, δρ3, c1)`, with the MAP draw marked.
"""
function sasdyw6_fit2_posterior_hist(result)
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
    sasdyw6_fit2_crysol_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit.
"""
function sasdyw6_fit2_crysol_comparison_figure(result, data)
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
        title  = "BAYSOL MAP vs. CRYSOL fit2 (paper)",
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
        color = :seagreen, linewidth = 2, linestyle = :dash, label = "CRYSOL fit2",
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

fig = sasdyw6_fit2_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit2.png"), fig)

fig_residuals = sasdyw6_fit2_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit2_residuals.png"), fig_residuals)

fig_hist = sasdyw6_fit2_posterior_hist(result)
save(joinpath(@__DIR__, "res_fit2_hist.png"), fig_hist)

fig_crysol = sasdyw6_fit2_crysol_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit2_crysol_comparison.png"), fig_crysol)

"Display the SASDYW6 fit2 figure. Blocks until the window is closed."
vis_sasdyw6_fit2() = wait(display(fig))
