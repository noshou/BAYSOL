# SPDX-License-Identifier: LGPL-3.0-or-later

# The log-posterior in the sampled coordinates: the
# likelihood, the prior and the Jacobian.

"""
Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The forward
model produces a predicted curve `y_model(q)`, but the data `I_exp(q)` sits at
some unknown overall scale scale and background offset `bkgrnd_corr`, i.e.
`I_calc` = scale·`y_model` + `bkgrnd_corr`. `wls_fit` (ProfiledCorrs.jl) fits
(scale, `bkgrnd_corr`) in closed form (2-parameter weighted linear regression),
and the likelihood is the profile log-likelihood: (scale, `bkgrnd_corr`) are
pinned at their best-fit values (a point estimate), [`wls_prof_ll`](@ref):

    -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

# Arguments
-   `wls::WLSData`: precomputed data-only weighted sums over (`I_exp`, `σ_exp`),
    from [`WLSData`](@ref); forwarded to [`profiled_corrs`](@ref).
-   `ξ::SVector{N,<:Real}`: the physical fit parameters, (ρₑ, δρ₁, δρ₂, δρ₃) for `N = 4`.
-   `fw::ForwardCache`: the structure's static cache, from
    [`BAYSOL.Scattering.forward_cache`](@ref).

# Keywords
- `tab::Union{Nothing,_C1Tables} = nothing`, `c1_tol = EXCL_VOL_CORR_TOL`: forwarded to
    [`profiled_corrs`](@ref) as `tables`/`tol`.

# Returns
- `Real`: the log-likelihood, composing by addition with the log-prior terms.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{N,<:Real},
    fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N}
    _, fit, _ = profiled_corrs(wls, ξ, fw; tables = tab, tol = c1_tol)
    return wls_prof_ll(fit)
end

"""
[`_ll`](@ref) at a ForwardDiff dual ξ: the
value and the gradient with respect to ξ come from [`_profile_ll_grad`](@ref)
(analytic, no dual-number vectors through the forward model), and are
composed with the partials of ξ, so `ForwardDiff.gradient` of any
function of θ sees the exact chain rule.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{N,D},
    fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N,D<:ForwardDiff.Dual{<:Any,Float64}}
    tb = tab === nothing ? _C1Tables(fw) : tab
    ll, g = _profile_ll_grad(wls, SVector{N,Float64}(ForwardDiff.value.(ξ)), fw, tb, c1_tol)
    parts = ntuple(
        j -> sum(ntuple(k -> g[k] * ForwardDiff.partials(ξ[k], j), Val(N))),
        Val(ForwardDiff.npartials(D)),
    )
    return ForwardDiff.Dual{ForwardDiff.tagtype(D)}(
        ll,
        ForwardDiff.Partials(parts),
    )
end

"""
Log prior density of ξ = (ρₑ, δρ₁, δρ₂, δρ₃) in ξ-space. The δρ `LocationScale`
priors carry their own -ln W terms.
"""
_lp(ξ::SVector{4,<:Real}, p::ξ_priors) =
    logpdf(p.ρₑPrior, ξ[1]) +
    logpdf(p.δρ₁Prior, ξ[2]) +
    logpdf(p.δρ₂Prior, ξ[3]) +
    logpdf(p.δρ₃Prior, ξ[4])

"""
By change of variables, a density trasnfromed from ξ-space into θ-space picks
up the Jacobian of ξ(θ):

    log π(θ) = log p(ξ(θ)) + log|det(∂ξ/∂θ)|

Every coordinate is reparameterized (see [`Θ`](@ref)):

    - ρₑ  = eᵃ
    - δρ₁ = -10 + 12·σ(t₁)
    - δρ₂ = -10 + 12·σ(t₂)
    - δρ₃ = L₃ + W₃·σ(t₃)

So ∂ξ/∂θ is diagonal, giving:

    log|det(∂ξ/∂θ)| = a + Σₖ [ln Wₖ + ln σ(tₖ) + ln(1 - σ(tₖ))] ([`logjac`](@ref))

with W₁ = W₂ = 12 and (L₃, W₃) the δρ₃ prior's location and scale.

log p(ξ(θ)) is the sum of the log-prior and log-likelihood:

    log p(ξ | data) = log p(ξ) + log p(data | ξ) = _lp(ξ, p) + _ll(wls, ξ, fw)

giving:

    log π(θ) = _lp(ξ(θ), p) + _ll(wls, ξ(θ), fw) + logjac(θ)

# Arguments
- `θ::SVector{N,<:Real}`: the current NUTS position, (a, t₁, t₂, t₃) for `N = 4`.
- `p::ξ_priors`: the physical priors, forwarded to [`_lp`](@ref).
- `wls::WLSData`: the precomputed data, forwarded to [`_ll`](@ref).
- `fw::ForwardCache`: the structure's geometry-only cache, forwarded to [`_ll`](@ref).

# Keywords
- `tab`, `c1_tol`: forwarded to [`_ll`](@ref).

# Returns
- `Real`: log π(θ), up to the additive constant NUTS doesn't need.
"""
function _logπ(
    θ::SVector{N,<:Real},
    p::ξ_priors,
    wls::WLSData,
    fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N}
    ξ = Ξ(θ, p)  # unconstrained θ-space -> physical ξ-space
    return _lp(ξ, p) + _ll(wls, ξ, fw; tab = tab, c1_tol = c1_tol) + logjac(θ, p)
end
