# SPDX-License-Identifier: LGPL-2.1-or-later

using StaticArrays
using Optim: minimizer, optimize, Brent
using ForwardDiff
using ..Scattering: ForwardCache, excluded_volume_factor, intensity_terms, model_intensity, EV_EXP_COEFF
using ..PhysicalConstants: DRO_UNIT
using Bumper: @no_escape, @alloc
using FastClosures

# ---------------------------------------------------------------------------
# c1 only enters through the excluded-volume envelope g(q; c1), so for a fixed ξ the
# model curve is ŷ(q; c1) = A(q) + g·B(q) + g²·C(q) with A, B, C from
# `Scattering.intensity_terms` (the contrast contraction lives in Scattering; see its
# docstring). A, B, C are built once per ξ; the scan reads g from a static table and
# each Brent step costs one exp per q, instead of a full forward pass per trial c1.
# What is fitting, and so lives here: the weighted χ² of ŷ against the data, the c1
# scan and Brent polish, and the saturation test.
# ---------------------------------------------------------------------------

"""
    _C1Tables

Static per-run tables for [`profiled_corrs`](@ref)'s c1 search: everything that depends
only on the structure's [`ForwardCache`](@ref BAYSOL.Scattering.ForwardCache) and the scan
settings, not on ξ. Built once (by [`seed_fitting`](@ref), or on the fly), then only ever
read: no field is modified after construction, so one instance can be shared by any
number of threads. Per-evaluation scratch is never stored here.

# Fields
- `cs::Vector{Float64}`: the scan points (cmin − eps):eps:(cmax + eps).
- `g1::Matrix{Float64}`, (Q, length(cs)): g(q; cᵢ) at every scan point.
- `qvals::Vector{Float64}`, `r_m::Float64`: the grid and mean atomic radius g is built on.
- `cmin`, `cmax`, `eps::Float64`: the scan settings the tables were built for.
"""
struct _C1Tables
    cs::Vector{Float64}
    g1::Matrix{Float64}
    qvals::Vector{Float64}
    r_m::Float64
    cmin::Float64
    cmax::Float64
    eps::Float64
end

"""
Build the static c1-search tables for `fw` (see [`_C1Tables`](@ref)). 
g is evaluated with `Scattering.excluded_volume_factor`, the same 
function the forward model uses.

# Keywords
- `cmin, cmax = EXCL_VOL_CORR_BOUNDS`
- `eps = EXCL_VOL_CORR_EPS`

# Returns
- `_C1Tables`.
"""
function _C1Tables(
    fw::ForwardCache;
    cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
    cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
    eps::Float64=EXCL_VOL_CORR_EPS,
)::_C1Tables
    Q = length(fw.qvals)
    cs = collect(Float64, (cmin - eps):eps:(cmax + eps))
    g1 = Matrix{Float64}(undef, Q, length(cs))
    for (i, c) in enumerate(cs)
        g1[:, i] = excluded_volume_factor(fw.qvals, fw.r_m, c)
    end
    return _C1Tables(cs, g1, copy(fw.qvals), fw.r_m, cmin, cmax, eps)
end

"""
The three model-dependent weighted sums of the fit, Σwŷ, Σwŷ², Σwŷ·I, for
ŷ = A + g·B + g²·C at one arbitrary c1, in a single fused pass with g evaluated on
the fly (the Brent step). Same g formula as `Scattering.excluded_volume_factor`.

# Returns
- `(SwI, SwII, SwIy)::NTuple{3,Float64}`.
"""
function _sums_at(
    A::AbstractVector{Float64},
    B::AbstractVector{Float64},
    C::AbstractVector{Float64},
    tab::_C1Tables, 
    wls::WLSData, 
    c1::Float64
)
    k = (c1^2 - 1) * EV_EXP_COEFF * tab.r_m^2
    c3 = c1^3
    
    q = tab.qvals
    w = wls.weights
    y = wls.I_obs
    
    SwI  = 0.0
    SwII = 0.0
    SwIy = 0.0
    
    @inbounds @fastmath @simd for i in eachindex(q)
        g = c3 * exp(-(q[i]^2) * k)
        ŷ = A[i] + g * (B[i] + g * C[i])
        wŷ = w[i] * ŷ
        SwI += wŷ
        SwII += wŷ * ŷ
        SwIy += wŷ * y[i]
    end
    return SwI, SwII, SwIy
