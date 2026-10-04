# SPDX-License-Identifier: LGPL-2.1-or-later

using StaticArrays
using Optim: minimizer, optimize, Brent
using ForwardDiff
using ..Scattering: ForwardCache, excluded_volume_factor, _EV_EXP_COEFF
using ..BAYSOL_Utils.Constants: EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS, DRO_UNIT
using LinearAlgebra: mul!
using FastClosures

# ---------------------------------------------------------------------------
# c1 only enters through the excluded-volume envelope g(q; c1) on species 2, so
# for a fixed ξ (contrast v = (1, −ρₑ, dro₁, dro₂, dro₃), forward's scale 1, bkg 0)
#
#     ŷ(q; c1) = A(q) + g·B(q) + g²·C(q),   g = g(q; c1),
#
#     A = Σ_{a,b ∈ S} v_a v_b G_ab,   B = −2ρₑ Σ_{b ∈ S} v_b G_2b,   C = ρₑ² G_22,
#     S = {1, 3, 4, 5}.
#
# A, B, C are built once per ξ (two BLAS products against the static Gc below);
# the scan reads g from a static table and each Brent step costs one exp per q,
# instead of a full forward pass per trial c1.
# ---------------------------------------------------------------------------

"Species pairs (a, b), a ≤ b, in Gc's column order: A's 10, then B's 4 (2, b), then C's (2, 2)."
const _C1_PAIRS = ((1, 1), (1, 3), (1, 4), (1, 5), (3, 3), (3, 4), (3, 5), (4, 4), (4, 5), (5, 5),
                   (1, 2), (2, 3), (2, 4), (2, 5),
                   (2, 2))

"""
    _C1Tables

Static per-run tables for [`profiled_corrs`](@ref)'s c1 search: everything that depends
only on the structure's [`ForwardCache`](@ref BAYSOL.Scattering.ForwardCache) and the scan
settings, not on ξ. Built once (by [`seed_fitting`](@ref), or on the fly), then only ever
read: no field is modified after construction, so one instance can be shared by any
number of threads. Per-evaluation scratch is never stored here.

# Fields
- `Gc::Matrix{Float64}`, (Q, 15): G_ab(q) for the pairs in `_C1_PAIRS`, contiguous in q.
- `cs::Vector{Float64}`: the scan points (cmin − eps):eps:(cmax + eps).
- `g1::Matrix{Float64}`, (Q, length(cs)): g(q; cᵢ) at every scan point.
- `qvals::Vector{Float64}`, `r_m::Float64`: the grid and mean atomic radius g is built on.
- `cmin`, `cmax`, `eps::Float64`: the scan settings the tables were built for.
"""
struct _C1Tables
    Gc::Matrix{Float64}
    cs::Vector{Float64}
    g1::Matrix{Float64}
    qvals::Vector{Float64}
    r_m::Float64
    cmin::Float64
    cmax::Float64
    eps::Float64
end

"""
$(TYPEDSIGNATURES)

Build the static c1-search tables for `fw` (see [`_C1Tables`](@ref)). g is evaluated with
`Scattering.excluded_volume_factor`, the same function the forward model uses.

# Keywords
- `cmin, cmax = EXCL_VOL_CORR_BOUNDS`, `eps = EXCL_VOL_CORR_EPS`: as [`profiled_corrs`](@ref).

# Returns
- `_C1Tables`.

# Exceptions
- `ArgumentError`: fw's Gram matrix is not the five-species one.
"""
function _C1Tables(
    fw::ForwardCache;
    cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
    cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
    eps::Float64=EXCL_VOL_CORR_EPS,
)::_C1Tables
    G = fw.G
    (size(G, 1) == 5 && size(G, 2) == 5) ||
        throw(ArgumentError("_C1Tables: needs the five-species Gram matrix; got $(size(G, 1))×$(size(G, 2))"))
    Q = size(G, 3)
    Gc = Matrix{Float64}(undef, Q, length(_C1_PAIRS))
    @inbounds for (j, (a, b)) in enumerate(_C1_PAIRS)
        @simd for q in 1:Q
            Gc[q, j] = G[a, b, q]
        end
    end
    cs = collect(Float64, (cmin - eps):eps:(cmax + eps))
    g1 = Matrix{Float64}(undef, Q, length(cs))
    for (i, c) in enumerate(cs)
        g1[:, i] = excluded_volume_factor(fw.qvals, fw.r_m, c)
    end
    return _C1Tables(Gc, cs, g1, copy(fw.qvals), fw.r_m, cmin, cmax, eps)
