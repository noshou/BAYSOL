# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Sampling and statistics for BAYSOL.
"""
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
using ..Runtime:
    withGcPaused, gcCheckpoint, drawBase, stream, tmapItems, StageLog,
    tick, tock!, fmtCount
using Random: Random, AbstractRNG

#----------------
# Priors
#----------------

include("params.jl")

# Fixed internals: not settings (changing them could break a run), so they are not in
# params.jl.

"""
Absolute tolerance on c1 of [`Inference.profiledCorrs`](@ref
`BAYSOL.Inference.profiledCorrs`)'s `Brent()` polish, used everywhere c1 is profiled
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

"""
The rank-normalized split R̂ below which the pooled
chains are reported as converged (Stan's recommendation).
"""
const RHAT_OK = 1.01

"""
The smallest bulk and tail effective sample size a run may have to count as converged:
400 (Vehtari et al. 2021, the companion of the R̂ limit). Below it, or when an ESS cannot
be computed, the run is retried and, if it is still below, [`NotConvergedError`](@ref) is
thrown.
"""
const ESS_MIN = 400.0

"""
Default `retry` of [`infer`](@ref) and [`runModel`](@ref BAYSOL.Pipeline.runModel):
whether a run whose worst R̂ is above [`RHAT_OK`](@ref) is sampled once more, longer
([`RETRY_N_ADAPT`](@ref), [`RETRY_N_DRAWS`](@ref)).
"""
const RETRY = true

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
Mahalanobis distance (under the MAP Hessian) beyond which two L-BFGS optima count as
distinct modes in the MAP search's multimodality count.
"""
const MAP_MODE_SEP = 3.0

"""
Floor on the eigenvalues of the MAP Hessian (prior-standardized z-space) before
whitening. z-space is scaled to unit prior spread, so a direction whose curvature is
below 1 (wider than the prior itself, or negative: a ridge or saddle) keeps the prior
scaling NUTS would have used without the whitening.
"""
const MAP_HESS_EIG_FLOOR = 1.0

"""
An optimum carries mass when its Laplace share (its mass over the total of the optima
found) is at least this much.
"""
const OPTIMUM_MIN_SHARE = 0.01

"""
Two chains are in the same mode when the larger of their rank-normalized split R̂ over
the parameters and log π is at most this. Chains of one mode agree (R̂ near 1, a few
hundredths above it for slow ones); chains of two separate modes disagree and R̂
saturates near 1.7, so any value between is a clean cut; 1.25 is the middle of the gap.
"""
const MODE_RHAT = 1.25

"""
A mode whose mass share is below this fraction keeps no draws in the
pooled posterior (its chains are still reported, with their weight).
"""
const MODE_NEGLIGIBLE = 1e-4

"""
Largest `q²·|k(c1) − k(cⱼ)|` for which the anchored envelope's Taylor
polynomial is used; its truncation error there is below 6e-18 relative. Beyond
it (a very large q or mean radius) the passes use the library exponential.
"""
const ENVELOPE_TAYLOR_LIMIT = 0.05

"""
Central-difference step, in prior-standardized z-space, of the first Hessian pass at
the MAP. The second pass rescales it per coordinate to `MAP_HESS_REL_STEP` times that
coordinate's Laplace standard deviation from the first pass.
"""
const MAP_HESS_STEP = 1e-4

"Second-pass Hessian step as a fraction of each coordinate's first-pass Laplace σ."
const MAP_HESS_REL_STEP = 0.1

"""
A jittered start whose log π is not finite (or whose gradient is not)
is pulled halfway back toward the MAP at most this many times; if it
never becomes usable the chain starts at the MAP and is marked as such.
"""
const CHAIN_JITTER_MAX_HALVINGS = 8

"""
A chain is not pooled when more than this fraction
of its post-warm-up transitions diverged.
"""
const CHAIN_MAX_DIVERGENT = 0.5

"""
Offset that derives the rerun's `rngSeed` from the original one
(wrapping multiplication by a 64-bit odd constant after adding the offset), so a
retry is a deterministic function of the seeds and the data.
"""
const RETRY_SEED_OFFSET = UInt64(0x72657472795f7264)   # "retry_rd"

"Iteration cap of the bridge-sampling fixed point."
const BRIDGE_MAX_ITER = 1000

"Convergence tolerance of the bridge-sampling fixed point, on log Z."
const BRIDGE_TOL = 1e-10

"""
The largest bridge-sampling error (in nats) of a mode's log mass at which the mode
weights are still applied. A larger error means the estimate does not determine the
mode's share (an error of 6 nats is a factor of 400), so thinning the draws to it
could discard a whole mode on the strength of noise; see [`weightsUncertain`](@ref).
"""
const BRIDGE_MAX_ERR = 1.0

"Largest exponent (in nats) allowed in the bridge-sampling weights: `exp(230) ≈ 1e100`."
const BRIDGE_CLAMP = 230.0

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
    iObs::V
    weights::V
    sw::T
    swy::T
    swyy::T
    sumLogVar::T
end

"""
    WLSFit{T}