end

"""
Reduced χ² at every scan point of `tab` for ŷ = A + g·B + g²·C, without forming ŷ.
Expanding the sums in powers of g,

    Σwŷ   = ⟨w, A⟩  + Σ g·(wB + g·wC)
    Σwŷ·I = ⟨wI, A⟩ + Σ g·(wIB + g·wIC)
    Σwŷ²  = ⟨w, A²⟩ + Σ g·(2wAB + g·(w(B² + 2AC) + g·(2wBC + g·wC²))),

the seven coefficient vectors are built once in a fused pass, then each scan point is
one fused `@simd` pass over q in Horner form (three accumulators, g read from `tab.g1`).

Writes into `chis` (length `length(tab.cs)`) and takes the eight length-Q work vectors from the task's Bumper
buffer, so the call allocates nothing on the heap. `A`, `B`, `C` may be Bumper arrays.

# Arguments
- `chis::AbstractVector{Float64}`: output, one entry per scan point.

# Returns
- `chis`: the reduced χ² per scan point.

# Exceptions
- `WLSError`: as [`wls_fit`](@ref), if the model is flat at a scan point.
"""
function _scan_chi2!(
    chis::AbstractVector{Float64},
    A::AbstractVector{Float64},
    B::AbstractVector{Float64},
    C::AbstractVector{Float64},
    tab::_C1Tables,
    wls::WLSData
)
    Q = length(A)
    w = wls.weights
    y = wls.I_obs
    g1 = tab.g1
    @no_escape begin
        r11 = @alloc(Float64, Q)   # Σwŷ: wB
        r21 = @alloc(Float64, Q)   # Σwŷ: wC
        r12 = @alloc(Float64, Q)   # Σwŷ·I: wIB
        r22 = @alloc(Float64, Q)   # Σwŷ·I: wIC
        r13 = @alloc(Float64, Q)   # Σwŷ²: 2wAB
        r23 = @alloc(Float64, Q)   # Σwŷ²: w(B² + 2AC)
        r33 = @alloc(Float64, Q)   # Σwŷ²: 2wBC
        r43 = @alloc(Float64, Q)   # Σwŷ²: wC²

        SA = 0.0; SAy = 0.0; SA2 = 0.0      # ⟨w, A⟩, ⟨wI, A⟩, ⟨w, A²⟩
        @inbounds @fastmath @simd for i in 1:Q
            wi = w[i]
            a = A[i]; b = B[i]; c = C[i]; wy = wi * y[i]
            SA += wi * a; SAy += wy * a; SA2 += wi * a * a
            r11[i] = wi * b;      r21[i] = wi * c
            r12[i] = wy * b;      r22[i] = wy * c
            r13[i] = 2wi * a * b; r23[i] = wi * (b * b + 2a * c)
            r33[i] = 2wi * b * c; r43[i] = wi * c * c
        end
        @inbounds for j in eachindex(chis)
            SwI = 0.0; SwIy = 0.0; SwII = 0.0
            @fastmath @simd for i in 1:Q
                g = g1[i, j]
                SwI  += g * (r11[i] + g * r21[i])
                SwIy += g * (r12[i] + g * r22[i])
                SwII += g * (r13[i] + g * (r23[i] + g * (r33[i] + g * r43[i])))
            end
            chis[j] = reduced_chi2(_wls_from_sums(SA + SwI, SA2 + SwII, SAy + SwIy, Q, wls))
        end
    end
    return chis
end

