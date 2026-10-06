# SPDX-License-Identifier: LGPL-2.1-or-later

module Fitting

using Distributions: Beta, Continuous, LocationScale, LogNormal
using ..PhysicalConstants: STANDARD_TEMPERATURE_C

#----------------
# Priors
#----------------

"""
Default solution temperature, °C, for `_ρₑ`/[`Fitting.ρₑ_prior`](@ref BAYSOL.Fitting.ρₑ_prior)'s bulk-electron
-density calculation. Pass the sample's real temperature instead whenever it is
known: water's density is evaluated at it exactly, and the solutes' 25 °C
partial molar volumes get a widened uncertainty (see
[`PMV_FRACTIONAL_EXPANSIBILITY`](@ref BAYSOL.PartialMolarVolumes.PMV_FRACTIONAL_EXPANSIBILITY)).
Defaults to the standard reference temperature, [`STANDARD_TEMPERATURE_C`](@ref
`BAYSOL.PhysicalConstants.STANDARD_TEMPERATURE_C`), the same temperature the PMV tables are
given at, so the default never widens their uncertainty.
"""
const DEFAULT_TEMPERATURE_C = STANDARD_TEMPERATURE_C

"""
CRYSOL3's fitting limits `(lo, hi)` on the convex/concave shell contrasts
δρ₁, δρ₂, in units of [`DRO_UNIT`](@ref): "The limits during the fitting are
-10 to 2". They are the support of the δρ₁/δρ₂ priors
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)) and of the scaled-logit
maps [`Fitting.Θ`](@ref BAYSOL.Fitting.Θ)/[`Fitting.Ξ`](@ref BAYSOL.Fitting.Ξ)
put on them.
"""
const DRO_BOUNDS = (-10.0, 2.0)

"Lower end L of the δρ₁/δρ₂ support [L, L + W] = [`DRO_BOUNDS`](@ref)."
const DRO_LOWER = DRO_BOUNDS[1]

"Width W of the δρ₁/δρ₂ support [L, L + W] = [`DRO_BOUNDS`](@ref)."
const DRO_WIDTH = DRO_BOUNDS[2] - DRO_BOUNDS[1]

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

"""
Upper bound on the cavity occupancy φ = `ρ_cavity/ρ₀`. Water in a cavity can
be at most modestly denser than bulk: the densest well-attested hydration
water is Merzel & Smith's first layer at 1.15·ρ₀, so `φ_max` = 1.25 leaves
margin above it while excluding unphysical over-dense "water" (e.g. the
δρ3 = 4, φ ≈ 1.36, seen when δρ3 was unconstrained).
"""
const φ_max = 1.25

@assert(DRO_BOUNDS[1] < DRO12_MODE < DRO_BOUNDS[2], "DRO12_MODE must lie inside DRO_BOUNDS")

#----------------
# Profiled c1
#----------------

"""
Hard bounds `(cmin, cmax)` on CRYSOL's excluded-volume correction c1
([`Fitting.profiled_corrs`](@ref BAYSOL.Fitting.profiled_corrs)), CRYSOL's
`r₀/r_m`. c1 is profiled, not sampled, so these bounds -- not a prior -- are
what stops it from absorbing model misspecification that belongs on the
physically meaningful parameters (dns/δρ1-3) instead.
"""
const EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)

"""
Padding/grid-resolution unit for [`Fitting.profiled_corrs`](@ref
`BAYSOL.Fitting.profiled_corrs`)'s c1 search: the search actually runs on
`(cmin - EXCL_VOL_CORR_EPS, cmax + EXCL_VOL_CORR_EPS)` so that landing
exactly on `cmin`/`cmax` can be distinguished from genuinely wanting to go
further (real "saturation"), and the same value is the coarse pre-scan
grid's step size.
"""
const EXCL_VOL_CORR_EPS = 0.02

"""
Absolute tolerance on c1 of [`Fitting.profiled_corrs`](@ref
`BAYSOL.Fitting.profiled_corrs`)'s `Brent()` polish, used during sampling and the MAP
search. χ² is quadratic in the c1 error at the optimum, so 1e-5 leaves the profiled
log-likelihood exact to far below its Monte Carlo noise; the reported c1 is good to
about this much.
"""
const EXCL_VOL_CORR_TOL = 1e-5

"""
Tight c1 tolerance for the finite-difference Hessian at the MAP: the envelope-theorem
gradient is off by O(c1 error), and central differences divide that by their step,
so the Hessian's gradient calls profile c1 to about Optim's own default precision.
"""
const EXCL_VOL_CORR_TOL_FINE = 1e-8

@assert(
    0 < EXCL_VOL_CORR_EPS <= (EXCL_VOL_CORR_BOUNDS[2] - EXCL_VOL_CORR_BOUNDS[1]),
    "EXCL_VOL_CORR_EPS must be in (0, cmax-cmin]"
)

#----------------
# Sampler
#----------------

