# SPDX-License-Identifier: LGPL-2.1-or-later

"""
    BeadClass

Where a hydration-shell bead sits, matching CRYSOL 3's three border-layer
populations (each carries its own fitted contrast; CRYSOL's defaults are
1, 1, 0 in units of 0.03 e/Å³).

- `CONVEX`:  outer surface, open solvent ahead of it.
- `CONCAVE`: outer surface but recessed.
- `CAVITY`:  enclosed interior void, unreachable from outside.
"""
@enum BeadClass CONVEX CONCAVE CAVITY

"""
Classify one shell bead by what fraction of its outward hemisphere escapes the
molecule. Rays are cast only over [`BEAD_RAY_RANGE`](@ref), and the outward normal is
tried first so open surfaces, which is the common case, costs one ray.
"""
function _bead_class(
    p::NTuple{3,Float64},
    n̂::NTuple{3,Float64},
    nb::Vector{Int},
    dirs::Vector{Vec3},
    crds::Matrix{Float64},
    rads::Vector{Float64},
    probe::Float64
)::BeadClass
    isempty(nb) && return CONVEX
    blocked(p, n̂, nb, crds, rads, probe) || return CONVEX

    esc = 0; tot = 0
    @inbounds for d in dirs
        d[1] * n̂[1] + d[2] * n̂[2] + d[3] * n̂[3] > 0.0 || continue
        tot += 1
        blocked(p, d, nb, crds, rads, probe) || (esc += 1)
    end
    tot == 0 && return CONVEX

    esc == 0 && return CAVITY
    return esc / tot ≥ BEAD_CONVEX_ESCAPE ? CONVEX : CONCAVE
end

"""
Indices selecting a prefix of each atom's block, sized in proportion to that
block, totalling exactly budget out of m points.

Allocation is cumulative-floor (Bresenham): atom i gets
floor(`C_i`·budget/m) - floor(`C_{i-1}`·budget/m) where `C_i` is the running
accepted count. The differences sum to budget with no rounding drift, and each
is within one point of the proportional share.
"""
function _prefix_thin(counts::Vector{Int}, m::Int, budget::Int)::Vector{Int}
    idx = Vector{Int}(undef, 0); sizehint!(idx, budget)
    base = 0; prev = 0
    @inbounds for c in counts
        c == 0 && continue
        cum = base + c
        take = (cum * budget) ÷ m - prev
        for t in 1:take
            push!(idx, base + t)          # prefix of this atom's block
        end
        base = cum
        prev = (cum * budget) ÷ m
    end
    return idx
end

"""
Classification pass behind [`sasa`](@ref). A second function barrier for
the same reason [`_sasa_loop`](@ref) is one: the inrange query per bead would
otherwise dispatch dynamically on the non-concrete tree type, once per bead.
"""
function _class_loop(
    tree::T, pts::Matrix{Float64}, nrm::Matrix{Float64}, crds::Matrix{Float64},
    rads::Vector{Float64}, probe::Float64, dirs::Vector{Vec3}
)::Vector{BeadClass} where {T}
    out = Vector{BeadClass}(undef, size(pts, 2))
    @inbounds for k in axes(pts, 2)
        nb = inrange(tree, view(pts, :, k), BEAD_RAY_RANGE)
        out[k] = _bead_class(
            (pts[1, k], pts[2, k], pts[3, k]),
            (nrm[1, k], nrm[2, k], nrm[3, k]),
            nb,
            dirs,
            crds,
            rads,
            probe
        )
    end
    return out
end