"""
The profiled c1 for given A, B, C: the coarse scan over the precomputed g table, then `Brent()` inside the
bracket of the best scan point, to an absolute tolerance `tol` on c1 (see [`profiled_corrs`](@ref)). The scan's
work vectors come from the Bumper buffer.

# Returns
- `Float64`: the c1 minimising the reduced χ² (within the padded window `cmin - eps .. cmax + eps`).
"""
function _c1_search(
    A::AbstractVector{Float64}, B::AbstractVector{Float64}, C::AbstractVector{Float64}, tab::_C1Tables, wls::WLSData, tol::Float64,
)::Float64
    n = length(A)
    cs = tab.cs
    lo, hi = tab.cmin - tab.eps, tab.cmax + tab.eps
    lo_b = lo; hi_b = hi
    @no_escape begin
        chis = @alloc(Float64, length(cs))
        _scan_chi2!(chis, A, B, C, tab, wls)
        i_best = argmin(chis)
        lo_b = i_best == 1          ? lo : cs[i_best-1]
        hi_b = i_best == length(cs) ? hi : cs[i_best+1]
    end

    # polish: Brent on the same objective, one fused pass per step.
    # No assignments inside the closure: a name assigned both in a closure and in
    # this enclosing body is one shared, Core.Box'ed variable (type-unstable).
    χ²_at_c1 = @closure c1 -> reduced_chi2(_wls_from_sums(_sums_at(A, B, C, tab, wls, c1)..., n, wls))
    return minimizer(optimize(χ²_at_c1, lo_b, hi_b, Brent(); abs_tol = tol, rel_tol = 0.0))
end

"""
[`intensity_terms`](@ref) for Float64 arguments, writing A, B, C in place (column by column over the packed Gram
matrix `Gc`) and taking `s1, s2, s3 = DRO_UNIT·(δρ₁, δρ₂, δρ₃)`: no heap allocation.
"""
function _intensity_terms!(
    A::AbstractVector{Float64}, B::AbstractVector{Float64}, C::AbstractVector{Float64},
    Gc::Matrix{Float64}, ρ::Float64, s1::Float64, s2::Float64, s3::Float64,
)
    Q = size(Gc, 1)
    kA = (1.0, 2s1, 2s2, 2s3, s1 * s1, 2s1 * s2, 2s1 * s3, s2 * s2, 2s2 * s3, s3 * s3)
    kB = (-2ρ, -2ρ * s1, -2ρ * s2, -2ρ * s3)
    ρ2 = ρ * ρ
    @inbounds @fastmath @simd for q in 1:Q
        A[q] = kA[1] * Gc[q, 1]
        B[q] = kB[1] * Gc[q, 11]
        C[q] = ρ2 * Gc[q, 15]
    end
    @inbounds for c in 2:10
        k = kA[c]
        @fastmath @simd for q in 1:Q
            A[q] += k * Gc[q, c]
        end
    end
    @inbounds for c in 2:4
        k = kB[c]
        @fastmath @simd for q in 1:Q
            B[q] += k * Gc[q, 10 + c]
        end
    end
    return nothing
end

"Σᵢ Gc[i, c]·v[i] over one column of the packed Gram matrix."
function _dotcol(Gc::Matrix{Float64}, c::Int, v::AbstractVector{Float64})
    s = 0.0
    @inbounds @fastmath @simd for i in eachindex(v)
        s += Gc[i, c] * v[i]
    end
    return s
end

