# SPDX-License-Identifier: LGPL-2.1-or-later

# Does the MAP search's f-stop (`MAP_F_ABSTOL`, `MAP_F_SUCCESSIVE`) change what it finds? For each fitting test and
# each RNG seed, the multi-start MAP search runs twice from the same starting points: with the f-stop (the default)
# and with the gradient test alone (`f_abstol = 0`, as before). No sampling.
#
#   tclsh test/run/validate.tcl map_fstop [ID ...] --approved      # the entry point: prints its plan without --approved
#
# which runs
#
#   julia --project=test/fitting_tests test/validation/map_fstop/validate.jl [--seeds 1,2,3] [--out FILE.tsv] ID[:tag] ...
#
# (The criteria and the outcome are also in README.md in this folder.) Criteria, fixed on 2026-10-08 before the first run and judged over distributions (not per fit), as for the Shannon
# binning. Δf is −log π at the f-stop's mode minus that at the gradient-only mode, in nats (positive: the f-stop is worse),
# over every (fit, seed):
#   1. Fit quality:  median Δf ≤ 1e-3; 95th percentile of Δf ≤ 0.05; no Δf above 1 (no lost basin); the median relative change of
#      the reduced χ² at the mode within 0.1 % and its 95th percentile within 1 %.
#   2. Parameter distribution: over the fits (mean over seeds), each of ρₑ, δρ₁, δρ₂, δρ₃, c1 has its median moved by less than
#      0.05 of its interquartile range, and the number of fits with δρ₁ or δρ₂ at a prior bound or c1 saturated changes by at most 1.
#   3. Health of the regression: the number of distinct modes agrees within ±1 in at least 90 % of the (fit, seed) pairs; the
#      Hessian-based whitening is available (`whitened`) wherever it was without the f-stop; and the median ratio of objective
#      evaluations (gradient-only / f-stop) is at least 3.

using Printf, Random, Statistics
using BAYSOL
const Fit = BAYSOL.Fitting
include(joinpath(@__DIR__, "..", "..", "utils", "fit_seed.jl"))

# Mode of one MAP search run: coordinates (ρₑ, δρ₁, δρ₂, δρ₃, c1), −log π, reduced χ², evaluations, modes, starts, whitened.
function run_search(seed, rng_seed; kw...)
    Random.seed!(rng_seed)
    sp = Fit._sampling_space(seed, Fit.PROFILE(); kw...)
    f = Fit._neglogπ(sp.ẑ, sp.μ, sp.σ, seed, Fit.PROFILE(), Fit.EXCL_VOL_CORR_TOL)
    ξ = Fit.Ξ(sp.μ .+ sp.σ .* sp.ẑ, seed.pr)
    ŷ, wfit, c1 = Fit.profiled_corrs(seed.wls, ξ, seed.fw; tables = seed.c1tab, tol = 1e-8)
    return (; p = [ξ[1], ξ[2], ξ[3], ξ[4], c1], f, χ² = Fit.reduced_chi2(wfit), n_evals = sp.n_evals,
            n_modes = sp.n_modes, n_ok = sp.n_ok, whitened = sp.whitened)
end

function main(args)
    seeds = [1, 2, 3]; out = nothing; specs = String[]
    i = 1
    while i ≤ length(args)
        if args[i] == "--seeds"; seeds = parse.(Int, split(args[i+1], ",")); i += 2
        elseif args[i] == "--out"; out = args[i+1]; i += 2
        else push!(specs, args[i]); i += 1 end
    end
    isempty(specs) && error("give at least one ID[:tag]")
    io = out === nothing ? nothing : open(out, "w")
    hdr = "fit\tseed\tevals_gonly\tevals_fstop\tdf_nats\tchi2_gonly\tchi2_fstop\tmodes_gonly\tmodes_fstop\tok_gonly\tok_fstop\twhitened_gonly\twhitened_fstop\t" *
          join(("$(k)_$(v)" for v in ("gonly", "fstop") for k in ("rho", "d1", "d2", "d3", "c1")), "\t")
    println(hdr); io === nothing || println(io, hdr)
    rows = NamedTuple[]
    for spec in specs
        id, tag = occursin(':', spec) ? split(spec, ":") : (spec, "")
        seed, _, label = load_fit_seed(String(id), String(tag); makie = false)
        for s in seeds
            a = run_search(seed, s; f_abstol = 0.0, successive_f_tol = 1)      # gradient test alone
            b = run_search(seed, s)                                              # with the f-stop
            r = (; fit = label, seed = s, a, b, df = b.f - a.f)
            push!(rows, r)
            line = @sprintf("%s\t%d\t%d\t%d\t%+.6f\t%.6f\t%.6f\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s", label, s, a.n_evals, b.n_evals, r.df, a.χ², b.χ²,
                            a.n_modes, b.n_modes, a.n_ok, b.n_ok, a.whitened, b.whitened,
                            join((@sprintf("%.6g", x) for x in a.p), "\t"), join((@sprintf("%.6g", x) for x in b.p), "\t"))
            println(line); io === nothing || (println(io, line); flush(io))
        end
    end
    io === nothing || close(io)
    summarize(rows)
