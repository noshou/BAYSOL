# SPDX-License-Identifier: LGPL-3.0-or-later

using StaticArrays
using LinearAlgebra: Symmetric, eigen, diag, norm
using Optim: Optim, optimize, LBFGS, Options, OnceDifferentiable, minimizer
using ForwardDiff, DiffResults

# ---------------------------------------------------------------------------
# NUTS samples log π in prior-standardized z-space, θ = μ + σ·z. The posterior is
# often far narrower than the prior (σ_z down to ~1e-4 along δρ₁/δρ₂), and Stan's
# windowed adaptation assumes O(1) scales: it starts from M⁻¹ = I and shrinks every
# covariance estimate toward 1e-3·I, which then dominates the narrow directions and
# forces tiny steps / deep trees all through warmup. So before NUTS:
#
#   1. multi-start L-BFGS on −log π(z) finds the MAP ẑ (same density NUTS samples,
#      Jacobian included, so it always has an interior mode);
#   2. a central-difference Hessian H of −log π at ẑ (of the envelope-theorem gradient,
#      which is exact only if c1 is profiled tightly: see `EXCL_VOL_CORR_TOL`);
#   3. NUTS samples w with z = ẑ + S·w, S = V·diag(λ)^(-1/2) from H = V·diag(λ)·Vᵀ,
#      so the posterior is ≈ N(0, I) in w and starts at its mode.
#
# The map z ↦ w is affine (constant Jacobian), so the target distribution is
# unchanged; only the chain's path is.
# ---------------------------------------------------------------------------

"""
    _Optimum

One distinct optimum of −log π in z-space, with what its Laplace mass needs.

# Fields
- `z::SVector{N,Float64}`, `f::Float64`: the optimum and −log π there.
- `λ::SVector{N,Float64}`, `V::SMatrix{N,N,Float64,L}`: the eigenvalues (not floored) and
    eigenvectors of the Hessian of −log π at `z` (`NaN` and the identity if it was not
    finite).
- `logmass::Float64`: the Laplace log-mass `−f − ½ Σ log λ`; `NaN` unless every `λ > 0`
    (an optimum on a prior bound has none: it carries no mass here).
"""
struct _Optimum{N,L}
    z::SVector{N,Float64}
    f::Float64
    λ::SVector{N,Float64}
    V::SMatrix{N,N,Float64,L}
    logmass::Float64
end

"""
    _StartRecord

How one L-BFGS start of the MAP search ended, as the optimizer reported it (kept for the
run statistics): the start's number, whether it was feasible, the objective at its optimum
the iterations and objective evaluations, which stopping rules fired and the final gradient
(`gNorm`, the largest absolute component, in z space). An infeasible start has `NaN` for `f`
and `gNorm` and `0` iterations and evaluations.
"""
struct _StartRecord
    start::Int
    feasible::Bool
    f::Float64
    iters::Int
    gConverged::Bool
    fConverged::Bool
    iterLimit::Bool
    evals::Int
    gNorm::Float64
end

"""
    _SamplingSpace

The affine map from NUTS's coordinates w to θ-space, θ = μ + σ·(ẑ + S·w), plus what
the MAP search found. Immutable, built once per [`infer`](@ref) call.

# Fields
- `μ`, `σ::SVector{N,Float64}`: the prior standardization, from [`θ_prior_moments`](@ref).
- `ẑ::SVector{N,Float64}`: the MAP in z-space (the seed's z₀ if every start failed).
- `S::SMatrix{N,N,Float64,L}`: the whitening matrix (identity if the Hessian was unusable).
- `nOk::Int`: L-BFGS starts that reached a finite optimum.
- `nStarts::Int`: L-BFGS starts made (prior draws, jittered starts, any extra ones).
- `nModes::Int`: distinct optima among them (Mahalanobis distance > `MAP_MODE_SEP`
    under the MAP Hessian).
- `whitened::Bool`: whether `S` comes from the Hessian (`false`: identity fallback).
- `nEvals::Int`: objective evaluations (value and gradient) over all L-BFGS starts.
- `logπ::Float64`: log π at the MAP (`NaN` if every start failed):
    the value NUTS's chains are measured against (a draw that beats it
    by [`BASIN_RESTART_NATS`](@ref) shows that a better basin exists).
- `optima::Vector{_Optimum}`: the distinct optima found (the best [`MAP_OPTIMA_KEPT`](@ref)
    of them, lowest −log π first), each with its Laplace mass.
- `starts::Vector{_StartRecord}`: how each L-BFGS start ended, in the order they ran.
"""
struct _SamplingSpace{N,L}
    μ::SVector{N,Float64}
    σ::SVector{N,Float64}
    ẑ::SVector{N,Float64}
    S::SMatrix{N,N,Float64,L}
    nOk::Int
    nStarts::Int
    nModes::Int
    whitened::Bool
    nEvals::Int
    logπ::Float64
    optima::Vector{_Optimum{N,L}}
    starts::Vector{_StartRecord}