"""
The profile log-likelihood of [`wls_prof_ll`](@ref) at ξ, with its gradient with respect to ξ, without automatic
differentiation: the model is ŷ = A + g·B + g²·C with A, B, C linear/quadratic in (ρₑ, s = DRO_UNIT·δρ) through the
packed Gram matrix, and scale, background and c1 are optima of the same objective, so (envelope theorem) the
gradient of the profiled χ² is its partial gradient at the fitted scale m, background b and c1:

    ∂ℓ/∂ξₖ = m · Σᵢ pᵢ ∂ŷᵢ/∂ξₖ,    pᵢ = wᵢ(Iᵢ − m·ŷᵢ − b).

The contractions Σᵢ pᵢ·gⁿ·Gc[i, c] for the 15 Gram columns are all it needs. This is the same quantity that
ForwardDiff gave through `profiled_corrs` (c1 held at its profiled value), without the dual-number vectors.
All temporaries are Bumper-allocated.

# Keywords
- `c1::Union{Nothing,Float64} = nothing`: evaluate at this c1 instead of searching for it (the tests compare the
    formula with ForwardDiff at one and the same c1, since the gradient depends on c1 to first order).

# Returns
- `(ll::Float64, ∇ξℓ::SVector{4,Float64})`.

# Exceptions
- `WLSError`: as [`wls_fit`](@ref), if the model is flat.
"""
function _profile_ll_grad(
    wls::WLSData, ξ::SVector{4,Float64}, fw::ForwardCache, tab::_C1Tables, tol::Float64;
    c1::Union{Nothing,Float64} = nothing,
)::Tuple{Float64,SVector{4,Float64}}
    c1_fixed = c1
    Gc = fw.Gc
    Q = size(Gc, 1)
    ρ = ξ[1]; s1 = DRO_UNIT * ξ[2]; s2 = DRO_UNIT * ξ[3]; s3 = DRO_UNIT * ξ[4]
    q = tab.qvals; w = wls.weights; y = wls.I_obs
    ll = 0.0
    grad = SVector(0.0, 0.0, 0.0, 0.0)
    @no_escape begin
        A = @alloc(Float64, Q); B = @alloc(Float64, Q); C = @alloc(Float64, Q)
        _intensity_terms!(A, B, C, Gc, ρ, s1, s2, s3)
        c1 = c1_fixed === nothing ? _c1_search(A, B, C, tab, wls, tol) : c1_fixed
        fit = _wls_from_sums(_sums_at(A, B, C, tab, wls, c1)..., Q, wls)
        m = fit.scale; b = fit.bkgrnd_corr

        p = @alloc(Float64, Q); pg = @alloc(Float64, Q); pgg = @alloc(Float64, Q)
        k = (c1^2 - 1) * EV_EXP_COEFF * tab.r_m^2
        c3 = c1^3
        @inbounds @fastmath @simd for i in 1:Q
            g = c3 * exp(-(q[i]^2) * k)
            ŷ = A[i] + g * (B[i] + g * C[i])
            pi_ = w[i] * (y[i] - m * ŷ - b)
            p[i] = pi_; pg[i] = pi_ * g; pgg[i] = pi_ * g * g
        end
        TA = ntuple(c -> _dotcol(Gc, c, p), Val(10))
        TB = ntuple(c -> _dotcol(Gc, 10 + c, pg), Val(4))
        TC = _dotcol(Gc, 15, pgg)

        d_ρ  = -2 * (TB[1] + s1 * TB[2] + s2 * TB[3] + s3 * TB[4]) + 2ρ * TC
        d_s1 = 2TA[2] + 2s1 * TA[5] + 2s2 * TA[6] + 2s3 * TA[7] - 2ρ * TB[2]
        d_s2 = 2TA[3] + 2s1 * TA[6] + 2s2 * TA[8] + 2s3 * TA[9] - 2ρ * TB[3]
        d_s3 = 2TA[4] + 2s1 * TA[7] + 2s2 * TA[9] + 2s3 * TA[10] - 2ρ * TB[4]
        grad = SVector(m * d_ρ, m * DRO_UNIT * d_s1, m * DRO_UNIT * d_s2, m * DRO_UNIT * d_s3)
        ll = wls_prof_ll(fit)
    end
    return ll, grad
end

