# SPDX-License-Identifier: LGPL-3.0-or-later

using StaticArrays: SVector
using LinearAlgebra: dot, cross, norm, normalize
using FastClosures: @closure

const _coord = SVector{3,Float64}

"checks if two points in 'points' are degenerate"
_dgn(points, a, b, ε) = all(isapprox.(points[a], points[b]; atol = ε))

"computes unit normal of three points"
_normal(a, b, c) = normalize(cross(b - a, c - a))

"signed height of point d above the plane through a with normal n"
_height(n, d, a) = dot(n, d - a)

"One triangular face of the growing hull."
mutable struct _Face
    v::NTuple{3,Int}       # corners, counter-clockwise seen from outside
    n::_coord               # unit outward normal
    d::Float64              # plane offset: n ⋅ x = d, so the height of x is n ⋅ x - d
    nb::NTuple{3,Int}      # face across edge i, the edge (v[i], v[i % 3 + 1])
    out::Vector{Int}        # points above this face, not yet known to be inside the hull
    far::Int                # the highest of them (0 when there are none)
    farH::Float64           # and its height
    seen::Int               # round in which the face was found visible
    alive::Bool
end

"The face through corners i, j, k (in this winding), or nothing if they are collinear."
function _newFace(points::Vector{_coord}, i::Int, j::Int, k::Int, ε::Float64)
    a, b, c = points[i], points[j], points[k]
    m = cross(b - a, c - a)
    len = norm(m)
    (isfinite(len) && len > ε) || return nothing
    n = m / len
    return _Face((i, j, k), n, dot(n, a), (0, 0, 0), Int[], 0, 0.0, 0, true)
end

"Each point of `cand` (except `skip`) goes to the first face of `ids` it is above by more
than ε; a point above none of them is inside the hull and is dropped for good."
function _assign!(
    faces::Vector{_Face}, ids::Vector{Int}, points::Vector{_coord},
    cand::Vector{Int}, skip::Int, ε::Float64,
)
    @inbounds for q in cand
        q == skip && continue
        pq = points[q]
        for id in ids
            f = faces[id]
            h = dot(f.n, pq) - f.d
            if h > ε
                push!(f.out, q)
                if h > f.farH
                    f.far = q
                    f.farH = h
                end
                break
            end
        end
    end
    return nothing
end

"Neighbours of the four faces of the starting tetrahedron: two faces are neighbours
when one runs along an edge in the opposite direction of the other."
function _linkInitial!(faces::Vector{_Face})::Bool
    edges = Dict{Tuple{Int,Int},Int}()
    for (id, f) in pairs(faces), i in 1:3
        edges[(f.v[i], f.v[i%3+1])] = id
    end
    for f in faces
        nb = ntuple(i -> get(edges, (f.v[i%3+1], f.v[i]), 0), 3)
        any(iszero, nb) && return false
        f.nb = nb
    end
    return true
end

