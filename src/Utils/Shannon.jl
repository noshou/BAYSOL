# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Shannon sampling of a SAXS curve: a particle of diameter `D` has a scattering curve that carries no
information at a q spacing finer than `π/D` (one *Shannon channel*), so a curve of thousands of points holds
only `(q_max - q_min)·D/π` independent values. [`shannon_data`](@ref) bins the measured curve to that
resolution and picks the band limit [`auto_lmax`](@ref) the binned q range needs; [`cloud_diameter`](@ref)
supplies `D`; [`model_on_raw`](@ref) and [`residual_structure`](@ref) check the result against the measured data.
"""
module Shannon

using Quickhull: Quickhull

export ShannonInfo, SHANNON_REBIN, cloud_diameter, auto_lmax, shannon_data, bin_bias_ratio, model_on_raw, residual_structure

"""
Default number of bins per Shannon channel (`k`): the bin width is `π/(k·D)`. Binning at `k ≥ 8`
preserved the Laplace posterior width and moved the MAP by less than the posterior σ on the
fitting tests (see the Shannon section of the Fitting-test README).
"""
const SHANNON_REBIN = 12

"""
Everything [`shannon_data`](@ref) decided about a measured curve, kept in the `Fitting.Seed` so
the report and the fitting scripts can reach both the data the fit used and the raw data.

# Fields
- `D::Float64`: diameter of the scatterer cloud (atoms and hydration-shell beads), Å.
- `lMax::Int`: spherical-harmonic band limit the forward model was built with.
- `rebin::Int`: bins per Shannon channel; `0` when the data was not binned.
- `n_channels::Float64`: Shannon channels the fitted q range holds, `(q_max - q_min)·D/π`.
- `q_raw, I_raw, σ_raw`: the measured curve as given.
- `q, I, σ`: the curve the fit sees (binned, then non-positive bins dropped).
- `bin::Vector{Int}`: for each raw point, the index into `q` of its bin; `0` if that bin was dropped.
- `n_nonpositive::Int`: bins dropped for `I ≤ 0`.
"""
struct ShannonInfo
    D::Float64
    lMax::Int
    rebin::Int
    n_channels::Float64
    q_raw::Vector{Float64}
    I_raw::Vector{Float64}
    σ_raw::Vector{Float64}
    q::Vector{Float64}
    I::Vector{Float64}
    σ::Vector{Float64}
    bin::Vector{Int}
    n_nonpositive::Int
end

# Largest squared distance between two of the columns of `P`, brute force.
function _brute_max_sq(P::AbstractMatrix{<:Real})
    n = size(P, 2)
    best = 0.0
    @inbounds for i in 1:n-1
        xi, yi, zi = P[1, i], P[2, i], P[3, i]
        m = 0.0
        @fastmath @simd for j in i+1:n
            m = max(m, (P[1, j] - xi)^2 + (P[2, j] - yi)^2 + (P[3, j] - zi)^2)
        end
        best = max(best, m)
    end
    return best
end

"""
Diameter of a point cloud: the largest distance between two of its points.

The farthest pair of a set is always a pair of vertices of its convex hull, so the hull is
built with [Quickhull.jl](https://github.com/augustt198/Quickhull.jl) and only its vertices (typically
~100 of thousands of points) are compared. Fewer than four points, or a degenerate (collinear, coplanar
or repeated) cloud, has no 3-D hull and is compared pair by pair.

# Arguments
- `points::AbstractMatrix{<:Real}`: `(3, n)` coordinates, one column per point; `n ≥ 1`.

# Returns
- `Float64`: the diameter, in the units of `points` (0 for a single point).

# Exceptions
- `ArgumentError`: `points` is not 3-by-n, or has no column.
"""
function cloud_diameter(points::AbstractMatrix{<:Real})::Float64
    size(points, 1) == 3 || throw(ArgumentError("cloud_diameter: points must be 3-by-n, got $(size(points, 1))-by-$(size(points, 2))"))
    n = size(points, 2)
    n ≥ 1 || throw(ArgumentError("cloud_diameter: at least one point is needed"))
    if n ≥ 4
        tuples = [(Float64(points[1, i]), Float64(points[2, i]), Float64(points[3, i])) for i in 1:n]
        hull = try
            Quickhull.quickhull(tuples)
        catch e
            e isa ArgumentError || rethrow()   # "all the points are coplanar": handled below
            nothing
        end
        if hull !== nothing
            v = Quickhull.vertexpoints(hull)
            return sqrt(_brute_max_sq([x[k] for k in 1:3, x in v]))
        end
    end
    return sqrt(_brute_max_sq(points))
end

"""
Spherical-harmonic band limit the forward model needs for a particle of diameter `D` at momentum
transfers up to `q_max`: `ceil(q_max·D)`, the usual `q·D_max` multipole-resolution rule of thumb.

