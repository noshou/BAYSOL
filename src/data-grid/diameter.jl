# SPDX-License-Identifier: LGPL-3.0-or-later

"Largest squared distance between two of the columns of `P`, brute force."
function _bruteMaxSq(P::AbstractMatrix{<:Real})
    n = size(P, 2)
    best = 0.0
    @inbounds for i in 1:(n-1)
        xi, yi, zi = P[1, i], P[2, i], P[3, i]
        m = 0.0
        @fastmath @simd for j in (i+1):n
            m = max(m, (P[1, j] - xi)^2 + (P[2, j] - yi)^2 + (P[3, j] - zi)^2)
        end
        best = max(best, m)
    end
    return best
end


"""
Diameter of a point cloud: the largest distance between two of its points.

The farthest pair of a set is always a pair of vertices of its convex hull,
so the hull is built (a 3-D quickhull, `quick-hull.jl`)
and only its vertices (typically ~100 of thousands of points) are compared. Fewer than
four points, or a degenerate (collinear, coplanar or repeated) cloud, has no 3-D hull
and is compared pair by pair.

# Arguments
- `points::AbstractMatrix{<:Real}`: `(3, n)` coordinates, one column per point; `n ≥ 1`.

# Returns
- `Float64`: the diameter, in the units of `points` (0 for a single point).

# Exceptions
- `ArgumentError`: `points` is not 3-by-n, or has no column.
"""
function cloudDiameter(points::AbstractMatrix{<:Real})::Float64
    size(points, 1) == 3 || throw(
        ArgumentError(
            "cloudDiameter: points must be 3-by-n, " *
            "got $(size(points, 1))-by-$(size(points, 2))",
        ),
    )
    n = size(points, 2)
    n ≥ 1 || throw(ArgumentError("cloudDiameter: at least one point is needed"))
    if n ≥ 4
        cloud = [_coord(points[1, i], points[2, i], points[3, i]) for i in 1:n]
        hull = _quickhull(cloud)
        if hull !== nothing
            return sqrt(_bruteMaxSq(reduce(hcat, cloud[hull])))
        end
    end
    return sqrt(_bruteMaxSq(points))
end
