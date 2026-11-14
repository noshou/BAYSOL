# SPDX-License-Identifier: LGPL-3.0-or-later

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
function _beadClass(
    p::NTuple{3,Float64},
    n̂::NTuple{3,Float64},
    nb::Vector{Int},
    dirs::Vector{Vec3},
    crds::Matrix{Float64},
    rads::Vector{Float64},
    probe::Float64,
)::BeadClass
    isempty(nb) && return CONVEX
    blocked(p, n̂, nb, crds, rads, probe) || return CONVEX

    esc = 0
    tot = 0
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
function _prefixThin(counts::Vector{Int}, m::Int, budget::Int)::Vector{Int}
    idx = Vector{Int}(undef, 0)
    sizehint!(idx, budget)
    base = 0
    prev = 0
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
the same reason [`_sasaLoop`](@ref) is one: the inrange query per bead would
otherwise dispatch dynamically on the non-concrete tree type, once per bead.
"""
function _classLoop(
    tree::T, pts::Matrix{Float64}, nrm::Matrix{Float64}, crds::Matrix{Float64},
    rads::Vector{Float64}, probe::Float64, dirs::Vector{Vec3}, rayRange::Float64,
)::Vector{BeadClass} where {T}
    out = Vector{BeadClass}(undef, size(pts, 2))
    m = size(pts, 2)
    # beads are independent (each writes only out[k]), so
    # the blocks run on the Julia threads (large inputs)
    tmapBlocks(m, CLASS_BLOCK; threaded = m ≥ ATOM_PARALLEL_MIN) do blk
        @inbounds for k in blk
            nb = inrange(tree, view(pts, :, k), rayRange)
            out[k] = _beadClass(
                (pts[1, k], pts[2, k], pts[3, k]),
                (nrm[1, k], nrm[2, k], nrm[3, k]),
                nb,
                dirs,
                crds,
                rads,
                probe,
            )
        end
    end
    return out
end

"""
The solvent-accessible surface of mol as a point cloud: the area each point
stands for, and which CRYSOL border-layer population it belongs to.

Each atom is sampled at [`SHELL_SAMPLE`](@ref) directions and the cloud is then
thinned to `nTarget` points for the whole molecule, by keeping a prefix of
each atom's accepted points sized in proportion to that atom's count. Every survivor
then carries an equal sum(area)/M, so sum(areas) is the solvent-accessible area.

# Arguments
- `mol::SphereCloud`: molecule (or other sphere cloud) whose surface to sample.

# Keywords
-   `probe`: solvent probe radius in Å; probe ≥ 0.
    Default [`PROBE_RADIUS`](@ref) (water, 1.4).
-   `nTarget`: total points to keep; > 0. Default
    `nothing`, which derives it from
    the accessible area via [`SHELL_AREA_PER_POINT`](@ref)
    so spacing stays fixed as the molecule grows. A cloud
    already smaller than the budget is kept whole.
-   `shellAreaPerPoint::Real = SHELL_AREA_PER_POINT`, `shellMinPoints::Integer =
    SHELL_MIN_POINTS`: the derived point budget is `max(shellMinPoints,
    round(area / shellAreaPerPoint))`.
-   `shellSample::Integer = SHELL_SAMPLE`, `sasaNOcc::Integer = SASA_N_OCC`: directions
    per atom and the witness-pass prefix, `0 < sasaNOcc ≤ shellSample`.
-   `beadRayRange::Real = BEAD_RAY_RANGE`, `beadRayDirs::Integer = BEAD_RAY_DIRS`: the
    escape-ray range (Å) and the number of directions of the cavity classification.

# Returns
-   `pts`::Matrix{Float64}, (3, M): accessible points in mol's centred
    cartesian frame, sharing the origin `coordsCartesian` uses.
-   `areas::Vector{Float64}, (M,)`: Å² per point, equal across all M.
-   `class::Vector{BeadClass}, (M,)`: per-point [`BeadClass`](@ref). Cavity
    detection is exact for voids up to [`BEAD_RAY_RANGE`](@ref) across;
    anything larger classifies as open surface.

M is 0 for a molecule with no accessible surface; pts is then (3, 0).

# Exceptions
- `DomainError` if `nTarget` is not above 0, `probe` is negative, a shell setting is
    outside its limit (positive, counts at least 1) or `sasaNOcc` exceeds
    `shellSample`.
