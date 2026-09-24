# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Even point sets drawn from the plastic (`R_d`) family of additive
low-discrepancy sequences (Roberts, M. (2018). The Unreasonable Effectiveness
of Quasirandom Sequences.). `dim` selects the *output* space:

- `dim = 2`: the raw 2-D `R₂` generator, unlifted, in the plane.
- `dim = 3`: the same 2-D `R₂` generator lifted onto a sphere -- either its
**surface** (`shape = :surface`, the default: a 2-D manifold, since a
sphere's surface only takes 2 coordinates to parametrize) or its
**volume** (`shape = :volume`: a genuinely 3-D region, built from the
3-D `R₃` generator instead, since filling a ball needs a 3rd, radial,
coordinate).

Independent of any caller (`Solvation.SASA` is one, not the only one): this
module knows nothing about atoms, molecules, or surfaces, only about the
sequence and the sphere/ball it is lifted onto.
"""
module PlasticSequence

using Roots: find_zero

export  Vec2, Vec3, plastic_ratio, PLASTIC_RATIO_2, 
        PLASTIC_RATIO_3, plastic_points

"A point in the plane, `(x, y)`."
const Vec2 = NTuple{2,Float64}

"A unit vector on the sphere, `(x, y, z)`."
const Vec3 = NTuple{3,Float64}

"""
    plastic_ratio(d::Int) -> Float64

The generalized `d`-dimensional plastic ("harmonious") ratio: the real root
in `(1, 2)` of `x^(d+1) = x + 1`. `d = 2` recovers the classic plastic ratio
`ρ ≈ 1.324718` (root of `x³ = x + 1`), the constant this module's `dim = 2`
and `dim = 3` layouts both build on.
"""
function plastic_ratio(d::Int)::Float64
    d >= 1 || throw(DomainError(d, "d must be >= 1"))
    return find_zero(x -> x^(d + 1) - x - 1, (1.0, 2.0))
end

"Plastic ratio ρ ≈ 1.324718, the real root of `x³ = x + 1` (`plastic_ratio(2)`)."
const PLASTIC_RATIO_2     = plastic_ratio(2)
const _PLASTIC_RATIO_SQR = PLASTIC_RATIO_2^2

"3-D plastic ratio, the real root of `x⁴ = x + 1` (`plastic_ratio(3)`), driving the volume layout."
const PLASTIC_RATIO_3      = plastic_ratio(3)
const _PLASTIC_RATIO_3_SQR  = PLASTIC_RATIO_3^2
const _PLASTIC_RATIO_3_CUBE = PLASTIC_RATIO_3^3

"Fractional part of `x`, i.e. `x - floor(x)`, in `[0, 1)`."
_frac(x) = x - floor(x)

"""
    _plastic_term(i::Int) -> (Float64, Float64)

1-based term `i` of the 2-D `R₂` additive recurrence: `(frac(i/ρ), frac(i/ρ²))`.
Shared by the plane and surface layouts below so a `dim = 3` (`:surface`)
cloud and its `dim = 2` pre-image agree term for term.

Division by `ρ`/`ρ²` (rather than multiplication by reciprocals) keeps the
fractional part accurate; it degrades only once `i` nears the mantissa limit
(~1e15), far above any realistic point count.
"""
@inline function _plastic_term(i::Int)::Tuple{Float64,Float64}
    return (_frac(i / PLASTIC_RATIO_2), _frac(i / _PLASTIC_RATIO_SQR))
end

"""
    _plastic_term3(i::Int) -> (Float64, Float64, Float64)

1-based term `i` of the 3-D `R₃` additive recurrence: `(frac(i/ρ₃), frac(i/ρ₃²), frac(i/ρ₃³))`,
`ρ₃ = plastic_ratio(3)`. A genuinely 3-D generator, distinct from `_plastic_term`
(which only ever has 2 degrees of freedom) -- needed because filling a
*volume* takes a 3rd, radial, coordinate that a surface has no use for.
"""
@inline function _plastic_term3(i::Int)::Tuple{Float64,Float64,Float64}
    return (_frac(i / PLASTIC_RATIO_3), _frac(i / _PLASTIC_RATIO_3_SQR), _frac(i / _PLASTIC_RATIO_3_CUBE))
end

"""
    _plastic_point_2d(i::Int) -> Vec2

Raw 2-D term `i`, in `[0, 1)²`.
"""
@inline function _plastic_point_2d(i::Int)::Vec2
    return _plastic_term(i)
end

"""
    _plastic_point_surface(i::Int) -> Vec3

Unit-**sphere-surface** point for 1-based plastic-sequence term `i`. The 2-D
term is read as `(azimuth, height)` and lifted to the sphere through the
equal-area cylindrical projection, so the points are uniform in *area*
rather than clustered at the poles. `|p| == 1` for every point.
"""
@inline function _plastic_point_surface(i::Int)::Vec3
    u, v = _plastic_term(i)
    φ = 2.0 * π * u
    z = 2.0 * v - 1.0
    r = sqrt(max(0.0, 1.0 - z * z))
    sinφ, cosφ = sincos(φ)
    return (r * cosφ, r * sinφ, z)
end

"""
    _plastic_point_volume(i::Int) -> Vec3

Unit-**ball-volume** point for 1-based plastic-sequence term `i`, built from
the 3-D `R₃` generator ([`_plastic_term3`](@ref)). The first two terms are
read exactly as in [`_plastic_point_surface`](@ref) (azimuth `φ`, `cosθ`);
the 3rd is a radius `r = cbrt(w)`, the inverse-CDF correction for the
sphere's `r²dr` volume element (`r = w` directly would over-cluster mass at
the centre). `0 <= |p| < 1` for every point, uniform in *volume* rather than
clustered at the centre.
"""
@inline function _plastic_point_volume(i::Int)::Vec3
    u, v, w = _plastic_term3(i)
    φ  = 2.0 * π * u
    ct = 2.0 * v - 1.0                          # cosθ
    r  = cbrt(w)
    s  = r * sqrt(max(0.0, 1.0 - ct * ct))      # r * sinθ
    sinφ, cosφ = sincos(φ)
    return (s * cosφ, s * sinφ, r * ct)
end

"""
    plastic_points(n::Int, ::Val{2}) -> Vector{Vec2}
    plastic_points(n::Int, ::Val{3}) -> Vector{Vec3}
    plastic_points(n::Int, ::Val{3}, ::Val{:surface}) -> Vector{Vec3}
    plastic_points(n::Int, ::Val{3}, ::Val{:volume}) -> Vector{Vec3}
    plastic_points(n::Int; dim::Int=3, shape::Symbol=:surface) -> Vector{Vec2} or Vector{Vec3}