"""
[`profiled_corrs`](@ref) for a plain Float64 ξ: A, B, C and the c1 search's work vectors come from the Bumper buffer,
ŷ is written in one fused pass (the only heap allocation besides the returned fit), no dual numbers.

# Returns
- `(ŷ::Vector{Float64}, fit::WLSFit, c1_star::Float64)`, as [`profiled_corrs`](@ref).
"""
function _profiled_value(wls::WLSData, ξ::SVector{4,Float64}, fw::ForwardCache, tab::_C1Tables, tol::Float64)
    Q = length(tab.qvals)
    ŷ = Vector{Float64}(undef, Q)
    c1_star = 0.0
    @no_escape begin
        A = @alloc(Float64, Q); B = @alloc(Float64, Q); C = @alloc(Float64, Q)
        _intensity_terms!(A, B, C, fw.Gc, ξ[1], DRO_UNIT * ξ[2], DRO_UNIT * ξ[3], DRO_UNIT * ξ[4])
        c1_star = _c1_search(A, B, C, tab, wls, tol)
        k = (c1_star^2 - 1) * EV_EXP_COEFF * tab.r_m^2
        c3 = c1_star^3
        q = tab.qvals
        @inbounds @fastmath @simd for i in 1:Q
            g = c3 * exp(-(q[i]^2) * k)
            ŷ[i] = A[i] + g * (B[i] + g * C[i])
        end
    end
    return ŷ, wls_fit(ŷ, wls), c1_star
end

"""
Profiles out the correction terms

# Scale and Background Correction
Since the calculated intensity is at an arbitrary scale and
the experimental background correction is likely to be imperfect,
a simple WLS fit minimizing the reduced χ² returns optimal correction factors.

# Excluded Volume Correction
c1 is the correction factor for the Gaussian-blob approximation of
each atom's excluded volume. Finds the c1 that minimizes reduced χ²,
with `scale/bkgrnd_corr` re-fit by `wls_fit` at every trial c1. Unlike
`scale/bkgrnd_corr`, c1 is nonlinear w.r.t. I(q) (see
`Scattering.excluded_volume_factor`'s `c1³·exp(...)` form), so it needs an
iterative 1-D search rather than a closed form fit.

The search is a coarse grid pre-scan followed by a `Brent()` polish, both
gradient-free:

1.  Evaluate reduced χ² on the grid `(cmin-eps):eps:(cmax+eps)` -- cheap
    (one fused pass over q per point, no autodiff), and unlike a purely
    local method this can't miss a second basin at the resolution of `eps`.
    Number of grid points ≈ `((cmax+eps) - (cmin-eps)) / eps + 1`, so
    tightening `eps` for a more precise saturation test.
2.  Bracket the best grid point with its two grid neighbours (or the padded
    edge, if the best point is first/last) and run `Brent()` inside that
    bracket, to an absolute tolerance `tol` on c1.

χ²(c1) is not globally monotone once ξ is badly wrong; 
a bare `Brent()` bracketed only by `(cmin-eps, cmax+eps)` 
could converge to whichever of these basins it starts exploring
toward and would have no way to tell you it missed the other one.

# Arguments
- `wls::WLSData`: precomputed data-only weighted sums over the measured
    intensity/per-point standard errors, from [`WLSData`](@ref); forwarded
    to every trial-c1 call of [`wls_fit`](@ref) inside the inner search
    without rebuilding those sums each time.
- `ξ::SVector{4,<:Real}`: (ρₑ, δρ₁, δρ₂, δρ₃), held fixed during the c1 search. (There is no
    `SVector{5}` method yet; the δρ4 extension is not implemented.)
- `fw::ForwardCache`: the structure's geometry-only cache: its Gram matrix G and
    mean radius `r_m` are all the c1 search reads.

# Keywords
- `cmin, cmax = EXCL_VOL_CORR_BOUNDS`: the physical c1 bounds.
- `eps = EXCL_VOL_CORR_EPS`: both the amount the search window is padded
    past `(cmin, cmax)` and the coarse pre-scan's grid step.
- `tol = EXCL_VOL_CORR_TOL`: absolute tolerance on c1 of the `Brent()` polish. It sets the
    accuracy of the *gradient* taken through this function to first order, not just of c1 (the
    envelope-theorem gradient is exact only at the exact optimum); see [`EXCL_VOL_CORR_TOL`](@ref).
- `tables::Union{Nothing,_C1Tables} = nothing`: static tables for fw and these scan
    settings ([`_C1Tables`](@ref), built once per run by [`seed_fitting`](@ref) and
    read-only, so safe to share across threads). `nothing` builds them for this call.

# Implementation

ŷ(q; c1) = A(q) + g(q; c1)·B(q) + g(q; c1)²·C(q), with A, B, C depending on ξ only
(see the note at the top of `ProfiledCorrs.jl`). They are built once per call; the scan
then costs one fused Horner pass per scan point against the precomputed g table, and each
Brent step one fused pass with one exp per q, instead of a full forward pass + `wls_fit`
per trial c1. The search itself (scan points, bracket, `Brent()`) is unchanged.

# Exceptions
- `ArgumentError`: `tables` were built for a different q grid, `r_m` or scan settings.
- `WLSError`: as [`wls_fit`](@ref).

# Returns
- `(ŷ::Vector, fit::WLSFit, c1_star::Float64)`: the `c1_star`-corrected model
    curve (at the caller's real ξ), its WLS fit, and the profiled c1 itself.
    `Sampler.jl`'s hot-path likelihood call drops `ŷ`/`c1_star`; its
    posterior-draw curve/report loop needs all three.
"""
function profiled_corrs end

