# SPDX-License-Identifier: LGPL-2.1-or-later

# Pairwise sphere tests over a cloud of expanded spheres (radius + probe, atom-centred but
# agnostic to what "probe" means to the caller). `_caps!` is the exact,
# sampling-free shortcut `_sasa_loop` tries first for every atom, and packs the caps its
# vectorized point test then runs against; `blocked` is the point/ray occlusion test
# (`_bead_class` uses the ray form).

"""
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

The scalar tests above are followed by the caps themselves, for the sampler. For each
neighbour j that cuts a cap, with cⱼ its centre relative to i's, the point ρᵢ·u of
i's expanded sphere (u a unit direction) lies inside j's expanded sphere iff

    |cⱼ - ρᵢu|² ≤ ρⱼ²   ⟺   u·cⱼ ≥ tⱼ,   tⱼ = (|cⱼ|² + ρᵢ² - ρⱼ²) / (2ρᵢ),

one dot product and a compare. Neighbours that cut nothing can never occlude a point
of i's surface, so they are dropped here rather than tested per point.

# Arguments
- `cx, cy, cz, ct`: output buffers, length ≥ the number of cutting neighbours (e.g.
    `length(candidates)`); entries 1:K receive cⱼ and tⱼ. Contents past K, and all
    contents when the result is `ALL_BURIED`, are unspecified.
- `i`: sphere to classify (an index into crds/rads).
- `candidates`: neighbour indices from a coarse range query; may include i.
- `crds`: (3, n) coordinate matrix.
- `rads`: per-sphere radius, indexed like crds's columns.
- `probe`: uniform radius added to every sphere before comparison.

# Returns
- `(coverage::Coverage, K::Int)`: the [`Coverage`](@ref) and K, the number of cutting caps
    packed (0 unless `AMBIGUOUS`).
"""
function _caps!(
    cx::Vector{Float64}, cy::Vector{Float64}, cz::Vector{Float64}, ct::Vector{Float64},
    i::Int,
    candidates::Vector{Int},
    crds::Matrix{Float64},
    rads::Vector{Float64},
    probe::Float64,
)::Tuple{Coverage,Int}
    ρ_i = rads[i] + probe
    x_i = crds[1, i]
    y_i = crds[2, i]
    z_i = crds[3, i]
    K = 0
    @inbounds for j in candidates
        j == i && continue
        ρ_j = rads[j] + probe
        dx = crds[1, j] - x_i
        dy = crds[2, j] - y_i
        dz = crds[3, j] - z_i
        d² = dx * dx + dy * dy + dz * dz

        # a neighbour that swallows i settles it outright
        ρ_j ≥ ρ_i && d² ≤ (ρ_j - ρ_i)^2 && return ALL_BURIED, 0

        # neighbours that never reach i's surface cut nothing
        (d² ≥ (ρ_i + ρ_j)^2 || (ρ_i ≥ ρ_j && d² ≤ (ρ_i - ρ_j)^2)) && continue
        K += 1
        cx[K] = dx
        cy[K] = dy
        cz[K] = dz
        ct[K] = (d² + ρ_i * ρ_i - ρ_j * ρ_j) / (2ρ_i)
    end
    return (K == 0 ? ALL_EXPOSED : AMBIGUOUS), K
end

"""
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
    self::Int,
)::Bool
    x_p, y_p, z_p = p
    @inbounds for c in candidates
        c == self && continue
        ρ_c = rads[c] + probe
        x_c = crds[1, c]
        y_c = crds[2, c]
        z_c = crds[3, c]
        dst² = (x_c - x_p)^2 + (y_c - y_p)^2 + (z_c - z_p)^2
        if dst² ≤ ρ_c * ρ_c
            return true
        end
    end
    return false
end

"""
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
    crds::Matrix{Float64}, rads::Vector{Float64}, probe::Float64,
)::Bool
    @inbounds for j in candidates
        wx = crds[1, j] - p[1]
        wy = crds[2, j] - p[2]
        wz = crds[3, j] - p[3]
        t = wx * d[1] + wy * d[2] + wz * d[3]
        t ≤ 0.0 && continue
        ρ = rads[j] + probe
        (wx * wx + wy * wy + wz * wz) - t * t < ρ * ρ && return true
    end
    return false
end
