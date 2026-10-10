# SPDX-License-Identifier: LGPL-2.1-or-later

# Do the eight NUTS chains (two at the MAP and three mirrored pairs) converge to one posterior, is a better basin the MAP search missed found, and does
# pooling change what the single chain started at the MAP gives? For each fitting test and each RNG seed, `infer` runs with the
# defaults (8 chains) and with `n_chains = 1`, and the pooled post-warm-up draws are compared with the single chain's.
#
#   tclsh test/run/validate.tcl chains [ID ...] --approved      # the entry point: prints its plan without --approved
#
# which runs
#
#   julia --project=test/fitting_tests test/validation/chains/validate.jl [--seeds 1,2] [--out FILE.tsv] ID[:tag] ...
#
# Criteria (fixed 2026-10-10 before the first run of this version, also in README.md in this folder), over distributions:
#   1. Convergence, within each posterior mode: >= 95 % of the (fit, seed) runs have rank-normalized split R-hat <= 1.01 for every parameter and log pi, none above
#      1.05, median smallest bulk ESS >= 800 and median smallest tail ESS >= 400.
#   2. Starts and basins: >= 95 % of the (run, chain) pairs pooled; >= 90 % of the starts keep their nominal scale; no run ends with a
#      chain better than its MAP by more than BASIN_RESTART_NATS (rewhitenings are counted and listed).
#   3. Agreement with the single chain, over the runs with one posterior mode: over the fits (mean over seeds) each of rho_e, d1, d2, d3,
#      c1 has its median moved by < 0.05 IQR; the reduced chi^2 of the best draw changes by <= 0.1 % (median) and <= 1 % (95th
#      percentile). Runs with several modes are listed with their bridge-sampled shares, not judged here.
#   4. Cost (reported only): leapfrog steps and seconds of the pool over the single chain's.

using Printf, Random, Statistics
using BAYSOL
const Fit = BAYSOL.Inference
include(joinpath(@__DIR__, "..", "..", "utils", "fit_seed.jl"))

const N_SAMPLES, N_ADAPT = BAYSOL.Pipeline.DEFAULT_N_SAMPLES, BAYSOL.Pipeline.DEFAULT_N_ADAPT

# Median of each of (ρₑ, δρ₁, δρ₂, δρ₃, c1) over the draws `idx` of `r`.
function medians(r, idx)
    isempty(idx) && return fill(NaN, 5)
    [[median(getindex.(r.samples[idx], k)) for k in 1:4]; median(r.c1[idx])]
end

# Post-warm-up mean of f(draw index) in each chain of the pool, "c1:v1,c2:v2,..." (for reading which chain sits where).
function chain_means(r, f)
    join((@sprintf("%d:%.4g", c, (idx = findall(j -> r.chain[j] == c && r.iteration[j] > N_ADAPT, eachindex(r.chain));
                                  isempty(idx) ? NaN : mean(f(i) for i in idx)))      # a negligible mode keeps no draws
          for c in unique(r.chain)), ",")
end

# χ² of the best (highest log density, non-divergent) draw among `idx`.
function best_chi2(r, idx)
    ok = [i for i in idx if !r.stats[i].numerical_error]
    isempty(ok) && return NaN
    r.chisq_red[ok[argmax([r.stats[i].log_density for i in ok])]]
end

function main(args)
    seeds = [1, 2]; out = nothing; specs = String[]
    i = 1
    while i ≤ length(args)
        if args[i] == "--seeds"; seeds = parse.(Int, split(args[i+1], ",")); i += 2
        elseif args[i] == "--out"; out = args[i+1]; i += 2
        else push!(specs, args[i]); i += 1 end
    end
    isempty(specs) && error("give at least one ID[:tag]")
    io = out === nothing ? nothing : open(out, "w")
    hdr = "fit\tseed\tpooled\tmodes\tshares\trewhitened\trhat_max\tess_min\tess_tail_min\tdiv\tchi2_one\tchi2_pool\tgap_nats\t" *
          join(("$(w)_$(k)" for w in ("rhat", "ess", "esst") for k in ("rho", "d1", "d2", "d3", "lp")), "\t") * "\t" *
          join(("$(k)_$(v)" for v in ("one", "pool") for k in ("rho", "d1", "d2", "d3", "c1")), "\t") *
          "\tsteps_ratio\tsec_one\tsec_pool\tscales\tchain_logpi\tchain_d1\tchain_d2\tchain_d3\treasons"
    println(hdr); io === nothing || println(io, hdr)
    rows = NamedTuple[]
    for spec in specs
        id, tag = occursin(':', spec) ? split(spec, ":") : (spec, "")
        seed, _, label = load_fit_seed(String(id), String(tag); makie = false)
        for s in seeds
            t_one = @elapsed one = Fit.infer(seed, N_SAMPLES, N_ADAPT; rng_seed = s, n_chains = 1)
            t_all = @elapsed r = Fit.infer(seed, N_SAMPLES, N_ADAPT; rng_seed = s)
            d = r.diagnostics
            post = findall(>(N_ADAPT), r.iteration)
            post1 = findall(>(N_ADAPT), one.iteration)
            lf(x, idx) = sum((x.stats[i].n_steps for i in idx); init = 0)
            # mean log π of the pool over that of the single chain: positive = the single chain sits in a worse basin
            gap = mean(r.stats[i].log_density for i in post) - mean(one.stats[i].log_density for i in post1)
            row = (; fit = label, seed = s, d, p1 = medians(one, post1), pp = medians(r, post), gap,
                   c_one = best_chi2(one, post1), c_pool = best_chi2(r, post), cost = lf(r, post) / max(lf(one, post1), 1))
            push!(rows, row)
            line = @sprintf("%s\t%d\t%d\t%d\t%s\t%.1f\t%.4f\t%.0f\t%.0f\t%.4f\t%.6g\t%.6g\t%.2f\t%s\t%s\t%s\t%.2f\t%.1f\t%.1f\t%s\t%s\t%s\t%s\t%s\t%s",
                            label, s, count(d.pooled), length(d.mode_weight),
                            join((@sprintf("%.3f±%.2f", w, e) for (w, e) in zip(d.mode_weight, d.mode_err)), ","), d.rewhitened, maximum(filter(!isnan, d.rhat); init = -Inf),
                            minimum(filter(!isnan, d.ess); init = Inf), minimum(filter(!isnan, d.ess_tail); init = Inf),
                            count(i -> r.stats[i].numerical_error, post) / length(post), row.c_one, row.c_pool, gap,
                            join((@sprintf("%.4g", x) for v in (d.rhat, d.ess, d.ess_tail) for x in v), "\t"),
                            join((@sprintf("%.6g", x) for x in row.p1), "\t"), join((@sprintf("%.6g", x) for x in row.pp), "\t"),
                            row.cost, t_one, t_all, join((@sprintf("%.3g", x) for x in d.start_scale), ","),
                            chain_means(r, i -> r.stats[i].log_density), chain_means(r, i -> r.samples[i][2]),
                            chain_means(r, i -> r.samples[i][3]), chain_means(r, i -> r.samples[i][4]),
                            join(filter(!=("ok"), d.reason), "; "))
            println(line); io === nothing || (println(io, line); flush(io))
        end
    end
    io === nothing || close(io)
    summarize(rows)
