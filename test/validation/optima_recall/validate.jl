# SPDX-License-Identifier: LGPL-3.0-or-later

# Does the MAP search find every optimum of the posterior that carries probability
# mass, and which general rule finds the ones it misses, at what cost?
#
#   bb validate optima_recall [ID ...] --approved
#       (the entry point: prints its plan without --approved)
#
# which runs
#
#   julia --project=test/fitting_tests test/validation/optima_recall/validate.jl \
#       [--seeds 1,2] [--out FILE.tsv] ID[:tag] ...
#
# The question, the criteria (fixed on 2026-10-10 before the first run), how to read
# the two TSV files and the outcome are in README.md in this folder. This header says
# what the script does, step by step, so that the numbers can be checked against it.
#
# ---------------------------------------------------------------------------------
# Vocabulary
# ---------------------------------------------------------------------------------
# Everything lives in z-space: the prior-standardized coordinates in which the MAP
# search runs L-BFGS on f(z) = -log π(θ(z)) (c1 profiled, `Inference._neglogπ`).
#   * an OPTIMUM is a local minimum of f that L-BFGS converges to;
#   * its BASIN is the set of starts that end there; HIT RATE p is the share of
#     random starts (prior draws) that end there;
#   * two optima are THE SAME when their Mahalanobis distance is at most
#     `MAP_MODE_SEP`, under the Hessian of f at the best optimum (eigenvalues floored
#     at 1, as the MAP search does): the rule the production search uses;
#   * the LAPLACE MASS of an optimum is exp(-f)·(2π)^{d/2}·det(H)^{-1/2} (log
#     form: -f - ½ Σ log λ); its SHARE is its mass over the total of the reference
#     set. An optimum whose Hessian is not positive definite (usually: on a prior
#     bound) has no Laplace mass; it is counted and listed, not judged.
#
# ---------------------------------------------------------------------------------
# 1. The reference set (the "oracle")
# ---------------------------------------------------------------------------------
# It is not the truth, only the most that this script can find. It is the union of
#   * ORACLE_STARTS = 500 L-BFGS runs from prior draws (the production kind of start,
#     15 times as many);
#   * every optimum any of the rules below finds, for every seed;
#   * L-BFGS runs from the draws of one LONG run of the real sampler (1000 warm-up +
#     3000 draws per chain, 8 chains): the farthest-point cover of its draws and its
#     divergent draws (see 2.F). This is what reaches optima that random starts hit
#     with probability close to 0 but that the chains visit.
# The union is clustered with the rule above. Each cluster is one reference optimum:
# its best point, its Hessian, its Laplace log-mass and share. A reference optimum is
# MASSIVE when its share is at least MASSIVE_SHARE = 1 %.
#
# ---------------------------------------------------------------------------------
# 2. The rules under test (arms)
# ---------------------------------------------------------------------------------
# Each is one general way of choosing L-BFGS starts. Not one of them knows anything
# about a particular fit. All rules but F also start from the fit's own θ₀, as the
# production search does.
#   P32   the production search, replayed: 32 starts (θ₀ and 31 prior draws).
#   A64   64 starts: P32 plus 32 more prior draws. A128: 128 starts. Plain multistart;
#         a basin of hit rate p is missed by K starts with probability (1-p)^K.
#   S32   sample, screen, descend (the idea of Multi-Level Single Linkage, Rinnooy Kan
#         & Timmer 1987): evaluate f at SCREEN_POINTS = 3000 prior draws (value only,
#         cheap), keep the points that are the lowest among their SCREEN_K = 15 nearest
#         neighbours (the local minima of the sampled landscape: one candidate per
#         basin instead of one per draw) and run L-BFGS from the 32 best of them.
#   J     P32 plus JITTER: for each of the (at most 4) optima P32 found within 15 nats
#         of the best, L-BFGS from 3 radii (3, 6, 12 posterior sd) × 2 random directions,
#         in the optimum's own Hessian metric (basin hopping / mode-neighbourhood
#         starts; the same idea as the sampler's jittered chain starts).
#   H     P32 plus HARVEST: after the production sampling round (1000 iterations, 8
#         chains, 300 warm-up, the `run_model` default), L-BFGS from a farthest-point cover
#         of 16 of its post-warm-up draws and up to 8 divergent draws (2.F). The
#         chains have to be run anyway; only the L-BFGS runs are the cost of the rule.
#   JH    P32 plus J's jitter plus H's harvest.
#   2.F   FARTHEST-POINT COVER of a set of draws: take the draw of highest log π, then
#         repeatedly the draw farthest (Euclidean in z) from those already taken. It
#         covers the sampled region evenly instead of piling starts on the bulk.
#
# ---------------------------------------------------------------------------------
# 3. What is measured, per fit, arm and seed
# ---------------------------------------------------------------------------------
#   recall_mass  Σ share of the massive reference optima the arm found / Σ share of
#                all massive reference optima: 1 means nothing with mass was missed;
#                an arm FINDS a reference optimum when one of its optima is the same
#                (as defined above);
#   n_missed     the number of massive reference optima it did not find;
#   evals        objective + gradient evaluations (the cost; the pre-screen counts
#                too); `seconds` is wall time and depends on the machine and threads;
#   hits / chao1 see below.
# Per reference optimum (the `_optima.tsv` file): position ξ, f, log-mass, share,
# `hits` (how many of the ORACLE_STARTS random starts ended there), the hit rate
# p = hits/ORACLE_STARTS, `miss32 = (1-p)^32` (the probability that P32 misses it),
# `starts_for_95 = log(0.05)/log(1-p)` (the number of random starts for 95 % detection),
# and which arms found it. CHAO1: from the number of reference optima seen exactly once
# (f1) and twice (f2) among a set of starts, Chao's (1984) lower bound on the number
# unseen is f1²/(2 f2) (f1(f1-1)/2 if f2 = 0); it is reported for the oracle's 500
# starts, as an estimate of how many optima even the oracle has not seen.
#
# The verdict at the end of the run is the README's criteria, evaluated over all the
# fits it was given.

