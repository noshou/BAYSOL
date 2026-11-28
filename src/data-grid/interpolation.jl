# SPDX-License-Identifier: LGPL-3.0-or-later

"""
The factorised moment system of the interpolating spline through the nodes `x`: the
second derivatives `m` at the nodes solve one tridiagonal system whose matrix depends
only on `x`, so it is eliminated once here and solved for any number of curves.

- `x`: the nodes (strictly increasing, at least two).
- `h`: the node spacings.
- `w`, `piv`, `up`: the multipliers, pivots and upper diagonal of the eliminated system
  for the interior moments (empty below four nodes).
"""
struct _SplineSystem
    x::Vector{Float64}
    h::Vector{Float64}
    w::Vector{Float64}
    piv::Vector{Float64}
    up::Vector{Float64}
end

"""
    _splineSystem(x) -> _SplineSystem

Eliminate the tridiagonal system of the not-a-knot cubic spline through `x`. The
end conditions (third derivative continuous at the second and the last-but-one node)
fix the end moments from the interior ones and fold into the first and last rows, which
keeps the system tridiagonal. Below four nodes there is nothing to eliminate: two nodes
give the line and three the parabola, as a lower-degree FITPACK spline did.

# Arguments
- `x::AbstractVector{<:Real}`: the nodes, strictly increasing.

# Returns
- `_SplineSystem`.

# Exceptions
- `ArgumentError`: fewer than two nodes.
"""
function _splineSystem(x::AbstractVector{<:Real})::_SplineSystem
    n = length(x)
    n ≥ 2 || throw(ArgumentError("a spline needs at least two nodes"))
    xs = Float64.(x)
    h = diff(xs)
    if n < 4
        return _SplineSystem(xs, h, Float64[], Float64[], Float64[])
    end
    p = n - 2
    a = Vector{Float64}(undef, p) # row k, column k - 1
    b = Vector{Float64}(undef, p)
    c = Vector{Float64}(undef, p) # row k, column k + 1
    @inbounds for k in 1:p
        a[k] = h[k]
        b[k] = 2 * (h[k] + h[k+1])
        c[k] = h[k+1]
    end
    @inbounds begin
        b[1] += h[1] * (1 + h[1] / h[2])
        c[1] -= h[1]^2 / h[2]
        a[p] -= h[n-1]^2 / h[n-2]
        b[p] += h[n-1] * (1 + h[n-1] / h[n-2])
    end
    w = zeros(p)
    @inbounds for k in 2:p
        w[k] = a[k] / b[k-1]
        b[k] -= w[k] * c[k-1]
    end
    return _SplineSystem(xs, h, w, b, c)
end

"""
    _moments!(m, sys, y) -> m

Write the second derivatives of the spline through `(sys.x, y)` into `m`.

# Arguments
- `m::Vector{Float64}`: output, as long as `y`.
- `sys::_SplineSystem`.
- `y::AbstractVector{Float64}`: the values at the nodes.

# Returns
- `m`.

# Exceptions
- None.
"""
function _moments!(m::Vector{Float64}, sys::_SplineSystem, y::AbstractVector{Float64})
    n = length(sys.x)
    h = sys.h
    if n == 2
        fill!(m, 0.0)
        return m
    elseif n == 3
        # one parabola: constant second derivative
        mm = 2 * ((y[3] - y[2]) / h[2] - (y[2] - y[1]) / h[1]) / (h[1] + h[2])
        fill!(m, mm)
        return m
    end
    p = n - 2
    w, piv, up = sys.w, sys.piv, sys.up
    # right-hand side 6 (d_i - d_{i-1}) built in place in m[2:n-1], then eliminated
    @inbounds begin
        dPrev = (y[2] - y[1]) / h[1]
        for k in 1:p
            d = (y[k+2] - y[k+1]) / h[k+1]
            m[k+1] = 6 * (d - dPrev)
            dPrev = d
        end
        for k in 2:p
            m[k+1] -= w[k] * m[k]
        end
        m[p+1] /= piv[p]
        for k in (p-1):-1:1
            m[k+1] = (m[k+1] - up[k] * m[k+2]) / piv[k]
        end
        m[1] = m[2] * (1 + h[1] / h[2]) - m[3] * h[1] / h[2]
        m[n] = m[n-1] * (1 + h[n-1] / h[n-2]) - m[n-2] * h[n-1] / h[n-2]
    end
    return m
end

"""
    _segments(x, xq) -> Vector{Int}

The interval of the nodes `x` that carries each query point: `i` with
`x[i] ≤ xq ≤ x[i+1]`, and the first or last interval outside the nodes (the spline's
end polynomial is extended there).

# Arguments
- `x::AbstractVector{Float64}`: the nodes, increasing.
- `xq::AbstractVector{<:Real}`: the query points.

# Returns
- `Vector{Int}`, as long as `xq`, entries in `1:length(x)-1`.

# Exceptions
- None.
"""
function _segments(x::AbstractVector{Float64}, xq::AbstractVector{<:Real})::Vector{Int}
    last = length(x) - 1
    seg = Vector{Int}(undef, length(xq))
    @inbounds for k in eachindex(xq)
        seg[k] = clamp(searchsortedlast(x, xq[k]), 1, last)
    end
    return seg