"""
The solvent-accessible surface of mol as a point cloud: the area each point
stands for, and which CRYSOL border-layer population it belongs to.

Each atom is sampled at [`SHELL_SAMPLE`](@ref) directions and the cloud is then
thinned to `n_target` points for the whole molecule, by keeping a prefix of
each atom's accepted points sized in proportion to that atom's count. Every survivor 
then carries an equal sum(area)/M, so sum(areas) is the solvent-accessible area.

# Arguments
- `mol`: molecule whose surface to sample.

# Keywords
-   `probe`: solvent probe radius in Å; probe ≥ 0. Default [`PROBE_RADIUS`](@ref) (water, 1.4).
-   `n_target`: total points to keep; > 0. Default
    [`SHELL_N_TARGET`](@ref) (nothing), deriving it from
    the accessible area via [`SHELL_AREA_PER_POINT`](@ref)
    so spacing stays fixed as the molecule grows. A cloud
    already smaller than the budget is kept whole.

# Returns
-   `pts`::Matrix{Float64}, (3, M): accessible points in mol's centred
    cartesian frame, sharing the origin `coords_cartesian` uses.
-   `areas::Vector{Float64}, (M,)`: Å² per point, equal across all M.
-   `class::Vector{BeadClass}, (M,)`: per-point [`BeadClass`](@ref). Cavity
    detection is exact for voids up to [`BEAD_RAY_RANGE`](@ref) across;
    anything larger classifies as open surface.

M is 0 for a molecule with no accessible surface; pts is then (3, 0).
"""
function sasa(
    mol::Molecule;
    probe::Float64                  = PROBE_RADIUS,
    n_target::Union{Nothing,Int}    = SHELL_N_TARGET
)::Tuple{Matrix{Float64},Vector{Float64},Vector{BeadClass}}
    n_target === nothing || n_target > 0 ||
        throw(DomainError(n_target, "n_target must be > 0"))
    probe ≥ 0.0 || throw(DomainError(probe, "probe must be ≥ 0"))

    pmap = plastic_points(SHELL_SAMPLE)
    rads = radii(mol)
    rmax = r_max(mol)
    crds = coords_cartesian(mol)
    tree = neighbour_tree(mol)
    pts, areas, nrm, counts =
        _sasa_loop(tree, crds, rads, rmax, pmap, probe, SHELL_SAMPLE, SASA_N_OCC)

    total = sum(areas)
    m = length(areas)
    budget = n_target === nothing ?
        max(SHELL_MIN_POINTS, round(Int, total / SHELL_AREA_PER_POINT)) : n_target

    if m > budget
        idx = _prefix_thin(counts, m, budget)
        pts, nrm = pts[:, idx], nrm[:, idx]
        areas = fill(total / length(idx), length(idx))
    end

    class = _class_loop(tree, pts, nrm, crds, rads, probe,
                        plastic_points(BEAD_RAY_DIRS))
    return pts, areas, class
end

