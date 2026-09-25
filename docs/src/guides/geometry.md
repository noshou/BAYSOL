# Geometry

```julia
module Geometry
    include("PlasticSequence.jl")
    include("Metrics.jl")
    using .PlasticSequence: PlasticSequence
    using .Metrics:         Metrics
end
```

## PlasticSequence.jl

Even point sets drawn from the plastic (R_d) family of additive low-discrepancy sequences (Roberts, M. (2018). The Unreasonable Effectiveness of Quasirandom Sequences.).

- plastic_ratio(d::Int) -> Float64: the generalized d-dimensional plastic ("harmonious") ratio, the real root in (1, 2) of x^(d+1) = x + 1. d = 2 recovers the classic plastic ratio ρ ≈ 1.324718 (root of x³ = x + 1); d = 3 gives ρ ≈ 1.220744 (real root of x⁴ = x + 1).
- PLASTIC_RATIO_2, PLASTIC_RATIO_3: plastic_ratio(2)/plastic_ratio(3), precomputed.
- Vec2, Vec3: NTuple{2,Float64}/NTuple{3,Float64} point types.
- plastic_points(n::Int, ::Val{2}) -> Vector{Vec2}: the first n raw 2-D R₂ terms (frac(i/ρ), frac(i/ρ²)), uniform on [0, 1)².
- plastic_points(n::Int, ::Val{3}) -> Vector{Vec3} (same as Val{3}, Val{:surface}): those same 2-D R₂ terms read as (azimuth, height) and lifted onto the **surface** of the unit sphere via
- Lambert's cylindrical equal-area projection. Points are uniform in *area*, |p| == 1 .
- plastic_points(n::Int, ::Val{3}, ::Val{:volume}) -> Vector{Vec3}: the 3-D R₃ terms lifted to **fill** the unit ball, a 3-D region built from the R₃ generator (the extra coordinate becomes a radius, inverse-CDF-corrected for the sphere's r²dr volume element). Points are uniform in *volume*, 0 ≤ |p| < 1.
- plastic_points(n::Int; dim::Int=3, shape::Symbol=:surface): keyword convenience dispatching to the Val methods above; shape is only consulted when dim == 3.

Surface vs. volume is  **multiple dispatch** on Val{:surface}/Val{:volume} (a second Val argument); both layouts are deterministic and prefix-stable, term i never changes as n grows, so plastic_points(k, args...) == plastic_points(n, args...)[1:k] for any k ≤ n.

```julia
using ..Geometry.PlasticSequence: plastic_points, plastic_ratio, PLASTIC_RATIO_2, PLASTIC_RATIO_3

pts2d = plastic_points(500, Val(2))                 # Vector{Vec2}, [0,1)^2
surf  = plastic_points(256)                         # Vector{Vec3}, sphere surface (default)
ball  = plastic_points(256, Val(3), Val(:volume))   # Vector{Vec3}, fills the sphere volume
ρ4    = plastic_ratio(4)                            # generalized 4-D plastic ratio
```

or, from outside the package:

```julia
using BAYSOL.Geometry.PlasticSequence: plastic_points, PLASTIC_RATIO_2, PLASTIC_RATIO_3
```

## Metrics.jl

Geometric shortcuts and pairwise distance tests over a cloud of expanded spheres (radius + probe, atom-centred but agnostic to what "probe" means to the caller).

- Coverage: @enum with values ALL_EXPOSED, ALL_BURIED, AMBIGUOUS; how much of a sphere its neighbours cover.
- classify(i, candidates, crds, rads, probe) -> Coverage: settles ALL_EXPOSED/ALL_BURIED from pairwise centre-to-centre distances alone, with no point sampling; everything else (a union-of-caps question) is left as AMBIGUOUS for sampling to estimate.
- blocked(p, candidates, crds, rads, probe, self) -> Bool: whether point p lies inside any candidate's expanded sphere other than self (self is skipped since p is typically sampled on/in self's own expanded sphere).
- blocked(p, d, candidates, crds, rads, probe) -> Bool: whether the ray from p along unit direction d hits any candidate's expanded sphere.

[`classify`](@ref BAYSOL.Geometry.Metrics.classify) and [`blocked`](@ref BAYSOL.Geometry.Metrics.blocked) are distance/containment tests against crds/rads; they don't care where a query point p came from, so they work unchanged whether p is a PlasticSequence.plastic_points(..., Val(3), Val(:surface)) point (always |p - centre| == radius) or a ..., Val(3), Val(:volume)) point (|p - centre| < radius, filling the interior).

```julia
using ..Geometry.Metrics: classify, blocked, Coverage, ALL_EXPOSED, ALL_BURIED, AMBIGUOUS

status = classify(i, candidates, crds, rads, probe)
status == ALL_BURIED && continue          # atom contributes nothing, skip sampling
keep_all = status == ALL_EXPOSED          # atom is untouched, every sample point survives
hit = blocked(p, candidates, crds, rads, probe, i)          # point test
hit = blocked(p, dir, candidates, crds, rads, probe)        # ray test, dispatches to the other method
```

or, from outside the package:

```julia
using BAYSOL.Geometry.Metrics: classify, blocked, Coverage, ALL_EXPOSED, ALL_BURIED, AMBIGUOUS
```
