# SPDX-License-Identifier: LGPL-2.1-or-later

module Fitting

using DocStringExtensions
using Distributions: Beta, Continuous, LocationScale, LogNormal

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

Result of [`wls_fit`](@ref): the fitted I_calc(q) = scale·y_model(q) +
bkgrnd_corr plus everything needed for uncertainty propagation and for
using the fit as a (profiled or marginalised) Gaussian log-likelihood term.
"""
struct WLSFit{T}
    scale::T
    bkgrnd_corr::T
    var_scale::T
    var_bkgrnd_corr::T
    cov_scale_bkgrnd_corr::T
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

export  Solute, Protein, NonBiological, DNA, RNA, Seed, FitResult,
        seed_fitting, run_fitting, PROFILE, MARGINAL,
        ρₑ_prior, δρ_prior, prior_z_scores,
        ξ_priors, θ_prior_moments, profiled_corrs, excl_vol_saturation,
        WLSData, wls_fit

end # module
