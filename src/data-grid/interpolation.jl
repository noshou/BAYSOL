# SPDX-License-Identifier: LGPL-3.0-or-later

using Dierckx: Spline1D

"""
A model curve given on the fitted (binned) grid, interpolated onto the measured grid
by an interpolating cubic spline in q (FITPACK through Dierckx.jl: not-a-knot ends,
non-uniform knots, linear extrapolation beyond the end bins; a lower degree when the
fitted grid has fewer than four points). Cubics are reproduced exactly. On crambin's
forward model the worst error is 0.001 σ for 1 % data at the default `rebin`
(0.06 σ at `rebin = 4`), where linear interpolation reaches 0.25 σ (1.8 σ); a natural
spline (zero curvature at the ends) was tried and is 200× worse there.

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
    k = min(3, length(info.q) - 1) # cubic where the grid allows it
    return Spline1D(info.q, Float64.(y); k = k, bc = "extrapolate")(info.qRaw)
end

"""
    rawInterpolation(info) -> Matrix{Float64}

The matrix `M` with `M * y == modelOnRaw(info, y)` for every model `y` on the fitted
grid: an interpolating spline is linear in the values it interpolates, so the map from
the fitted grid to the measured one is one matrix, built here from the unit vectors. The
product of `M` with a matrix of curves evaluates them all at once, where `modelOnRaw`
builds a spline per curve.

# Arguments
- `info::ShannonInfo`.

# Returns
- `Matrix{Float64}`, `length(info.qRaw) × length(info.q)`.

# Exceptions
- `ArgumentError`: the fitted grid has fewer than two points.
"""
function rawInterpolation(info::ShannonInfo)::Matrix{Float64}
    n = length(info.q)
    M = Matrix{Float64}(undef, length(info.qRaw), n)
    e = zeros(n)
    for j in 1:n
        e[j] = 1.0
        M[:, j] = modelOnRaw(info, e)
        e[j] = 0.0
    end
    return M
end