# Returns
- `Int`: the band limit, at least 1.

# Exceptions
- `DomainError`: `D` or `q_max` is not positive and finite.
"""
function auto_lmax(D::Real, q_max::Real)::Int
    (isfinite(D) && D > 0) || throw(DomainError(D, "auto_lmax: D must be positive and finite"))
    (isfinite(q_max) && q_max > 0) || throw(DomainError(q_max, "auto_lmax: q_max must be positive and finite"))
    return max(1, ceil(Int, q_max * D))
end

# Inverse-variance bins of width Δ from min(q): per raw point the bin it falls in, and per bin the
# weighted-mean q and I and σ = 1/√Σw (independent-errors assumption). Empty bins vanish; the
# output is in increasing q.
function _rebin(q::Vector{Float64}, I::Vector{Float64}, σ::Vector{Float64}, Δ::Float64)
    q0 = minimum(q)
    b = [floor(Int, (x - q0) / Δ) + 1 for x in q]
    nb = maximum(b)
    Sw = zeros(nb); SwI = zeros(nb); Swq = zeros(nb)
    @inbounds for i in eachindex(q)
        w = 1 / σ[i]^2
        Sw[b[i]] += w; SwI[b[i]] += w * I[i]; Swq[b[i]] += w * q[i]
    end
    used = findall(>(0), Sw)
    remap = zeros(Int, nb)
    remap[used] .= 1:length(used)
    return Swq[used] ./ Sw[used], SwI[used] ./ Sw[used], 1 ./ sqrt.(Sw[used]), remap[b]
end

"""
Bins a measured curve by Shannon channel, drops the bins with non-positive intensity, and picks the
band limit.

The curve is cut into bins of width `π/(rebin·D)` in q, and each bin is replaced by the
inverse-variance weighted mean of its points (position and intensity), with the standard error
`1/√Σ(1/σᵢ²)`. Bins narrower than the data's own spacing change nothing. Bins whose mean intensity is
not positive (noise at high q) are then dropped, unless `drop_nonpositive = false`. With `rebin = nothing`
the curve is not binned, only filtered. Dropping is not neutral: it removes the negative half of the noise
at high q, so the surviving points are biased upwards (on SASDN32 it moves the MAP by 1.7 posterior σ).

# Arguments
- `q, I, σ`: the measured curve, equal lengths, `σ > 0`, finite.

# Keywords
- `D::Real`: diameter of the scatterer cloud in Å (see [`cloud_diameter`](@ref)).
- `rebin::Union{Nothing,Integer} = SHANNON_REBIN`: bins per Shannon channel, or `nothing`.
- `lMax::Union{Nothing,Integer} = nothing`: band limit; `nothing` takes [`auto_lmax`](@ref)`(D, q_max)`
    with `q_max` the largest binned q.
- `drop_nonpositive::Bool = true`: drop the bins whose mean intensity is not positive.

# Returns
- [`ShannonInfo`](@ref).

# Exceptions
- `DomainError`: lengths differ, `q`, `I` or `σ` is not finite, `σ ≤ 0`, `rebin < 1`, or `D ≤ 0`.
- `ArgumentError`: no point has a positive binned intensity.
"""
function shannon_data(
    q::AbstractVector{<:Real}, I::AbstractVector{<:Real}, σ::AbstractVector{<:Real};
    D::Real,
    rebin::Union{Nothing,Integer} = SHANNON_REBIN,
    lMax::Union{Nothing,Integer} = nothing,
    drop_nonpositive::Bool = true,
)::ShannonInfo
    length(q) == length(I) == length(σ) || throw(DomainError((length(q), length(I), length(σ)), "q, I and σ must have the same length"))
    isempty(q) && throw(ArgumentError("q, I and σ cannot be empty"))
    (all(isfinite, q) && all(isfinite, I) && all(isfinite, σ)) || throw(DomainError("non-finite", "q, I and σ must be finite"))
    all(>(0), σ) || throw(DomainError(minimum(σ), "σ must be positive"))
    (isfinite(D) && D > 0) || throw(DomainError(D, "D must be positive and finite"))
    rebin === nothing || rebin ≥ 1 || throw(DomainError(rebin, "rebin must be at least 1 (or nothing)"))

    qr, Ir, σr = Float64.(q), Float64.(I), Float64.(σ)
    if rebin === nothing
        qb, Ib, σb, bin = copy(qr), copy(Ir), copy(σr), collect(1:length(qr))
    else
        qb, Ib, σb, bin = _rebin(qr, Ir, σr, π / (rebin * D))
    end

    keep = drop_nonpositive ? findall(>(0), Ib) : collect(eachindex(Ib))
    isempty(keep) && throw(ArgumentError("no point has a positive intensity after binning"))
    n_nonpositive = length(Ib) - length(keep)
    if n_nonpositive > 0
        remap = zeros(Int, length(Ib))
        remap[keep] .= 1:length(keep)
        bin = [b == 0 ? 0 : remap[b] for b in bin]
        qb, Ib, σb = qb[keep], Ib[keep], σb[keep]
    end

    l = lMax === nothing ? auto_lmax(D, maximum(qb)) : Int(lMax)
    return ShannonInfo( Float64(D), l, rebin === nothing ? 0 : Int(rebin), (maximum(qb) - minimum(qb)) * D / π,
                        qr, Ir, σr, qb, Ib, σb, bin, n_nonpositive)
end

"""
Worst-case bias of the binning against the precision of the binned points, as a fraction of the smallest
binned relative error.

