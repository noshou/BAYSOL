# SPDX-License-Identifier: LGPL-2.1-or-later

module Inference

using ..BulkElectronDensity: BulkElectronDensity, Solute, DEFAULT_TEMPERATURE_C
using ..Shannon: ShannonInfo
using AdvancedHMC: DenseEuclideanMetric, Hamiltonian, MassMatrixAdaptor,
    find_good_stepsize, Leapfrog, StanHMCAdaptor, StepSizeAdaptor, sample,
    HMCKernel, Trajectory, MultinomialTS, GeneralisedNoUTurn
using FastClosures, StaticArrays, Distributions, ForwardDiff, DiffResults
using SpecialFunctions: digamma, trigamma
using ..Scattering: ForwardCache
using ..PhysicalConstants: NS_PER_S, MS_PER_S
using Printf: @sprintf
using ..Runtime: with_gc_paused, gc_checkpoint, draw_base, stream, tmap_items, StageLog,
    tick, tock!, fmt_count
using Random: Random, AbstractRNG

#----------------
# Priors
#----------------


"""
CRYSOL3's fitting limits `(lo, hi)` on the convex/concave shell contrasts
δρ₁, δρ₂, in units of [`UNIT_OF_δρ`](@ref): "The limits during the fitting are
-10 to 2". They are the support of the δρ₁/δρ₂ priors
([`Inference.δρ_prior`](@ref BAYSOL.Inference.δρ_prior)) and of the scaled-logit
maps [`Inference.Θ`](@ref BAYSOL.Inference.Θ)/[`Inference.Ξ`](@ref BAYSOL.Inference.Ξ)
put on them.
"""
const BOUNDS_δρ₁₂ = (-10.0, 2.0)

"Lower end L of the δρ₁/δρ₂ support [L, L + W] = [`BOUNDS_δρ₁₂`](@ref)."
const LOWER_BOUND_δρ₁₂ = BOUNDS_δρ₁₂[1]

"Width W of the δρ₁/δρ₂ support [L, L + W] = [`BOUNDS_δρ₁₂`](@ref)."
const WIDTH_δρ₁₂ = BOUNDS_δρ₁₂[2] - BOUNDS_δρ₁₂[1]

"""
CRYSOL3's default convex/concave shell contrast δρ₁ = δρ₂, in units of
[`UNIT_OF_δρ`](@ref): "The default parameters of the contrasts for the three types
of water beads are 1, 1, 0". The mode of the δρ₁/δρ₂ priors
([`Inference.δρ_prior`](@ref BAYSOL.Inference.δρ_prior)); must lie inside
[`BOUNDS_δρ₁₂`](@ref).
"""
const MODE_δρ₁₂ = 1.0

"""
Default concentration κ = α + β − 2 of the δρ₁/δρ₂ Beta priors
([`Inference.δρ_prior`](@ref BAYSOL.Inference.δρ_prior)). κ = 14 gives
Beta(83/6, 13/6) on [`BOUNDS_δρ₁₂`](@ref), with its mode at δρ = 1 and
SD(δρ) ≈ 1.00. That is the same spread as the Normal(1, 1) δρ₂ prior it
replaces.
"""
const κ_δρ₁₂ = 14.0

"""
Default concentration κ = α + β − 2 of the cavity-contrast (δρ₃) Beta prior
([`Inference.δρ_prior`](@ref BAYSOL.Inference.δρ_prior)), stretched onto
[−ρ̄ₑ/`UNIT_OF_δρ`, (`φ_max` − 1)·ρ̄ₑ/`UNIT_OF_δρ`]. κ = 1.25 gives Beta(2, 1.25) on
u = (δρ₃ − X)/W, with its mode at δρ₃ = 0 (bulk-density cavity water).
"""
const κ_δρ₃ = 1.25