end

"θ = μ + σ·(ẑ + S·w): NUTS coordinates w to θ-space (see [`_SamplingSpace`](@ref))."
_θ_of_w(w::SVector{N,<:Real}, sp::_SamplingSpace{N}) where {N} =
    sp.μ .+ sp.σ .* (sp.ẑ .+ sp.S * w)

"""
w = S⁻¹·((θ − μ)/σ − ẑ): θ-space back to NUTS's
coordinates, the inverse of [`_θ_of_w`](@ref).
"""
_w_of_θ(θ::SVector{N,<:Real}, sp::_SamplingSpace{N}) where {N} =
    sp.S \ ((θ .- sp.μ) ./ sp.σ .- sp.ẑ)

"""
−log π at prior-standardized z, with c1 profiled to `tol`. Non-finite values and
`WLSError` (a flat model curve) map to `+Inf`, so the L-BFGS line search backs off.

# Returns
- `Real`: −log π(θ(z)), or `+Inf`.
"""
function _neglogπ(
    z::SVector{N,T},
    μ,
    σ,
    seed::Seed,
    tol::Float64,
)::T where {N,T<:Real}
    v = try
        -_logπ(μ .+ σ .* z, seed.pr, seed.wls, seed.fw; tab = seed.c1tab, c1Tol = tol)
    catch e
        e isa WLSError || rethrow()
        Threads.atomic_add!(seed.c1tab.counts.wlsErrors, 1)     # the tally of the log
        return T(Inf)
    end
    return isfinite(v) ? v : T(Inf)
end

"""
Gradient of [`_neglogπ`](@ref) at z (one ForwardDiff pass).

# Returns
- `SVector{N,Float64}` (non-finite where −log π is `+Inf`).
"""
function _neglogπ_grad(
    z::SVector{N,Float64},
    μ,
    σ,
    seed::Seed,
    tol::Float64,
) where {N}
    return ForwardDiff.gradient(x -> _neglogπ(x, μ, σ, seed, tol), z)
end