Result of [`wlsFit`](@ref): the fitted `I_calc(q)` = scale·`yModel(q)` +
`bkgrndCorr` plus everything needed to use the fit as a profiled Gaussian
log-likelihood term.
"""
struct WLSFit{T}
    scale::T
    bkgrndCorr::T
    chi2::T
    dof::Int
    sumLogVar::T
end

"Raised by [`wlsFit`](@ref) on invalid input or a degenerate (flat-model) fit."
struct WLSError <: Exception
    msg::String
end

"""
    _C1Tables

Static per-run tables for [`profiledCorrs`](@ref)'s c1 search: everything that depends
only on the structure's [`ForwardCache`](@ref BAYSOL.Scattering.ForwardCache) and the scan
settings, not on ξ. Built once (by [`seedSampler`](@ref), or on the fly), then only ever
read: no field is modified after construction, so one instance can be shared by any
number of threads. Per-evaluation scratch is never stored here.

# Fields
- `cs::Vector{Float64}`: the scan points (cmin − eps):eps:(cmax + eps).
- `g1::Matrix{Float64}`, (Q, length(cs)): g(q; cᵢ) at every scan point.
- `qvals::Vector{Float64}`, `rM::Float64`: the grid and mean atomic radius g is built on.
- `cmin`, `cmax`, `eps::Float64`: the scan settings the tables were built for.
- `q2max::Float64`: the largest q², which bounds the
    argument of the anchored envelope (see [`_anchor`](@ref)).
"""
struct _C1Tables
    cs::Vector{Float64}
    g1::Matrix{Float64}
    qvals::Vector{Float64}
    rM::Float64
    cmin::Float64
    cmax::Float64
    eps::Float64
    q2max::Float64
end

# The anchored envelope of the c1 search

# 1/0!, 1/1!, …, 1/8!: the Taylor polynomial of eˣ, degree 8
const _EXP_TAYLOR = ntuple(n -> 1 / factorial(n - 1), 9)

#----------------
# Sampler
#----------------

# Purpose tags of the random streams

"""
Purpose tags of [`stream`](@ref BAYSOL.Runtime.stream):
which use of randomness a stream is for.
"""
const _RNG_MAP_STARTS = 1
const _RNG_NUTS = 2
const _RNG_JITTER = 3
const _RNG_BRIDGE = 4
const _RNG_MAP_JITTER = 5
const _RNG_INITIAL_POINT = 6

# The data a run starts from

"""
    Seed{T<:Real,N}

Everything [`infer`](@ref) needs to start a NUTS chain.

# Fields
-   `pr::ξ_priors`: the physical priors over ξ, from [`_calc_ξ_priors`](@ref).
-   `θ₀::SVector{N,T}`: one draw from pr ([`_ξ₀`](@ref)) from a stream of
    [`RNG_SEED`](@ref), so it is the same in every run, reparameterized into
    unconstrained θ-space via [`Θ`](@ref); the first start of the MAP search.
-   `fw::ForwardCache`: the structure's geometry-only cache (the Gram matrix
    G(q), q-grid, and mean atomic radius), from `forwardCache`.
-   `wls::WLSData`: the measured intensity curve and its per-point standard
    errors, precomputed into [`WLSData`](@ref) once so the NUTS hot path
    (`_ll`/`_logπ`) never rebuilds the data-only weighted sums.
-   `timing::Union{Nothing,StageLog}`: the run's stage log, if timing is on;
    [`infer`](@ref) appends its stages and hands it on in the [`Inferred`](@ref).
-   `c1tab::_C1Tables`: the static c1-search tables for fw ([`_C1Tables`](@ref)), built
    once here and passed to every [`profiledCorrs`](@ref) call; read-only, so safe to
    share across threads.
-   `shannon::Union{Nothing,ShannonInfo}`: how the measured curve was reduced to the
    data `wls` holds (diameter, band limit, binning, raw data), when it came
    through [`Shannon.shannonData`](@ref BAYSOL.Utils.Shannon.shannonData);
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


include("priors.jl")
include("profiled-corrs.jl")
include("posterior.jl")
include("modes.jl")
include("infer.jl")
include("map.jl")

export Seed, Inferred, SamplerOptions,
    seedSampler, infer, ChainDiagnostics, OptimumReport, NotConvergedError,
    N_CHAINS,
    ρₑ_prior, δρ_prior, priorZScores,
    ξ_priors, θ_prior_moments, profiledCorrs, exclVolSaturation,
    WLSData, wlsFit

end # module