"""
Upper bound on the cavity occupancy φ = `ρ_cavity/ρ₀`. Water in a cavity can
be at most modestly denser than bulk: the densest well-attested hydration
water is Merzel & Smith's first layer at 1.15·ρ₀, so `φ_max` = 1.25 leaves
margin above it while excluding unphysical over-dense "water" (e.g. the
δρ3 = 4, φ ≈ 1.36, seen when δρ3 was unconstrained).
"""
const φ_max = 1.25

@assert(
    BOUNDS_δρ₁₂[1] < MODE_δρ₁₂ < BOUNDS_δρ₁₂[2],
    "MODE_δρ₁₂ must lie inside BOUNDS_δρ₁₂"
)

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

#----------------
# Profiled c1
#----------------

"""
Hard bounds `(cmin, cmax)` on CRYSOL's excluded-volume correction c1
([`Inference.profiled_corrs`](@ref BAYSOL.Inference.profiled_corrs)), CRYSOL's
`r₀/r_m`. c1 is profiled, not sampled, so these bounds -- not a prior -- are
what stops it from absorbing model misspecification that belongs on the
physically meaningful parameters (dns/δρ1-3) instead.
"""
const EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)

"""
Padding/grid-resolution unit for [`Inference.profiled_corrs`](@ref
`BAYSOL.Inference.profiled_corrs`)'s c1 search: the search actually runs on
`(cmin - EXCL_VOL_CORR_EPS, cmax + EXCL_VOL_CORR_EPS)` so that landing
exactly on `cmin`/`cmax` can be distinguished from genuinely wanting to go
further (real "saturation"), and the same value is the coarse pre-scan
grid's step size.
"""
const EXCL_VOL_CORR_EPS = 0.02

"""
Absolute tolerance on c1 of [`Inference.profiled_corrs`](@ref
`BAYSOL.Inference.profiled_corrs`)'s `Brent()` polish, used everywhere c1 is profiled
(the MAP search, its Hessian, and every NUTS log-density and gradient call).

The tolerance has to be judged on the *gradient*, not the value. χ² is quadratic in the c1
error δ at the optimum, so the profiled log-likelihood is accurate to O(δ²). But the
gradient comes from the envelope theorem, which makes ∂ₓf exact only at the exact optimum:
at c1* + δ it is off by (∂²f/∂c1∂ξ)·δ, first order in δ. That second derivative grows with
χ² and with how narrow the posterior is, so the error is negligible for a good fit and as
large as the true gradient for a poor one. Measured in NUTS's whitened coordinates
(posterior ≈ N(0, I), true gradient norm 1.7–2.1) on the fits that ran at the tree-depth
limit, the median gradient error is 1.0–1.5 at 1e-5 (SASDBS6 model 3, SASDLP4 model 3,
SASDEP6 model 2), 0.02–0.18 at 1e-6, and at most 0.007 at 1e-8, falling linearly with the
tolerance; a well-behaved fit (SASDMJ9) is 0.03 at 1e-5. A gradient that disagrees with
the value inflates the leapfrog energy error, so step-size adaptation shrinks ε from about
0.6 to 0.001–0.03 and the trees grow to 100–1000 steps, with a cost that depends on the
RNG seed (SASDMZ9 model 3 at 1e-5: 13 to 820 steps per iteration over four seeds; at 1e-6:
6.0 to 6.2). The price of the tight tolerance is a 15–40 % slower profiled evaluation.
"""
const EXCL_VOL_CORR_TOL = 1e-8

@assert(
    0 < EXCL_VOL_CORR_EPS <= (EXCL_VOL_CORR_BOUNDS[2] - EXCL_VOL_CORR_BOUNDS[1]),
    "EXCL_VOL_CORR_EPS must be in (0, cmax-cmin]"
)

# The weighted-least-squares data and fit the profiled
# likelihood is built from, and the static c1 tables

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

"Raised by [`wls_fit`](@ref) on invalid input or a degenerate (flat-model) fit."
struct WLSError <: Exception
    msg::String
end