"Indices of the vertices of the convex hull of `points`, grown from the tetrahedron
`simplex`; nothing if the construction breaks down (the caller then compares all
pairs, which is slow but right)."
function _hull(
    points::Vector{_coord}, ε::Float64, simplex::NTuple{4,Int},
)::Union{Nothing,Vector{Int}}
    a, b, c, d = simplex
    center = (points[a] + points[b] + points[c] + points[d]) / 4

    # the four faces, each with its normal pointing away from the centre
    faces = _Face[]
    for (i, j, k) in ((a, b, c), (a, b, d), (a, c, d), (b, c, d))
        f = _newFace(points, i, j, k, ε)
        f === nothing && return nothing
        if dot(f.n, center) - f.d > 0   # pointing inward: reverse the winding
            f = _newFace(points, i, k, j, ε)
            f === nothing && return nothing
        end
        push!(faces, f)
    end
    _linkInitial!(faces) || return nothing

    # every other point goes to a face it is above, or is inside and is dropped
    cand = [q for q in eachindex(points) if q ∉ simplex]
    _assign!(faces, [1, 2, 3, 4], points, cand, 0, ε)
    todo = [id for id in 1:4 if !isempty(faces[id].out)]

    round = 0
    limit = 10 * length(points) + 100   # a guard: every round adds a hull vertex
    while !isempty(todo)
        f0 = pop!(todo)
        (faces[f0].alive && !isempty(faces[f0].out)) || continue
        round += 1
        round > limit && return nothing
        p = faces[f0].far
        pp = points[p]

        # the faces that see p, found outward from f0, and the horizon: the edges where
        # a visible face meets one that does not
        visible = [f0]
        faces[f0].seen = round
        horizon = Tuple{Int,Int,Int,Int}[]   # (u, v, face outside, its slot of (v, u))
        s = 1
        while s <= length(visible)
            g = faces[visible[s]]
            s += 1
            for i in 1:3
                h = g.nb[i]
                hf = faces[h]
                hf.seen == round && continue
                if dot(hf.n, pp) - hf.d > ε
                    hf.seen = round
                    push!(visible, h)
                else
                    u, v = g.v[i], g.v[i%3+1]
                    j = 0
                    for t in 1:3
                        if hf.v[t] == v && hf.v[t%3+1] == u
                            j = t
                            break
                        end
                    end
                    j == 0 && return nothing
                    push!(horizon, (u, v, h, j))
                end
            end
        end

        # the points that were above a visible face are shared out again below
        cand = Int[]
        for id in visible
            append!(cand, faces[id].out)
            faces[id].alive = false
        end

        # one new face per horizon edge, (u, v, p), keeping the direction of the edge
        newIds = Int[]
        startAt = Dict{Int,Int}()   # horizon vertex => new face whose edge starts there
        endAt = Dict{Int,Int}()     # ... and the one whose edge ends there
        for (u, v, h, j) in horizon
            nf = _newFace(points, u, v, p, ε)
            nf === nothing && return nothing
            nf.nb = (h, 0, 0)
            push!(faces, nf)
            id = length(faces)
            faces[h].nb = Base.setindex(faces[h].nb, id, j)
            (haskey(startAt, u) || haskey(endAt, v)) && return nothing   # pinched horizon
            startAt[u] = id
            endAt[v] = id
            push!(newIds, id)
        end
        for id in newIds
            f = faces[id]
            u, v, _ = f.v
            sv = get(startAt, v, 0)
            eu = get(endAt, u, 0)
            (sv == 0 || eu == 0) && return nothing
            f.nb = (f.nb[1], sv, eu)
        end

        _assign!(faces, newIds, points, cand, p, ε)
        for id in newIds
            isempty(faces[id].out) || push!(todo, id)
        end
    end

    onHull = falses(length(points))
    for f in faces
        f.alive || continue
        for t in f.v
            onHull[t] = true
        end
    end
    # a closed triangulated sphere has F = 2V - 4 faces; anything else went wrong
    hullVertices = findall(onHull)
    nLive = count(f -> f.alive, faces)
    (length(hullVertices) >= 4 && nLive == 2 * length(hullVertices) - 4) || return nothing
    return hullVertices
end

"Componentwise minimum and maximum of the points (the corners of their bounding box)."
function _bounds(points::Vector{_coord})
    lo = hi = points[1]
    for p in points
        lo = min.(lo, p)
        hi = max.(hi, p)
    end
    return lo, hi
end

"The vertices of the convex hull of `points` (their indices), or nothing if the cloud
has no 3-D hull (fewer than four points, or collinear, coplanar or all equal to within
the tolerance). ε is `scale` units in the last place of the size of the cloud."
function _quickhull(
    points::Vector{_coord};
    scale::Float64 = 100.0,
)::Union{Nothing,Vector{Int}}
    length(points) < 4 && return nothing

    # tolerance from the size of the cloud (componentwise bounding box)
    _eps = @closure (points) -> begin
        lo, hi = _bounds(points)
        scale * eps(Float64) * norm(hi - lo)
    end
    ε = _eps(points)

    # no possible non-degenerate simplex exists; return nothing
    iszero(ε) && return nothing

    simplex = _3SimplexInitial(points, ε)
    isnothing(simplex) && return nothing

    # a cloud thinner than FLAT_FACTOR·ε has no reliable hull at this tolerance (the
    # planes are tilted by rounding): the caller compares all pairs instead
    i, j, k, l = simplex
    thickness = abs(_height(_normal(points[i], points[j], points[k]), points[l], points[i]))
    thickness > FLAT_FACTOR * ε || return nothing
    return _hull(points, ε, simplex)
end

"Attempts to find a set of coordinates such that extrema of each coordinates are included.
If two points are degenerate, picks a third point at a sufficient epsilon distance. If
three points degenerate, falls back to finding two points via brute force. If no points
can be found, returns nothing."
function _3SimplexInitial(
    points::Vector{_coord}, ε::Float64,
)::Union{Nothing,NTuple{4,Int}}

    length(points) < 4 && return nothing

    # heuristic to find a "big enough" set of coordinates.
    # (indices, not points: argmin/argmax over the indices return an Int)
    candidates = [
        argmin(i -> points[i][1], eachindex(points)),
        argmax(i -> points[i][1], eachindex(points)),
        argmin(i -> points[i][2], eachindex(points)),
        argmax(i -> points[i][2], eachindex(points)),
        argmin(i -> points[i][3], eachindex(points)),
        argmax(i -> points[i][3], eachindex(points)),
    ]

    # check for degeneracies and dedup
    distinct = Int[]
    for p in candidates
        any(q -> _dgn(points, p, q, ε), distinct) && continue
        push!(distinct, p)
    end

    # dispatch into correct tuple size
    found = if length(distinct) >= 4
        Tuple(distinct[1:4])
    elseif length(distinct) == 3
        Tuple(distinct)
    elseif length(distinct) == 2
        Tuple(distinct)
    elseif length(distinct) == 1
        Tuple(distinct)
    else
        ()
    end

    return _tetra(points, ε, found)