"""
function sasa(
    mol::SphereCloud;
    probe::Float64              = PROBE_RADIUS,
    nTarget::Union{Nothing,Int} = nothing,
    shellAreaPerPoint::Real     = SHELL_AREA_PER_POINT,
    shellMinPoints::Integer     = SHELL_MIN_POINTS,
    shellSample::Integer        = SHELL_SAMPLE,
    sasaNOcc::Integer           = SASA_N_OCC,
    beadRayRange::Real          = BEAD_RAY_RANGE,
    beadRayDirs::Integer        = BEAD_RAY_DIRS,
)::Tuple{Matrix{Float64},Vector{Float64},Vector{BeadClass}}
    nTarget === nothing || nTarget > 0 ||
        throw(DomainError(nTarget, "nTarget must be > 0"))
    probe ≥ 0.0 || throw(DomainError(probe, "probe must be ≥ 0"))
    shellAreaPerPoint > 0 ||
        throw(DomainError(shellAreaPerPoint, "shellAreaPerPoint must be > 0"))
    shellMinPoints ≥ 1 ||
        throw(DomainError(shellMinPoints, "shellMinPoints must be ≥ 1"))
    shellSample ≥ 1 || throw(DomainError(shellSample, "shellSample must be ≥ 1"))
    0 < sasaNOcc ≤ shellSample ||
        throw(DomainError(sasaNOcc, "sasaNOcc must be in (0, shellSample]"))
    beadRayRange > 0 || throw(DomainError(beadRayRange, "beadRayRange must be > 0"))
    beadRayDirs ≥ 1 || throw(DomainError(beadRayDirs, "beadRayDirs must be ≥ 1"))

    pmap = plasticPoints(Int(shellSample))
    rads = radii(mol)
    rmax = rMax(mol)
    crds = coordsCartesian(mol)
    tree = neighbourTree(mol)
    pts, areas, nrm, counts =
        _sasaLoop(
            tree, crds, rads, rmax, pmap, probe, Int(shellSample), Int(sasaNOcc),
        )

    total = sum(areas)
    m = length(areas)
    budget =
        nTarget === nothing ?
        max(Int(shellMinPoints), round(Int, total / shellAreaPerPoint)) : nTarget

    if m > budget
        idx = _prefixThin(counts, m, budget)
        pts, nrm = pts[:, idx], nrm[:, idx]
        areas = fill(total / length(idx), length(idx))
    end

    class = _classLoop(tree, pts, nrm, crds, rads, probe,
        plasticPoints(Int(beadRayDirs)), Float64(beadRayRange))
    return pts, areas, class
end

"""
Per-atom loop behind [`sasa`](@ref), split out as a function barrier:
`neighbourTree(mol)`'s KDTree has no concrete type at the call site (it's a
Molecule-cached, non-concretely-typed field), so the barrier lets Julia specialize.

Per atom i, with ρ = rads[i] + probe:

1. [`_caps!`](@ref) settles `ALL_BURIED` (skip) and `ALL_EXPOSED` (keep all `nPts`
    directions) exactly, and otherwise packs the K caps that actually cut i's sphere.
    Only those can occlude a point of it, so every other neighbour is dropped here.
2. The directions are tested in two blocks of the prefix-stable plastic sequence,
    1:`nOcc` then `nOcc`+1:`nPts`. Within a block the test is vectorized over points,
    one cap at a time (direction u is occluded by cap j iff u·cⱼ ≥ tⱼ), and stops
    early once every point of the block is occluded (checked every 4 caps).
3. Witness pass: if no point of the first block is exposed, the atom (which can then
    expose at most ~`3/nOcc` of its sphere, by the rule of three) is dropped without
    testing the second block. `nOcc` = `nPts` turns the pass off. This trades a little
    accessible area for speed, by design: with [`SASA_N_OCC`](@ref) the total loss is
    kept within the 256-direction sampling's own error (≤ 0.92 %; 0.31–0.57 % measured
    on the protein fixtures, see its docstring).

Atoms that do not bail keep exactly the points the plain per-point test keeps, in the
same order, so [`_prefixThin`](@ref)'s prefixes are unchanged.

# Arguments
- `tree`, `crds`, `rads`, `rmax`, `probe`: the molecule's neighbour tree, (3, n)
    coordinates, radii, largest radius, and the probe radius.
- `pmap`: unit sample directions; the first `nPts` are used.
- `nPts`: directions per atom; `nOcc`: witness-pass prefix, 0 < `nOcc` ≤ `nPts`.

# Returns
- `(pts, areas, nrm, counts)`: accepted points (3, M), the area each stands for,
    their outward unit normals (3, M), and accepted points per atom.
