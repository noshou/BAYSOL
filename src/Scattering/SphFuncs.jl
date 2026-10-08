# SPDX-License-Identifier: LGPL-2.1-or-later

"Spherical harmonics (by recurrence) and Gautschi's continued-fraction method for spherical Bessel functions."
module SphFuncs

using ..Scattering: GAUTSCHI_MARGIN

export sphHarm!, sphHarmCache, SphHarmCache, SphHarmError

"Exception thrown by [`sphHarm!`](@ref) when its arguments are invalid."
struct SphHarmError <: Exception; msg::String end
Base.showerror(io::IO, e::SphHarmError) = print(io, "SphHarmError: ", e.msg)

"""
Workspace of [`sphHarm!`](@ref) for degrees up to `lMax`: the recurrence coefficients (they depend only on `(l, m)`,
so they are built once) and scratch vectors. Build it once with [`sphHarmCache`](@ref) and reuse it; it is mutable
state, so one task at a time.
"""
struct SphHarmCache
    lMax::Int
    a::Vector{Float64}       # a(l, m) = √((4l² − 1)/(l² − m²)), at the packed index of (l, m), l ≥ m + 2
    b::Vector{Float64}       # b(l, m) = √(((l − 1)² − m²)/(4(l − 1)² − 1))
    p0::Vector{Float64}      # P̄_l^m (m = 0..l) for the degree being computed, and the two before it
    p1::Vector{Float64}
    p2::Vector{Float64}
    cr::Vector{Float64}      # cos(mφ), sin(mφ), m = 0..lMax
    ci::Vector{Float64}
end

"""
The workspace [`sphHarm!`](@ref) needs for degrees up to `lMax ≥ 0`; build it once and reuse it across calls.

# Throws
- `SphHarmError`: `lMax < 0`.
"""
function sphHarmCache(lMax::Int)
    lMax ≥ 0 || throw(SphHarmError("lMax must be ≥ 0"))
    K = (lMax + 1) * (lMax + 2) ÷ 2
    a = zeros(K); b = zeros(K)
    for l in 2:lMax, m in 0:(l - 2)
        i = l * (l + 1) ÷ 2 + m + 1
        a[i] = sqrt((4l^2 - 1) / (l^2 - m^2))
        b[i] = sqrt(((l - 1)^2 - m^2) / (4 * (l - 1)^2 - 1))
    end
    return SphHarmCache(lMax, a, b, zeros(lMax + 1), zeros(lMax + 1), zeros(lMax + 1), zeros(lMax + 1), zeros(lMax + 1))
end

"""
Compute the complex spherical harmonics `Yₗᵐ(θ, φ) = P̄ₗᵐ(cos θ) e^{imφ}` for all degrees `0 ≤ l ≤ lMax` and orders
`0 ≤ m ≤ l` (orthonormal, Condon–Shortley phase; the orders `m < 0` follow from `Yₗ₋ₘ = (−1)ᵐ conj(Yₗᵐ)` and are not
stored), into a preallocated matrix, with no allocation per call.

`P̄ₗᵐ` comes from the standard recurrences: the diagonal `P̄ₗˡ = −√((2l+1)/2l) sin θ P̄ₗ₋₁ˡ⁻¹` from `P̄₀⁰ = 1/√(4π)`, the
sub-diagonal `P̄ₗˡ⁻¹ = √(2l+1) cos θ P̄ₗ₋₁ˡ⁻¹`, and `P̄ₗᵐ = aₗₘ (cos θ P̄ₗ₋₁ᵐ − bₗₘ P̄ₗ₋₂ᵐ)` above; `e^{imφ}` comes from a
sine/cosine table. The inner loop over `m` is vectorized.

The output is the real layout the multipole product in [`compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm) consumes: for degree `l`, with
`k0 = l(l + 1) ÷ 2`, rows `2k0 + 1 … 2k0 + l + 1` hold `Re Yₗᵐ` for `m = 0..l` and rows `2k0 + l + 2 … 2k0 + 2l + 2` hold
`−Im Yₗᵐ`; the rows of degree `l` are `2k0 + 1 … 2k0 + 2(l + 1)`.

# Arguments
- `A::AbstractMatrix{Float64}`: output with `size(A, 1) ≥ (lMax + 1)(lMax + 2)` rows and one column per point; may be a view.
- `S::SphHarmCache`: from [`sphHarmCache`](@ref)`(lMax′)` with `lMax′ ≥ lMax`.
- `lMax::Int`: maximum degree, `lMax ≥ 0`.
- `θ`, `φ`: one-dimensional arrays (or views) of polar angles in `[0, π]` and azimuthal angles, in radians, of equal,
    non-zero length.

# Returns
- `A`.

# Throws
- `SphHarmError`: if `lMax < 0` or exceeds the cache's, either angle array is not one-dimensional, either is empty, the two
    have different lengths, or `A` has the wrong size.
"""
function sphHarm!(A::AbstractMatrix{Float64}, S::SphHarmCache, lMax::Int, θ::AbstractArray{<:Real}, φ::AbstractArray{<:Real})
    lMax < 0 && throw(SphHarmError("lMax must be ≥ 0"))
    lMax ≤ S.lMax || throw(SphHarmError("lMax = $lMax exceeds the workspace's $(S.lMax)"))
    (ndims(θ) == 1 && ndims(φ) == 1) || throw(SphHarmError("theta/phi must be 1-D"))
    (isempty(θ) || isempty(φ)) && throw(SphHarmError("theta/phi must be non-empty"))
    length(θ) == length(φ) || throw(SphHarmError("theta/phi length mismatch"))
    (size(A, 1) ≥ (lMax + 1) * (lMax + 2) && size(A, 2) == length(θ)) ||
        throw(SphHarmError("A must have ≥ $((lMax + 1) * (lMax + 2)) rows and $(length(θ)) columns, got $(size(A))"))
    p0, p1, p2, cr, ci, a, b = S.p0, S.p1, S.p2, S.cr, S.ci, S.a, S.b
    P00 = 1 / sqrt(4π)
    @inbounds for t in eachindex(θ)
        i = t - firstindex(θ) + 1
        x = cos(Float64(θ[t])); sn = sin(Float64(θ[t]))
        sφ, cφ = sincos(Float64(φ[t]))
        cr[1] = 1.0; ci[1] = 0.0                       # index m + 1
        for m in 1:lMax
            cr[m + 1] = cr[m] * cφ - ci[m] * sφ
            ci[m + 1] = cr[m] * sφ + ci[m] * cφ
        end
        # degree 0
        pa, pb, pc = p0, p1, p2                        # current, previous, one before
        pa[1] = P00
        A[1, i] = P00; A[2, i] = -0.0
        for l in 1:lMax
            pa, pb, pc = pc, pa, pb                    # rotate: pb holds degree l − 1, pc degree l − 2
            k0 = l * (l + 1) ÷ 2
            pa[l + 1] = -sqrt((2l + 1) / (2l)) * sn * pb[l]          # m = l
            pa[l]     = sqrt(2l + 1) * x * pb[l]                       # m = l − 1
            @fastmath @simd for m in 1:(l - 1)                         # m = 0 .. l − 2, shifted by one
                ia = k0 + m
                pa[m] = a[ia] * (x * pb[m] - b[ia] * pc[m])
            end
            r0 = 2k0
            @fastmath @simd for m in 1:(l + 1)
                pv = pa[m]
                A[r0 + m, i] = pv * cr[m]
                A[r0 + l + 1 + m, i] = -(pv * ci[m])
            end
        end
    end
    return A
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
stable upward-recurrence region and no ratio is ever read for it (it only drops out of the sweep window below).

