# SPDX-License-Identifier: LGPL-2.1-or-later

# Per-atom "displaced solvent volume" (Å³), for the excluded-volume dummy
# species, **not** a physical atomic size. Bonded atoms overlap heavily, so
# an isolated van der Waals sphere (`AtomicRadii`/`sphere_volume`) overcounts
# the volume a bonded atom actually displaces from the bulk solvent; computed
# geometrically per atom (radical-plane/power-diagram sampling, see
# `excluded_volume` below) rather than looked up from a per-element table.

using NearestNeighbors: inrange, KDTree
using ..Geometry: sphere_volume
using ..Geometry.PlasticSequence: plastic_points, Vec3
using ..BAYSOL_Utils.Constants: N_VOL_SHELL
using LinearAlgebra: dot
using StaticArrays: SVector

"""
Points to map onto the volume of a sphere.
"""
const _pts::Vector{Vec3} = plastic_points(N_VOL_SHELL, Val(3), Val(:volume))

"""
    excluded_volume(cart, rads, tree, rmax) -> Vector{Float64}

Per-atom excluded (displaced-solvent) volume in Å³. Algorithm adapted from Chamberlain,
Moore & Grant (2023), DOI 10.1016/j.bpj.2023.10.034 "Fitting high-resolution
electron density maps from atomic models to solution scattering data".

For each atom `i`, a bonded/packed neighbour `j` claims the part of `i`'s van
der Waals sphere on `j`'s side of their radical (power-diagram) plane. Atom 
`i`'s excluded volume is the intersection

    S_i = {x : |x - p_i| <= r_i ∧ power_i(x) <= power_j(x) ∀ overlapping neighbour j}

where `power_k(x) = |x - p_k|² - r_k²`, and `x` is a point within `i`'s vdW radius.

Rather than computing `S_i` exactly (the volume of a ball clipped by the
half-spaces, which has no simple closed  form once more than one neighbour
cuts the same region), `S_i` is estimated by sampling: `N_VOL_SHELL` points
from [`_pts`](@ref) are scaled/translated onto `i`'s sphere,
each is tested against every overlapping neighbour's radical plane
(`dot(x - p_i, n) <= plane_dist`, computed as `dot(x, n) <= plane_dist +
dot(p_i, n)` to avoid re-translating every sample point), and the surviving
fraction scales [`sphere_volume`](@ref)`(r_i)`.

An atom with no overlapping neighbours skips sampling and returns its full 
`sphere_volume`; an atom whose sphere is entirely engulfed by its neighbours 
returns `0.0`.

# Arguments
- `cart::Matrix{Float64}`: `(3, n)` centroid-centred cartesian coordinates,
    i.e. `coords_cartesian(mol)`.
- `rads::Vector{Float64}`: per-atom van der Waals radius, i.e. `radii(mol)`.
- `tree::KDTree`: neighbour-query tree over `cart`, i.e. `neighbour_tree(mol)`.
- `rmax::Float64`: largest per-atom radius in `rads`, i.e. `r_max(mol)`; bounds
    the candidate search per atom (`d_ij < r_i + r_j <= r_i + rmax`).

# Returns
- `Vector{Float64}`: one excluded volume per atom, in the same order as
    `cart`'s columns / `rads`; each entry is `>= 0` and `<= sphere_volume(rads[i])`.
"""
function excluded_volume(
    cart::Matrix{Float64},
    rads::Vector{Float64},
    tree::KDTree,
    rmax::Float64
)::Vector{Float64}
    
    # excluded volumes
    vols = Vector{Float64}(undef, size(cart, 2))

    # iterate over columns for each atom coord
    i = 1
    @inbounds for (x, y, z) in eachcol(cart)

        p_i = (x, y, z)

        # candidate list of all possible overlapping radii.
        # Radii can overlap when: d_ij < r_i + r_j, and since
        # r_j <= r_max; d_ij < r_i + r_j <= r_i + r_max
        # inrange requires an AbstractVector query point, not a Tuple/Vec3
        candidates = inrange(tree, SVector(p_i), rads[i] + rmax)

        if length(candidates) == 1
            vols[i] = sphere_volume(rads[i])

        else
            # check potential candidate points
            planes = Vector{Tuple{Vec3,Float64}}()
            sizehint!(planes, length(candidates))
            for c in candidates
                # skip self
                c == i && continue

                p_j = (cart[1, c], cart[2, c], cart[3, c])
                dst = sqrt(sum((p_i .- p_j) .^ 2))

                # only actual overlaps matter
                dst >= rads[i] + rads[c] && continue

                # radical plane between i and j. Store the threshold
                # `plane_dist + dot(p_i, n)` rather than `plane_dist`,
                # so the per-sample-point test below is `dot(x, n) > thresh`
                # instead of `dot(x .- p_i, n) > plane_dist`.
                dst2 = dst^2
                plane_dist = (dst2 + rads[i]^2 - rads[c]^2) / (2 * dst)
                n = (p_j .- p_i) ./ dst

                push!(planes, (n, plane_dist + dot(p_i, n)))
            end

            # Scale/translate each of `_pts` onto atom i's sphere and count
            # victims: points that fall beyond at least one neighbour's
            # radical plane, i.e. are claimed by that neighbour instead of i.
            # `break` on first violation, since a point is a victim at most
            # once regardless of how many planes it fails.
            # survivors = N_VOL_SHELL - victims.
            victims = 0
            for u in _pts
                x = p_i .+ rads[i] .* u
                for (n, thresh) in planes
                    if dot(x, n) > thresh
                        victims += 1
                        break
                    end
                end
            end

            # scale vdW volume by num of survivors
            vols[i] = sphere_volume(rads[i]) * (N_VOL_SHELL - victims) / N_VOL_SHELL

        end
        i+=1
    end
    return vols
end
