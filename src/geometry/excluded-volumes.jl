# SPDX-License-Identifier: LGPL-3.0-or-later

# Per-atom "displaced solvent volume" (Å³), for the excluded-volume dummy
# species, **not** a physical atomic size. Bonded atoms overlap heavily, so
# an isolated van der Waals sphere (AtomicRadii/sphereVolume) overcounts
# the volume a bonded atom actually displaces from the bulk solvent; computed
# geometrically per atom (radical-plane/power-diagram sampling, see
# excludedVolume below) rather than looked up from a per-element table.

"Volume of a sphere of radius rad."
sphereVolume(rad::Float64)::Float64 = (4.0 / 3.0) * π * rad^3

"""
Per-atom excluded (displaced-solvent) volume in Å³. Algorithm adapted from Chamberlain,
Moore & Grant (2023), DOI 10.1016/j.bpj.2023.10.034 "Fitting high-resolution
electron density maps from atomic models to solution scattering data".

For each atom i, a bonded/packed neighbour j claims the part of i's van
der Waals sphere on j's side of their radical (power-diagram) plane. Atom
i's excluded volume is the intersection

    S_i = {x : |x - pI| ≤ r_i ∧ power_i(x) ≤ power_j(x) ∀ overlapping neighbour j}

where `power_k(x)` = |x - `p_k`|² - `r_k²`, and x is a point within i's vdW radius.

Rather than computing `S_i` exactly (the volume of a ball clipped by the
half-spaces, which has no simple closed  form once more than one neighbour
cuts the same region), `S_i` is estimated by sampling: `N_VOL_SHELL` points
from [`_PTS`](@ref) are scaled/translated onto i's sphere,
each is tested against every overlapping neighbour's radical plane
(dot(x - `pI`, n) ≤ `planeDist`, computed as dot(x, n) ≤ `planeDist` +
dot(`pI`, n) to avoid re-translating every sample point), and the surviving
fraction scales [`sphereVolume`](@ref)(`r_i`).

An atom with no overlapping neighbours skips sampling and returns its full
`sphereVolume`; an atom whose sphere is entirely engulfed by its neighbours
returns 0.0.

# Arguments
- `cart::Matrix{Float64}`: (3, n) centroid-centred cartesian coordinates,
    i.e. `coordsCartesian(mol)`.
- `rads::Vector{Float64}`: per-atom van der Waals radius, i.e. radii(mol).
- `tree::KDTree`: neighbour-query tree over cart, i.e. `neighbourTree(mol)`.
- `rmax::Float64`: largest per-atom radius in rads, i.e. `rMax(mol)`; bounds
    the candidate search per atom (`d_ij` < `r_i` + `r_j` ≤ `r_i` + rmax).

# Returns
- `Vector{Float64}`: one excluded volume per atom, in the same order as
    cart's columns / rads; each entry is ≥ 0 and ≤ `sphereVolume(rads[i])`.
"""
function excludedVolume(
    cart::Matrix{Float64},
    rads::Vector{Float64},
    tree::KDTree,
    rmax::Float64,
)::Vector{Float64}

    vols = Vector{Float64}(undef, size(cart, 2))
    n = size(cart, 2)
    # every atom is independent and writes only vols[i], so
    # the blocks run on the Julia threads (large inputs)
    tmapBlocks(n, ATOM_BLOCK; threaded = n ≥ ATOM_PARALLEL_MIN) do blk
        _excludedVolumeBlock!(vols, cart, rads, tree, rmax, blk)
    end
    return vols
end

"""
[`excludedVolume`](@ref) for the atoms `blk` only, written into
`vols[blk]`. Owns its scratch, so blocks can run concurrently.

# Returns
- `nothing`.

# Exceptions
- `BoundsError` if `blk` does not match `cart` or `rads` (a caller error).
"""
function _excludedVolumeBlock!(
    vols::Vector{Float64},
    cart::Matrix{Float64},
    rads::Vector{Float64},
    tree::KDTree,
    rmax::Float64,
    blk::UnitRange{Int},
)::Nothing
    # per-block scratch, reused: the sample points mapped onto atom i's sphere
    # (coordinate vectors) and whether each is claimed by some neighbour
    npts = length(_PTS)
    xs, ys, zs = Vector{Float64}(undef, npts),
    Vector{Float64}(undef, npts),
    Vector{Float64}(undef, npts)
    hit = Vector{Bool}(undef, npts)

    @inbounds for i in blk
        x = cart[1, i]
        y = cart[2, i]
        z = cart[3, i]

        pI = (x, y, z)

        # candidate list of all possible overlapping radii.
        # Radii can overlap when: d_ij < r_i + r_j, and since
        # r_j ≤ rMax; d_ij < r_i + r_j ≤ r_i + rMax
        # inrange requires an AbstractVector query point, not a Tuple/Vec3
        candidates = inrange(tree, SVector(pI), rads[i] + rmax)

        if length(candidates) == 1
            vols[i] = sphereVolume(rads[i])

        else
            # check potential candidate points
            planes = Vector{Tuple{Vec3,Float64}}()
            sizehint!(planes, length(candidates))
            for c in candidates
                # skip self
                c == i && continue

                pJ = (cart[1, c], cart[2, c], cart[3, c])
                dst = sqrt(sum((pI .- pJ) .^ 2))

                # only actual overlaps matter
                dst ≥ rads[i] + rads[c] && continue

                # radical plane between i and j. Store the threshold
                # planeDist + dot(pI, n) rather than planeDist,
                # so the per-sample-point test below is dot(x, n) > thresh
                # instead of dot(x .- pI, n) > planeDist.
                dst2 = dst^2
                planeDist = (dst2 + rads[i]^2 - rads[c]^2) / (2 * dst)
                n = (pJ .- pI) ./ dst

                push!(planes, (n, planeDist + dot(pI, n)))
            end

            # Scale/translate each of _pts onto atom i's sphere and count
            # victims: points that fall beyond at least one neighbour's
            # radical plane, i.e. are claimed by that neighbour instead of i.
            # break on first violation, since a point is a victim at most
            # once regardless of how many planes it fails.
            # survivors = N_VOL_SHELL - victims.
            #
            # Vectorized over points rather than breaking early per point: map every
            # point onto the sphere once, then test each plane against all of them,
            # OR-ing the result. The comparison is exactly dot(x, n) > thresh as before
            # (same terms, same order), so the count is unchanged.
            victims = 0
            if !isempty(planes)
                r = rads[i]
                @simd for p in 1:npts
                    xs[p] = x + r * _UX[p]
                    ys[p] = y + r * _UY[p]
                    zs[p] = z + r * _UZ[p]
                    hit[p] = false
                end
                for (n, thresh) in planes
                    nx, ny, nz = n
                    @simd for p in 1:npts
                        hit[p] |= (xs[p] * nx + ys[p] * ny) + zs[p] * nz > thresh
                    end
                end
                victims = count(hit)
            end

            # scale vdW volume by num of survivors
            vols[i] = sphereVolume(rads[i]) * (N_VOL_SHELL - victims) / N_VOL_SHELL

        end
    end
    return nothing
end
