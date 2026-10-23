# SPDX-License-Identifier: LGPL-3.0-or-later

using StaticArrays
using LinearAlgebra: Symmetric, eigen, diag
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
    _SamplingSpace

The affine map from NUTS's coordinates w to θ-space, θ = μ + σ·(ẑ + S·w), plus what
the MAP search found. Immutable, built once per [`infer`](@ref) call.

# Fields
- `μ`, `σ::SVector{N,Float64}`: the prior standardization, from [`θ_prior_moments`](@ref).
- `ẑ::SVector{N,Float64}`: the MAP in z-space (the seed's z₀ if every start failed).
- `S::SMatrix{N,N,Float64,L}`: the whitening matrix (identity if the Hessian was unusable).
- `n_ok::Int`: L-BFGS starts that reached a finite optimum.
- `n_starts::Int`: L-BFGS starts made (prior draws, jittered starts, any extra ones).
- `n_modes::Int`: distinct optima among them (Mahalanobis distance > `MAP_MODE_SEP`
    under the MAP Hessian).
- `whitened::Bool`: whether `S` comes from the Hessian (`false`: identity fallback).
- `n_evals::Int`: objective evaluations (value and gradient) over all L-BFGS starts.
- `logπ::Float64`: log π at the MAP (`NaN` if every start failed):
    the value NUTS's chains are measured against (a draw that beats it
    by [`BASIN_RESTART_NATS`](@ref) shows that a better basin exists).
- `optima::Vector{_Optimum}`: the distinct optima found (the best [`MAP_MAX_BASINS`](@ref)
    of them, lowest −log π first), each with its Laplace mass.
"""
struct _SamplingSpace{N,L}
    μ::SVector{N,Float64}
    σ::SVector{N,Float64}
    ẑ::SVector{N,Float64}
    S::SMatrix{N,N,Float64,L}
    n_ok::Int
    n_starts::Int
    n_modes::Int
    whitened::Bool
    n_evals::Int
    logπ::Float64
    optima::Vector{_Optimum{N,L}}
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
        -_logπ(μ .+ σ .* z, seed.pr, seed.wls, seed.fw; tab = seed.c1tab, c1_tol = tol)
    catch e
        e isa WLSError || rethrow()
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
function _fd_hessian(
    z::SVector{N,Float64}, h::SVector{N,Float64}, μ, σ, seed::Seed,
) where {N}
    cols = ntuple(Val(N)) do i
        e = SVector(ntuple(j -> j == i ? h[i] : 0.0, Val(N)))
        (
            _neglogπ_grad(z + e, μ, σ, seed, EXCL_VOL_CORR_TOL) -
            _neglogπ_grad(z - e, μ, σ, seed, EXCL_VOL_CORR_TOL)
        ) / (2h[i])
    end
    H = hcat(cols...)
    return (H + H') / 2
end

"""
Eigen-decompose a symmetric Hessian and floor its eigenvalues at `MAP_HESS_EIG_FLOOR`.

