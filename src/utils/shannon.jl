# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Shannon sampling of a SAXS curve. A particle of diameter `D` has a scattering
curve that carries no information at a q spacing finer than `π/D` (one *Shannon
channel*), so a curve of thousands of points holds only `(qMax - qMin)·D/π`
independent values. [`shannonData`](@ref) bins the measured curve to that
resolution and picks the band limit [`autoLmax`](@ref) the binned q range
needs; [`cloudDiameter`](@ref) supplies `D`; [`modelOnRaw`](@ref) and
[`residualStructure`](@ref) check the result against the measured data.
"""
module Shannon

using Quickhull: Quickhull
using StatsBase: autocor
using HypothesisTests: WaldWolfowitzTest
using Dierckx: Spline1D

export ShannonInfo, SHANNON_REBIN, BIN_BIAS_MAX, cloudDiameter, autoLmax,
    shannonData, binBiasRatio, modelOnRaw, rawInterpolation, residualStructure

"""
Default number of bins per Shannon channel (`k`): the bin width is `π/(k·D)`. Binning
at `k ≥ 8` preserved the Laplace posterior width and moved the MAP by less than the
posterior σ on the fitting tests (see the Shannon section of the Fitting-test README).
"""
const SHANNON_REBIN = 12

"""
Largest worst-case bias of the binning, as a fraction of the smallest binned
relative error ([`binBiasRatio`](@ref)), that [`shannonData`](@ref)
accepts: if the requested `rebin` gives more, the bins are made finer until
the bound is met (or the curve is fitted unbinned). 0.3 keeps the binning's
systematic shift of any bin under a third of that bin's smallest error bar.
"""
const BIN_BIAS_MAX = 0.3

"""
Everything [`shannonData`](@ref) decided about a measured curve,
kept in the `Inference.Seed` so the report and the fitting
scripts can reach both the data the fit used and the raw data.

# Fields
-   `D::Float64`: diameter of the scatterer cloud (atoms and hydration-shell beads), Å.
-   `lMax::Int`: spherical-harmonic band limit the forward model was built with.
-   `rebin::Int`: bins per Shannon channel; `0` when the data was not binned.
-   `nChannels::Float64`: Shannon channels the fitted q range holds, `(qMax - qMin)·D/π`.
-   `qRaw, I_raw, σ_raw`: the measured curve as given.
-   `q, I, σ`: the curve the fit sees (binned, then non-positive bins dropped).
-   `bin::Vector{Int}`: for each raw point, the index into `q` of its bin;
    `0` if that bin was dropped.
-   `nNonpositive::Int`: bins dropped for `I ≤ 0`.
"""
struct ShannonInfo
    D::Float64
    lMax::Int
    rebin::Int
    nChannels::Float64
    qRaw::Vector{Float64}
    iRaw::Vector{Float64}
    σ_raw::Vector{Float64}
    q::Vector{Float64}
    I::Vector{Float64}
    σ::Vector{Float64}
    bin::Vector{Int}
    nNonpositive::Int
end

# Largest squared distance between two of the columns of `P`, brute force.
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
so the hull is built with [Quickhull.jl](https://github.com/augustt198/Quickhull.jl)
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
        tuples = [
            (Float64(points[1, i]),
                Float64(points[2, i]),
                Float64(points[3, i]))
            for i in 1:n
        ]
        hull = try
            Quickhull.quickhull(tuples)
        catch e
            # "all the points are coplanar": handled below
            e isa ArgumentError || rethrow()
            nothing
        end
        if hull !== nothing
            v = Quickhull.vertexpoints(hull)
            return sqrt(_bruteMaxSq([x[k] for k in 1:3, x in v]))
        end
    end
    return sqrt(_bruteMaxSq(points))
end

"""
Spherical-harmonic band limit the forward model needs for
a particle of diameter `D` at momentum transfers up to
`qMax`: `ceil(qMax·D)`, the usual `q·D_max` multipole
resolution rule of thumb.

# Returns
- `Int`: the band limit, at least 1.