A binned point is the mean of the curve over a bin of width `Δq = π/(rebin·D)`, not its value at the bin's mean
q; the relative difference is about `(Δq²/24)·|I″/I|`. For a particle of diameter `D`, `I(q)` is the Fourier
transform of a function supported on `[0, D]`, so `|I″/I| ≤ (D/2)²` and the bias is at most `π²/(96·rebin²)`
whatever the size (a typical protein is several times smoother). Dividing by the smallest `σ/I` of the binned curve
says whether the bias can matter: above about 0.3 the curve is precise enough that a larger `rebin` is advisable.

# Returns
- `Float64`: the ratio; `NaN` when the data was not binned.
"""
function bin_bias_ratio(info::ShannonInfo)::Float64
    info.rebin == 0 && return NaN
    return (π^2 / (96 * info.rebin^2)) / minimum(info.σ ./ info.I)
end

"""
A model curve given on the fitted (binned) grid, interpolated onto the measured grid by local cubic
(4-point Lagrange) interpolation in q; linear interpolation when the fitted grid has fewer than four
points, and the end intervals extrapolate from the nearest four nodes. Cubics are reproduced exactly. On
crambin's forward model the worst error is 0.001 σ for 1 % data at the default `rebin` (0.06 σ at
`rebin = 4`), where linear interpolation reaches 0.25 σ (1.8 σ).

# Arguments
- `info::ShannonInfo`.
- `y::AbstractVector{<:Real}`: the model at `info.q`.

# Returns
- `Vector{Float64}`: the model at `info.q_raw`.

# Exceptions
- `DimensionMismatch`: `y` is not as long as `info.q`.
- `ArgumentError`: the fitted grid has fewer than two points.
"""
function model_on_raw(info::ShannonInfo, y::AbstractVector{<:Real})::Vector{Float64}
    length(y) == length(info.q) || throw(DimensionMismatch("model has $(length(y)) points, the fitted grid $(length(info.q))"))
    n = length(info.q)
    n ≥ 2 || throw(ArgumentError("model_on_raw: need at least two fitted points"))
    xs = info.q
    out = Vector{Float64}(undef, length(info.q_raw))
    @inbounds for (i, x) in enumerate(info.q_raw)
        j = clamp(searchsortedlast(xs, x), 1, n - 1)         # x lies in [xs[j], xs[j+1]] (or beyond an end)
        if n < 4
            t = (x - xs[j]) / (xs[j+1] - xs[j])
            out[i] = (1 - t) * y[j] + t * y[j+1]
        else
            lo = clamp(j - 1, 1, n - 3)                        # the four nodes lo:lo+3 around the interval
            acc = 0.0
            for a in lo:lo+3
                w = 1.0
                for b in lo:lo+3
                    b == a || (w *= (x - xs[b]) / (xs[a] - xs[b]))
                end
                acc += w * y[a]
            end
            out[i] = acc
        end
    end
    return out
end

"""
Whether normalized residuals `r = (I - model)/σ` are white, as the likelihood assumes.

# Returns
A named tuple:
- `lag1`: the lag-1 autocorrelation `Σ rᵢrᵢ₊₁ / Σ rᵢ²`; ≈ 0 ± 1/√n for white residuals.
- `runs_z`: Wald–Wolfowitz runs-test z-score of the residual signs; ≈ N(0,1) for white residuals, strongly negative
    when residuals come in long same-sign runs (`NaN` if all residuals have one sign).
"""
function residual_structure(r::AbstractVector{<:Real})
    n = length(r)
    n ≥ 3 || throw(ArgumentError("residual_structure: need at least 3 residuals"))
    ss = sum(abs2, r)
    lag1 = ss > 0 ? sum(r[i] * r[i+1] for i in 1:n-1) / ss : 0.0
    pos = r .> 0
    np = count(pos); nn = n - np
    runs = 1 + count(i -> pos[i] != pos[i+1], 1:n-1)
    z = if np == 0 || nn == 0
        NaN
    else
        μ = 2np * nn / n + 1
        v = (μ - 1) * (μ - 2) / (n - 1)
        v > 0 ? (runs - μ) / sqrt(v) : NaN
    end
    return (; lag1, runs_z = z)
end

end # module
