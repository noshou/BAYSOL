# SPDX-License-Identifier: LGPL-2.1-or-later

"Complex spherical harmonics and Gautschi's continued-fraction method for spherical Bessel functions."
module SphFuncs

using SphericalHarmonics: SphericalHarmonics
using ..Scattering: GAUTSCHI_MARGIN

export sphHarm, SphHarmError

"Exception thrown by [`sphHarm`](@ref) when its arguments are invalid."
struct SphHarmError <: Exception; msg::String end
Base.showerror(io::IO, e::SphHarmError) = print(io, "SphHarmError: ", e.msg)

"""
Compute the complex spherical harmonics `Yₗᵐ(θ, φ)` for all degrees
`0 ≤ l ≤ lMax` and orders `0 ≤ m ≤ l`.

The harmonics are packed into a single row index

    i(l, m) = l(l + 1) ÷ 2 + m + 1

so that each column corresponds to one input point and each row to one
`(l, m)` pair.

Only non-negative orders `m` are returned. The normalization, phase convention,
and harmonic values are those provided by `SphericalHarmonics.jl`.

# Arguments
- `lMax`: maximum degree, must satisfy `lMax ≥ 0`.
- `θ`: one-dimensional array of polar angles, in radians.
- `φ`: one-dimensional array of azimuthal angles, in radians. Must have the
  same length as `θ`.

# Returns
A `Matrix{ComplexF64}` of size
`((lMax + 1)(lMax + 2) ÷ 2, length(θ))`. Entry
`[l(l + 1) ÷ 2 + m + 1, i]` is `Yₗᵐ(θ[i], φ[i])`.

# Throws
- `SphHarmError`: if `lMax < 0`, either angle array is not one-dimensional,
  either array is empty, or the two arrays have different lengths.
"""
function sphHarm(lMax::Int, θ::AbstractArray{<:Real}, φ::AbstractArray{<:Real})::Matrix{ComplexF64}
    lMax < 0 && throw(SphHarmError("lMax must be ≥ 0"))
    (ndims(θ) == 1 && ndims(φ) == 1) || throw(SphHarmError("theta/phi must be 1-D"))
    (isempty(θ) || isempty(φ)) && throw(SphHarmError("theta/phi must be non-empty"))
    length(θ) == length(φ) || throw(SphHarmError("theta/phi length mismatch"))

    npts = length(θ)
    y = Matrix{ComplexF64}(undef, (lMax + 1) * (lMax + 2) ÷ 2, npts)
    S = SphericalHarmonics.cache(Int(lMax))
    θv, φv = vec(θ), vec(φ)

    # Each point is independent, but S is shared mutable workspace.
    @inbounds for i in 1:npts
        θi = Float64(θv[i])
        SphericalHarmonics.computePlmcostheta!(S, θi, lMax)
        Yi = SphericalHarmonics.computeYlm!(S, θi, Float64(φv[i]), lMax)
        for l in 0:lMax, m in 0:l
            y[l * (l + 1) ÷ 2 + m + 1, i] = Yi[(l, m)]
        end
    end
    return y
end

"""
Compute complex spherical harmonics from angles stored in a `(2, N)` matrix.

The first row contains the polar angles `θ` and the second row contains the
azimuthal angles `φ`. Each column therefore represents one angular point.

This method is equivalent to

    sphHarm(lMax, view(angles, 1, :), view(angles, 2, :))

and uses the same harmonic convention and packed `(l, m)` indexing as the
one-dimensional-array method.

# Arguments
- `lMax`: maximum degree, must satisfy `lMax ≥ 0`.
- `angles`: real `(2, N)` matrix whose first row contains `θ` and second row
  contains `φ`.

# Returns
A `Matrix{ComplexF64}` of size
`((lMax + 1)(lMax + 2) ÷ 2, N)`, with one column per input point.

# Throws
- `SphHarmError`: if `angles` does not have exactly two rows, or if the
  underlying [`sphHarm`](@ref) call rejects the angle data.
"""
function sphHarm(lMax::Int, angles::AbstractMatrix{<:Real})::Matrix{ComplexF64}
    size(angles, 1) == 2 ||
        throw(SphHarmError("angles matrix must have 2 rows (θ, φ); got $(size(angles, 1))"))
    return sphHarm(lMax, view(angles, 1, :), view(angles, 2, :))
end