# Exceptions
- `DomainError`: `D` or `qMax` is not positive and finite.
"""
function autoLmax(D::Real, qMax::Real)::Int
    (isfinite(D) && D > 0) || throw(
        DomainError(
            D,
            "autoLmax: D must be positive and finite",
        ),
    )
    (isfinite(qMax) && qMax > 0) || throw(DomainError(
        qMax, "autoLmax: qMax must be positive and finite")
    )
    return max(1, ceil(Int, qMax * D))
end

# The curve binned to `k` bins per channel (as measured when
# `k === nothing`), the non-positive bins dropped when asked: (q, I, σ, per
# raw point the index of its bin (0 if dropped), the number of bins dropped).
function _binAndKeep(qr, ir, σr, D, k, dropNonpositive)
    if k === nothing
        qb, ib, σb, bin = copy(qr), copy(ir), copy(σr), collect(1:length(qr))
    else
        qb, ib, σb, bin = _rebin(qr, ir, σr, π / (k * D))
    end
    keep = dropNonpositive ? findall(>(0), ib) : collect(eachindex(ib))
    isempty(keep) && throw(ArgumentError("no point has a positive intensity after binning"))
    nNonpositive = length(ib) - length(keep)
    if nNonpositive > 0
        remap = zeros(Int, length(ib))
        remap[keep] .= 1:length(keep)
        bin = [b == 0 ? 0 : remap[b] for b in bin]
        qb, ib, σb = qb[keep], ib[keep], σb[keep]
    end
    return qb, ib, σb, bin, nNonpositive
end

# Inverse-variance bins of width Δ from min(q): per
# raw point the bin it falls in, and per bin the
# weighted-mean q and I and σ = 1/√Σw
# (independent-errors assumption). Empty bins vanish;
# the output is in increasing q.
function _rebin(
    q::Vector{Float64},
    I::Vector{Float64},
    σ::Vector{Float64},
    Δ::Float64,
)
    q0 = minimum(q)
    b = [floor(Int, (x - q0) / Δ) + 1 for x in q]
    nb = maximum(b)
    sw = zeros(nb)
    swI = zeros(nb)
    swq = zeros(nb)
    @inbounds for i in eachindex(q)
        w = 1 / σ[i]^2
        sw[b[i]] += w
        swI[b[i]] += w * I[i]
        swq[b[i]] += w * q[i]
    end
    used = findall(>(0), sw)
    remap = zeros(Int, nb)
    remap[used] .= 1:length(used)
    return swq[used] ./ sw[used], swI[used] ./ sw[used], 1 ./ sqrt.(sw[used]), remap[b]
end

"""
Bins a measured curve by Shannon channel, drops the bins with non-positive
intensity, and picks the band limit.

The curve is cut into bins of width π/(rebin·D) in q, and each bin is
replaced by the inverse-variance weighted mean of its points
(position and intensity), with the standard error 1/√Σ(1/σᵢ²). Bins
narrower than the data's own spacing change nothing. Bins whose mean
intensity is not positive (noise at high q) are then dropped, unless
`dropNonpositive = false`. With `rebin = nothing` the curve is not binned,
only filtered. Dropping is not neutral: it removes the negative half of
the noise at high q, so the surviving points are biased upwards.

# Arguments
- `q, I, σ`: the measured curve, equal lengths, `σ > 0`, finite.

# Keywords
-   `D::Real`: diameter of the scatterer cloud in Å (see [`cloudDiameter`](@ref)).
-   `rebin::Union{Nothing,Integer} = SHANNON_REBIN`: bins per Shannon channel,
    at least this many (see `maxBinBias`), or `nothing` for no binning.
-   `maxBinBias::Real = BIN_BIAS_MAX`: if [`binBiasRatio`](@ref) of
    the binned curve exceeds this, `rebin` is raised until it does not (a
    precise curve needs finer bins), and the curve is fitted as measured
    once the bins are as fine as its points; `Inf` keeps `rebin` as given.
-   `lMax::Union{Nothing,Integer} = nothing`: band limit; `nothing` takes
    [`autoLmax`](@ref)`(D, qMax)` with `qMax` the largest binned q.
-   `dropNonpositive::Bool = true`: drop the bins whose mean intensity is not positive.

# Returns
- [`ShannonInfo`](@ref).

# Exceptions
-   `DomainError`: lengths differ, `q`, `I` or `σ` is not finite,
    `σ ≤ 0`, `rebin < 1`, or `D ≤ 0`.