end

q(v, p) = (s = sort(v); s[clamp(round(Int, p * (length(s) - 1)) + 1, 1, length(s))])

function summarize(rows)
    isempty(rows) && return
    rhat = [maximum(filter(!isnan, r.d.rhat); init = -Inf) for r in rows]
    ess  = [minimum(filter(!isnan, r.d.ess); init = Inf) for r in rows]
    esst = [minimum(filter(!isnan, r.d.ess_tail); init = Inf) for r in rows]
    c1 = count(≤(1.01), rhat) / length(rows) ≥ 0.95 && maximum(rhat) ≤ 1.05 && median(ess) ≥ 800 && median(esst) ≥ 400
    println("\n1. convergence:      R̂ ≤ 1.01 in $(@sprintf("%.1f", 100count(≤(1.01), rhat) / length(rows))) % | max R̂ $(@sprintf("%.3f", maximum(rhat))) | median min bulk ESS $(@sprintf("%.0f", median(ess))) | median min tail ESS $(@sprintf("%.0f", median(esst)))   -> $(c1 ? "PASS" : "FAIL")")
    nominal(r) = count(k -> r.d.start_scale[k] == Fit.chain_radius(k, r.d.n_chains), 1:r.d.n_chains)
    pooled_share = sum(count(r.d.pooled) for r in rows) / sum(r.d.n_chains for r in rows)
    kept_share = sum(nominal(r) for r in rows) / sum(r.d.n_chains for r in rows)
    rew = [r for r in rows if r.d.rewhitened > 0]
    c2 = pooled_share ≥ 0.95 && kept_share ≥ 0.90
    println("2. starts, basins:   chains pooled $(@sprintf("%.1f", 100pooled_share)) % | nominal scale kept $(@sprintf("%.1f", 100kept_share)) % | rewhitened in $(length(rew)) of $(length(rows)) runs" *
            join((" [$(r.fit) seed $(r.seed): +$(@sprintf("%.1f", r.d.rewhitened)) nats]" for r in rew), "")   * "   -> $(c2 ? "PASS" : "FAIL")")
    multi = [r for r in rows if length(r.d.mode_weight) > 1]
    use = filter(r -> all(isfinite, r.p1) && length(r.d.mode_weight) == 1, rows)
    fits = unique(r.fit for r in use)
    mean_p(which, k) = [mean(getfield(r, which)[k] for r in use if r.fit == f) for f in fits]
    names = ("ρₑ", "δρ₁", "δρ₂", "δρ₃", "c1")
    shifts = [abs(median(mean_p(:pp, k)) - median(mean_p(:p1, k))) / max(q(mean_p(:p1, k), .75) - q(mean_p(:p1, k), .25), eps()) for k in 1:5]
    rel = [(r.c_pool - r.c_one) / r.c_one for r in use if isfinite(r.c_pool) && isfinite(r.c_one)]
    c3 = all(<(0.05), shifts) && abs(median(rel)) ≤ 1e-3 && q(abs.(rel), .95) ≤ 1e-2
    println("3. agreement:        median shift / IQR: " * join(("$n $(@sprintf("%.3f", x))" for (n, x) in zip(names, shifts)), ", ") *
            " | best-draw χ² change median $(@sprintf("%+.2e", median(rel))), p95 |.| $(@sprintf("%.2e", q(abs.(rel), .95)))   -> $(c3 ? "PASS" : "FAIL")" *
            "\n                     runs with more than one posterior mode (not judged here; the pool carries the bridge-sampled shares): $(length(multi))" *
            join((" [$(r.fit) seed $(r.seed): " * join((@sprintf("%.2f", w) for w in r.d.mode_weight), "/") * "]" for r in multi), ""))
    cost = [r.cost for r in rows]
    println("4. cost (reported):  leapfrog steps of the pool over the single chain: median $(@sprintf("%.2f", median(cost)))×, max $(@sprintf("%.2f", maximum(cost)))×")
    println("\nverdict: $(c1 && c2 && c3 ? "PASS" : "FAIL") over $(length(unique(r.fit for r in rows))) fits × $(length(rows) ÷ length(unique(r.fit for r in rows))) seeds")
end

main(ARGS)