"""
Symmetrized central-difference Hessian of [`_neglogπ`](@ref) at z, step `h[i]` along
coordinate i, from its envelope-theorem gradient, with c1 profiled to
`EXCL_VOL_CORR_TOL`.

# Returns
- `SMatrix{N,N,Float64}`: may contain non-finite entries if a probe hit a flat model.
"""
function _fdHessian(
    z::SVector{N,Float64}, h::SVector{N,Float64}, μ, σ, seed::Seed,
) where {N}
    H = _centralJacobian(
        u -> collect(_neglogπ_grad(z + h .* SVector{N}(u), μ, σ, seed, EXCL_VOL_CORR_TOL)),
        h,
    )
    return SMatrix{N,N,Float64}((H + H') / 2)
end

"""
Jacobian at the origin of the vector function `g` with central differences of step `h[i]`
along coordinate i (`FiniteDiff.finite_difference_jacobian`
on the rescaled argument u = x/h with a unit absolute step), as a plain `Matrix`.
`g` takes the rescaled argument, so a gradient `∇f(x₀ + h∘u)` gives the Hessian of `f`.
"""
function _centralJacobian(g, h::SVector{N,Float64}) where {N}
    J = FiniteDiff.finite_difference_jacobian(
        g, zeros(N), Val(:central); relstep = 0.0, absstep = 1.0,
    )
    return J ./ collect(h)'
end

"""
Eigen-decompose a symmetric Hessian and floor its eigenvalues at `MAP_HESS_EIG_FLOOR`.

# Returns
- `(λ, V)`: floored eigenvalues and eigenvectors, H ≈ V·diag(λ)·Vᵀ.
"""
function _flooredEigen(H::SMatrix{N,N,Float64}) where {N}
    E = eigen(Symmetric(Matrix(H)))
    λ = SVector{N}(max.(E.values, MAP_HESS_EIG_FLOOR))
    return λ, SMatrix{N,N}(E.vectors)
end

"""
The L-BFGS machinery of the MAP search, as a closure: `run(z)` minimizes −log π (c1
profiled to `EXCL_VOL_CORR_TOL`, the density NUTS samples) from `z`, and returns
`(z, f, evals, iters, gConverged, fConverged, iterLimit)` of the optimum (the last four
how the optimizer stopped), or `nothing` if the start is infeasible or ends
non-finite. `f` is the objective itself. `maxIter` caps the iterations of each start.
"""
function _lbfgsRunner(
    seed::Seed{<:Real,N};
    f_abstol::Real = MAP_F_ABSTOL,
    successive_f_tol::Int = MAP_F_SUCCESSIVE,
    maxIter::Int = MAP_MAX_ITER,
) where {N}
    μ, σ = θ_prior_moments(seed.pr, Val(N))
    f = z -> _neglogπ(SVector{N}(z...), μ, σ, seed, EXCL_VOL_CORR_TOL)
    fg! = (G, z) -> begin
        gcCheckpoint()
        dr = DiffResults.GradientResult(z)
        ForwardDiff.gradient!(dr, f, z)
        G === nothing || (G .= DiffResults.gradient(dr))
        DiffResults.value(dr)
    end
    g! = (G, z) -> (fg!(G, z); G)
    opts = Options(
        g_abstol = MAP_G_TOL,
        f_abstol = f_abstol,
        successive_f_tol = successive_f_tol,
        iterations = maxIter,
    )
    run =
        zs -> begin
            isfinite(f(Vector(zs))) || return nothing
            res =
                optimize(
                    OnceDifferentiable(f, g!, fg!, Vector(zs)),
                    Vector(zs),
                    LBFGS(),
                    opts,
                )
            v = Optim.minimum(res)
            isfinite(v) || return nothing
            return (
                z = SVector{N}(minimizer(res)...), f = v, evals = Optim.f_calls(res),
                iters = Optim.iterations(res), gConverged = Optim.g_converged(res),
                fConverged = Optim.f_converged(res),
                iterLimit = Optim.iteration_limit_reached(res),
                gNorm = Optim.g_residual(res),
            )
        end
    return run
end

"""
The [`_Optimum`](@ref) at `z` (value `f`): its Hessian by central differences of step
`MAP_HESS_STEP`, eigen-decomposed, and the Laplace log-mass (`NaN` if the Hessian is not
finite or not positive definite).
"""
function _optimum(
    z::SVector{N,Float64},
    f::Float64,
    μ,
    σ,
    seed::Seed,
) where {N}
    H = _fdHessian(z, MAP_HESS_STEP .* ones(SVector{N,Float64}), μ, σ, seed)
    iN = one(SMatrix{N,N,Float64})
    if !all(isfinite, H)
        return _Optimum(z, f, SVector{N}(ntuple(_ -> NaN, Val(N))), iN, NaN)
    end
    E = eigen(Symmetric(Matrix(H)))
    λ = SVector{N}(E.values)
    logmass = all(>(0), λ) ? -f - sum(log, λ) / 2 : NaN
    return _Optimum(z, f, λ, SMatrix{N,N}(E.vectors), logmass)
end

"""
`k` of the rows of `W` chosen by farthest-point cover: row `first`, then repeatedly the
row farthest (Euclidean) from those already taken, so they cover the cloud evenly instead
of piling up on its bulk. Fewer than `k` if the rows run out of distinct points.

# Returns
- `Vector{Int}`: the row indices, in the order taken.
"""
function _farthestCover(W::AbstractMatrix{<:Real}, k::Int, first::Int)
    n = size(W, 1)
    taken = [first]
    d = [norm(@view(W[i, :]) .- @view(W[first, :])) for i in 1:n]
    while length(taken) < min(k, n)
        j = argmax(d)
        d[j] > 0 || break
        push!(taken, j)
        for i in 1:n
            d[i] = min(d[i], norm(@view(W[i, :]) .- @view(W[j, :])))
        end
    end
    return taken
end

"""
Pre-NUTS MAP search and Laplace whitening (see the note at the top of `map.jl`).

L-BFGS runs from the seed's θ₀ and `MAP_N_STARTS - 1` further prior draws (and any
`extraStarts`), on −log π in prior-standardized z-space with c1 profiled to
`EXCL_VOL_CORR_TOL` (the same objective NUTS then samples). A second round of L-BFGS
runs then starts around the optima found: from [`MAP_JITTER_RADII`](@ref) ×
[`MAP_JITTER_DIRECTIONS`](@ref) points at distances from each optimum measured in
its own Hessian (at most [`MAP_JITTER_MAX_OPTIMA`](@ref) optima, those within
[`MAP_JITTER_WITHIN_NATS`](@ref) of the lowest), which reaches basins next to the ones
already found that random starts rarely hit. The distinct basins among all the optima
(Mahalanobis distance under the Hessian at the lowest one) are compared by their Laplace
mass, `−f − ½ log det H`, for the best `MAP_OPTIMA_KEPT` of them: a narrow basin can have
the lowest f and still carry less mass than a wide one. The heaviest basin's optimum is the
MAP ẑ. Its Hessian is taken in two central-difference passes: step `MAP_HESS_STEP`, then
`MAP_HESS_REL_STEP` × each coordinate's Laplace σ from the first pass.

# Arguments
- `seed::Seed`: priors, data, forward cache and c1 tables; `seed.θ₀` is the first start.

# Keywords
- `options::SamplerOptions`: the counts, radii and caps named above (`MAP_*` settings of
    [`SamplerOptions`](@ref)); the defaults are the constants.
- `f_abstol`, `successive_f_tol`: the f-based stopping rule of each L-BFGS start.
- `base::UInt64`: the run's random base value; start `i ≥ 2` draws its
    prior sample from the stream `stream(base, _RNG_MAP_STARTS, i)`, and the jittered
    start `j` its direction from `stream(base, _RNG_MAP_JITTER, j)`.
    Default: a fresh draw from the default RNG (`infer` always passes its own).
- `extraStarts`: further L-BFGS starts in z-space (the sampler passes the
    best draw of a first round of chains here, to re-whiten at a better basin).

# Returns
- [`_SamplingSpace`](@ref). If no start reaches a finite optimum, ẑ is the seed's
    z₀ and S the identity (plain prior standardization, as without this step). If the
    Hessian is non-finite, ẑ is kept and S is the identity.
"""
function _samplingSpace(
    seed::Seed{<:Real,N};
    options::SamplerOptions = SamplerOptions(),
    f_abstol::Real = MAP_F_ABSTOL,
    successive_f_tol::Int = options.mapFSuccessive,
    base::UInt64 = drawBase(),
    extraStarts::AbstractVector = SVector{N,Float64}[],
)::_SamplingSpace where {N}
    μ, σ = θ_prior_moments(seed.pr, Val(N))
    run = _lbfgsRunner(
        seed; f_abstol, successive_f_tol, maxIter = options.mapMaxIter,
    )
    L = N * N
    noOptima = _Optimum{N,L}[]

    z₀ = _standardize(seed.θ₀, seed.pr)
    # start i ≥ 2 draws from its own stream, so the
    # starts do not depend on the order they run in
    starts = vcat(
        [z₀],
        [
            _standardize(
                _θOfξ(_ξ₀(seed.pr, Val(N), stream(base, _RNG_MAP_STARTS, i)), seed),
                seed.pr,
            )
            for i in 2:options.mapNStarts
        ],
        [SVector{N,Float64}(z) for z in extraStarts],
    )
    # serial on purpose: the whole search is ~8 ms warm (a start is ~1
    # ms), so threading it was measured slower (0.71× at 4 threads, a
    # validation run since removed from `test/validation/threading/`)
    optima = Tuple{SVector{N,Float64},Float64}[]
    nEvals = 0
    nTry = 0
    records = _StartRecord[]
    function search!(zs)
        nTry += 1
        r = run(zs)
        if r === nothing
            push!(records, _StartRecord(nTry, false, NaN, 0, false, false, false, 0, NaN))
            return
        end
        push!(
            records,
            _StartRecord(nTry, true, r.f, r.iters, r.gConverged,
                r.fConverged, r.iterLimit, r.evals, r.gNorm),
        )
        nEvals += r.evals
        push!(optima, (r.z, r.f))
        return
    end
    foreach(search!, starts)
    iN = one(SMatrix{N,N,Float64})
    isempty(optima) &&
        return _SamplingSpace(
            μ, σ, z₀, iN, 0, nTry, 0, false, nEvals, NaN, noOptima, records,
        )

    sort!(optima; by = last)            # lowest −log π first
    ẑ, fMode = optima[1]
    h₀ = MAP_HESS_STEP .* ones(SVector{N,Float64})
    memo = Dict{SVector{N,Float64},_Optimum{N,L}}()
    mk(z, f) = get!(() -> _optimum(z, f, μ, σ, seed), memo, z)

    # distinct basins: the lowest optimum of each (Mahalanobis distance under `Hm`)
    function basins(hm)
        reps = Int[]
        for (i, (z, _)) in enumerate(optima)
            any(
                j -> sqrt((z - optima[j][1])' * hm * (z - optima[j][1])) ≤ MAP_MODE_SEP,
                reps,
            ) ||
                push!(reps, i)
        end
        return reps
    end
    metric(o) = begin
        λf = max.(o.λ, MAP_HESS_EIG_FLOOR)
        o.V * (λf .* o.V')
    end

    o₁ = mk(ẑ, fMode)
    all(isfinite, o₁.λ) || return _SamplingSpace(
        μ, σ, ẑ, iN, length(optima), nTry, 1, false, nEvals, -fMode, [o₁], records,
    )

    # the second round: jittered starts around the distinct optima of the first
    ctr = 0
    for i in basins(metric(o₁))[1:min(end, options.mapJitterMaxOptima)]
        zᵢ, fᵢ = optima[i]
        fᵢ ≤ fMode + options.mapJitterWithinNats || continue
        oᵢ = mk(zᵢ, fᵢ)
        all(isfinite, oᵢ.λ) || continue
        half = oᵢ.V .* (1 ./ sqrt.(max.(oᵢ.λ, MAP_HESS_EIG_FLOOR)))' # z = zᵢ + half·u
        for r in options.mapJitterRadii, _ in 1:options.mapJitterDirections
            ctr += 1
            u = randn(stream(base, _RNG_MAP_JITTER, ctr), N)
            search!(zᵢ + r .* (half * SVector{N}(u ./ norm(u))))
        end
    end
    sort!(optima; by = last)
    if optima[1][1] != ẑ                 # a jittered start found a lower optimum
        ẑ, fMode = optima[1]
        o₁ = mk(ẑ, fMode)
        all(isfinite, o₁.λ) || return _SamplingSpace(
            μ, σ, ẑ, iN, length(optima), nTry, 1, false, nEvals, -fMode, [o₁], records,
        )
    end
    λ₁, V₁ = max.(o₁.λ, MAP_HESS_EIG_FLOOR), o₁.V
    H₁f = V₁ * (λ₁ .* V₁')

    # The heaviest basin, not just the lowest optimum: representatives of the
    # distinct basins (the lowest optimum of each, Mahalanobis distance under H₁),
    # the best MAP_OPTIMA_KEPT of them compared by Laplace mass −f − ½ log det H
    # (eigenvalues floored, as for the whitening).
    reps = basins(H₁f)
    found = [mk(optima[i]...) for i in reps[1:min(end, options.mapOptimaKept)]]
    mass₁ = -fMode - sum(log, λ₁) / 2
    for o in found[2:end]
        all(isfinite, o.λ) || continue
        λᵢ, Vᵢ = max.(o.λ, MAP_HESS_EIG_FLOOR), o.V
        massᵢ = -o.f - sum(log, λᵢ) / 2
        if massᵢ > mass₁
            ẑ, fMode, mass₁, λ₁, V₁ = o.z, o.f, massᵢ, λᵢ, Vᵢ
        end
    end
    σ_lap = sqrt.(diag(V₁ * ((1 ./ λ₁) .* V₁')))   # Laplace σ per coordinate
    H = _fdHessian(ẑ, MAP_HESS_REL_STEP .* σ_lap, μ, σ, seed)
    all(isfinite, H) || (H = SMatrix{N,N}(V₁ * (λ₁ .* V₁')))
    λ, V = _flooredEigen(H)

    # distinct modes: greedy clustering of the optima, Mahalanobis distance under H
    hf = V * (λ .* V')
    modes = SVector{N,Float64}[]
    for (z, _) in optima
        any(m -> sqrt((z - m)' * hf * (z - m)) ≤ MAP_MODE_SEP, modes) || push!(modes, z)
    end
    S = V .* (1 ./ sqrt.(λ))'    # V·diag(λ)^(-1/2): Sᵀ·H·S = I
    return _SamplingSpace(
        μ, σ, ẑ, S, length(optima), nTry, length(modes), true, nEvals, -fMode, found,
        records,
    )
end

"""
Optima the chains visit that the MAP search did not report. L-BFGS runs from a
farthest-point cover ([`_farthestCover`](@ref)) of `HARVEST_COVER` of the draws `W`
(rows, in the whitened coordinates of `sp`; the one of highest log density `ld` first)
and of up to `HARVEST_DIVERGENT` of the divergent ones (`diverged`). Each optimum that
is not within `MAP_MODE_SEP` (Mahalanobis, under the Hessian of `sp`) of one already
known is added with its Laplace mass. `options` (`harvestCover`, `harvestDivergent`,
`mapMaxIter`, `mapFSuccessive` of [`SamplerOptions`](@ref)) replace those constants.

# Returns
- `(optima::Vector{_Optimum}, nEvals::Int)`: `sp.optima` and the new
    ones, lowest −log π first, and the evaluations of the L-BFGS runs.
"""
function _harvestOptima(
    seed::Seed{<:Real,N},
    sp::_SamplingSpace{N,L},
    W::AbstractMatrix{<:Real},
    ld::AbstractVector{<:Real},
    diverged::AbstractVector{Bool};
    options::SamplerOptions = SamplerOptions(),
    f_abstol::Real = MAP_F_ABSTOL,
    successive_f_tol::Int = options.mapFSuccessive,
) where {N,L}
    n = size(W, 1)
    n == 0 && return sp.optima, 0
    run = _lbfgsRunner(
        seed; f_abstol, successive_f_tol, maxIter = options.mapMaxIter,
    )
    rows = _farthestCover(W, options.harvestCover, argmax(ld))
    dv = findall(diverged)
    if !isempty(dv)
        append!(rows, dv[_farthestCover(W[dv, :], options.harvestDivergent, 1)])
    end
    hf = inv(sp.S * sp.S')
    known = copy(sp.optima)
    nEvals = 0
    for i in unique(rows)
        r = run(sp.ẑ + sp.S * SVector{N,Float64}(W[i, :]))
        r === nothing && continue
        nEvals += r.evals
        any(o -> sqrt((r.z - o.z)' * hf * (r.z - o.z)) ≤ MAP_MODE_SEP, known) && continue
        push!(known, _optimum(r.z, r.f, sp.μ, sp.σ, seed))
    end
    sort!(known; by = o -> o.f)
    return known, nEvals
end

# ---------------------------------------------------------------------------
#   Chain starts, draws in the whitened coordinates, the best draw
# ---------------------------------------------------------------------------

"""
The nominal signed distance from the MAP, in posterior standard deviations, at which
chain `k` of `n` starts: a single chain at the MAP (0); with several, chains 1 and 2
both at the MAP (two independent chains of their own random streams from the same point:
independent effective sample size within the main mode and a baseline for R̂ there), and
chains 3 and up in mirrored pairs at the radii of [`CHAIN_START_RADII`](@ref) (the first
of a pair positive, the second negative: the same random direction, opposite sides).
`radii` replaces [`CHAIN_START_RADII`](@ref) (a non-empty vector or tuple).

# Returns
- `Float64`.

# Exceptions
- None.
"""
function chainRadius(
    k::Int, n::Int, radii::Union{AbstractVector{<:Real},Tuple} = CHAIN_START_RADII,
)::Float64
    (n == 1 || k ≤ 2) && return 0.0
    r = radii[min((k - 1) ÷ 2, length(radii))]
    return isodd(k) ? r : -r
end

"""
Start of chain `k` of `n` in NUTS's whitened coordinates w, with its signed distance
from the MAP in posterior standard deviations ([`chainRadius`](@ref)). The start is
`r·u` for a direction `u` on the unit sphere: a single chain, and chain 1, at the MAP
(`w = 0`); chain 2 also at the MAP (its own random stream makes it an independent
chain); chains 3 and up in mirrored pairs, chains `2p+1` and `2p+2` at `+r_p·u_p` and
`-r_p·u_p`. The directions come from streams of the run's `base` (its
`rngSeed`), under their own purpose tag. A start where log π or its gradient is not
finite is pulled halfway back toward the MAP, up to [`CHAIN_JITTER_MAX_HALVINGS`](@ref)
times, and the distance returned is the one used; a start that never becomes usable is the
MAP itself (0).

# Returns
- `(w₀::Vector{Float64}, r::Float64)`.
"""
function _chainStart(
    k::Int, n::Int, N::Int, ℓπ, ∂ℓπ∂w, base::UInt64,
    radii::Union{AbstractVector{<:Real},Tuple} = CHAIN_START_RADII,
)
    r = chainRadius(k, n, radii)
    r == 0 && return zeros(N), 0.0
    z = randn(stream(base, _RNG_JITTER, (k - 1) ÷ 2), N)
    u = z ./ norm(z)
    for _ in 0:CHAIN_JITTER_MAX_HALVINGS
        w = r .* u
        usable = try
            v, g = ∂ℓπ∂w(w)
            isfinite(v) && all(isfinite, g)
        catch e
            e isa InterruptException && rethrow()
            false
        end
        usable && return w, r
        r /= 2
    end
    return zeros(N), 0.0
end

"""
The draws `ξs` in NUTS's whitened coordinates, one draw per row.

# Returns
- `Matrix{Float64}`, `length(ξs) × N`.
"""
function _drawsW(seed::Seed{<:Real,N}, sp, ξs::AbstractVector) where {N}
    W = Matrix{Float64}(undef, length(ξs), N)
    @inbounds for (i, ξ) in enumerate(ξs)
        w = _w_of_θ(_θOfξ(ξ, seed), sp)
        for j in 1:N
            W[i, j] = w[j]
        end
    end
    return W
end

"""
The highest post-warm-up log density among the
non-divergent draws of the chains that ran, and its ξ.

# Returns
- `NamedTuple` `(ld, ξ)`; `ld = -Inf` if there is no such draw.
"""
function _bestDraw(runs, post)
    best = (ld = -Inf, ξ = nothing)
    for r in runs
        r.error === nothing || continue
        for i in post
            st = r.stats[i]
            st.numerical_error || st.log_density <= best.ld ||
                (best = (ld = st.log_density, ξ = r.ξ[i]))
        end
    end
    return best
end


# ---------------------------------------------------------------------------
#   Optima beyond the MAP search: shares, chains at them, chains started at them
# ---------------------------------------------------------------------------

"""
The Laplace share of every optimum: `exp(logmass)` over the sum over those that have
one; 0 for an optimum with none (`NaN`).
"""
function _optimumShares(optima)
    lm = [o.logmass for o in optima]
    ok = filter(!isnan, lm)
    isempty(ok) && return zeros(length(optima))
    top = maximum(ok)
    tot = sum(exp(x - top) for x in ok)
    return [isnan(x) ? 0.0 : exp(x - top) / tot for x in lm]
end

"""
How many of the chains, whose post-warm-up draws are the rows of `wsRows` (whitened
coordinates of `sp`), are at the optimum `o`: at least [`OPTIMUM_CHAIN_FRACTION`](@ref) of
a chain's draws lie within [`OPTIMUM_CHAIN_RADIUS`](@ref) of it in the Mahalanobis distance
of the Hessian there. 0 for an optimum without a positive definite Hessian. `radius` and
`fraction` replace the two constants.
"""
function _chainsAt(
    o, sp, wsRows;
    radius::Real = OPTIMUM_CHAIN_RADIUS, fraction::Real = OPTIMUM_CHAIN_FRACTION,
)
    all(>(0), o.λ) || return 0
    H = o.V * (o.λ .* o.V')
    return count(wsRows) do W
        size(W, 1) == 0 && return false
        inside = count(axes(W, 1)) do i
            d = sp.ẑ + sp.S * typeof(sp.ẑ)(@view W[i, :]) - o.z
            d' * H * d ≤ radius^2
        end
        inside ≥ fraction * size(W, 1)
    end
end

"""
The first round of chains `runs` (with their `starts`), extended: L-BFGS from their draws
for optima the MAP search did not report ([`_optimaAndExtraChains`](@ref)), then the
chains that optima carrying mass are missing, run and appended (none for `nChains == 1`,
which is a single chain). Also the [`OptimumReport`](@ref)s of the optima that carry mass.

# Returns
- `NamedTuple` `(runs, starts, nExtra, optimaReport)`.
"""
function _withOptimaChains(seed::Seed{<:Real,N}, sp, runs, starts, post,
    nSamples, nAdapt, δ, base, nChains;
    options::SamplerOptions = SamplerOptions()) where {N}
    opt = _optimaAndExtraChains(seed, sp, runs, post; options = options)
    if nChains > 1 && !isempty(opt.extraW)
        ex = _runExtraChains(
            seed, sp, nSamples, nAdapt, δ, base, opt.extraW, length(runs),
        )
        allRuns = vcat(runs, ex.runs)
        wsRows = vcat(
            opt.wsRows,
            [_drawsW(seed, sp, r.ξ[post]) for r in ex.runs if r.error === nothing],
        )
        report = _optimumReports(
            seed, sp, opt.optima, wsRows, opt.owner[ex.keep]; options = options,
        )
        return (runs = allRuns, starts = vcat(starts, ex.starts),
            nExtra = length(ex.runs),
            optimaReport = report)
    end
    report = _optimumReports(seed, sp, opt.optima, opt.wsRows, Int[]; options = options)
    return (runs = runs, starts = starts, nExtra = 0, optimaReport = report)
end

"""
After the first round of chains: the optima known (the MAP search's and those found by
L-BFGS from the chains' draws, [`_harvestOptima`](@ref)), and the whitened starts of the
chains that optima carrying mass ([`OPTIMUM_MIN_SHARE`](@ref)) are missing: up to
[`OPTIMUM_MIN_CHAINS`](@ref) chains at each, [`OPTIMUM_CHAIN_CAP`](@ref) in all,
the heaviest optimum first.

# Returns
- `(optima, extraW, owner, wsRows)`: the optima, the starts and, for each
    start, the index in `optima` of the optimum it is at, and the whitened
    post-warm-up draws of each chain (one matrix per chain that ran).
"""
function _optimaAndExtraChains(
    seed::Seed{<:Real,N},
    sp,
    runs,
    post;
    options::SamplerOptions = SamplerOptions(),
) where {N}
    ran = [r for r in runs if r.error === nothing]
    isempty(ran) && return (
        optima = sp.optima, extraW = Vector{Float64}[], owner = Int[],
        wsRows = Matrix{Float64}[],
    )
    wsRows = [_drawsW(seed, sp, r.ξ[post]) for r in ran]
    ld = reduce(vcat, [getproperty.(r.stats[post], :log_density) for r in ran])
    dv = reduce(vcat, [getproperty.(r.stats[post], :numerical_error) for r in ran])
    optima, _ = _harvestOptima(
        seed, sp, reduce(vcat, wsRows), ld, Vector{Bool}(dv); options = options,
    )
    shares = _optimumShares(optima)
    extraW = Vector{Float64}[]
    owner = Int[]
    for i in sortperm(shares; rev = true)
        shares[i] ≥ OPTIMUM_MIN_SHARE || break
        need =
            options.optimumMinChains - _chainsAt(
                optima[i], sp, wsRows;
                radius = options.optimumChainRadius,
                fraction = options.optimumChainFraction,
            )
        need > 0 || continue
        w = Vector(sp.S \ (optima[i].z - sp.ẑ))
        for _ in 1:need
            length(extraW) < options.optimumChainCap || break
            push!(extraW, w)
            push!(owner, i)
        end
    end
    return (optima = optima, extraW = extraW, owner = owner, wsRows = wsRows)
end

"""
The [`OptimumReport`](@ref)s of the optima that carry mass, the best first,
with the chains at each after all the chains have run (`wsRows`: the
whitened post-warm-up draws of each chain that ran); `owners` lists, for
each chain started at an optimum, the index in `optima` of that optimum.
"""
function _optimumReports(
    seed::Seed{<:Real,N}, sp, optima, wsRows, owners;
    options::SamplerOptions = SamplerOptions(),
) where {N}
    shares = _optimumShares(optima)
    out = OptimumReport[]
    for i in sortperm(shares; rev = true)
        shares[i] ≥ OPTIMUM_MIN_SHARE || break
        push!(
            out,
            OptimumReport(
                Vector(_ξOfθ(sp.μ .+ sp.σ .* optima[i].z, seed)), optima[i].logmass,
                shares[i],
                _chainsAt(
                    optima[i], sp, wsRows;
                    radius = options.optimumChainRadius,
                    fraction = options.optimumChainFraction,
                ),
                count(==(i), owners),
            ),
        )
    end
    return out
end

"""
Runs one NUTS chain at each of the whitened starts `wStarts`, as chains `k0 + 1`,
`k0 + 2`, … (their streams belong to those indices). A start where log π or its gradient
is not finite is dropped.

# Returns
-   `NamedTuple` `(runs, starts, keep)`: the [`_ChainRun`](@ref)s, their `(w₀, distance
    from the MAP)` and the positions in `wStarts` that were run.
"""
function _runExtraChains(seed::Seed{<:Real,N}, sp, nSamples::Int64,
    nAdapt::Int64, δ::Real, base::UInt64, wStarts::AbstractVector, k0::Int) where {N}
    ℓπ, ∂ℓπ∂w, runChain = _chainRunner(seed, sp, nSamples, nAdapt, δ, base, false)
    keep = filter(eachindex(wStarts)) do i
        try
            v, g = ∂ℓπ∂w(wStarts[i])
            isfinite(v) && all(isfinite, g)
        catch e
            e isa InterruptException && rethrow()
            false
        end
    end
    runs = tmapItems(i -> runChain(k0 + findfirst(==(i), keep), wStarts[i]), keep)
    starts = [(wStarts[i], norm(wStarts[i])) for i in keep]
    return (runs = runs, starts = starts, keep = keep)
end
