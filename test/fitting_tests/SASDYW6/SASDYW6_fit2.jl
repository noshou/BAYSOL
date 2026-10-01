using DelimitedFiles
using Statistics
using Random
using GLMakie
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE

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
# and B, 360 residues each, and their `mon_id` sequences are byte-identical.

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
#   Buffer (structured field, REST API 2026-10-01): "20 mM Tris-HCl pH, 300 mM NaCl", pH 8.0,
#                λ = 0.09464 nm -- identical to the sibling Pyruvate Kinase entry SASDYV6,
#                so most likely copied from it.
#   Buffer (this entry's own free-text description): 50 mM sodium phosphate,
#                500 mM NaCl, 500 mM imidazole, 1 mM PMSF, pH 8.5, λ = 0.094 nm
#   (These are one entry's conflicting fields, not two datasets. The free text is
#   used: it is specific to Fba1 and to this SEC-SAXS run.)
#   Beamline:    B21, Diamond Light Source (Didcot, UK)
#   Temperature: 15°C (both datasets)
#   Concentration: 1 mg/ml
#   Publication: Cuéllar-Cruz M, Siliqi D, Moreno A (2026), ACS Omega,
#                "Insights into the Solution Structure and Oligomeric State
#                of Fructose-1,6-bisphosphate Aldolase and Pyruvate Kinase
#                from Nakaseomyces glabratus by SAXS and AlphaFold
#                Prediction", DOI 10.1021/acsomega.6c06099
const PH, σ_PH = 8.5, 0.1   # paper/SASBDB: "pH 8.5"; ±0.1 typical benchtop precision

const ENERGY_EV       = 12398.42 / 0.94    # ≈ 13191 eV, from λ = 0.094 nm = 0.94 Å
const TEMPERATURE_C    = 15.0    # 15°C, SASBDB (both datasets)
# I = ½Σcᵢzᵢ² over Na⁺ (NaCl + both NaPi fractions), Cl⁻, H2PO4⁻ (z=1), and
# HPO4²⁻ (z=2, enters with weight 4) -- same careful multi-species treatment
# SASDWZ9.jl uses for its own NaPi buffer, now that phosphate has real PMV
# data (previously missing at wiring time, see SOLUTES above).
# Na⁺ total = 0.500 + 0.002386 + 2·0.047610 ≈ 0.59761 M
# I = ½·[0.59761·1 + 0.500·1 + 0.002386·1 + 0.047610·4] ≈ 0.6452 M
# Imidazole (pKa≈7, mostly neutral free base at pH 8.5) and PMSF (a neutral
# organosulfonyl compound) contribute ~0 and are not separately counted.
const IONIC_STRENGTH_M = 0.6452   # unused by the fit; from the old pKa2 = 7.2 split

# Fba1 monomer sequence, read directly off SASDYW6_fit2_model1.cif's
# `_entity_poly_seq` records (entity 1, chain A, 360 residues; entity 2/
# chain B is byte-identical, confirming the homodimer). Converted from the
# file's 3-letter `mon_id` codes to 1-letter via the standard 20-residue table.
const FBA1_SEQ = 
    "MGVQEVLKRKTGVIVGDDVRALFDYAKEHKFAIPAINVTSSSTVVAALEAARDAKSPIIL" *
    "QTSNGGAAYFAGKGVSNDGQNASIRGSIAAAHYIRSIAPAYGIPVVLHSDHCAKKLLPWY" *
    "DGMLEADEAYFKEHGEPLFSSHMLDLSEETDDENIATCVKYFKRMAAMNQWLEMEIGITG" *
    "GEEDGVNNEHVDKESLYTKPETVFAVHEALAPISPNFSIAAAFGNVHGVYQAGNVVLSPE" *
    "ILADHQKYAAEKTGAPAGSKPLYLVFHGGSGSTQEEFNTGINNGVVKVNLDTDCQYAYLT" *
    "GIRDYVLNKKDYIMSMVGNPEGADKPNKKFFDPRVWVREGEKTMSKRISEALDVFHTKNT"

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
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see Fitting.Solute).
    NonBiological(0.500, 0.005, "sodium chloride"),   # 500 mM NaCl, ±1%
    NonBiological(0.500, 0.010, "imidazole"),          # 500 mM imidazole, ±2%
    # Cl⁻ counter-ion (added 2026-10-01): imidazole taken as titrated with HCl at 22 °C; protonated
    # fraction 0.046 with pK from Goldberg, Kishore & Lennen 2002 (DOI 10.1063/1.1416902; 6.993, ΔH 36.64
    # kJ/mol), Davies-corrected at I ≈ 0.671 M. The titrant is not stated.
    NonBiological(0.023086, 0.006466, "chloride"),   # Cl⁻ from HCl titration of imidazole
    # 50 mM sodium phosphate at pH 8.5 is split into NaH2PO4/Na2HPO4 (no single "sodium phosphate" PMV key). The
    # HPO4²⁻ fraction is 0.979: pK2 from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
    # 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C (pH set at room temperature),
    # Davies-corrected at I ≈ 0.671 M, giving an effective pK2' ≈ 6.82. This replaces the earlier flat pKa2 =
    # 7.2, which ignored ionic strength. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on
    # C.
    NonBiological(0.001032, 0.000357, "sodium dihydrogen phosphate"),   # 50 mM NaPi, H2PO4⁻ part
    NonBiological(0.048968, 0.001042, "disodium hydrogen phosphate"),   # 50 mM NaPi, HPO4²⁻ part
    # PMSF / phenylmethylsulfonyl fluoride (1 mM): no measured aqueous V0
    # exists (it hydrolyzes in water); the table entry
    # ("phenylmethanesulfonyl fluoride", resolves from "pmsf") is our own
    # estimate, 127.2 ± 5.0 cm³/mol (basis=predicted; see
    # PartialMolarVolumes/README.md, "Adding a missing solute"). It is the
    # smallest-concentration component by far, so its ρₑ impact is minimal.
    NonBiological(0.001, 0.00005, "pmsf"),  # 1 mM PMSF, ±5% (unstable stock)
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

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

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
    s = BAYSOL.seed_model(
        LocalPathSource(_CIF_PATH), LMAX, ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    res = BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())
    return res, s.fw.form_factor_log, s.fw.n_atoms, (q_fit, I_fit, σ_fit)
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdyw6_fit2()

