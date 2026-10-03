# SPDX-License-Identifier: LGPL-2.1-or-later

"Complex spherical harmonics and Gautschi's continued-fraction method for spherical Bessel functions."
module SphFuncs

using SphericalHarmonics: SphericalHarmonics
using DocStringExtensions
using ...BAYSOL_Utils.Constants: GAUTSCHI_MARGIN

export sphHarm, SphHarmError

"Raised by [`sphHarm`](@ref) on invalid input."
struct SphHarmError <: Exception; msg::String end
Base.showerror(io::IO, e::SphHarmError) = print(io, "SphHarmError: ", e.msg)

"""
$(TYPEDSIGNATURES)

Complex spherical harmonics Y_l^m for l = 0..lMax, m = 0..l. Rows are packed as
l*(l+1)÷2 + m + 1; columns are input points.

# Arguments
- `lMax`: maximum degree, lMax ≥ 0.
- `θ`: 1-D vector of polar angles; same length as φ.
- `φ`: 1-D vector of azimuthal angles; same length as θ.

# Returns
- `Matrix{ComplexF64}`, ((lMax+1)(lMax+2)/2, |θ|): Y_l^m(θᵢ, φᵢ), one column per point.

# Exceptions
- `SphHarmError`: lMax < 0, or θ/φ not 1-D, empty, or of different lengths.
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
$(TYPEDSIGNATURES)

As [`sphHarm`](@ref) above, but reading the angles from a (2, N) matrix whose
rows are θ and φ and whose columns are points — the column-per-atom layout
MolecularStructure.coords_spherical produces, sliced to its two angular rows. Exactly
sphHarm(lMax, view(angles, 1, :), view(angles, 2, :)).

# Arguments
- `lMax`: maximum degree, lMax ≥ 0.
- `angles`: (2, N) real matrix; row 1 is θ, row 2 is φ.

# Returns
- `Matrix{ComplexF64}`, ((lMax+1)(lMax+2)/2, N): as the (θ, φ) method.

# Exceptions
- `SphHarmError`: angles does not have 2 rows, or as the (θ, φ) method.
"""
function sphHarm(lMax::Int, angles::AbstractMatrix{<:Real})::Matrix{ComplexF64}
    size(angles, 1) == 2 ||
        throw(SphHarmError("angles matrix must have 2 rows (θ, φ); got $(size(angles, 1))"))
    return sphHarm(lMax, view(angles, 1, :), view(angles, 2, :))
end

"""
    sphBess

Per-q state of the spherical Bessel sweep for one radius, reused across radii so
the sweep allocates nothing. [`sphBessRatios!`](@ref) fills it (pass 1); the
caller's pass 2 then steps the values upward with [`sphBessStep`](@ref).

# Fields
- `x::Vector{Float64}`, `invx::Vector{Float64}`: x = q·r and 1/x (0 at x = 0) per q.
- `lup::Vector{Int}`: ⌊x⌋, the last order taken from the upward recurrence.
- `N::Vector{Int}`: start order of the ratio sweep (−1 when ⌊x⌋ ≥ lMax: no ratios needed).
- `rp::Vector{Float64}`: rₗ₊₁ during the ratio sweep (scratch).
- `jm1::Vector{Float64}`, `jm2::Vector{Float64}`: jₗ₋₁ and jₗ₋₂ per q; pass 1
    leaves j₁ and j₀ in them, pass 2 updates them as it steps up.
- `R::Matrix{Float64}`, (|q|, lMax): R[k, l] = rₗ(x_k), contiguous in q.
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
$(TYPEDSIGNATURES)

Zeroed buffers for up to `nq` q values and orders up to `lMax`.

# Returns
- `sphBess` with length-`nq` vectors and an `nq` × max(lMax, 1) ratio matrix.

# Exceptions
- `DomainError`: nq < 0 or lMax < 0.
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
$(TYPEDSIGNATURES)

One upward step of the spherical Bessel sweep: jₗ(x) for l ≥ 2 from the two orders
below it,

    jₗ(x) = ((2l − 1)/x)·jₗ₋₁(x) − jₗ₋₂(x)    for l ≤ ⌊x⌋ (upward recurrence, stable here),
    jₗ(x) = jₗ₋₁(x)·rₗ(x)                    for l > ⌊x⌋ (ratio from [`sphBessRatios!`](@ref)).

The two are selected branch-free, so a loop over q calling this vectorizes.

# Arguments
- `jm1`, `jm2`: jₗ₋₁(x), jₗ₋₂(x).
- `l`: the order to produce, ≥ 2.
- `lup`: ⌊x⌋.
- `invx`: 1/x (0 at x = 0).
- `rl`: rₗ(x) = jₗ(x)/jₗ₋₁(x).

# Returns
- `Float64`: jₗ(x), already normalized.
"""
@inline sphBessStep(jm1::Float64, jm2::Float64, l::Int, lup::Int, invx::Float64, rl::Float64)::Float64 =
    ifelse(l ≤ lup, muladd((2l - 1) * invx, jm1, -jm2), jm1 * rl)