"""
    _C1Tables

Static per-run tables for [`profiled_corrs`](@ref)'s c1 search: everything that depends
only on the structure's [`ForwardCache`](@ref BAYSOL.Scattering.ForwardCache) and the scan
settings, not on ξ. Built once (by [`seed_sampler`](@ref), or on the fly), then only ever
read: no field is modified after construction, so one instance can be shared by any
number of threads. Per-evaluation scratch is never stored here.

# Fields
- `cs::Vector{Float64}`: the scan points (cmin − eps):eps:(cmax + eps).
- `g1::Matrix{Float64}`, (Q, length(cs)): g(q; cᵢ) at every scan point.
- `qvals::Vector{Float64}`, `r_m::Float64`: the grid and mean atomic radius g is built on.
- `cmin`, `cmax`, `eps::Float64`: the scan settings the tables were built for.
- `q2max::Float64`: the largest q², which bounds the
    argument of the anchored envelope (see [`_anchor`](@ref)).
"""
struct _C1Tables
    cs::Vector{Float64}
    g1::Matrix{Float64}
    qvals::Vector{Float64}
    r_m::Float64
    cmin::Float64
    cmax::Float64
    eps::Float64
    q2max::Float64
end

# The anchored envelope of the c1 search

"""
Largest `q²·|k(c1) − k(cⱼ)|` for which the anchored envelope's Taylor
polynomial is used; its truncation error there is below 6e-18 relative. Beyond
it (a very large q or mean radius) the passes use the library exponential.
"""
const ENVELOPE_TAYLOR_LIMIT = 0.05

# 1/0!, 1/1!, …, 1/8!: the Taylor polynomial of eˣ, degree 8
const _EXP_TAYLOR = ntuple(n -> 1 / factorial(n - 1), 9)

#----------------
# Likelihood
#----------------

"Dispatch tag selecting profile vs. marginal log-likelihood in [`_ll`](@ref)."
abstract type LIKELIHOOD end

"""
Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The forward
model produces a predicted curve `y_model(q)`, but the data `I_exp(q)` sits at
some unknown overall scale scale and background offset `bkgrnd_corr`, i.e.
`I_calc` = scale·`y_model` + `bkgrnd_corr`. `wls_fit` (ProfiledCorrs.jl) fits
(scale, `bkgrnd_corr`) in closed form (2-parameter weighted linear regression),
and reports the resulting Gaussian log-likelihood two ways, selected by l:

- `l = PROFILE()`: treat (scale, `bkgrnd_corr`) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, `bkgrnd_corr`), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, `bkgrnd_corr`) [`wls_marg_ll`](@ref).
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"""
struct PROFILE<:LIKELIHOOD
    type::AbstractString
    PROFILE() = new("profile_log_likelihood")
end

"""
Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The forward
model produces a predicted curve `y_model(q)`, but the data `I_exp(q)` sits at
some unknown overall scale scale and background offset `bkgrnd_corr`, i.e.
`I_calc` = scale·`y_model` + `bkgrnd_corr`. `wls_fit` (ProfiledCorrs.jl) fits
(scale, `bkgrnd_corr`) in closed form (2-parameter weighted linear regression),
and reports the resulting Gaussian log-likelihood two ways, selected by l:

- `l = PROFILE()`: treat (scale, `bkgrnd_corr`) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, `bkgrnd_corr`), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, `bkgrnd_corr`) [`wls_marg_ll`](@ref).
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"""
struct MARGINAL<:LIKELIHOOD
    type::AbstractString
    MARGINAL() = new("marginal_log_likelihood")
end

#----------------
# Sampler
#----------------

"""
Default NUTS target acceptance rate, as a percentage in (0, 100), for
[`run_model`](@ref BAYSOL.Pipeline.run_model) /
[`Inference.infer`](@ref BAYSOL.Inference.infer): Stan's usual default of 80 %.
"""
const DEFAULT_TARGET_ACCEPT = 80