# Returns
- `(λ, V)`: floored eigenvalues and eigenvectors, H ≈ V·diag(λ)·Vᵀ.
"""
function _floored_eigen(H::SMatrix{N,N,Float64}) where {N}
    E = eigen(Symmetric(Matrix(H)))
    λ = SVector{N}(max.(E.values, MAP_HESS_EIG_FLOOR))
    return λ, SMatrix{N,N}(E.vectors)
end

"""
The L-BFGS machinery of the MAP search, as a closure: `run(z)` minimizes −log π (c1
profiled to `EXCL_VOL_CORR_TOL`, the density NUTS samples) from `z`, and returns
`(z, f, evals)` of the optimum, or `nothing` if the start is infeasible or ends
non-finite. `f` is the objective itself.
"""
function _lbfgs_runner(
    seed::Seed{<:Real,N};
    f_abstol::Real = MAP_F_ABSTOL,
    successive_f_tol::Int = MAP_F_SUCCESSIVE,
) where {N}
    μ, σ = θ_prior_moments(seed.pr)
    f = z -> _neglogπ(SVector{N}(z...), μ, σ, seed, EXCL_VOL_CORR_TOL)
    fg! = (G, z) -> begin
        gc_checkpoint()
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
        iterations = MAP_MAX_ITER,
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
            return (z = SVector{N}(minimizer(res)...), f = v, evals = Optim.f_calls(res))
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
    H = _fd_hessian(z, MAP_HESS_STEP .* ones(SVector{N,Float64}), μ, σ, seed)
    I_N = one(SMatrix{N,N,Float64})
    if !all(isfinite, H)
        return _Optimum(z, f, SVector{N}(ntuple(_ -> NaN, Val(N))), I_N, NaN)
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
function _farthest_cover(W::AbstractMatrix{<:Real}, k::Int, first::Int)
    n = size(W, 1)
    taken = [first]
    d = [sqrt(sum(abs2, @view(W[i, :]) .- @view(W[first, :]))) for i in 1:n]
    while length(taken) < min(k, n)
        j = argmax(d)
        d[j] > 0 || break
        push!(taken, j)
        for i in 1:n
            d[i] = min(d[i], sqrt(sum(abs2, @view(W[i, :]) .- @view(W[j, :]))))
        end
    end
    return taken
end

"""
Pre-NUTS MAP search and Laplace whitening (see the note at the top of `MAP.jl`).

L-BFGS runs from the seed's θ₀ and `MAP_N_STARTS - 1` further prior draws (and any
`extra_starts`), on −log π in prior-standardized z-space with c1 profiled to
`EXCL_VOL_CORR_TOL` (the same objective NUTS then samples). A second round of L-BFGS
runs then starts around the optima found: from [`MAP_JITTER_RADII`](@ref) ×
[`MAP_JITTER_DIRECTIONS`](@ref) points at distances from each optimum measured in
its own Hessian (at most [`MAP_JITTER_MAX_OPTIMA`](@ref) optima, those within
[`MAP_JITTER_WITHIN_NATS`](@ref) of the lowest), which reaches basins next to the ones
already found that random starts rarely hit. The distinct basins among all the optima
(Mahalanobis distance under the Hessian at the lowest one) are compared by their Laplace
mass, `−f − ½ log det H`, for the best `MAP_MAX_BASINS` of them: a narrow basin can have
the lowest f and still carry less mass than a wide one. The heaviest basin's optimum is the
MAP ẑ. Its Hessian is taken in two central-difference passes: step `MAP_HESS_STEP`, then
`MAP_HESS_REL_STEP` × each coordinate's Laplace σ from the first pass.

# Arguments
- `seed::Seed`: priors, data, forward cache and c1 tables; `seed.θ₀` is the first start.

# Keywords
- `f_abstol`, `successive_f_tol`: the f-based stopping rule of each L-BFGS start.
- `base::UInt64`: the run's random base value; start `i ≥ 2` draws its
    prior sample from the stream `stream(base, _RNG_MAP_STARTS, i)`, and the jittered
    start `j` its direction from `stream(base, _RNG_MAP_JITTER, j)`.
    Default: a fresh draw from the default RNG.
- `extra_starts`: further L-BFGS starts in z-space (the sampler passes the
    best draw of a first round of chains here, to re-whiten at a better basin).

# Returns
- [`_SamplingSpace`](@ref). If no start reaches a finite optimum, ẑ is the seed's
    z₀ and S the identity (plain prior standardization, as without this step). If the
    Hessian is non-finite, ẑ is kept and S is the identity.