"""
Reusable workspace for evaluating spherical Bessel functions over a fixed
`q` grid.

The workspace is used by [`sphBessRatios!`](@ref) to perform the first pass of
the spherical-Bessel recurrence. It stores the per-`q` quantities needed by
the subsequent upward sweep, avoiding allocation for each radius.

# Fields
- `x`: `x[k] = q[k] * r` for the current radius.
- `invx`: `1 / x[k]`, with `0.0` substituted when `x[k] == 0`.
- `lup`: `floor(Int, x[k])`, the largest order for which the upward recurrence
  is used.
- `N`: starting order of the downward continued-fraction recurrence. A value
  of `-1` indicates that `floor(x[k]) ≥ lMax` and no ratios are required.
- `rp`: scratch storage for the current continued-fraction ratio during the
  downward sweep.
- `jm1`: current `jₗ₋₁(x[k])` value for the upward sweep. After
  [`sphBessRatios!`](@ref), it contains `j₁(x[k])`.
- `jm2`: current `jₗ₋₂(x[k])` value for the upward sweep. After
  [`sphBessRatios!`](@ref), it contains `j₀(x[k])`.
- `R`: ratio table with `R[k, l] = jₗ(x[k]) / jₗ₋₁(x[k])` for the orders
  required by the sweep. The first dimension is contiguous in `q`.
"""
struct sphBess
    x::Vector{Float64}
    invx::Vector{Float64}
    lup::Vector{Int}
    N::Vector{Int}
    rp::Vector{Float64}
    jm1::Vector{Float64}
    jm2::Vector{Float64}
    R::Matrix{Float64}
end

"""
Allocate a zero-initialized [`sphBess`](@ref) workspace.

The workspace can hold `nq` q values and ratios through order `lMax`. It is
intended to be allocated once and reused for multiple radii.

# Arguments
- `nq`: number of q values the workspace must hold, `nq ≥ 0`.
- `lMax`: maximum spherical-Bessel order, `lMax ≥ 0`.

# Returns
A [`sphBess`](@ref) workspace with capacity for `nq` q values and orders
through `lMax`.

The ratio matrix has at least one column even when `lMax == 0`, so that the
workspace remains a valid two-dimensional storage object.

# Throws
- `DomainError`: if `nq < 0` or `lMax < 0`.
"""
function sphBess(nq::Int, lMax::Int)
    nq ≥ 0 || throw(DomainError(nq, "sphBess: nq must be ≥ 0"))
    lMax ≥ 0 || throw(DomainError(lMax, "sphBess: lMax must be ≥ 0"))
    return sphBess(
        zeros(nq), 
        zeros(nq), 
        zeros(Int, nq), 
        zeros(Int, nq),
        zeros(nq), 
        zeros(nq), 
        zeros(nq), 
        zeros(nq, max(lMax, 1))
    )
end

"""
Compute one spherical-Bessel value from the two preceding orders.

For `l ≤ floor(x)`, the value is obtained from the upward three-term recurrence

    jₗ(x) = ((2l - 1) / x) jₗ₋₁(x) - jₗ₋₂(x).

For `l > floor(x)`, upward recurrence is unstable because `jₗ` is the minimal
solution of the recurrence. In this region the value is instead computed from
the ratio

    jₗ(x) = jₗ₋₁(x) rₗ(x),

where `rₗ(x) = jₗ(x) / jₗ₋₁(x)` was computed by
[`sphBessRatios!`](@ref).

The two cases are selected with `ifelse`, allowing calls over independent q
values to be vectorized.

# Arguments
- `jm1`: `jₗ₋₁(x)`.
- `jm2`: `jₗ₋₂(x)`.
- `l`: order to compute, with `l ≥ 2`.
- `lup`: `floor(x)`, the last order for which upward recurrence is used.
- `invx`: reciprocal `1 / x`, with `0.0` representing `x == 0`.
- `rl`: ratio `rₗ(x) = jₗ(x) / jₗ₋₁(x)`.

# Returns
The spherical Bessel function `jₗ(x)`.

The returned value is on the same normalization as the supplied anchor values
`j₀` and `j₁`.
"""
@inline sphBessStep(jm1::Float64, jm2::Float64, l::Int, lup::Int, invx::Float64, rl::Float64)::Float64 =
    ifelse(l ≤ lup, muladd((2l - 1) * invx, jm1, -jm2), jm1 * rl)