"""
Per-atom loop behind [`sasa`](@ref), split out as a function barrier:
`neighbour_tree(mol)`'s KDTree has no concrete type at the call site (it's a
Molecule-cached, non-concretely-typed field), so the barrier lets Julia specialize.

Per atom i, with ρ = rads[i] + probe:

1. [`_caps!`](@ref) settles `ALL_BURIED` (skip) and `ALL_EXPOSED` (keep all `n_pts`
    directions) exactly, and otherwise packs the K caps that actually cut i's sphere.
    Only those can occlude a point of it, so every other neighbour is dropped here.
2. The directions are tested in two blocks of the prefix-stable plastic sequence,
    1:`n_occ` then `n_occ`+1:`n_pts`. Within a block the test is vectorized over points,
    one cap at a time (direction u is occluded by cap j iff u·cⱼ ≥ tⱼ), and stops
    early once every point of the block is occluded (checked every 4 caps).
3. Witness pass: if no point of the first block is exposed, the atom (which can then
    expose at most ~`3/n_occ` of its sphere, by the rule of three) is dropped without
    testing the second block. `n_occ` = `n_pts` turns the pass off. This trades a little 
    accessible area for speed, by design: with [`SASA_N_OCC`](@ref) the total loss is 
    kept within the 256-direction sampling's own error (≤ 0.92 %; 0.31–0.57 % measured 
    on the protein fixtures, see its docstring).

Atoms that do not bail keep exactly the points the plain per-point test keeps, in the
same order, so [`_prefix_thin`](@ref)'s prefixes are unchanged.

# Arguments
- `tree`, `crds`, `rads`, `rmax`, `probe`: the molecule's neighbour tree, (3, n)
    coordinates, radii, largest radius, and the probe radius.
- `pmap`: unit sample directions; the first `n_pts` are used.
- `n_pts`: directions per atom; `n_occ`: witness-pass prefix, 0 < `n_occ` ≤ `n_pts`.

# Returns
- `(pts, areas, nrm, counts)`: accepted points (3, M), the area each stands for,
    their outward unit normals (3, M), and accepted points per atom.
"""
function _sasa_loop(
    tree::T,
    crds::Matrix{Float64},
    rads::Vector{Float64},
    rmax::Float64,
    pmap::Vector{Vec3},
    probe::Float64,
    n_pts::Int,
    n_occ::Int
)::Tuple{Matrix{Float64},Vector{Float64},Matrix{Float64},Vector{Int}} where {T}

    xs = Float64[]; ys = Float64[]; zs = Float64[]; areas = Float64[]
    nx = Float64[]; ny = Float64[]; nz = Float64[]
    upper_bound = size(crds, 2) * n_pts
    sizehint!(xs, upper_bound); sizehint!(ys, upper_bound); sizehint!(zs, upper_bound)
    sizehint!(areas, upper_bound)
    sizehint!(nx, upper_bound); sizehint!(ny, upper_bound); sizehint!(nz, upper_bound)
    counts = zeros(Int, size(crds, 2))

    # directions as coordinate vectors, so the per-cap test vectorizes over points
    ux = [pmap[j][1] for j in 1:n_pts]
    uy = [pmap[j][2] for j in 1:n_pts]
    uz = [pmap[j][3] for j in 1:n_pts]
    hit = zeros(UInt8, n_pts)                 # 0x01 where some cap occludes direction j

    # per-atom scratch, reused: neighbour candidates and the packed caps
    candidates = Int[]
    cx = Float64[]; cy = Float64[]; cz = Float64[]; ct = Float64[]

    for i in axes(crds, 2)
        x = crds[1, i]; y = crds[2, i]; z = crds[3, i]
        ρ = rads[i] + probe
        full = 4 * π * ρ^2
        per_pt = full / n_pts   # every direction stands for this much

        empty!(candidates)
        inrange!(candidates, tree, @view(crds[:, i]), ρ + rmax + probe)
        nc = length(candidates)
        if length(cx) < nc
            resize!(cx, nc); resize!(cy, nc); resize!(cz, nc); resize!(ct, nc)
        end
        status, K = _caps!(cx, cy, cz, ct, i, candidates, crds, rads, probe)
        status == ALL_BURIED && continue

        if status == ALL_EXPOSED
            fill!(hit, 0x00)
        else
            # witness block, then (unless it bails) the rest
            _occlude!(hit, ux, uy, uz, cx, cy, cz, ct, K, 1, n_occ)
            _n_open(hit, 1, n_occ) == 0 && continue
            _occlude!(hit, ux, uy, uz, cx, cy, cz, ct, K, n_occ + 1, n_pts)
        end

        got = 0
        @inbounds for j in 1:n_pts
            hit[j] == 0x00 || continue
            push!(xs, x + ρ * ux[j]); push!(ys, y + ρ * uy[j]); push!(zs, z + ρ * uz[j])
            push!(nx, ux[j]); push!(ny, uy[j]); push!(nz, uz[j])
            push!(areas, per_pt)
            got += 1
        end
        counts[i] = got
    end

    pts = Matrix{Float64}(undef, 3, length(areas))
    nrm = Matrix{Float64}(undef, 3, length(areas))
    @inbounds @fastmath @simd for k in eachindex(areas)
        pts[1, k] = xs[k]; pts[2, k] = ys[k]; pts[3, k] = zs[k]
        nrm[1, k] = nx[k]; nrm[2, k] = ny[k]; nrm[3, k] = nz[k]
    end
    return pts, areas, nrm, counts
end

"Number of open (unoccluded) directions in hit[lo:hi]."
function _n_open(hit::Vector{UInt8}, lo::Int, hi::Int)::Int
    s = 0
    @inbounds @fastmath @simd for j in lo:hi
        s += hit[j]
    end
    return (hi - lo + 1) - s
end

"""
Mark in hit[lo:hi] which of directions lo:hi the first K packed caps occlude
(direction j by cap k iff `u_j`·`c_k` ≥ `t_k`, see [`_caps!`](@ref)): vectorized over
directions, one cap at a time, stopping early once the whole block is occluded
(checked every 4 caps, so the check stays a small share of the work).

# Returns
- `nothing`; hit[lo:hi] is overwritten.
"""
function _occlude!(
    hit::Vector{UInt8}, ux::Vector{Float64}, uy::Vector{Float64}, uz::Vector{Float64},
    cx::Vector{Float64}, cy::Vector{Float64}, cz::Vector{Float64}, ct::Vector{Float64},
    K::Int, lo::Int, hi::Int
)::Nothing
    @inbounds @fastmath @simd for j in lo:hi
        hit[j] = 0x00
    end
    @inbounds for k in 1:K
        a = cx[k]; b = cy[k]; c = cz[k]; t = ct[k]
        @fastmath @simd for j in lo:hi
            hit[j] |= UInt8(ux[j] * a + uy[j] * b + uz[j] * c ≥ t)
        end
        (k & 3) == 0 && _n_open(hit, lo, hi) == 0 && return nothing
    end
    return nothing
end