"""
function _sampling_space(
    seed::Seed{<:Real,N};
    f_abstol::Real = MAP_F_ABSTOL,
    successive_f_tol::Int = MAP_F_SUCCESSIVE,
    base::UInt64 = draw_base(),
    extra_starts::AbstractVector = SVector{N,Float64}[],
)::_SamplingSpace where {N}
    μ, σ = θ_prior_moments(seed.pr)
    run = _lbfgs_runner(seed; f_abstol, successive_f_tol)
    L = N * N
    no_optima = _Optimum{N,L}[]

    z₀ = _standardize(seed.θ₀, seed.pr)
    # start i ≥ 2 draws from its own stream, so the
    # starts do not depend on the order they run in
    starts = vcat(
        [z₀],
        [
            _standardize(
                Θ(_ξ₀(seed.pr, stream(base, _RNG_MAP_STARTS, i)), seed.pr)[1],
                seed.pr,
            )
            for i in 2:MAP_N_STARTS
        ],
        [SVector{N,Float64}(z) for z in extra_starts],
    )
    # serial on purpose: the whole search is ~8 ms warm (a start is ~1 ms), so
    # threading it was measured slower (0.71× at 4 threads, test/validation/threading/)
    optima = Tuple{SVector{N,Float64},Float64}[]
    n_evals = 0
    n_try = 0
    function search!(zs)
        n_try += 1
        r = run(zs)
        r === nothing && return
        n_evals += r.evals
        push!(optima, (r.z, r.f))
        return
    end
    foreach(search!, starts)
    I_N = one(SMatrix{N,N,Float64})
    isempty(optima) &&
        return _SamplingSpace(μ, σ, z₀, I_N, 0, n_try, 0, false, n_evals, NaN, no_optima)

    sort!(optima; by = last)            # lowest −log π first
    ẑ, f_mode = optima[1]
    h₀ = MAP_HESS_STEP .* ones(SVector{N,Float64})
    memo = Dict{SVector{N,Float64},_Optimum{N,L}}()
    mk(z, f) = get!(() -> _optimum(z, f, μ, σ, seed), memo, z)

    # distinct basins: the lowest optimum of each (Mahalanobis distance under `Hm`)
    function basins(Hm)
        reps = Int[]
        for (i, (z, _)) in enumerate(optima)
            any(
                j -> sqrt((z - optima[j][1])' * Hm * (z - optima[j][1])) ≤ MAP_MODE_SEP,
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

    o₁ = mk(ẑ, f_mode)
    all(isfinite, o₁.λ) || return _SamplingSpace(
        μ, σ, ẑ, I_N, length(optima), n_try, 1, false, n_evals, -f_mode, [o₁],
    )

    # the second round: jittered starts around the distinct optima of the first
    ctr = 0
    for i in basins(metric(o₁))[1:min(end, MAP_JITTER_MAX_OPTIMA)]
        zᵢ, fᵢ = optima[i]
        fᵢ ≤ f_mode + MAP_JITTER_WITHIN_NATS || continue
        oᵢ = mk(zᵢ, fᵢ)
        all(isfinite, oᵢ.λ) || continue
        half = oᵢ.V .* (1 ./ sqrt.(max.(oᵢ.λ, MAP_HESS_EIG_FLOOR)))' # z = zᵢ + half·u
        for r in MAP_JITTER_RADII, _ in 1:MAP_JITTER_DIRECTIONS
            ctr += 1
            u = randn(stream(base, _RNG_MAP_JITTER, ctr), N)
            search!(zᵢ + r .* (half * SVector{N}(u ./ sqrt(sum(abs2, u)))))
        end
    end
    sort!(optima; by = last)
    if optima[1][1] != ẑ                 # a jittered start found a lower optimum
        ẑ, f_mode = optima[1]
        o₁ = mk(ẑ, f_mode)
        all(isfinite, o₁.λ) || return _SamplingSpace(
            μ, σ, ẑ, I_N, length(optima), n_try, 1, false, n_evals, -f_mode, [o₁],
        )
    end
    λ₁, V₁ = max.(o₁.λ, MAP_HESS_EIG_FLOOR), o₁.V
    H₁f = V₁ * (λ₁ .* V₁')

    # The heaviest basin, not just the lowest optimum: representatives of the
    # distinct basins (the lowest optimum of each, Mahalanobis distance under H₁),
    # the best MAP_MAX_BASINS of them compared by Laplace mass −f − ½ log det H
    # (eigenvalues floored, as for the whitening).
    reps = basins(H₁f)
    found = [mk(optima[i]...) for i in reps[1:min(end, MAP_MAX_BASINS)]]
    mass₁ = -f_mode - sum(log, λ₁) / 2
    for o in found[2:end]
        all(isfinite, o.λ) || continue
        λᵢ, Vᵢ = max.(o.λ, MAP_HESS_EIG_FLOOR), o.V
        massᵢ = -o.f - sum(log, λᵢ) / 2
        if massᵢ > mass₁
            ẑ, f_mode, mass₁, λ₁, V₁ = o.z, o.f, massᵢ, λᵢ, Vᵢ
        end
    end
    σ_lap = sqrt.(diag(V₁ * ((1 ./ λ₁) .* V₁')))   # Laplace σ per coordinate
    H = _fd_hessian(ẑ, MAP_HESS_REL_STEP .* σ_lap, μ, σ, seed)
    all(isfinite, H) || (H = SMatrix{N,N}(V₁ * (λ₁ .* V₁')))
    λ, V = _floored_eigen(H)

    # distinct modes: greedy clustering of the optima, Mahalanobis distance under H
    Hf = V * (λ .* V')
    modes = SVector{N,Float64}[]
    for (z, _) in optima
        any(m -> sqrt((z - m)' * Hf * (z - m)) ≤ MAP_MODE_SEP, modes) || push!(modes, z)
    end
    S = V .* (1 ./ sqrt.(λ))'    # V·diag(λ)^(-1/2): Sᵀ·H·S = I
    return _SamplingSpace(
        μ, σ, ẑ, S, length(optima), n_try, length(modes), true, n_evals, -f_mode, found,
    )
end

"""
Optima the chains visit that the MAP search did not report. L-BFGS runs from a
farthest-point cover ([`_farthest_cover`](@ref)) of `HARVEST_COVER` of the draws `W`
(rows, in the whitened coordinates of `sp`; the one of highest log density `ld` first)
and of up to `HARVEST_DIVERGENT` of the divergent ones (`diverged`). Each optimum that
is not within `MAP_MODE_SEP` (Mahalanobis, under the Hessian of `sp`) of one already
known is added with its Laplace mass.