end

"Is (i, j, k, l) a real tetrahedron? c must be more than ε from the line through a, b,
and d more than ε from the plane of a, b, c."
function _isTetra(points::Vector{_coord}, ε::Float64, i::Int, j::Int, k::Int, l::Int)
    a, b, c, d = points[i], points[j], points[k], points[l]
    ab = b - a
    norm(ab) > ε || return false
    norm(cross(ab, c - a)) / norm(ab) > ε || return false
    return abs(_height(_normal(a, b, c), d, a)) > ε
end

"The two indices of `t` whose points are farthest apart."
function _farthestPair(points::Vector{_coord}, t::NTuple{N,Int}) where {N}
    pair = (t[1], t[2])
    best = -1.0
    for x in 1:(N-1), y in (x+1):N
        s = sum(abs2, points[t[x]] - points[t[y]])
        s > best && ((pair, best) = ((t[x], t[y]), s))
    end
    return pair
end

"Triangle (i, j, k), known not to be collinear: the point farthest from its plane makes
the fourth corner, or nothing if every point is within ε of the plane (flat cloud)."
function _fromTriangle(points::Vector{_coord}, ε::Float64, i::Int, j::Int, k::Int)
    a, b, c = points[i], points[j], points[k]
    n = _normal(a, b, c)
    height, l = findmax(p -> abs(_height(n, points[p], a)), eachindex(points))
    height > ε || return nothing
    return (i, j, k, l)
end

"Computes if the tetrahedron is valid or not"
function _tetra end

"5 or 6 candidates: of the 4-subsets that are real tetrahedra, the one of largest volume.
If there is none, restart from the farthest pair."
function _tetra(points::Vector{_coord}, ε::Float64, t::NTuple{N,Int}) where {N}
    best = 0.0
    bestT = nothing
    for i in 1:(N-3), j in (i+1):(N-2), k in (j+1):(N-1), l in (k+1):N
        q = (t[i], t[j], t[k], t[l])
        _isTetra(points, ε, q...) || continue
        a, b, c, d = points[q[1]], points[q[2]], points[q[3]], points[q[4]]
        v = abs(dot(b - a, cross(c - a, d - a)))
        v > best && ((best, bestT) = (v, q))
    end
    bestT === nothing || return bestT
    return _tetra(points, ε, _farthestPair(points, t))
end

"4 candidates: the one attempt. If it fails, restart from the farthest pair."
function _tetra(points::Vector{_coord}, ε::Float64, t::NTuple{4,Int})
    _isTetra(points, ε, t...) && return t
    return _tetra(points, ε, _farthestPair(points, t))
end

"3 candidates: if they are collinear, restart from the farthest pair; else find the
fourth corner by the distance from their plane."
function _tetra(points::Vector{_coord}, ε::Float64, t::NTuple{3,Int})
    i, j, k = t
    a, b, c = points[i], points[j], points[k]
    ab = b - a
    norm(ab) > ε || return _tetra(points, ε, (i, j))
    if norm(cross(ab, c - a)) / norm(ab) <= ε
        return _tetra(points, ε, _farthestPair(points, t))
    end
    return _fromTriangle(points, ε, i, j, k)
end

"2 candidates: the point farthest from their line is the third corner (nothing if the
whole cloud is collinear), then the fourth by the plane."
function _tetra(points::Vector{_coord}, ε::Float64, t::NTuple{2,Int})
    i, j = t
    a, b = points[i], points[j]
    ab = b - a
    length_ab = norm(ab)
    length_ab > ε || return nothing
    u = ab / length_ab
    dist, k = findmax(p -> norm(cross(u, points[p] - a)), eachindex(points))
    dist > ε || return nothing
    return _fromTriangle(points, ε, i, j, k)
end

"1 candidate: the point farthest from it is the second (nothing if all points coincide)."
function _tetra(points::Vector{_coord}, ε::Float64, t::NTuple{1,Int})
    a = points[t[1]]
    dist, j = findmax(p -> norm(points[p] - a), eachindex(points))
    dist > ε || return nothing
    return _tetra(points, ε, (t[1], j))
end

"No candidates: the heuristic found nothing, which says nothing about the cloud, so
start the scan from the first point."
_tetra(points::Vector{_coord}, ε::Float64, ::NTuple{0,Int}) = _tetra(points, ε, (1,))