The downward ratio sweep is performed simultaneously for the q values that need it. Each q has an independent
recurrence, allowing the inner loop to be vectorized. At order `l` only the q values with `l ≤ N[k]` (the sweep has
started) and `l > floor(x[k])` (a ratio is needed) are swept; for q ascending that is a contiguous window of k,
so the work is the number of (q, order) pairs that need a ratio, not `nq` times the highest start order.
The optional `ltop` gives the highest order wanted at each q (default `lMax` everywhere), which lowers the start
order of q values whose high orders are negligible and unused.

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

# Keywords
- `ltop::Union{Nothing,AbstractVector{Int}} = nothing`: the highest order wanted at each q (`≤ lMax`), nondecreasing for
    a sorted q grid; `nothing` means `lMax` for every q. The ratios of orders above `ltop[k]` at `q[k]` are not valid.

# Returns
`nothing`. The workspace is updated in place. For the first `length(q)` q
values, the routine fills `x`, `invx`, `lup`, `N` (the start order of each q's
downward sweep), the needed entries of `R`, and the initial recurrence values `jm1 = j₁` and `jm2 = j₀`.

# Throws
- `ArgumentError`: if the workspace does not have enough q entries or ratio
columns for the requested computation.
- `DomainError`: if `r < 0` or `lMax < 0`.
"""
function sphBessRatios!(
    b::sphBess, r::Float64, q::Vector{Float64}, lMax::Int; ltop::Union{Nothing,AbstractVector{Int}} = nothing,
)::Nothing
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
    ltop === nothing || length(ltop) ≥ nq ||
        throw(ArgumentError("sphBessRatios!: ltop has $(length(ltop)) entries, need $nq"))

    x    = b.x
    invx = b.invx
    lup  = b.lup
    N    = b.N
    rp   = b.rp
    jm1  = b.jm1
    jm2  = b.jm2
    R    = b.R

    d0, d1 = GAUTSCHI_MARGIN

    # Start order of each q's downward sweep: above the highest order wanted at that q (`ltop[k]`, or `lMax`) and
    # above x, plus the convergence margin. Independent per-q work, SIMD-vectorized.
    @inbounds for k in 1:nq
        xk = q[k] * r
        x[k] = xk
        lup[k] = floor(Int, xk)
        top = ltop === nothing ? lMax : ltop[k]
        N[k] = max(top, ceil(Int, xk)) + d0 + ceil(Int, d1 * cbrt(xk))
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

    # The sweep needs, at order l, only the q values that have started (l ≤ N[k]) and still need a ratio there
    # (l > ⌊x⌋, below which the upward recurrence is used). For q ascending, N and ⌊x⌋ are nondecreasing in k, so
    # those q form a contiguous window [lo, hi] that moves as l decreases; otherwise every q is swept at every l.
    mono = issorted(view(N, 1:nq)) && issorted(view(lup, 1:nq))
    Nmax = nq == 0 ? 0 : (mono ? N[nq] : maximum(view(N, 1:nq)))
    lo = nq + 1; hi = nq
    for l in Nmax:-1:1
        if mono
            while lo > 1 && N[lo - 1] ≥ l; lo -= 1; end
            while hi ≥ 1 && lup[hi] ≥ l; hi -= 1; end
        else
            lo = 1; hi = nq
        end
        lo > hi && continue
        two_l_plus_one = 2l + 1
        if l > lMax          # above the requested orders only the continued fraction is advanced
            @inbounds @fastmath @simd for k in lo:hi
                rp[k] = ifelse(l > N[k], 0.0, x[k] / (two_l_plus_one - x[k] * rp[k]))
            end
        else                 # the ratio table is stored with q as the first dimension: contiguous R[k, l]
            @inbounds @fastmath @simd for k in lo:hi
                v = ifelse(l > N[k], 0.0, x[k] / (two_l_plus_one - x[k] * rp[k]))
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