# Returns
- `(optima::Vector{_Optimum}, n_evals::Int)`: `sp.optima` and the new
    ones, lowest −log π first, and the evaluations of the L-BFGS runs.
"""
function _harvest_optima(
    seed::Seed{<:Real,N},
    sp::_SamplingSpace{N,L},
    W::AbstractMatrix{<:Real},
    ld::AbstractVector{<:Real},
    diverged::AbstractVector{Bool};
    f_abstol::Real = MAP_F_ABSTOL,
    successive_f_tol::Int = MAP_F_SUCCESSIVE,
) where {N,L}
    n = size(W, 1)
    n == 0 && return sp.optima, 0
    run = _lbfgs_runner(seed; f_abstol, successive_f_tol)
    rows = _farthest_cover(W, HARVEST_COVER, argmax(ld))
    dv = findall(diverged)
    if !isempty(dv)
        append!(rows, dv[_farthest_cover(W[dv, :], HARVEST_DIVERGENT, 1)])
    end
    Hf = inv(sp.S * sp.S')
    known = copy(sp.optima)
    n_evals = 0
    for i in unique(rows)
        r = run(sp.ẑ + sp.S * SVector{N,Float64}(W[i, :]))
        r === nothing && continue
        n_evals += r.evals
        any(o -> sqrt((r.z - o.z)' * Hf * (r.z - o.z)) ≤ MAP_MODE_SEP, known) && continue
        push!(known, _optimum(r.z, r.f, sp.μ, sp.σ, seed))
    end
    sort!(known; by = o -> o.f)
    return known, n_evals
end
