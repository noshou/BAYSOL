# SPDX-License-Identifier: LGPL-2.1-or-later

#--------------
# δρ Constants
#--------------

"Shell-contrast unit in e·Å⁻³ (CRYSOL's --dro); dro_k = DRO_UNIT * δρ_k."
const DRO_UNIT = 0.03

"""
Hard bounds `(cmin, cmax)` on CRYSOL's excluded-volume correction c1
([`Fitting.profiled_corrs`](@ref BAYSOL.Fitting.profiled_corrs)), CRYSOL's
r₀/r_m. c1 is profiled, not sampled, so these bounds -- not a prior -- are
what stops it from absorbing model misspecification that belongs on the
physically meaningful parameters (dns/δρ1-3) instead.
"""
const EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)

"""
Padding/grid-resolution unit for [`Fitting.profiled_corrs`](@ref
BAYSOL.Fitting.profiled_corrs)'s c1 search: the search actually runs on
`(cmin - EXCL_VOL_CORR_EPS, cmax + EXCL_VOL_CORR_EPS)` so that landing
exactly on `cmin`/`cmax` can be distinguished from genuinely wanting to go
further (real "saturation"), and the same value is the coarse pre-scan
grid's step size.
"""
const EXCL_VOL_CORR_EPS = 0.02

"""
Upper bound on the cavity occupancy φ = ρ_cavity/ρ₀. Water in a cavity can
be at most modestly denser than bulk: the densest well-attested hydration
water is Merzel & Smith's first layer at 1.15·ρ₀, so φ_max = 1.25 leaves
margin above it while excluding unphysical over-dense "water" (e.g. the
δρ3 = 4, φ ≈ 1.36, seen when δρ3 was unconstrained).
"""
const φ_max = 1.25

"""
CRYSOL3's fitting limits `(lo, hi)` on the convex/concave shell contrasts
δρ₁, δρ₂, in units of [`DRO_UNIT`](@ref): "The limits during the fitting are
-10 to 2". They are the support of the δρ₁/δρ₂ priors
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)) and of the scaled-logit
maps [`Fitting.Θ`](@ref BAYSOL.Fitting.Θ)/[`Fitting.Ξ`](@ref BAYSOL.Fitting.Ξ)
put on them.
"""
const DRO_BOUNDS = (-10.0, 2.0)

"""
CRYSOL3's default convex/concave shell contrast δρ₁ = δρ₂, in units of
[`DRO_UNIT`](@ref): "The default parameters of the contrasts for the three types
of water beads are 1, 1, 0". The mode of the δρ₁/δρ₂ priors
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)); must lie inside
[`DRO_BOUNDS`](@ref).
"""
const DRO12_MODE = 1.0

"""
Default concentration κ = α + β − 2 of the δρ₁/δρ₂ Beta priors
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)). κ = 14 gives
Beta(83/6, 13/6) on [`DRO_BOUNDS`](@ref), with its mode at δρ = 1 and
SD(δρ) ≈ 1.00. That is the same spread as the Normal(1, 1) δρ₂ prior it
replaces.
"""
const DRO12_CONCENTRATION = 14.0

"""
Default concentration κ = α + β − 2 of the cavity-contrast (δρ₃) Beta prior
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)), stretched onto
[−ρ̄ₑ/`DRO_UNIT`, (`φ_max` − 1)·ρ̄ₑ/`DRO_UNIT`]. κ = 1.25 gives Beta(2, 1.25) on
u = (δρ₃ − X)/W, with its mode at δρ₃ = 0 (bulk-density cavity water).
"""
const DRO3_CONCENTRATION = 1.25

@assert(DRO_BOUNDS[1] < DRO12_MODE < DRO_BOUNDS[2], "DRO12_MODE must lie inside DRO_BOUNDS")

@assert(
    0 < EXCL_VOL_CORR_EPS <= (EXCL_VOL_CORR_BOUNDS[2] - EXCL_VOL_CORR_BOUNDS[1]),
    "EXCL_VOL_CORR_EPS must be in (0, cmax-cmin]"
)
