# SPDX-License-Identifier: LGPL-2.1-or-later

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
    _SamplingSpace

The affine map from NUTS's coordinates w to θ-space, θ = μ + σ·(ẑ + S·w), plus what
the MAP search found. Immutable, built once per [`run_fitting`](@ref) call.

# Fields
- `μ`, `σ::SVector{4,Float64}`: the prior standardization, from [`θ_prior_moments`](@ref).
- `ẑ::SVector{4,Float64}`: the MAP in z-space (the seed's z₀ if every start failed).
- `S::SMatrix{4,4,Float64,16}`: the whitening matrix (identity if the Hessian was unusable).
- `n_ok::Int`: L-BFGS starts that reached a finite optimum.
- `n_modes::Int`: distinct optima among them (Mahalanobis distance > `MAP_MODE_SEP`
    under the MAP Hessian).
- `whitened::Bool`: whether `S` comes from the Hessian (`false`: identity fallback).
- `n_evals::Int`: objective evaluations (value and gradient) over all L-BFGS starts.
"""
struct _SamplingSpace
    μ::SVector{4,Float64}
    σ::SVector{4,Float64}
    ẑ::SVector{4,Float64}
    S::SMatrix{4,4,Float64,16}
    n_ok::Int
    n_modes::Int
    whitened::Bool
    n_evals::Int
end

"θ = μ + σ·(ẑ + S·w): NUTS coordinates w to θ-space (see [`_SamplingSpace`](@ref))."
_θ_of_w(w::SVector{4,<:Real}, sp::_SamplingSpace) = sp.μ .+ sp.σ .* (sp.ẑ .+ sp.S * w)

"""
−log π at prior-standardized z, with c1 profiled to `tol`. Non-finite values and
`WLSError` (a flat model curve) map to `+Inf`, so the L-BFGS line search backs off.

# Returns
- `Real`: −log π(θ(z)), or `+Inf`.
"""
function _neglogπ(z::SVector{4,T}, μ, σ, seed::Seed, l::LIKELIHOOD, tol::Float64)::T where {T<:Real}
    v = try
        -_logπ(μ .+ σ .* z, seed.pr, seed.wls, seed.fw, l; tab = seed.c1tab, c1_tol = tol)
    catch e
        e isa WLSError || rethrow()
        return T(Inf)
    end
    return isfinite(v) ? v : T(Inf)
end

"""
Gradient of [`_neglogπ`](@ref) at z (one ForwardDiff pass).

# Returns
- `SVector{4,Float64}` (non-finite where −log π is `+Inf`).
"""
function _neglogπ_grad(z::SVector{4,Float64}, μ, σ, seed::Seed, l::LIKELIHOOD, tol::Float64)
    return ForwardDiff.gradient(x -> _neglogπ(x, μ, σ, seed, l, tol), z)
end

"""
Symmetrized central-difference Hessian of [`_neglogπ`](@ref) at z, step `h[i]` along
coordinate i, from its envelope-theorem gradient, with c1 profiled to
`EXCL_VOL_CORR_TOL`.

# Returns
- `SMatrix{4,4,Float64}`: may contain non-finite entries if a probe hit a flat model.
"""
function _fd_hessian(z::SVector{4,Float64}, h::SVector{4,Float64}, μ, σ, seed::Seed, l::LIKELIHOOD)
    cols = ntuple(4) do i
        e = SVector(ntuple(j -> j == i ? h[i] : 0.0, 4))
        (_neglogπ_grad(z + e, μ, σ, seed, l, EXCL_VOL_CORR_TOL) -
        _neglogπ_grad(z - e, μ, σ, seed, l, EXCL_VOL_CORR_TOL)) / (2h[i])
    end
    H = hcat(cols...)
    return (H + H') / 2
end

"""
Eigen-decompose a symmetric Hessian and floor its eigenvalues at `MAP_HESS_EIG_FLOOR`.

# Returns
- `(λ, V)`: floored eigenvalues and eigenvectors, H ≈ V·diag(λ)·Vᵀ.
"""
function _floored_eigen(H::SMatrix{4,4,Float64})
    E = eigen(Symmetric(Matrix(H)))
    λ = SVector{4}(max.(E.values, MAP_HESS_EIG_FLOOR))
    return λ, SMatrix{4,4}(E.vectors)
end

"""
Pre-NUTS MAP search and Laplace whitening (see the note at the top of `MAP.jl`).

L-BFGS runs from the seed's θ₀ and `MAP_N_STARTS - 1` further prior draws, on
−log π in prior-standardized z-space with c1 profiled to `EXCL_VOL_CORR_TOL`
(the same objective NUTS then samples). The best optimum is the MAP ẑ. Its Hessian is
taken in two central-difference passes: step `MAP_HESS_STEP`, then
`MAP_HESS_REL_STEP` × each coordinate's Laplace σ from the first pass.

# Arguments
- `seed::Seed`: priors, data, forward cache and c1 tables; `seed.θ₀` is the first start.
- `l::LIKELIHOOD`: `PROFILE()` or `MARGINAL()`, as [`_logπ`](@ref).

# Returns
- [`_SamplingSpace`](@ref). If no start reaches a finite optimum, ẑ is the seed's
    z₀ and S the identity (plain prior standardization, as without this step). If the
    Hessian is non-finite, ẑ is kept and S is the identity.
"""
function _sampling_space(seed::Seed, l::LIKELIHOOD;
                         f_abstol::Real = MAP_F_ABSTOL, successive_f_tol::Int = MAP_F_SUCCESSIVE)::_SamplingSpace
    μ, σ = θ_prior_moments(seed.pr)
    f  = z -> _neglogπ(SVector{4}(z...), μ, σ, seed, l, EXCL_VOL_CORR_TOL)
    fg! = (G, z) -> begin
        dr = DiffResults.GradientResult(z)
        ForwardDiff.gradient!(dr, f, z)
        G === nothing || (G .= DiffResults.gradient(dr))
        DiffResults.value(dr)
    end
    g! = (G, z) -> (fg!(G, z); G)
    opts = Options(g_abstol = MAP_G_TOL, f_abstol = f_abstol, successive_f_tol = successive_f_tol,
                   iterations = MAP_MAX_ITER)

    z₀ = _standardize(seed.θ₀, seed.pr)
    starts = vcat([z₀], [_standardize(Θ(_ξ₀(seed.pr), seed.pr)[1], seed.pr) for _ in 2:MAP_N_STARTS])
    optima = Tuple{SVector{4,Float64},Float64}[]
    n_evals = 0
    for zs in starts
        isfinite(f(Vector(zs))) || continue
        res = optimize(OnceDifferentiable(f, g!, fg!, Vector(zs)), Vector(zs), LBFGS(), opts)
        n_evals += Optim.f_calls(res)
        v = Optim.minimum(res)
        isfinite(v) && push!(optima, (SVector{4}(minimizer(res)...), v))
    end
    I4 = one(SMatrix{4,4,Float64})
    isempty(optima) && return _SamplingSpace(μ, σ, z₀, I4, 0, 0, false, n_evals)

    ẑ = optima[argmin(last.(optima))][1]
    H₁ = _fd_hessian(ẑ, MAP_HESS_STEP .* ones(SVector{4,Float64}), μ, σ, seed, l)
    all(isfinite, H₁) || return _SamplingSpace(μ, σ, ẑ, I4, length(optima), 1, false, n_evals)
    λ₁, V₁ = _floored_eigen(H₁)
    σ_lap = sqrt.(diag(V₁ * ((1 ./ λ₁) .* V₁')))   # Laplace σ per coordinate
    H = _fd_hessian(ẑ, MAP_HESS_REL_STEP .* σ_lap, μ, σ, seed, l)
    all(isfinite, H) || (H = H₁)
    λ, V = _floored_eigen(H)

    # distinct modes: greedy clustering of the optima, Mahalanobis distance under H
    Hf = V * (λ .* V')
    modes = SVector{4,Float64}[]
    for (z, _) in optima
        any(m -> sqrt((z - m)' * Hf * (z - m)) ≤ MAP_MODE_SEP, modes) || push!(modes, z)
    end
    S = V .* (1 ./ sqrt.(λ))'    # V·diag(λ)^(-1/2): Sᵀ·H·S = I
    return _SamplingSpace(μ, σ, ẑ, S, length(optima), length(modes), true, n_evals)
end