using Printf, Random, Statistics, LinearAlgebra
using BAYSOL
const F = BAYSOL.Inference
const SV = F.SVector
const ForwardDiff = F.ForwardDiff
const DiffResults = F.DiffResults
include(joinpath(@__DIR__, "..", "..", "utils", "fit_seed.jl"))

const ORACLE_STARTS = 500
const ORACLE_CHAIN_ITER = (4000, 1000)       # n_samples, n_adapt of the long run
const MASSIVE_SHARE = 0.01
const SCREEN_POINTS = 3000
const SCREEN_K = 15
const JITTER_RADII = (3.0, 6.0, 12.0)
const JITTER_DIRECTIONS = 2
const JITTER_MAX_OPTIMA = 4
const JITTER_WITHIN_NATS = 15.0
const HARVEST_COVER = 16
const HARVEST_DIVERGENT = 8
# `printf` with a format that is not a literal (`@printf` needs one).
pf(fmt, args...) = print(Printf.format(Printf.Format(fmt), args...))

const ARMS = ("P32", "A64", "A128", "S32", "J", "H", "JH")

# ---------------------------------------------------------------------------------
# The problem of one fit: f(z), its gradient, one L-BFGS run
# ---------------------------------------------------------------------------------

struct Problem{S}
    seed::S
    μ::SV{4,Float64}
    σ::SV{4,Float64}
    f::Function
    fg!::Function
    g!::Function
    opts::Any
end

function Problem(seed)
    l = F.PROFILE()
    μ, σ = F.θ_prior_moments(seed.pr)
    f = z -> F._neglogπ(SV{4}(z...), μ, σ, seed, l, F.EXCL_VOL_CORR_TOL)
    function fg!(G, z)
        dr = DiffResults.GradientResult(z)
        ForwardDiff.gradient!(dr, f, z)
        G === nothing || (G .= DiffResults.gradient(dr))
        return DiffResults.value(dr)
    end
    g!(G, z) = (fg!(G, z); G)
    opts = F.Options(g_abstol = F.MAP_G_TOL, iterations = F.MAP_MAX_ITER)
    return Problem(seed, μ, σ, f, fg!, g!, opts)
end

ξ_of(P::Problem, z) = F.Ξ(P.μ .+ P.σ .* SV{4}(z...), P.seed.pr)
z_of_ξ(P::Problem, ξ) = F._standardize(F.Θ(ξ, P.seed.pr)[1], P.seed.pr)

"One L-BFGS run from `z0`: `nothing` if the start is infeasible."
function local_search(P::Problem, z0)
    z = Vector{Float64}(z0)
    isfinite(P.f(z)) || return nothing
    try
        res = F.optimize(F.OnceDifferentiable(P.f, P.g!, P.fg!, z), z, F.LBFGS(), P.opts)
        ẑ = SV{4}(F.Optim.minimizer(res)...)
        f = F.Optim.minimum(res)
        isfinite(f) || return nothing
        return (; z = ẑ, f, evals = F.Optim.f_calls(res) + F.Optim.g_calls(res))
    catch
        return nothing
    end
