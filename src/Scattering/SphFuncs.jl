# SPDX-License-Identifier: LGPL-2.1-or-later

"Complex spherical harmonics and spherical Bessel functions over point/grid inputs."
module SphFuncs

using SphericalHarmonics: SphericalHarmonics
using LegendrePolynomials: Plm
using DocStringExtensions

export legendre_sphPlm, sphHarm, sphBess, SphHarmError, SphBessError

"Raised by [`sphHarm`](@ref) on invalid input."
struct SphHarmError <: Exception; msg::String end
"Raised by [`sphBess`](@ref) on invalid input."
struct SphBessError <: Exception; msg::String end
Base.showerror(io::IO, e::SphHarmError) = print(io, "SphHarmError: ", e.msg)
Base.showerror(io::IO, e::SphBessError) = print(io, "SphBessError: ", e.msg)

const _INV_SQRT_2PI = 1.0 / sqrt(2.0 * π)

"""
$(TYPEDSIGNATURES)

Normalized associated Legendre P̄_l^m(x) with Condon–Shortley phase (GSL legendre_sphPlm).

# Arguments
- `l`: degree, l ≥ 0.
- `m`: order, 0 ≤ m ≤ l.
- `x`: argument, typically cos θ in [-1, 1].
"""
@inline legendre_sphPlm(l::Integer, m::Integer, x::Real)::Float64 =
    Plm(float(x), l, m; norm = Val(:normalized), csphase = true) * _INV_SQRT_2PI

"""
$(TYPEDSIGNATURES)

Complex spherical harmonics Y_l^m for l = 0..lMax, m = 0..l. Rows are packed as
l*(l+1)÷2 + m + 1; columns are input points.

# Arguments
- `lMax`: maximum degree, lMax ≥ 0.
- `θ`: 1-D vector of polar angles; same length as φ.
- `φ`: 1-D vector of azimuthal angles; same length as θ.
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
"""
function sphHarm(lMax::Int, angles::AbstractMatrix{<:Real})::Matrix{ComplexF64}
    size(angles, 1) == 2 ||
        throw(SphHarmError("angles matrix must have 2 rows (θ, φ); got $(size(angles, 1))"))
    return sphHarm(lMax, view(angles, 1, :), view(angles, 2, :))
end