end

"""
    _evaluate!(out, sys, y, m, xq, seg) -> out

Evaluate the spline with moments `m` through `(sys.x, y)` at `xq`, whose intervals are
`seg`: on each interval the cubic of the nodes' values and second derivatives.

# Arguments
- `out::Vector{Float64}`: output, as long as `xq`.
- `sys::_SplineSystem`, `y`, `m`: the nodes, the values and the moments.
- `xq`, `seg`: the query points and their intervals ([`_segments`](@ref)).

# Returns
- `out`.

# Exceptions
- None.
"""
function _evaluate!(
    out::Vector{Float64},
    sys::_SplineSystem,
    y::AbstractVector{Float64},
    m::Vector{Float64},
    xq::AbstractVector{<:Real},
    seg::Vector{Int},
)
    x, h = sys.x, sys.h
    @inbounds @fastmath @simd for k in eachindex(xq)
        i = seg[k]
        hi = h[i]
        a = (x[i+1] - xq[k]) / hi # 1 at the left node, 0 at the right
        b = 1 - a
        out[k] =
            a * y[i] +
            b * y[i+1] +
            ((a^3 - a) * m[i] + (b^3 - b) * m[i+1]) * (hi * hi / 6)
    end
    return out
end

"""
A model curve given on the fitted (binned) grid, interpolated onto the measured grid
by an interpolating cubic spline in q (not-a-knot ends, non-uniform knots, the end
polynomial continued beyond the end bins; a parabola for three fitted points and a
line for two). Cubics are reproduced exactly. On crambin's
forward model the worst error is 0.001 σ for 1 % data at the default `rebin`
(0.06 σ at `rebin = 4`), where linear interpolation reaches 0.25 σ (1.8 σ); a natural
spline (zero curvature at the ends) was tried and is 200× worse there. The spline is
solved here (one tridiagonal system) and agrees with the FITPACK spline it replaced
to rounding.

# Arguments
- `info::ShannonInfo`.
- `y::AbstractVector{<:Real}`: the model at `info.q`.

# Returns
- `Vector{Float64}`: the model at `info.qRaw`.

# Exceptions
- `DimensionMismatch`: `y` is not as long as `info.q`.
- `ArgumentError`: the fitted grid has fewer than two points.
"""
function modelOnRaw(info::ShannonInfo, y::AbstractVector{<:Real})::Vector{Float64}
    length(y) == length(info.q) || throw(
        DimensionMismatch(
            "model has $(length(y)) points, the fitted grid $(length(info.q))",
        ),
    )
    length(info.q) ≥ 2 || throw(
        ArgumentError(
            "modelOnRaw: need at least two fitted points",
        ),
    )
    sys = _splineSystem(info.q)
    yf = Float64.(y)
    m = Vector{Float64}(undef, length(yf))
    _moments!(m, sys, yf)
    out = Vector{Float64}(undef, length(info.qRaw))
    return _evaluate!(out, sys, yf, m, info.qRaw, _segments(sys.x, info.qRaw))
end

"""
    rawInterpolation(info) -> Matrix{Float64}

The matrix `M` with `M * y == modelOnRaw(info, y)` for every model `y` on the fitted
grid: an interpolating spline is linear in the values it interpolates, so the map from
the fitted grid to the measured one is one matrix, built here from the unit vectors (the
system is eliminated and the intervals found once). The product of `M` with a matrix of
curves evaluates them all at once, where `modelOnRaw` solves a spline per curve.

# Arguments
- `info::ShannonInfo`.

# Returns
- `Matrix{Float64}`, `length(info.qRaw) × length(info.q)`.

# Exceptions
- `ArgumentError`: the fitted grid has fewer than two points.
"""
function rawInterpolation(info::ShannonInfo)::Matrix{Float64}
    n = length(info.q)
    n ≥ 2 || throw(
        ArgumentError(
            "rawInterpolation: need at least two fitted points",
        ),
    )
    sys = _splineSystem(info.q)
    seg = _segments(sys.x, info.qRaw)
    M = Matrix{Float64}(undef, length(info.qRaw), n)
    e = zeros(n)
    m = Vector{Float64}(undef, n)
    col = Vector{Float64}(undef, length(info.qRaw))
    for j in 1:n
        e[j] = 1.0
        _moments!(m, sys, e)
        _evaluate!(col, sys, e, m, info.qRaw, seg)
        copyto!(view(M, :, j), col)
        e[j] = 0.0
    end
    return M
end