"""
Number of L-BFGS starts of the pre-NUTS MAP search
([`Inference.infer`](@ref BAYSOL.Inference.infer)): the seed's own initial
point plus `MAP_N_STARTS - 1` further prior draws (32: the search takes
tens of milliseconds, and a narrow basin can attract only a few starts).
"""
const MAP_N_STARTS = 32

"""
How many of the distinct basins the MAP search finds (lowest optimum
first) are compared by their Laplace mass (`−f − ½ log det H`, one
Hessian each) to choose the one the sampler is whitened at.
"""
const MAP_MAX_BASINS = 4

"Iteration cap of each L-BFGS start of the MAP search."
const MAP_MAX_ITER = 500

"""
Gradient tolerance (max-norm of ∇ log π in prior-standardized z-space) at which an
L-BFGS start of the MAP search counts as converged.
"""
const MAP_G_TOL = 1e-6

"""
Absolute decrease of −log π (nats) below which an L-BFGS start of the MAP search
counts as stalled, once it has stayed below it for `MAP_F_SUCCESSIVE` successive
iterations. The problem is conditioned ~1e6 in z-space, so the gradient test alone
([`MAP_G_TOL`](@ref)) keeps iterating long after f has stopped changing in the
fourth digit; the f test ends such a start. 1e-5 stopped some starts too early
(SASDMZ9 model 2 missed its best mode); 1e-6 lost none on 51 of the fitting tests.
"""
const MAP_F_ABSTOL = 1e-6

"""
Successive iterations with a decrease below [`MAP_F_ABSTOL`](@ref) that end an L-BFGS start.
"""
const MAP_F_SUCCESSIVE = 3

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

# Chains: starts, pooling

"""
Number of NUTS chains [`infer`](@ref) runs by default: 8. Fixed, not the
number of Julia threads: the number of threads only decides how many chains
run at the same time (two rounds on four cores), so the posterior never
depends on the machine. Where the chains start: [`chain_radius`](@ref).
"""
const DEFAULT_N_CHAINS = 8

"""
Distances from the MAP, in posterior standard deviations (the sampler's whitened
coordinates, where the posterior is ≈ N(0, I)), at which the mirrored pairs of chains
start: pair `p` (two chains) starts at `+r_p·u_p` and `-r_p·u_p` for a random direction
`u_p` on the sphere, so that along each direction both sides of the MAP are started from
(the posteriors are skewed against hard bounds, and the two sides differ). The typical
distance of a draw from the MAP in four dimensions is 2; the far starts are what finds
second modes. Pairs beyond `length(CHAIN_START_RADII)` reuse the last radius.
"""
const CHAIN_START_RADII = (4.0, 10.0, 20.0)

"""
Default `jitter_seed` of [`infer`](@ref): the jittered starts
come from streams of this value (never of the run's `rng_seed`),
so they are the same in every run unless the caller changes it.
"""
const DEFAULT_JITTER_SEED = UInt64(0x6a697474657273)   # "jitters"

"""
A jittered start whose log π is not finite (or whose gradient is not)
is pulled halfway back toward the MAP at most this many times; if it
never becomes usable the chain starts at the MAP and is marked as such.
"""
const CHAIN_JITTER_MAX_HALVINGS = 8

"""
If the best post-warm-up draw of the first round of chains beats log π at the MAP the
sampler was whitened at by more than this many nats, the MAP search missed a better basin
(a draw of a four-parameter posterior sits about 1.7 nats below its mode, so this is clear
evidence): the sampler re-whitens at that draw's basin and runs the chains once more.
"""
const BASIN_RESTART_NATS = 2.0

"""
A chain is not pooled when more than this fraction of its post-warm-up transitions diverged.
"""
const CHAIN_MAX_DIVERGENT = 0.5

"""
The rank-normalized split R̂ below which the pooled
chains are reported as converged (Stan's recommendation).
"""
const RHAT_OK = 1.01

# Several modes: grouping and bridge sampling