end

"""
$(TYPEDSIGNATURES)

A, B, C of ŷ = A + g·B + g²·C for the contrast of ρₑ, δρ (see the note at the top of this
file): two products against the static `Gc` (BLAS for Float64; Julia's generic product
when ρₑ/δρ carry ForwardDiff dual numbers).

# Returns
- `(A, B, C)`, three length-Q vectors with the eltype of ρₑ/δρ.
"""
function _abc(tab::_C1Tables, ρ::Real, δρ::NTuple{3,<:Real})
    T = promote_type(typeof(ρ), eltype(δρ), Float64)
    v1, v3, v4, v5 = one(T), T(DRO_UNIT * δρ[1]), T(DRO_UNIT * δρ[2]), T(DRO_UNIT * δρ[3])
    kA = T[v1^2, 2v1 * v3, 2v1 * v4, 2v1 * v5, v3^2, 2v3 * v4, 2v3 * v5, v4^2, 2v4 * v5, v5^2]
    kB = T[-2ρ * v1, -2ρ * v3, -2ρ * v4, -2ρ * v5]
    Q = size(tab.Gc, 1)
    A = Vector{T}(undef, Q); B = Vector{T}(undef, Q)
    mul!(A, view(tab.Gc, :, 1:10), kA)
    mul!(B, view(tab.Gc, :, 11:14), kB)
    ρ2 = T(ρ)^2
    C = Vector{T}(undef, Q)
    @inbounds @fastmath @simd for q in 1:Q
        C[q] = ρ2 * tab.Gc[q, 15]
    end
    return A, B, C
end

"""
$(TYPEDSIGNATURES)

The three model-dependent weighted sums of the fit, Σwŷ, Σwŷ², Σwŷ·I, for
ŷ = A + g·B + g²·C at one arbitrary c1, in a single fused pass with g evaluated on
the fly (the Brent step). Same g formula as `Scattering.excluded_volume_factor`.

# Returns
- `(SwI, SwII, SwIy)::NTuple{3,Float64}`.
"""
function _sums_at(A::Vector{Float64}, B::Vector{Float64}, C::Vector{Float64},
                  tab::_C1Tables, wls::WLSData, c1::Float64)
    k = (c1^2 - 1) * _EV_EXP_COEFF * tab.r_m^2
    c3 = c1^3
    q = tab.qvals; w = wls.weights; y = wls.I_obs
    SwI = 0.0; SwII = 0.0; SwIy = 0.0
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
$(TYPEDSIGNATURES)

Reduced χ² at every scan point of `tab` for ŷ = A + g·B + g²·C, without forming ŷ.
Expanding the sums in powers of g,

    Σwŷ   = ⟨w, A⟩  + Σ g·(wB + g·wC)
    Σwŷ·I = ⟨wI, A⟩ + Σ g·(wIB + g·wIC)
    Σwŷ²  = ⟨w, A²⟩ + Σ g·(2wAB + g·(w(B² + 2AC) + g·(2wBC + g·wC²))),

the seven coefficient vectors are built once in a fused pass, then each scan point is
one fused `@simd` pass over q in Horner form (three accumulators, g read from `tab.g1`).

# Returns
- `Vector{Float64}`: reduced χ² per scan point.