end

"`n` prior draws in z-space (the production kind of start); the first is θ₀."
function prior_starts(P::Problem, n, rng_seed)
    Random.seed!(rng_seed)
    pr = P.seed.pr
    z₀ = F._standardize(P.seed.θ₀, pr)
    return vcat([z₀], [F._standardize(F.Θ(F._ξ₀(pr), pr)[1], pr) for _ in 2:n])
end

"Runs `local_search` from every start (on the Julia threads); drops infeasible ones."
function search_all(P::Problem, starts)
    res = BAYSOL.Runtime.tmap_items(i -> local_search(P, starts[i]), eachindex(starts))
    return collect(filter(!isnothing, res))
end

# ---------------------------------------------------------------------------------
# Hessians, masses, clustering
# ---------------------------------------------------------------------------------

function hessian_at(P::Problem, z)
    H = F._fd_hessian(SV{4}(z...), 1e-3 .* ones(SV{4,Float64}), P.μ, P.σ, P.seed,
        F.PROFILE())
    return all(isfinite, H) ? Symmetric(Matrix(H)) : nothing
end

"""
Laplace log-mass of the optimum at `z` with value `f` (NaN when H is not positive
definite), and the Hessian eigenvalues.
"""
function log_mass(P::Problem, z, f)
    H = hessian_at(P, z)
    H === nothing && return NaN, fill(NaN, 4)
    λ = eigvals(H)
    return all(>(0), λ) ? (-f - 0.5 * sum(log, λ), λ) : (NaN, λ)
end