"""
$(TYPEDSIGNATURES)

Pass 1 of the spherical Bessel sweep for one radius r over every q: everything
[`sphBessStep`](@ref) needs to step jₗ(x), x = q·r, upward from l = 2 to lMax.

All orders satisfy the three-term recurrence

    jₗ₋₁(x) + jₗ₊₁(x) = ((2l + 1)/x)·jₗ(x).

Upward recurrence is stable while l ≤ x and unstable above, where jₗ is the
decaying (minimal) solution. So use Gautschi's hybrid:

1.  For l > ⌊x⌋, the ratios rₗ = jₗ/jₗ₋₁ from the continued fraction, evaluated
    downward from a start order N:

        rₗ(x) = x / ((2l + 1) − x·rₗ₊₁(x)),    r_{N+1} = 0,

    with N = max(lMax, ⌈x⌉) + 16 + ⌈6·x^(1/3)⌉
    ([`GAUTSCHI_MARGIN`](@ref)), deep enough that
    every ratio is converged to the Float64 rounding floor. The ratios stay bounded
    (rₗ ≈ x/(2l + 1) for l ≫ x), so nothing can overflow; orders too small for
    Float64 underflow to 0.
2.  The anchors in closed form,

        j₀(x) = sin(x)/x,    j₁(x) = sin(x)/x² − cos(x)/x,

    except j₁ = j₀·r₁ for x < 1 (⌊x⌋ = 0), where the closed form cancels
    catastrophically. Pass 2 then takes jₗ by the upward recurrence for l ≤ ⌊x⌋ and
    jₗ = jₗ₋₁·rₗ above it. The switch point is safe: jₗ has no zero below
    x ≈ l + 1.86·l^(1/3), so the anchor j_⌊x⌋(x) is never near 0.

Every value comes out normalized, so the caller can use it as it is produced.
Against a 512-bit reference (x ≤ 300, lMax ≤ 200): |Δjₗ| ≤ 1.5e-14·maxₖ|jₖ(x)|,
and ≤ 2.2e-14 relative in the decaying tail.

A q with ⌊x⌋ ≥ lMax needs no ratios (every order it needs comes from the upward
recurrence), so N = −1 and it takes no part in the downward sweep.

Loop layout: for a fixed r, the sweep is sequential in l, but different q values
never interact. So every q is stepped one order at a time together; that inner
loop over q has no dependencies between iterations, which lets the compiler
vectorize it (@simd) and keeps several independent operations in flight instead of
waiting on one chain. The sweep runs from the largest N on the grid; a q holds
r = 0 until l reaches its own N, so its result is the same as if it had been
computed alone.

x = 0 gives 1/x = 0 and every rₗ = 0, so j₀(0) = 1 and jₗ(0) = 0 for l > 0.

Sources:
    Gautschi, W. (1967). Computational aspects of three-term recurrence relations.
    SIAM Review 9(1), 24–82. doi:10.1137/1009002.

# Arguments
- `b::sphBess`: buffers for ≥ |q| values and orders up to ≥ lMax.
- `r`: the radius, ≥ 0.
- `q`: the q grid, every entry ≥ 0 (not checked here; it is the caller's grid,
    validated once rather than once per radius).
- `lMax`: maximum order, ≥ 0.

# Returns
- `nothing`. Writes, for the first |q| entries, `x`, `invx`, `lup`, `N`,
    `R[:, 1:lMax]`, and j₁, j₀ into `jm1`, `jm2`.

# Exceptions
- `ArgumentError`: the buffers in b hold fewer than |q| values or fewer than lMax orders.
- `DomainError`: r < 0 or lMax < 0.
"""
function sphBessRatios!(b::sphBess, r::Float64, q::Vector{Float64}, lMax::Int)::Nothing
    nq = length(q)
    length(b.x) ≥ nq || throw(ArgumentError("sphBessRatios!: buffers hold $(length(b.x)) q values, need $nq"))
    size(b.R, 2) ≥ lMax || throw(ArgumentError("sphBessRatios!: buffers hold $(size(b.R, 2)) orders, need $lMax"))
    r ≥ 0 || throw(DomainError(r, "sphBessRatios!: r must be ≥ 0"))
    lMax ≥ 0 || throw(DomainError(lMax, "sphBessRatios!: lMax must be ≥ 0"))
    x, invx, lup, N, rp, jm1, jm2, R = b.x, b.invx, b.lup, b.N, b.rp, b.jm1, b.jm2, b.R

    d0, d1 = GAUTSCHI_MARGIN
    Nmax = 0
    # integer start orders (floor/ceil/cbrt and a branch): scalar loop
    @inbounds for k in 1:nq
        xk = q[k] * r
        x[k] = xk
        lup[k] = floor(Int, xk)
        N[k] = lup[k] ≥ lMax ? -1 : max(lMax, ceil(Int, xk)) + d0 + ceil(Int, d1 * cbrt(xk))
        Nmax = max(Nmax, N[k])
    end

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

    # downward: rₗ = x/((2l+1) − x·rₗ₊₁) for every q, 0 until l reaches its own N;
    # stored for l ≤ lMax (the branch on l is outside the vectorized loop)
    for l in Nmax:-1:1
        if l ≤ lMax
            @inbounds @simd for k in 1:nq
                v = ifelse(l > N[k], 0.0, x[k] / ((2l + 1) - x[k] * rp[k]))
                rp[k] = v
                R[k, l] = v
            end
        else
            @inbounds @simd for k in 1:nq
                rp[k] = ifelse(l > N[k], 0.0, x[k] / ((2l + 1) - x[k] * rp[k]))
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