# Exceptions
- `WLSError`: as [`wls_fit`](@ref), if the model is flat at a scan point.
"""
function _scan_chi2(A::Vector{Float64}, B::Vector{Float64}, C::Vector{Float64},
                    tab::_C1Tables, wls::WLSData)::Vector{Float64}
    Q = length(A); w = wls.weights; y = wls.I_obs
    r11 = Vector{Float64}(undef, Q); r21 = Vector{Float64}(undef, Q)   # Σwŷ:   wB, wC
    r12 = Vector{Float64}(undef, Q); r22 = Vector{Float64}(undef, Q)   # Σwŷ·I: wIB, wIC
    r13 = Vector{Float64}(undef, Q); r23 = Vector{Float64}(undef, Q)   # Σwŷ²:  2wAB, w(B² + 2AC),
    r33 = Vector{Float64}(undef, Q); r43 = Vector{Float64}(undef, Q)   #        2wBC, wC²
    SA = 0.0; SAy = 0.0; SA2 = 0.0      # ⟨w, A⟩, ⟨wI, A⟩, ⟨w, A²⟩
    @inbounds @fastmath @simd for i in 1:Q
        wi = w[i]; a = A[i]; b = B[i]; c = C[i]; wy = wi * y[i]
        SA += wi * a; SAy += wy * a; SA2 += wi * a * a
        r11[i] = wi * b;      r21[i] = wi * c
        r12[i] = wy * b;      r22[i] = wy * c
        r13[i] = 2wi * a * b; r23[i] = wi * (b * b + 2a * c)
        r33[i] = 2wi * b * c; r43[i] = wi * c * c
    end
    g1 = tab.g1
    chis = Vector{Float64}(undef, length(tab.cs))
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
    return chis
end

"""
$(TYPEDSIGNATURES)

Profiles out the correction terms

# Scale and Background Correction
Since the calculated intensity is at an arbitrary scale and
the experimental background correction is likely to be imperfect,
a simple WLS fit minimizing the reduced χ² returns optimal correction factors.

# Excluded Volume Correction
c1 is the correction factor for the Gaussian-blob approximation of
each atom's excluded volume. Finds the c1 that minimizes reduced χ²,
with scale/bkgrnd_corr re-fit by wls_fit at every trial c1. Unlike
scale/bkgrnd_corr, c1 is nonlinear w.r.t. I(q) (see
`Scattering.excluded_volume_factor`'s `c1³·exp(...)` form), so it needs an
iterative 1-D search rather than a closed form fit.

The search is a coarse grid pre-scan followed by a `Brent()` polish, both
gradient-free:

1.  Evaluate reduced χ² on the grid `(cmin-eps):eps:(cmax+eps)` -- cheap
    (one `forward` + `wls_fit` per point, no autodiff), and unlike a purely
    local method this can't miss a second basin at the resolution of `eps`.
    Number of grid points ≈ `((cmax+eps) - (cmin-eps)) / eps + 1`, so
    tightening `eps` for a more precise saturation test.
2.  Bracket the best grid point with its two grid neighbours (or the padded
    edge, if the best point is first/last) and run `Brent()` inside that
    bracket to polish to full precision.

χ²(c1) is not globally monotone once ξ is badly wrong; 
a bare `Brent()` bracketed only by `(cmin-eps, cmax+eps)` 
could converge to whichever of these basins it starts exploring
toward and would have no way to tell you it missed the other one.

# Arguments
- `wls::WLSData`: precomputed data-only weighted sums over the measured
    intensity/per-point standard errors, from [`WLSData`](@ref); forwarded
    to every trial-c1 call of [`wls_fit`](@ref) inside the inner search
    without rebuilding those sums each time.
- `ξ::SVector{4,<:Real}` or `ξ::SVector{5,<:Real}`: (ρₑ, δρ₁, δρ₂, δρ₃[, δρ4]),
    held fixed during the c1 search.
- `fw::ForwardCache`: the structure's geometry-only cache, forwarded to
    [`Scattering.forward`](@ref BAYSOL.Scattering.forward).

# Keywords
- `cmin, cmax = EXCL_VOL_CORR_BOUNDS`: the physical c1 bounds.
- `eps = EXCL_VOL_CORR_EPS`: both the amount the search window is padded
    past `(cmin, cmax)` and the coarse pre-scan's grid step.
- `tables::Union{Nothing,_C1Tables} = nothing`: static tables for fw and these scan
    settings ([`_C1Tables`](@ref), built once per run by [`seed_fitting`](@ref) and
    read-only, so safe to share across threads). `nothing` builds them for this call.

# Implementation

ŷ(q; c1) = A(q) + g(q; c1)·B(q) + g(q; c1)²·C(q), with A, B, C depending on ξ only
(see the note at the top of `ProfiledCorrs.jl`). They are built once per call; the scan
then costs one fused Horner pass per scan point against the precomputed g table, and each
Brent step one fused pass with one exp per q, instead of a full `forward` + `wls_fit`
per trial c1. The search itself (scan points, bracket, `Brent()`) is unchanged.

# Exceptions
- `ArgumentError`: `tables` were built for a different q grid, r_m or scan settings.
- `WLSError`: as [`wls_fit`](@ref).

# Returns
- `(ŷ::Vector, fit::WLSFit, c1_star::Float64)`: the c1_star-corrected model
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
    tables::Union{Nothing,_C1Tables}=nothing,
)
    tab = tables === nothing ? _C1Tables(fw; cmin = cmin, cmax = cmax, eps = eps) : tables
    (tab.cmin == cmin && tab.cmax == cmax && tab.eps == eps &&
     tab.r_m == fw.r_m && tab.qvals == fw.qvals) ||
        throw(ArgumentError("profiled_corrs: tables were built for a different q grid, r_m or scan settings"))

    ξ_val = ForwardDiff.value.(ξ)
    A, B, C = _abc(tab, ξ_val[1], (ξ_val[2], ξ_val[3], ξ_val[4]))
    n = length(A)

    # scan: reduced χ² at every scan point from the precomputed g powers
    chis = _scan_chi2(A, B, C, tab, wls)
    lo, hi = cmin - eps, cmax + eps
    cs = tab.cs
    i_best = argmin(chis)
    lo_b = i_best == 1         ? lo : cs[i_best-1]
    hi_b = i_best == length(cs) ? hi : cs[i_best+1]

    # polish: Brent on the same objective, one fused pass per step.
    # No assignments inside the closure: a name assigned both in a closure and in
    # this enclosing body is one shared, Core.Box'ed variable (type-unstable).
    χ²_at_c1 = @closure c1 -> reduced_chi2(_wls_from_sums(_sums_at(A, B, C, tab, wls, c1)..., n, wls))
    res = optimize(χ²_at_c1, lo_b, hi_b, Brent())
    c1_star = minimizer(res)

    # the one fit that matters: at the caller's real (possibly Dual) ξ
    Ad, Bd, Cd = _abc(tab, ξ[1], (ξ[2], ξ[3], ξ[4]))
    g = excluded_volume_factor(tab.qvals, tab.r_m, c1_star)
    ŷ = similar(Ad)
    @inbounds @fastmath @simd for i in eachindex(ŷ)
        ŷ[i] = Ad[i] + g[i] * (Bd[i] + g[i] * Cd[i])
    end
    return ŷ, wls_fit(ŷ, wls), c1_star