"""
$(TYPEDSIGNATURES)

Spherical Bessel functions jₗ for l = 0..lMax over the outer product q ⊗ r,
shape (lMax+1, |q|, |r|):

    jₗ(x) = √(π / (2·x)) · Jₗ₊₀.₅(x)

Upward recurrence is unstable once l > x, so use Miller's downward recurrence
algorithm. With ĵ an unnormalized estimate,

    ĵₗ₋₁(x) = ((2l + 1)/x)·ĵₗ(x) − ĵₗ₊₁(x),    ĵ_{N+1} = 0,  ĵ_N = 2⁻⁵⁰⁰

started at N = max(lMax, ⌈x⌉) + 16 + ⌈6·x^(1/3)⌉, deep enough that every
returned order is converged to the Float64 rounding floor (checked against a
512-bit reference for x ≤ 300, lMax ≤ 200: |Δjₗ| ≤ 8e-15·maxₖ|jₖ(x)|). One
sweep yields every order, so the cost per value does not depend on l.

Loop layout: for a fixed r, the recurrence is sequential in l (each order needs
the two above it), but different q values never interact. So instead of running
one x at a time, the recurrence state (ĵₗ₊₁, ĵₗ₊₂ and the running normalization
sum) is held as length-|q| vectors, and every q is stepped down one order
together. That inner loop over q has no dependencies between iterations, which
lets the compiler vectorize it (@simd) and keeps several independent
multiply-adds in flight instead of waiting on one chain.

Each q needs its own start order N(x). The sweep runs from the largest N on the
grid; a q whose N has not been reached yet holds ĵ = 0, which the recurrence maps
to 0, and is seeded with ĵ_N exactly at its own N. Its result is therefore the
same as if it had been computed alone.

The estimate is normalized with the sum rule (DLMF 10.60.12)

    Σₗ (2l + 1)·jₗ(x)² = 1 => jₗ(x) = ĵₗ(x) / √(Σₗ (2l + 1)·ĵₗ(x)²)

rather than with j₀(x) = sin(x)/x, which vanishes at x = kπ and would then
mis-scale every order. ĵ_N > 0 and j_N(x) > 0 for N > x, so the sign is right.

For small x and large lMax, ĵ would overflow over the sweep (it grows like
(2N+1)!!/x^N). N is then lowered to the last order whose estimated growth,
from jₗ(x) ≈ xˡ/(2l+1)!!, stays below e⁶⁰⁰; the orders above it are below
~1e-260 and returned as 0.

For x = 0, use the convention:

    j₀(0) = 1
    jₗ(0) = 0  for l > 0

Sources:
    Arfken, George (1985). Mathematical Methods for Physicists (3rd ed.).
    Academic Press. p. 622.
    NIST DLMF, eq. 10.60.12, <https://dlmf.nist.gov/10.60.E12>.

# Arguments
- `r`: non-empty vector of radii, all ≥ 0.
- `q`: non-empty vector of q values, all ≥ 0.
- `lMax`: maximum order, lMax ≥ 0.
"""
function sphBess(
    r::AbstractArray{Float64},
    q::AbstractArray{Float64},
    lMax::Int
)::Array{Float64,3}

    isempty(r) && throw(SphBessError("radii must be non-empty"))
    isempty(q) && throw(SphBessError("q grid must be non-empty"))

    any(<(0), r) && throw(SphBessError("radii must be ≥ 0"))
    any(<(0), q) && throw(SphBessError("q must be ≥ 0"))

    lMax < 0 && throw(SphBessError("lMax must be ≥ 0"))

    rv, qv = Float64.(vec(r)), Float64.(vec(q))
    nq = length(qv)
    j = zeros(Float64, lMax + 1, nq, length(rv))

    # start order above max(lMax, x); ĵ_N = 2⁻⁵⁰⁰ and growth ≤ e⁶⁰⁰ keep ĵ² finite
    margin(x) = 16 + ceil(Int, 6 * cbrt(x))
    seed, log_budget = 2.0^-500, -600.0

    # ldf[l+1] = ln((2l+1)!!), up to the deepest start order on this grid
    xmax = maximum(qv) * maximum(rv)
    ldf = cumsum([0.0; log.(3.0:2.0:(2 * (max(lMax, ceil(Int, xmax)) + margin(xmax)) + 1))])

    # recurrence state, one entry per q (see "Loop layout" above):
    # 1/x, start order N(x), ĵₗ₊₁, ĵₗ₊₂, and the running sum Σ(2l+1)ĵₗ²
    invx, N = zeros(nq), zeros(Int, nq)
    jp1, jp2, S = zeros(nq), zeros(nq), zeros(nq)

    @inbounds for (ri, rr) in enumerate(rv)
        for k in 1:nq
            x = qv[k] * rr
            invx[k] = x == 0 ? 0.0 : inv(x)
            N[k] = x == 0 ? -1 : max(lMax, ceil(Int, x)) + margin(x)
            # lower N when the growth estimate l·ln x − ln((2l+1)!!) leaves the budget;
            # it decreases past l = (x−1)/2, so bisect for the last order inside it
            if x != 0 && N[k] * log(x) - ldf[N[k] + 1] < log_budget
                lo, hi, lx = max(0, floor(Int, (x - 1) / 2)), N[k], log(x)
                while hi - lo > 1
                    mid = (lo + hi) >>> 1
                    mid * lx - ldf[mid + 1] ≥ log_budget ? (lo = mid) : (hi = mid)
                end
                N[k] = lo
            end
        end

        # step every q down one order at a time; a q stays 0 until l reaches its
        # own N, where it is seeded, so it doesn't see the others' start orders
        fill!(jp1, 0.0); fill!(jp2, 0.0); fill!(S, 0.0)
        for l in maximum(N):-1:0
            @fastmath @simd for k in 1:nq
                # ĵₗ = ((2l+3)/x)·ĵₗ₊₁ − ĵₗ₊₂, or the seed at l = N
                v = ifelse(N[k] == l, seed, muladd((2l + 3) * invx[k], jp1[k], -jp2[k]))
                S[k] = muladd(2l + 1, v * v, S[k])
                jp2[k], jp1[k] = jp1[k], v
            end
            if l ≤ lMax
                for k in 1:nq
                    j[l + 1, k, ri] = jp1[k]
                end
            end
        end

        for k in 1:nq
            if invx[k] == 0
                j[1, k, ri] = 1.0
            else
                s = inv(sqrt(S[k]))
                @simd for l in 1:(lMax + 1)
                    j[l, k, ri] *= s
                end
            end
        end
    end

    return j
end

sphBess(r::AbstractArray{<:Real}, q::AbstractArray{<:Real}, lMax::Int) = sphBess(Float64.(vec(r)), Float64.(vec(q)), lMax)

end # module
