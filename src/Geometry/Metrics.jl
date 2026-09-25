# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Geometric shortcuts and pairwise distance tests over a
cloud of expanded spheres (radius + probe, atom-centred but agnostic to
what "probe" means to the caller).
"""
module Metrics

using ..PlasticSequence: Vec3

export Coverage, ALL_EXPOSED, ALL_BURIED, AMBIGUOUS, classify, blocked

"""
    Coverage

How much of a sphere its neighbours cover.
- `ALL_EXPOSED`:    no neighbour reaches the sphere, so the exposed fraction is
                    exactly 1 and the area/volume is exactly the full sphere's.
- `ALL_BURIED`:     a single neighbour swallows the whole sphere, so the exposed
                    fraction is exactly 0.
- `AMBIGUOUS`:      neighbours cut caps but no single one settles it; only point
                    sampling can estimate the fraction.
"""
@enum Coverage ALL_EXPOSED ALL_BURIED AMBIGUOUS

"""
    classify(i, candidates, crds, rads, probe) -> Coverage

Each neighbour j cuts a spherical cap out of i's expanded sphere. Writing
ρᵢ = rads[i] + probe, ρⱼ = rads[j] + probe and d = |cᵢ - cⱼ|, three cases
are decidable by comparing scalars, with no point sampling at all:

- d + ρᵢ ≤ ρⱼ:   j engulfs i entirely, so *every* point is occluded.
- d ≥ ρᵢ + ρⱼ:   j is too far to reach i's surface, so it cuts nothing.
- d + ρⱼ ≤ ρᵢ:   j's ball sits strictly inside i's surface, so it also
                    cuts nothing (i encloses j).

If no neighbour cuts a cap the sphere is fully exposed. Everything else is a
union-of-caps question that this predicate deliberately does not answer.

Sampling can only prove a sphere is not fully covered, it can never prove
burial, since nothing is stopping the next point from being covered.

# Arguments
- `i`: sphere to classify (an index into crds/rads).
- `candidates`: neighbour indices from a coarse range query; may include i.
- `crds`: (3, n) coordinate matrix.
- `rads`: per-sphere radius, indexed like crds's columns.
- `probe`: uniform radius added to every sphere before comparison.
"""
function classify(
    i::Int,
    candidates::Vector{Int},
    crds::Matrix{Float64},
    rads::Vector{Float64},
    probe::Float64
)::Coverage
    ρ_i = rads[i] + probe
    x_i = crds[1, i]; y_i = crds[2, i]; z_i = crds[3, i]
    cuts = false
    @inbounds for j in candidates
        j == i && continue
        ρ_j = rads[j] + probe
        d² = (crds[1, j] - x_i)^2 + (crds[2, j] - y_i)^2 + (crds[3, j] - z_i)^2

        # a neighbour that swallows i settles it outright
        ρ_j ≥ ρ_i && d² ≤ (ρ_j - ρ_i)^2 && return ALL_BURIED

        # neighbours that never reach i's surface cut nothing
        (d² ≥ (ρ_i + ρ_j)^2 || (ρ_i ≥ ρ_j && d² ≤ (ρ_i - ρ_j)^2)) && continue
        cuts = true
    end
    return cuts ? AMBIGUOUS : ALL_EXPOSED
end

"""
    blocked(p, candidates, crds, rads, probe, self) -> Bool

Whether point p lies inside the expanded sphere (radius + probe) of any
candidate sphere other than self.

self is skipped because p is typically generated *on* or *within* sphere
self's own expanded sphere, e.g. at distance exactly rads[self] + probe
from its centre for a surface sample; an unguarded test would then report
every one of self's own points as blocked.

# Arguments
- `p`: point to test.
- `candidates`: indices of spheres to test against.
- `crds`: (3, n) coordinate matrix.
- `rads`: per-sphere radius, indexed like crds's columns.
- `probe`: uniform radius added to every sphere before comparison.
- `self`: index of the sphere p was sampled on/in; never blocks p.
"""
function blocked(
    p::Vec3,
    candidates::Vector{Int},
    crds::Matrix{Float64},
    rads::Vector{Float64},
    probe::Float64,
    self::Int
)::Bool
    x_p, y_p, z_p = p
    @inbounds for c in candidates
        c == self && continue
        ρ_c = rads[c] + probe
        x_c = crds[1, c]; y_c = crds[2, c]; z_c = crds[3, c]
        dst² = (x_c - x_p)^2 + (y_c - y_p)^2 + (z_c - z_p)^2
        if dst² ≤ ρ_c * ρ_c
            return true
        end
    end
    return false
end

"""
    blocked(p, d, candidates, crds, rads, probe) -> Bool

Does the ray from p along unit direction d hit any expanded sphere
(radius + probe) among candidates?

Standard ray/sphere test: project each centre onto the ray, reject anything
behind p, and compare the perpendicular offset against r + probe. A
sphere whose own point p was sampled on always projects backwards (t ≤ 0),
so it never self-blocks and needs no explicit self exclusion.

Dispatches on d::Vec3 (vs. candidates::Vector{Int} in the point-only
method above) to share the blocked name with the point test above: both
answer "does this query intersect any nearby expanded sphere", just for a
point vs. a ray.
"""
function blocked(
    p::Vec3, d::Vec3, candidates::Vector{Int},
    crds::Matrix{Float64}, rads::Vector{Float64}, probe::Float64
)::Bool
    @inbounds for j in candidates
        wx = crds[1, j] - p[1]; wy = crds[2, j] - p[2]; wz = crds[3, j] - p[3]
        t = wx * d[1] + wy * d[2] + wz * d[3]
        t ≤ 0.0 && continue
        ρ = rads[j] + probe
        (wx * wx + wy * wy + wz * wz) - t * t < ρ * ρ && return true
    end
    return false
end

end # module Metrics