end

"""
$(TYPEDSIGNATURES)

Classifies a profiled c1_star (from [`profiled_corrs`](@ref)) against the
physical bounds `(cmin, cmax)`:

- `-1`: c1_star < cmin, i.e. the search wanted to go lower than the
    physical bound even with `eps` of extra room.
- `+1`: c1_star > cmax, symmetric case.
- `0`: c1_star ∈ [cmin, cmax], not saturated.

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

# function profiled_corrs(
#     wls::WLSData,
#     ξ::SVector{5,Float64},
#     fw::ForwardCache;
#     cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
#     cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
#     eps::Float64=EXCL_VOL_CORR_EPS,
# )::WLSFit
#     # forward doesn't take ξ[5] (δρ4) yet, see CLAUDE.md "Nucleotide
#     # support" gap (2), parameter-vector widening. Dropped here rather
#     # than silently miscomputed.
#     fit_at_c1_val = @closure c1 -> begin
#         ŷ = forward(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4], ξ[5]), c1)
#         wls_fit(ŷ, wls)
#     end
#     χ²_at_c1 = @closure c1 -> reduced_chi2(fit_at_c1_val(c1))
#     lo, hi = cmin - eps, cmax + eps
#     grid = lo:eps:hi
#     chis = [χ²_at_c1(c1) for c1 in grid]
#     i_best = argmin(chis)
#     lo_b = i_best == 1            ? lo : grid[i_best-1]
#     hi_b = i_best == length(grid) ? hi : grid[i_best+1]
#     res = optimize(χ²_at_c1, lo_b, hi_b, Brent())
#     c1_star = minimizer(res)
#     return fit_at_c1_val(c1_star)
# end