"""
The metric `d(a, b) = sqrt((a-b)' Hf (a-b))` of the best optimum's Hessian, with its
eigenvalues floored at 1.
"""
function metric_of(P::Problem, z_best)
    H = hessian_at(P, z_best)
    H === nothing && return Matrix{Float64}(I, 4, 4)
    e = eigen(H)
    return Symmetric(e.vectors * Diagonal(max.(e.values, 1.0)) * e.vectors')
end

dist(Hf, a, b) = sqrt(max(0.0, dot(a - b, Hf * (a - b))))

"""
Greedy clustering of the optima `(z, f)` in `opts`: sorted by f, each joins the first
cluster whose centre is within `F.MAP_MODE_SEP` under `Hf`, or starts a new one.
Returns the centres (indices into `opts`, best first) and, per optimum, its centre's
position in that list.
"""
function cluster_optima(opts, Hf)
    order = sortperm([o.f for o in opts])
    centres = Int[]
    assign = zeros(Int, length(opts))
    for i in order
        c = findfirst(j -> dist(Hf, opts[i].z, opts[j].z) ≤ F.MAP_MODE_SEP, centres)
        if c === nothing
            push!(centres, i)
            c = length(centres)
        end
        assign[i] = c
    end
    return centres, assign
end

# ---------------------------------------------------------------------------------
# Rules: the sets of starts
# ---------------------------------------------------------------------------------

"""
Farthest-point cover: `k` of the rows of `Z` (columns are coordinates), starting at
row `first`.
"""
function farthest_cover(Z::Matrix{Float64}, k, first)
    n = size(Z, 1)
    k = min(k, n)
    taken = [first]
    d = [norm(Z[i, :] - Z[first, :]) for i in 1:n]
    while length(taken) < k
        j = argmax(d)
        d[j] == 0 && break
        push!(taken, j)
        for i in 1:n
            d[i] = min(d[i], norm(Z[i, :] - Z[j, :]))
        end
    end
    return taken
end

"The MLSL-style screened starts: local minima of f over `SCREEN_POINTS` prior draws."
function screened_starts(P::Problem, n, rng_seed)
    Random.seed!(rng_seed)
    pr = P.seed.pr
    Z = [F._standardize(F.Θ(F._ξ₀(pr), pr)[1], pr) for _ in 1:SCREEN_POINTS]
    fv = BAYSOL.Runtime.tmap_items(i -> P.f(Vector(Z[i])), eachindex(Z))
    cand = Int[]
    for i in eachindex(Z)
        isfinite(fv[i]) || continue
        d = [norm(Z[i] - Z[j]) for j in eachindex(Z)]
        nb = partialsortperm(d, 2:(SCREEN_K+1))
        all(j -> !isfinite(fv[j]) || fv[i] ≤ fv[j], nb) && push!(cand, i)
    end
    sort!(cand, by = i -> fv[i])
    z₀ = F._standardize(P.seed.θ₀, pr)
    return vcat([z₀], Z[cand[1:min(n-1, length(cand))]]), SCREEN_POINTS
end

"Jitter starts around the optima `found` (best first): see the header, rule J."
function jitter_starts(P::Problem, found, rng_seed)
    rng = MersenneTwister(rng_seed)
    isempty(found) && return Vector{Float64}[]
    fbest = found[1].f
    out = Vector{Float64}[]
    for o in found
        o.f ≤ fbest + JITTER_WITHIN_NATS || continue
        length(out) ≥ JITTER_MAX_OPTIMA * length(JITTER_RADII) * JITTER_DIRECTIONS && break
        H = hessian_at(P, o.z)
        H === nothing && continue
        e = eigen(H)
        half = e.vectors * Diagonal(1 ./ sqrt.(max.(e.values, 1.0)))   # z = ẑ + half·u
        for r in JITTER_RADII, _ in 1:JITTER_DIRECTIONS
            u = randn(rng, 4)
            u ./= norm(u)
            push!(out, Vector(o.z + r .* (half * u)))
        end
    end
    return out
end

"Harvest starts from a sampler run: farthest-point cover plus divergent draws."
function harvest_starts(P::Problem, fit, k_cover, k_div)
    na = fit.diagnostics.n_adapt
    idx = findall(i -> fit.iteration[i] > na, eachindex(fit.iteration))
    isempty(idx) && return Vector{Float64}[]
    Z = permutedims(hcat((Vector(z_of_ξ(P, fit.samples[i])) for i in idx)...))
    ld = [fit.stats[i].log_density for i in idx]
    out = [Vector(Z[j, :]) for j in farthest_cover(Z, k_cover, argmax(ld))]
    dv = findall(j -> fit.stats[idx[j]].numerical_error, eachindex(idx))
    if !isempty(dv)
        Zd = Z[dv, :]
        append!(out, [Vector(Zd[j, :]) for j in farthest_cover(Zd, k_div, 1)])
    end
    return out
end

# ---------------------------------------------------------------------------------
# One fit
# ---------------------------------------------------------------------------------

mutable struct ArmRun
    arm::String
    seed::Int
    optima::Vector{NamedTuple}
    evals::Int
    seconds::Float64
end

function run_arms(P::Problem, seeds)
    runs = ArmRun[]
    harvest_cost = Dict{Int,Int}()
    for s in seeds
        t0 = time()
        # plain multistart, nested: the first 32 / 64 of the 128 starts
        st = prior_starts(P, 128, s)
        res = search_all(P, st)
        dt = time() - t0
        # (the order of `res` follows the starts; infeasible ones are dropped)
        for (arm, n) in (("P32", 32), ("A64", 64), ("A128", 128))
            sub = res[1:min(n, length(res))]
            push!(runs, ArmRun(arm, s, sub, sum(o.evals for o in sub), dt * n / 128))
        end
        # screened
        t0 = time()
        sst, nscreen = screened_starts(P, 32, s)
        sres = search_all(P, sst)
        push!(
            runs,
            ArmRun("S32", s, sres, nscreen + sum(o.evals for o in sres),
                time() - t0),
        )
        # jitter and harvest, on top of P32
        p32 = runs[end-3]
        found32 = sort(p32.optima, by = o -> o.f)
        # (the distinct optima of P32: its own best optimum's metric)
        isempty(found32) || (found32 = found32[first(cluster_optima(found32,
            metric_of(P, found32[1].z)))])
        t0 = time()
        jres = search_all(P, jitter_starts(P, found32, s))
        tj = time() - t0
        t0 = time()
        fit = F.infer(P.seed, 1000, 300; rng_seed = s, retry = false)
        harvest_cost[s] = sum(st_.n_steps for st_ in fit.stats)
        hres = search_all(P, harvest_starts(P, fit, HARVEST_COVER, HARVEST_DIVERGENT))
        th = time() - t0
        push!(
            runs,
            ArmRun("J", s, vcat(p32.optima, jres),
                p32.evals + sum(o.evals for o in jres), p32.seconds + tj),
        )
        push!(
            runs,
            ArmRun("H", s, vcat(p32.optima, hres),
                p32.evals + sum(o.evals for o in hres), p32.seconds + th),
        )
        push!(
            runs,
            ArmRun("JH", s, vcat(p32.optima, jres, hres),
                p32.evals + sum(o.evals for o in jres) + sum(o.evals for o in hres),
                p32.seconds + tj + th),
        )
    end
    return runs, harvest_cost
end

function oracle_runs(P::Problem)
    res = search_all(P, prior_starts(P, ORACLE_STARTS, 1000))
    fit = F.infer(P.seed, ORACLE_CHAIN_ITER[1], ORACLE_CHAIN_ITER[2]; rng_seed = 999,
        retry = false)
    hres = search_all(P, harvest_starts(P, fit, 2 * HARVEST_COVER, 2 * HARVEST_DIVERGENT))
    return res, hres
end

chao1(f1, f2) = f2 > 0 ? f1^2 / (2.0f2) : f1 * (f1 - 1) / 2

function analyse(io_rows, io_opt, label, P::Problem, seeds)
    t_fit = time()
    runs, harvest_cost = run_arms(P, seeds)
    orand, ohar = oracle_runs(P)
    # the reference set and the metric
    allopt = vcat(orand, ohar, [r.optima for r in runs]...)
    best = allopt[argmin([o.f for o in allopt])]
    Hf = metric_of(P, best.z)
    centres, _ = cluster_optima(allopt, Hf)
    ref = map(centres) do c
        o = allopt[c]
        lm, λ = log_mass(P, o.z, o.f)
        (; z = o.z, f = o.f, lm, λ)
    end
    lms = [r.lm for r in ref]
    ok = filter(!isnan, lms)
    top = isempty(ok) ? 0.0 : maximum(ok)
    tot = sum(exp(l - top) for l in ok; init = 0.0)
    share = [isnan(l) ? 0.0 : exp(l - top) / tot for l in lms]
    massive = findall(≥(MASSIVE_SHARE), share)
    nref, nmass, nunmass = length(ref), length(massive), count(isnan, lms)
    # hits of the oracle's random starts
    hits = zeros(Int, nref)
    for o in orand
        d = [dist(Hf, o.z, r.z) for r in ref]
        j = argmin(d)
        d[j] ≤ F.MAP_MODE_SEP && (hits[j] += 1)
    end
    found_by = Dict{String,BitVector}()
    function finds(optima)
        v = falses(nref)
        for o in optima, j in 1:nref
            dist(Hf, o.z, ref[j].z) ≤ F.MAP_MODE_SEP && (v[j] = true)
        end
        return v
    end
    # chao1 among the ORACLE starts and among the P32 starts of seed 1
    function hit_counts(optima)
        h = zeros(Int, nref)
        for o in optima
            d = [dist(Hf, o.z, r.z) for r in ref]
            j = argmin(d)
            d[j] ≤ F.MAP_MODE_SEP && (h[j] += 1)
        end
        return h
    end
    h_or = hit_counts(orand)
    c_or = chao1(count(==(1), h_or), count(==(2), h_or))
    rows = NamedTuple[]
    for r in runs
        v = finds(r.optima)
        found_by["$(r.arm)/$(r.seed)"] = v
        mass_all = sum(share[massive]; init = 0.0)
        rec =
            mass_all > 0 ? sum(share[j] for j in massive if v[j]; init = 0.0) / mass_all :
            1.0
        h = hit_counts(r.optima)
        row = (; fit = label, arm = r.arm, seed = r.seed, n_ref = nref, n_massive = nmass,
            n_unmassable = nunmass, recall_mass = rec,
            n_missed = count(j -> !v[j], massive), evals = r.evals,
            seconds = r.seconds, n_reported = count(v),
            chao1_unseen = chao1(count(==(1), h), count(==(2), h)),
            oracle_chao1_unseen = c_or,
            chain_steps = r.arm in ("H", "JH") ? harvest_cost[r.seed] : 0)
        push!(rows, row)
        println(io_rows, join((string(getfield(row, k)) for k in keys(row)), "\t"))
    end
    for j in 1:nref
        p = hits[j] / max(length(orand), 1)
        ξ = ξ_of(P, ref[j].z)
        println(
            io_opt,
            join(
                (label, j, @sprintf("%.6g", ref[j].f), @sprintf("%.4f", ref[j].lm),
                    @sprintf("%.5f", share[j]), share[j] ≥ MASSIVE_SHARE, hits[j],
                    @sprintf("%.4f", p),
                    p > 0 ? @sprintf("%.4g", (1 - p)^32) : "1",
                    p > 0 && p < 1 ? @sprintf("%.0f", log(0.05) / log(1 - p)) :
                    (p == 0 ? "Inf" : "1"),
                    join((@sprintf("%.5g", x) for x in ξ), ","),
                    join((k for k in sort(collect(keys(found_by))) if found_by[k][j]), ","),
                ),
                "\t"),
        )
    end
    pf(
        "%-22s ref %2d (massive %d, unmassable %d)  oracle starts ok %d  " *
        "chao1 unseen %.1f  [%.0f s]\n",
        label, nref, nmass, nunmass, length(orand), c_or, time() - t_fit)
    for a in ARMS
        rs = filter(r -> r.arm == a, rows)
        @printf("    %-5s recall %s  missed %s  evals %s\n", a,
            join((@sprintf("%.3f", r.recall_mass) for r in rs), "/"),
            join((string(r.n_missed) for r in rs), "/"),
            join((string(r.evals) for r in rs), "/"))
    end
    flush(stdout)
    return rows
end

const ROW_HEADER =
    "fit\tarm\tseed\tn_ref\tn_massive\tn_unmassable\trecall_mass\tn_missed\t" *
    "evals\tseconds\tn_reported\tchao1_unseen\toracle_chao1_unseen\tchain_steps"
const OPT_HEADER =
    "fit\toptimum\tf\tlog_mass\tshare\tmassive\thits\thit_rate\tmiss32\t" *
    "starts_for_95\txi\tfound_by"

# ---------------------------------------------------------------------------------
# The verdict: README's criteria, over all the fits given
# ---------------------------------------------------------------------------------

function verdict(rows)
    println("\n=== verdict (criteria in README.md, fixed 2026-10-10) ===")
    byarm = Dict(a => filter(r -> r.arm == a, rows) for a in ARMS)
    p32 = byarm["P32"]
    pf(
        "baseline P32: nothing missed in %.1f %% of (fit, seed); recall median " *
        "%.3f, min %.3f; %d of %d (fit, seed) miss at least one\n",
        100mean(r.n_missed == 0 for r in p32), median(r.recall_mass for r in p32),
        minimum(r.recall_mass for r in p32), count(r -> r.n_missed > 0, p32), length(p32))
    base = Dict((r.fit, r.seed) => r for r in p32)
    for a in ARMS[2:end]
        rs = byarm[a]
        ratio = [r.evals / max(base[(r.fit, r.seed)].evals, 1) for r in rs]
        c1 = mean(r.n_missed == 0 for r in rs) ≥ 0.95
        c2 = minimum(r.recall_mass for r in rs) ≥ 0.9
        c3 = median(ratio) ≤ 10
        c4 = all(r.n_missed ≤ base[(r.fit, r.seed)].n_missed for r in rs)
        pf(
            "%-5s nothing missed: %5.1f %% %s | min recall %.3f %s | evals ×%.1f %s | " *
            "never worse than P32 %s | ACCEPTED %s\n",
            a, 100mean(r.n_missed == 0 for r in rs), c1 ? "ok" : "FAIL",
            minimum(r.recall_mass for r in rs), c2 ? "ok" : "FAIL",
            median(ratio), c3 ? "ok" : "FAIL", c4 ? "ok" : "FAIL", c1 && c2 && c3 && c4)
    end
    fits = unique(r.fit for r in rows)
    println("fits with an unmassable optimum in the reference set: ",
        count(f -> any(r.n_unmassable > 0 for r in rows if r.fit == f), fits), " of ",
        length(fits))
end

function main(args)
    seeds = [1, 2]
    out = nothing
    specs = String[]
    i = 1
    while i ≤ length(args)
        if args[i] == "--seeds"
            seeds = parse.(Int, split(args[i+1], ","))
            i += 2
        elseif args[i] == "--out"
            out = args[i+1]
            i += 2
        else
            push!(specs, args[i])
            i += 1
        end
    end
    isempty(specs) && error("give at least one ID[:tag]")
    io_rows = out === nothing ? devnull : open(out, "w")
    io_opt =
        out === nothing ? devnull : open(replace(out, r"\.tsv$" => "") * "_optima.tsv", "w")
    println(io_rows, ROW_HEADER)
    println(io_opt, OPT_HEADER)
    rows = NamedTuple[]
    for spec in specs
        id, tag = occursin(':', spec) ? String.(split(spec, ":"; limit = 2)) : (spec, "")
        seed, _, label = load_fit_seed(id, tag; makie = false)
        append!(rows, analyse(io_rows, io_opt, label, Problem(seed), seeds))
        flush(io_rows)
        flush(io_opt)
    end
    verdict(rows)
    out === nothing || (close(io_rows); close(io_opt))
end

main(ARGS)