"""
Default NUTS target acceptance rate, as a percentage in (0, 100), for
[`run_model`](@ref BAYSOL.Report.run_model) / [`Fitting.run_fitting`](@ref BAYSOL.Fitting.run_fitting):
Stan's usual default of 80 %.
"""
const DEFAULT_TARGET_ACCEPT = 80

"""
Number of L-BFGS starts of the pre-NUTS MAP search
([`Fitting.run_fitting`](@ref BAYSOL.Fitting.run_fitting)): the seed's own initial
point plus `MAP_N_STARTS - 1` further prior draws.
"""
const MAP_N_STARTS = 8

"Iteration cap of each L-BFGS start of the MAP search."
const MAP_MAX_ITER = 500

"""
Gradient tolerance (max-norm of ∇ log π in prior-standardized z-space) at which an
L-BFGS start of the MAP search counts as converged.
"""
const MAP_G_TOL = 1e-6

"""
Central-difference step, in prior-standardized z-space, of the first Hessian pass at
the MAP. The second pass rescales it per coordinate to `MAP_HESS_REL_STEP` times that
coordinate's Laplace standard deviation from the first pass.
"""
const MAP_HESS_STEP = 1e-4

"Second-pass Hessian step as a fraction of each coordinate's first-pass Laplace σ."
const MAP_HESS_REL_STEP = 0.1

"""
Floor on the eigenvalues of the MAP Hessian (prior-standardized z-space) before
whitening. z-space is scaled to unit prior spread, so a direction whose curvature is
below 1 (wider than the prior itself, or negative: a ridge or saddle) keeps the prior
scaling NUTS would have used without the whitening.
"""
const MAP_HESS_EIG_FLOOR = 1.0

"""
Mahalanobis distance (under the MAP Hessian) beyond which two L-BFGS optima count as
distinct modes in the MAP search's multimodality count.
"""
const MAP_MODE_SEP = 3.0

"""
    WLSData{T,V}

Precomputed data for repeated weighted least-squares fits against the
same measured SAXS curve.

The measured intensity and uncertainty are retained together with the
weighted sums that do not depend on the forward model.
"""
struct WLSData{T,V<:AbstractVector}
    I_obs::V
    weights::V
    Sw::T
    Swy::T
    Swyy::T
    sum_log_var::T
end

"""
    WLSFit{T}

Result of [`wls_fit`](@ref): the fitted `I_calc(q)` = scale·`y_model(q)` +
`bkgrnd_corr` plus everything needed to use the fit as a (profiled or
marginalised) Gaussian log-likelihood term.
"""
struct WLSFit{T}
    scale::T
    bkgrnd_corr::T
    chi2::T
    dof::Int
    det_XtWX::T
    sum_log_var::T
end

"""
Solutes of the *buffer*: the solution the macromolecule is dissolved in, i.e.
what the buffer blank that was subtracted from the sample contains.

**Do not list the measured macromolecule itself.** Buffer-subtracted SAXS
measures contrast against the buffer, so the solvent electron density ρₑ is the
buffer's. Other copies of the measured species are separate scatterers (their
correlations show up as a structure factor, not as a uniform background
density), and the volume they displace in the sample cell only changes the
buffer-subtraction baseline, which the flat background correction absorbs. A
`Protein`/`DNA`/`RNA` solute is only correct for a genuine buffer component
that the blank also contained (e.g. a carrier protein).
"""
abstract type Solute end

"A protein buffer component (not the measured species; see [`Solute`](@ref))."
struct Protein <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"A non-biological buffer component (salt, buffering agent, cosolute, ...)."
struct NonBiological <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"A DNA buffer component (not the measured species; see [`Solute`](@ref))."
struct DNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"An RNA buffer component (not the measured species; see [`Solute`](@ref))."
struct RNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"A Beta prior stretched onto a bounded interval, as [`δρ_prior`](@ref) returns."
const BoundedBeta = LocationScale{Float64,Continuous,Beta{Float64}}

"""
Physical prior distributions over ξ = (ρₑ, δρ₁, δρ₂, δρ₃). δρ₃'s bounds are fixed
at the mean of `ρₑPrior` (see [`_δρ₃_prior`](@ref)).
"""
struct ξ_priors
    ρₑPrior::LogNormal{Float64}
    δρ₁Prior::BoundedBeta
    δρ₂Prior::BoundedBeta
    δρ₃Prior::BoundedBeta
end

include("WLS.jl")
include("ProfiledCorrs.jl")
include("DensityOfSolvent.jl")
include("DeltaRho.jl")
include("ParamTransform.jl")
include("Sampler.jl")
include("MAP.jl")

export  Solute, Protein, NonBiological, DNA, RNA, Seed, FitResult,
        seed_fitting, run_fitting, PROFILE, MARGINAL,
        ρₑ_prior, δρ_prior, prior_z_scores,
        ξ_priors, θ_prior_moments, profiled_corrs, excl_vol_saturation,
        WLSData, wls_fit

end # module