The first `n` terms of the plastic low-discrepancy sequence, selected by
**multiple dispatch** rather than a runtime branch:

- `Val(2)`: the raw 2-D `R₂` terms `(frac(i/ρ), frac(i/ρ²))`, uniform on
  `[0, 1)²`. No `shape` applies -- it's flat, neither a sphere surface nor
  a ball volume.
- `Val(3)` alone, or `Val(3), Val(:surface)` (default via the keyword form):
  those same 2-D `R₂` terms read as `(azimuth, height)` and lifted onto the
  **surface** of the unit sphere via Lambert's cylindrical equal-area
  projection -- a 2-D manifold, so the 2-D generator is all it needs.
  Points are uniform in *area*, `|p| == 1` always.
- `Val(3), Val(:volume)`: the 3-D `R₃` terms lifted to **fill** the unit
  ball -- a genuinely 3-D region, built from the 3-D generator (the extra
  coordinate becomes a radius, inverse-CDF-corrected for the sphere's
  `r²dr` volume element). Points are uniform in *volume*, `0 <= |p| < 1`.

Every layout is deterministic and prefix-stable: term `i` never changes as
`n` grows, so `plastic_points(k, args...) == plastic_points(n, args...)[1:k]`
for any `k <= n` and any fixed `args`.

The `dim`/`shape` keyword form is a convenience that dispatches to the `Val`
methods above; prefer calling them directly in performance-sensitive code (a
literal `dim`/`shape` at the call site still resolves to the same
specialization via constant propagation, but the `Val` form guarantees it
regardless of the compiler's inlining heuristics).

# Arguments
- `n`: number of points to generate; `n >= 0`.

# Keywords
- `dim`: `2` or `3`; selects the output space via `Val(dim)`. Default `3`.
- `shape`: `:surface` or `:volume`; only consulted when `dim == 3`, selects
  which 3-D layout via `Val(shape)`. Default `:surface`.
"""
function plastic_points(n::Int, ::Val{2})::Vector{Vec2}
    n < 0 && throw(DomainError(n, "n must be >= 0"))
    return [_plastic_point_2d(i) for i in 1:n]
end

function plastic_points(n::Int, ::Val{3}, ::Val{:surface})::Vector{Vec3}
    n < 0 && throw(DomainError(n, "n must be >= 0"))
    return [_plastic_point_surface(i) for i in 1:n]
end

function plastic_points(n::Int, ::Val{3}, ::Val{:volume})::Vector{Vec3}
    n < 0 && throw(DomainError(n, "n must be >= 0"))
    return [_plastic_point_volume(i) for i in 1:n]
end

function plastic_points(n::Int, ::Val{3}, ::Val{s}) where {s}
    throw(DomainError(s, "shape must be :surface or :volume"))
end

# Un-suffixed `Val(3)` keeps its pre-existing meaning (surface), so every
# pre-hoist call site (and `dim=3` with no `shape`) is unaffected.
plastic_points(n::Int, ::Val{3}) = plastic_points(n, Val(3), Val(:surface))

function plastic_points(n::Int, ::Val{d}) where {d}
    throw(DomainError(d, "dim must be 2 or 3"))
end

Base.@constprop :aggressive function plastic_points(n::Int; dim::Int=3, shape::Symbol=:surface)
    return dim == 3 ? plastic_points(n, Val(3), Val(shape)) : plastic_points(n, Val(dim))
end

end # module PlasticSequence