end

q(v, p) = (s = sort(v); s[clamp(round(Int, p * (length(s) - 1)) + 1, 1, length(s))])

function summarize(rows)
    isempty(rows) && return
    df = [r.df for r in rows]
    rel = [(r.b.χ² - r.a.χ²) / r.a.χ² for r in rows]
    ratio = [r.a.n_evals / max(r.b.n_evals, 1) for r in rows]
    c1 = median(df) ≤ 1e-3 && q(df, .95) ≤ 0.05 && maximum(df) ≤ 1 && abs(median(rel)) ≤ 1e-3 && q(abs.(rel), .95) ≤ 1e-2
    println("\n1. fit quality:      median Δf $(@sprintf("%.2e", median(df))) | p95 $(@sprintf("%.2e", q(df, .95))) | max $(@sprintf("%.3f", maximum(df))) nats | χ² rel change median $(@sprintf("%+.2e", median(rel))), p95 |.| $(@sprintf("%.2e", q(abs.(rel), .95)))   -> $(c1 ? "PASS" : "FAIL")")
    fits = unique(r.fit for r in rows)
    mean_p(variant, k) = [mean(getfield(r, variant).p[k] for r in rows if r.fit == f) for f in fits]
    names = ("ρₑ", "δρ₁", "δρ₂", "δρ₃", "c1")
    shifts = [abs(median(mean_p(:b, k)) - median(mean_p(:a, k))) / max(q(mean_p(:a, k), .75) - q(mean_p(:a, k), .25), eps()) for k in 1:5]
    atb(variant) = count(f -> (m = [mean(getfield(r, variant).p[k] for r in rows if r.fit == f) for k in 1:5]; m[2] ≥ 1.95 || m[2] ≤ -9.95 || m[3] ≥ 1.95 || m[3] ≤ -9.95 || m[5] ≥ 1.29 || m[5] ≤ 0.81), fits)
    c2 = all(<(0.05), shifts) && abs(atb(:b) - atb(:a)) ≤ 1
    println("2. parameters:       median shift / IQR: " * join(("$n $(@sprintf("%.3f", x))" for (n, x) in zip(names, shifts)), ", ") * " | fits at a bound $(atb(:a)) -> $(atb(:b))   -> $(c2 ? "PASS" : "FAIL")")
    agree = count(r -> abs(r.a.n_modes - r.b.n_modes) ≤ 1, rows) / length(rows)
    lost_w = count(r -> r.a.whitened && !r.b.whitened, rows)
    c3 = agree ≥ 0.9 && lost_w == 0 && median(ratio) ≥ 3
    println("3. regression health: modes agree (±1) in $(@sprintf("%.1f", 100agree)) % | whitening lost in $lost_w | evaluations gradient-only / f-stop: median $(@sprintf("%.1f", median(ratio)))×, min $(@sprintf("%.1f", minimum(ratio)))×   -> $(c3 ? "PASS" : "FAIL")")
    println("\nverdict: $(c1 && c2 && c3 ? "PASS" : "FAIL") over $(length(fits)) fits × $(length(rows) ÷ length(fits)) seeds")
end

main(ARGS)