"""
Prepare the spherical-Bessel recurrence for one radius over an entire q grid.

This routine performs the first pass of a two-pass evaluation. For each
`x = q * r`, it computes the anchors `j₀(x)` and `j₁(x)`, determines where the
upward recurrence is stable, and constructs the ratios

    rₗ(x) = jₗ(x) / jₗ₋₁(x)

needed above that stability boundary.

The ratios are evaluated with Gautschi's downward continued-fraction method,

    rₗ(x) = x / ((2l + 1) - x rₗ₊₁(x)),

starting from `rₙ₊₁ = 0`. The starting order `N` is chosen above both `lMax`
and `x` using [`GAUTSCHI_MARGIN`](@ref), so that the continued fraction has
converged before the ratios required by the caller are reached.

The resulting workspace is consumed by the second pass, which advances
`jₗ(x)` in increasing order using [`sphBessStep`](@ref). Upward recurrence is
used while `l ≤ floor(x)` and the continued-fraction ratios are used above
that boundary. This avoids the numerical instability that occurs when the
upward recurrence is continued into the decaying, minimal-solution region.

The anchors are

    j₀(x) = sin(x) / x
    j₁(x) = sin(x) / x² - cos(x) / x.

For `x < 1`, the closed form for `j₁` suffers severe cancellation, so `j₁` is
instead obtained from `j₀ r₁`. At `x = 0`, the limiting values are used:
`j₀(0) = 1` and `jₗ(0) = 0` for `l > 0`.

For a q value with `floor(x) ≥ lMax`, every required order lies within the
stable upward-recurrence region, so no continued-fraction ratios are needed
and its `N` value is set to `-1`.

The downward ratio sweep is performed simultaneously for all q values. Each q
has an independent recurrence, allowing the inner loop to be vectorized. A q
value remains at zero until the sweep reaches its own starting order `N`.

Gautschi's method is described in:

    Gautschi, W. (1967). Computational aspects of three-term recurrence
    relations. SIAM Review, 9(1), 24–82.
    doi:10.1137/1009002.

# Arguments
- `b`: [`sphBess`](@ref) workspace with capacity for at least `length(q)` q
values and `lMax` ratio columns.
- `r`: radius, with `r ≥ 0`.
- `q`: one-dimensional `Float64` q grid. Its entries are assumed to be
non-negative; q-grid validation is intentionally performed by the caller
rather than for every radius.
- `lMax`: maximum spherical-Bessel order, with `lMax ≥ 0`.

# Returns
`nothing`. The workspace is updated in place. For the first `length(q)` q
values, the routine fills `x`, `invx`, `lup`, `N`, the required columns of
`R`, and the initial recurrence values `jm1 = j₁` and `jm2 = j₀`.

# Throws
- `ArgumentError`: if the workspace does not have enough q entries or ratio
columns for the requested computation.
- `DomainError`: if `r < 0` or `lMax < 0`.
"""
function sphBessRatios!(b::sphBess, r::Float64, q::Vector{Float64}, lMax::Int)::Nothing
    nq = length(q)
    length(b.x) ≥ nq || throw(
            ArgumentError(
                "sphBessRatios!: buffers hold $(length(b.x)) q values, need $nq"
            )
        )
    size(b.R, 2) ≥ lMax || throw(
            ArgumentError(
                "sphBessRatios!: buffers hold $(size(b.R, 2)) orders, need $lMax"
            )
        )
    r ≥ 0 || throw(DomainError(r, "sphBessRatios!: r must be ≥ 0"))
    lMax ≥ 0 || throw(DomainError(lMax, "sphBessRatios!: lMax must be ≥ 0"))
    
    x    = b.x
    invx = b.invx
    lup  = b.lup
    N    = b.N
    rp   = b.rp
    jm1  = b.jm1
    jm2  = b.jm2    
    R    = b.R

    d0, d1 = GAUTSCHI_MARGIN
    Nmax = 0

    # Independent per-q work is SIMD-vectorized; 
    # Nmax is reduced separately to avoid a loop-carried dependency.
    @inbounds @simd for k in 1:nq
        xk = q[k] * r
        x[k] = xk
        lup[k] = floor(Int, xk)
        N[k] = lup[k] ≥ lMax ? -1 :
            max(lMax, ceil(Int, xk)) + d0 + ceil(Int, d1 * cbrt(xk))
    end

    # Separate reduction keeps the per-q loop SIMD-friendly and avoids a second temporary allocation.
    Nmax = maximum(@view N[1:nq])

    # anchors jm2 = j₀, jm1 = j₁ in closed form (j₁ is replaced below for x < 1).
    # 1/x is set to 0 at x = 0, so j₀(0) = 1 by the select and j₁(0) = (0 − 1)·0 = 0,
    # with no NaN to mask.
    @inbounds @simd for k in 1:nq
        xk = x[k]
        ix = ifelse(xk == 0.0, 0.0, inv(xk))
        invx[k] = ix
        sk = sin(xk)
        ck = cos(xk)
        jm2[k] = ifelse(xk == 0.0, 1.0, sk * ix)
        jm1[k] = (sk * ix - ck) * ix
        rp[k] = 0.0
    end

    # Downward sweep above lMax does not store ratios; splitting the ranges removes
    # the outer branch from the hot SIMD loops.
    if Nmax > lMax
        for l in Nmax:-1:(lMax + 1)
            two_l_plus_one = 2l + 1
            @inbounds @simd for k in 1:nq
                rp[k] = ifelse(l > N[k], 0.0,
                    x[k] / (two_l_plus_one - x[k] * rp[k]))
            end
        end
    end

    # The ratio table is stored with q as the first dimension so the SIMD loop
    # accesses contiguous memory in R[k, l].
    if lMax ≥ 1
        for l in min(Nmax, lMax):-1:1
            two_l_plus_one = 2l + 1
            @inbounds @simd for k in 1:nq
                v = ifelse(l > N[k], 0.0,
                    x[k] / (two_l_plus_one - x[k] * rp[k]))
                rp[k] = v
                R[k, l] = v
            end
        end
    end

    # x < 1: j₁ = j₀·r₁, since the closed form cancels catastrophically at small x
    if lMax ≥ 1
        @inbounds @simd for k in 1:nq
            jm1[k] = ifelse(lup[k] ≥ 1, jm1[k], jm2[k] * R[k, 1])
        end
    end
    return nothing
end

end # module