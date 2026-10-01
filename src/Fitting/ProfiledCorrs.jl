# SPDX-License-Identifier: LGPL-2.1-or-later

using StaticArrays
using Optim: minimizer, optimize, Brent
using ForwardDiff
using ..Scattering: forward, ForwardCache
using ..BAYSOL_Utils.Constants: EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS
using FastClosures

"""
$(TYPEDSIGNATURES)

Profiles out the correction terms

# Scale and Background Correction
Since the calculated intensity is at an arbitrary scale and
the experimental background correction is likely to be imperfect,
a simple WLS fit minimizing the reduced χ² returns optimal correction factors.

# Excluded Volume Correction
c1 is the correction factor for the Gaussian-blob approximation of
each atom's excluded volume. Finds the c1 that minimizes reduced χ²,
with scale/bkgrnd_corr re-fit by wls_fit at every trial c1. Unlike
scale/bkgrnd_corr, c1 is nonlinear w.r.t. I(q) (see
`Scattering.excluded_volume_factor`'s `c1³·exp(...)` form), so it needs an
iterative 1-D search rather than a closed form fit.

The search is a coarse grid pre-scan followed by a `Brent()` polish, both
gradient-free:

1.  Evaluate reduced χ² on the grid `(cmin-eps):eps:(cmax+eps)` -- cheap
    (one `forward` + `wls_fit` per point, no autodiff), and unlike a purely
    local method this can't miss a second basin at the resolution of `eps`.
    Number of grid points ≈ `((cmax+eps) - (cmin-eps)) / eps + 1`, so
    tightening `eps` for a more precise saturation test.
2.  Bracket the best grid point with its two grid neighbours (or the padded
    edge, if the best point is first/last) and run `Brent()` inside that
    bracket to polish to full precision.

χ²(c1) is not globally monotone once ξ is badly wrong; 
a bare `Brent()` bracketed only by `(cmin-eps, cmax+eps)` 
could converge to whichever of these basins it starts exploring
toward and would have no way to tell you it missed the other one.

# Arguments
- `wls::WLSData`: precomputed data-only weighted sums over the measured
    intensity/per-point standard errors, from [`WLSData`](@ref); forwarded
    to every trial-c1 call of [`wls_fit`](@ref) inside the inner search
    without rebuilding those sums each time.
- `ξ::SVector{4,<:Real}` or `ξ::SVector{5,<:Real}`: (ρₑ, δρ₁, δρ₂, δρ₃[, δρ4]),
    held fixed during the c1 search.
- `fw::ForwardCache`: the structure's geometry-only cache, forwarded to
    [`Scattering.forward`](@ref BAYSOL.Scattering.forward).

# Keywords
- `cmin, cmax = EXCL_VOL_CORR_BOUNDS`: the physical c1 bounds.
- `eps = EXCL_VOL_CORR_EPS`: both the amount the search window is padded
    past `(cmin, cmax)` and the coarse pre-scan's grid step.

# Returns
- `(ŷ::Vector, fit::WLSFit, c1_star::Float64)`: the c1_star-corrected model
    curve (at the caller's real ξ), its WLS fit, and the profiled c1 itself.
    `Sampler.jl`'s hot-path likelihood call drops `ŷ`/`c1_star`; its
    posterior-draw curve/report loop needs all three.
"""
function profiled_corrs end

function profiled_corrs(
    wls::WLSData,
    ξ::SVector{4,<:Real},
    fw::ForwardCache;
    cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
    cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
    eps::Float64=EXCL_VOL_CORR_EPS,
)
    ξ_val = ForwardDiff.value.(ξ)
    ρ_val  = ξ_val[1]
    δρ_val = (ξ_val[2], ξ_val[3], ξ_val[4])

    # No assignments inside these closures: a name assigned both in a closure
    # and in this enclosing body (as the final `ŷ` below is) is one shared,
    # Core.Box'ed variable, which makes every trial-c1 evaluation type-unstable.
    fit_at_c1_val = @closure c1 -> wls_fit(forward(fw, 1.0, 0.0, ρ_val, δρ_val, c1), wls)
    χ²_at_c1 = @closure c1 -> reduced_chi2(fit_at_c1_val(c1))

    lo, hi = cmin - eps, cmax + eps
    grid = lo:eps:hi
    chis = [χ²_at_c1(c1) for c1 in grid]
    i_best = argmin(chis)
    lo_b = i_best == 1            ? lo : grid[i_best-1]
    hi_b = i_best == length(grid) ? hi : grid[i_best+1]

    res = optimize(χ²_at_c1, lo_b, hi_b, Brent())
    c1_star = minimizer(res)

    # the one fit that matters: at the caller's real (possibly Dual) ξ.
    ŷ = forward(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4]), c1_star)
    return ŷ, wls_fit(ŷ, wls), c1_star
end

"""
$(TYPEDSIGNATURES)

Classifies a profiled c1_star (from [`profiled_corrs`](@ref)) against the
physical bounds `(cmin, cmax)`:

- `-1`: c1_star < cmin, i.e. the search wanted to go lower than the
    physical bound even with `eps` of extra room.
- `+1`: c1_star > cmax, symmetric case.
- `0`: c1_star ∈ [cmin, cmax], not saturated.

Meant to be called once, on a single reported value (e.g. the MAP draw's
c1), not per posterior draw or inside the sampler's hot path.
"""
function excl_vol_saturation(
    c1::Real;
    cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
    cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
)::Int
    c1 < cmin && return -1
    c1 > cmax && return 1
    return 0
end

# function profiled_corrs(
#     wls::WLSData,
#     ξ::SVector{5,Float64},
#     fw::ForwardCache;
#     cmin::Float64=EXCL_VOL_CORR_BOUNDS[1],
#     cmax::Float64=EXCL_VOL_CORR_BOUNDS[2],
#     eps::Float64=EXCL_VOL_CORR_EPS,
# )::WLSFit
#     # forward doesn't take ξ[5] (δρ4) yet, see CLAUDE.md "Nucleotide
#     # support" gap (2), parameter-vector widening. Dropped here rather
#     # than silently miscomputed.
#     fit_at_c1_val = @closure c1 -> begin
#         ŷ = forward(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4], ξ[5]), c1)
#         wls_fit(ŷ, wls)
#     end
#     χ²_at_c1 = @closure c1 -> reduced_chi2(fit_at_c1_val(c1))
#     lo, hi = cmin - eps, cmax + eps
#     grid = lo:eps:hi
#     chis = [χ²_at_c1(c1) for c1 in grid]
#     i_best = argmin(chis)
#     lo_b = i_best == 1            ? lo : grid[i_best-1]
#     hi_b = i_best == length(grid) ? hi : grid[i_best+1]
#     res = optimize(χ²_at_c1, lo_b, hi_b, Brent())
#     c1_star = minimizer(res)
#     return fit_at_c1_val(c1_star)
# end