function profiled_corrs(
    wls::WLSData,
    ξ::SVector{4,<:Real},
    fw::ForwardCache;
    cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
    cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
    eps::Float64=EXCL_VOL_CORR_EPS,
    tol::Float64=EXCL_VOL_CORR_TOL,
    tables::Union{Nothing,_C1Tables}=nothing,
)
    tab = tables === nothing ? _C1Tables(fw; cmin = cmin, cmax = cmax, eps = eps) : tables
    (tab.cmin == cmin && tab.cmax == cmax && tab.eps == eps &&
    tab.r_m == fw.r_m && tab.qvals == fw.qvals) ||
        throw(ArgumentError("profiled_corrs: tables were built for a different q grid, r_m or scan settings"))

    # plain Float64 ξ (the per-draw re-profile, the report): no dual numbers, Bumper temporaries, one output vector
    ξ isa SVector{4,Float64} && return _profiled_value(wls, ξ, fw, tab, tol)

    # c1 from the same A, B, C construction as every other path (so value and gradient agree on c1 exactly)
    ξ_val = ForwardDiff.value.(ξ)
    Q = length(tab.qvals)
    c1_star = 0.0
    @no_escape begin
        A = @alloc(Float64, Q); B = @alloc(Float64, Q); C = @alloc(Float64, Q)
        _intensity_terms!(A, B, C, fw.Gc, ξ_val[1], DRO_UNIT * ξ_val[2], DRO_UNIT * ξ_val[3], DRO_UNIT * ξ_val[4])
        c1_star = _c1_search(A, B, C, tab, wls, tol)
    end

    # the one fit that matters: at the caller's real (possibly Dual) ξ
    Ad, Bd, Cd = intensity_terms(fw, ξ[1], (ξ[2], ξ[3], ξ[4]))
    ŷ = model_intensity(Ad, Bd, Cd, excluded_volume_factor(tab.qvals, tab.r_m, c1_star))
    return ŷ, wls_fit(ŷ, wls), c1_star
end

"""
Classifies a profiled `c1_star` (from [`profiled_corrs`](@ref)) against the
physical bounds `(cmin, cmax)`:

- `-1`: `c1_star` < cmin, i.e. the search wanted to go lower than the
    physical bound even with `eps` of extra room.
- `+1`: `c1_star` > cmax, symmetric case.
- `0`: `c1_star` ∈ [cmin, cmax], not saturated.

Meant to be called once, on a single reported value (e.g. the MAP draw's
c1), not per posterior draw or inside the sampler's hot path.
"""
function excl_vol_saturation(
    c1::Real;
    cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
    cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
)::Int
    c1 < cmin && return -1
    c1 > cmax && return 1
    return 0
end