- ` ArgumentError`: no point has a positive binned intensity.
"""
function shannonData(
    q::AbstractVector{<:Real},
    I::AbstractVector{<:Real},
    σ::AbstractVector{<:Real};
    D::Real,
    rebin::Union{Nothing,Integer} = SHANNON_REBIN,
    lMax::Union{Nothing,Integer} = nothing,
    dropNonpositive::Bool = true,
    maxBinBias::Real = BIN_BIAS_MAX,
)::ShannonInfo
    length(q) == length(I) == length(σ) || throw(
        DomainError(
            (length(q),
                length(I),
                length(σ),
            ),
            "q, I and σ must have the same length",
        ),
    )
    isempty(q) && throw(ArgumentError("q, I and σ cannot be empty"))
    (all(isfinite, q) && all(isfinite, I) && all(isfinite, σ)) || throw(
        DomainError("non-finite", "q, I and σ must be finite"),
    )
    all(>(0), σ) || throw(DomainError(minimum(σ), "σ must be positive"))
    (isfinite(D) && D > 0) || throw(DomainError(D, "D must be positive and finite"))
    rebin === nothing || rebin ≥ 1 ||
        throw(
            DomainError(rebin, "rebin must be at least 1 (or nothing)"),
        )

    qr, ir, σr = Float64.(q), Float64.(I), Float64.(σ)
    k = rebin
    local qb, ib, σb, bin, nNonpositive
    for _ in 1:64
        qb, ib, σb, bin, nNonpositive = _binAndKeep(qr, ir, σr, D, k, dropNonpositive)
        k === nothing && break
        ratio = (π^2 / (96 * k^2)) / minimum(σb ./ ib)
        ratio ≤ maxBinBias && break
        # the bound falls as 1/k² (and faster, since finer bins hold fewer
        # points and so have larger errors): jump to the k that meets it, and
        # fit the curve as measured once the bins are as fine as its points
        k =
            length(qb) ≥ 0.9 * length(qr) ? nothing :
            max(k + 1, ceil(Int, k * sqrt(ratio / maxBinBias)))
    end
    # bins finer than the points, reached only by
    # raising a coarser request: nothing left to average
    if k !== nothing && k != rebin && length(qb) ≥ length(qr)
        qb, ib, σb, bin, nNonpositive =
            _binAndKeep(qr, ir, σr, D, nothing, dropNonpositive)
        k = nothing
    end

    l = lMax === nothing ? autoLmax(D, maximum(qb)) : Int(lMax)
    return ShannonInfo(
        Float64(D),
        l,
        k === nothing ? 0 : Int(k),
        (maximum(qb) - minimum(qb)) * D / π,
        qr,
        ir,
        σr,
        qb,
        ib,
        σb,
        bin,
        nNonpositive,
    )
end

"""
Worst-case bias of the binning against the precision of the binned points,
as a fraction of the smallest binned relative error.

A binned point is the mean of the curve over a bin of width `Δq = π/(rebin·D)`,
not its value at the bin's mean q; the relative difference is about `(Δq²/24)·|I″/I|`.
For a particle of diameter `D`, `I(q)` is the Fourier transform of a function supported
on `[0, D]`, so `|I″/I| ≤ (D/2)²` and the bias is at most `π²/(96·rebin²)` whatever the
size (a typical protein is several times smoother). Dividing by the smallest `σ/I` of
the binned curve says whether the bias can matter; [`shannonData`](@ref) makes the bins
finer until the ratio is at most [`BIN_BIAS_MAX`](@ref).

# Returns
- `Float64`: the ratio; `NaN` when the data was not binned.
"""
function binBiasRatio(info::ShannonInfo)::Float64
    info.rebin == 0 && return NaN
    return (π^2 / (96 * info.rebin^2)) / minimum(info.σ ./ info.I)
end

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

"""
Whether normalized residuals `r = (I - model)/σ`
are white, as the likelihood assumes.

# Returns
A named tuple:
- `lag1`: the lag-1 autocorrelation `Σ rᵢrᵢ₊₁ / Σ rᵢ²`; ≈ 0 ± 1/√n for white residuals.
- `runsZ`: Wald–Wolfowitz runs-test z-score of the residual signs; ≈ N(0,1) for white
    residuals, strongly negative     when residuals come in long same-sign runs
    (`NaN` if all residuals have one sign).
"""
function residualStructure(r::AbstractVector{<:Real})
    length(r) ≥ 3 || throw(ArgumentError("residualStructure: need at least 3 residuals"))
    lag1 = all(iszero, r) ? 0.0 : autocor(r, [1]; demean = false)[1] # Σ rᵢrᵢ₊₁ / Σ rᵢ²
    return (; lag1, runsZ = WaldWolfowitzTest(r .> 0).z) # runs of the residual signs
end

end # module