"""
Two chains are in the same mode when the larger of their rank-normalized split R̂ over
the parameters and log π is at most this. Chains of one mode agree (R̂ near 1, a few
hundredths above it for slow ones); chains of two separate modes disagree and R̂
saturates near 1.7, so any value between is a clean cut; 1.25 is the middle of the gap.
"""
const MODE_RHAT = 1.25

"Iteration cap of the bridge-sampling fixed point."
const BRIDGE_MAX_ITER = 1000

"Convergence tolerance of the bridge-sampling fixed point, on log Z."
const BRIDGE_TOL = 1e-10

"""
A mode whose mass share is below this fraction keeps no draws in the
pooled posterior (its chains are still reported, with their weight).
"""
const MODE_NEGLIGIBLE = 1e-4

"""
The largest bridge-sampling error (in nats) of a mode's log mass at which the mode
weights are still applied. A larger error means the estimate does not determine the
mode's share (an error of 6 nats is a factor of 400), so thinning the draws to it
could discard a whole mode on the strength of noise; see [`weights_uncertain`](@ref).
"""
const BRIDGE_MAX_ERR = 1.0

"Largest exponent (in nats) allowed in the bridge-sampling weights: `exp(230) ≈ 1e100`."
const BRIDGE_CLAMP = 230.0

# Purpose tags of the random streams

"""
Purpose tags of [`stream`](@ref BAYSOL.Runtime.stream):
which use of randomness a stream is for.
"""
const _RNG_MAP_STARTS = 1
const _RNG_NUTS   = 2
const _RNG_JITTER = 3
const _RNG_BRIDGE = 4

# The data a run starts from

"""
    Seed{T<:Real,N}

Everything [`infer`](@ref) needs to start a NUTS chain.

# Fields
-   `pr::ξ_priors`: the physical priors over ξ, from [`_calc_ξ_priors`](@ref).
-   `θ₀::SVector{N,T}`: one draw from pr ([`_ξ₀`](@ref)), reparameterized into
    unconstrained θ-space via [`Θ`](@ref); the first start of the MAP search.
-   `fw::ForwardCache`: the structure's geometry-only cache (the Gram matrix
    G(q), q-grid, and mean atomic radius), from `forward_cache`.
-   `wls::WLSData`: the measured intensity curve and its per-point standard
    errors, precomputed into [`WLSData`](@ref) once so the NUTS hot path
    (`_ll`/`_logπ`) never rebuilds the data-only weighted sums.
-   `timing::Union{Nothing,StageLog}`: the run's stage log, if timing is on;
    [`infer`](@ref) appends its stages and hands it on in the [`Inferred`](@ref).
-   `c1tab::_C1Tables`: the static c1-search tables for fw ([`_C1Tables`](@ref)), built
    once here and passed to every [`profiled_corrs`](@ref) call; read-only, so safe to
    share across threads.
-   `shannon::Union{Nothing,ShannonInfo}`: how the measured curve was reduced to the
    data `wls` holds (diameter, band limit, binning, raw data), when it came
    through [`Shannon.shannon_data`](@ref BAYSOL.Utils.Shannon.shannon_data);
    `nothing` otherwise.
"""
struct Seed{T<:Real,N}
    pr::ξ_priors
    θ₀::SVector{N,T}
    fw::ForwardCache
    wls::WLSData
    timing::Union{Nothing,StageLog}
    c1tab::_C1Tables
    shannon::Union{Nothing,ShannonInfo}
end


include("Priors.jl")
include("ProfiledCorrs.jl")
include("Posterior.jl")
include("Modes.jl")
include("Infer.jl")
include("MAP.jl")

export Seed, Inferred,
    seed_sampler, infer, PROFILE, MARGINAL, ChainDiagnostics, DEFAULT_N_CHAINS,
    ρₑ_prior, δρ_prior, prior_z_scores,
    ξ_priors, θ_prior_moments, profiled_corrs, excl_vol_saturation,
    WLSData, wls_fit

end # module