fit, divergence_rate, map_result, quantile_result = result

# `@__DIR__` (this SASDYW6/ folder), not the caller's cwd.
open(joinpath(@__DIR__, "res_fit2.txt"), "w") do io
    BAYSOL.write_report(io, result; form_factor_log = form_factor_log, n_atoms = n_atoms)
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
    ax = Axis(fig[1, 1], xlabel = "q (Å⁻¹)", ylabel = "I(q) - I_MAP(q)")

    map_curve = map_result === nothing ? nothing : map_result[2]

    if quantile_result !== nothing && map_curve !== nothing
        _, curves = quantile_result
        bounds    = curves["bounds"]
        quantiles = curves["quantiles"]
        I_map     = map_curve[:, 2]

        band!(
            ax, bounds[:, 1], bounds[:, 2] .- I_map, bounds[:, 3] .- I_map;
            color = (:darkorange, 0.15), label = "bounds",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 2] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 1.5, label = "quantiles",
        )
        lines!(
            ax, quantiles[:, 1], quantiles[:, 3] .- I_map;
            linestyle = :dot, color = :darkorange, linewidth = 1.5,
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
    sasdyw6_fit2_hist(result) -> Figure


"""
function sasdyw6_fit2_hist(result)
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
    sasdyw6_fit2_comparison_figure(result, data) -> Figure

Overlays our MAP curve against the reference CRYSOL fit.
"""
function sasdyw6_fit2_comparison_figure(result, data)
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

    log_I = log10.(I_fit)
    log_σ = σ_fit ./ (I_fit .* log(10))
    rangebars!(
        ax, q_fit, exp10.(log_I .- log_σ), exp10.(log_I .+ log_σ);
        whiskerwidth = 4, color = (:gray40, 0.6),
    )
    scatter!(ax, q_fit, I_fit; markersize = 4, color = :gray20, label = "data")

    lines!(
        ax, q_crysol[keep], I_crysol[keep];
        color = :mediumturquoise, linewidth = 2, linestyle = :dash, label = "CRYSOL fit2",
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

fig = sasdyw6_fit2_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit2.png"), fig; px_per_unit = 3.5)

fig_residuals = sasdyw6_fit2_residuals_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit2_residuals.png"), fig_residuals; px_per_unit = 3.5)

fig_hist = sasdyw6_fit2_hist(result)
save(joinpath(@__DIR__, "res_fit2_hist.png"), fig_hist; px_per_unit = 3.5)

fig_crysol = sasdyw6_fit2_comparison_figure(result, (q_fit, I_fit, σ_fit))
save(joinpath(@__DIR__, "res_fit2_comparison.png"), fig_crysol; px_per_unit = 3.5)

"Display the SASDYW6 fit2 figure. Blocks until the window is closed."
vis_sasdyw6_fit2() = wait(display(fig))