"""
function _sasaLoop(
    tree::T,
    crds::Matrix{Float64},
    rads::Vector{Float64},
    rmax::Float64,
    pmap::Vector{Vec3},
    probe::Float64,
    nPts::Int,
    nOcc::Int,
)::Tuple{Matrix{Float64},Vector{Float64},Matrix{Float64},Vector{Int}} where {T}

    # directions as coordinate vectors, so the per-cap test vectorizes over points
    ux = [pmap[j][1] for j in 1:nPts]
    uy = [pmap[j][2] for j in 1:nPts]
    uz = [pmap[j][3] for j in 1:nPts]

    n = size(crds, 2)
    counts = zeros(Int, n)
    # atoms are independent; each block owns its scratch and its slice of counts,
    # and the blocks run on the Julia threads (large inputs). Their points are
    # concatenated in block order, so the cloud is the serial one, bit for bit.
    parts = tmapBlocks(n, ATOM_BLOCK; threaded = n ≥ ATOM_PARALLEL_MIN) do blk
        _sasaBlock(tree, crds, rads, rmax, ux, uy, uz, probe, nPts, nOcc, blk, counts)
    end

    m = sum(length(p[4]) for p in parts)
    pts = Matrix{Float64}(undef, 3, m)
    nrm = Matrix{Float64}(undef, 3, m)
    areas = Vector{Float64}(undef, m)
    off = 0
    for (xs, ys, zs, ar, nx, ny, nz) in parts
        @inbounds @fastmath @simd for k in eachindex(ar)
            pts[1, off+k] = xs[k]
            pts[2, off+k] = ys[k]
            pts[3, off+k] = zs[k]
            nrm[1, off+k] = nx[k]
            nrm[2, off+k] = ny[k]
            nrm[3, off+k] = nz[k]
            areas[off+k]  = ar[k]
        end
        off += length(ar)
    end
    return pts, areas, nrm, counts
end

"""
[`_sasaLoop`](@ref) for the atoms `blk` only: their accepted points,
areas and normals (as vectors, in atom order), and `counts[i]` for
each of them. Owns its scratch, so blocks can run concurrently.

# Returns
- `(xs, ys, zs, areas, nx, ny, nz)`.

# Exceptions
- `BoundsError` if `blk` or `counts` do not match `crds` (a caller error).
"""
function _sasaBlock(
    tree::T,
    crds::Matrix{Float64},
    rads::Vector{Float64},
    rmax::Float64,
    ux::Vector{Float64}, uy::Vector{Float64}, uz::Vector{Float64},
    probe::Float64,
    nPts::Int,
    nOcc::Int,
    blk::UnitRange{Int},
    counts::Vector{Int},
)::NTuple{7,Vector{Float64}} where {T}
    xs = Float64[]
    ys = Float64[]
    zs = Float64[]
    areas = Float64[]
    nx = Float64[]
    ny = Float64[]
    nz = Float64[]
    hit = zeros(UInt8, nPts)                 # 0x01 where some cap occludes direction j

    # per-atom scratch, reused: neighbour candidates and the packed caps
    candidates = Int[]
    cx = Float64[]
    cy = Float64[]
    cz = Float64[]
    ct = Float64[]

    for i in blk
        x = crds[1, i]
        y = crds[2, i]
        z = crds[3, i]
        ρ = rads[i] + probe
        full = 4 * π * ρ^2
        perPt = full / nPts   # every direction stands for this much

        empty!(candidates)
        inrange!(candidates, tree, @view(crds[:, i]), ρ + rmax + probe)
        nc = length(candidates)
        if length(cx) < nc
            resize!(cx, nc)
            resize!(cy, nc)
            resize!(cz, nc)
            resize!(ct, nc)
        end
        status, K = _caps!(cx, cy, cz, ct, i, candidates, crds, rads, probe)
        status == ALL_BURIED && continue

        if status == ALL_EXPOSED
            fill!(hit, 0x00)
        else
            # witness block, then (unless it bails) the rest
            _occlude!(hit, ux, uy, uz, cx, cy, cz, ct, K, 1, nOcc)
            _nOpen(hit, 1, nOcc) == 0 && continue
            _occlude!(hit, ux, uy, uz, cx, cy, cz, ct, K, nOcc + 1, nPts)
        end

        got = 0
        @inbounds for j in 1:nPts
            hit[j] == 0x00 || continue
            push!(xs, x + ρ * ux[j])
            push!(ys, y + ρ * uy[j])
            push!(zs, z + ρ * uz[j])
            push!(nx, ux[j])
            push!(ny, uy[j])
            push!(nz, uz[j])
            push!(areas, perPt)
            got += 1
        end
        counts[i] = got
    end
    return xs, ys, zs, areas, nx, ny, nz
end

"Number of open (unoccluded) directions in hit[lo:hi]."
function _nOpen(hit::Vector{UInt8}, lo::Int, hi::Int)::Int
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
    K::Int, lo::Int, hi::Int,
)::Nothing
    @inbounds @fastmath @simd for j in lo:hi
        hit[j] = 0x00
    end
    @inbounds for k in 1:K
        a = cx[k]
        b = cy[k]
        c = cz[k]
        t = ct[k]
        @fastmath @simd for j in lo:hi
            hit[j] |= UInt8(ux[j] * a + uy[j] * b + uz[j] * c ≥ t)
        end
        (k & 3) == 0 && _nOpen(hit, lo, hi) == 0 && return nothing
    end
    return nothing
end
