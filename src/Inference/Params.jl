# SPDX-License-Identifier: LGPL-3.0-or-later

# The tunable constants of `Inference`: the prior shapes and bounds, the c1 search, the
# MAP search, the NUTS sampler, the chains and their pooling. Guardrails and numerical
# internals are not settings and stay in `Inference.jl`. Included by `Inference.jl`,
# so they live in the module.

"""
CRYSOL3's fitting limits `(lo, hi)` on the convex/concave shell contrasts
δρ₁, δρ₂, in units of [`UNIT_OF_δρ`](@ref): "The limits during the fitting are
-10 to 2". They are the support of the δρ₁/δρ₂ priors
([`Inference.δρ_prior`](@ref BAYSOL.Inference.δρ_prior)) and of the scaled-logit
maps [`Inference.Θ`](@ref BAYSOL.Inference.Θ)/[`Inference.Ξ`](@ref BAYSOL.Inference.Ξ)
put on them.
"""
const BOUNDS_δρ₁₂ = (-10.0, 2.0)

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
Uncertainty, cm³ mol⁻¹, that a non-biological buffer solute gets when its row of the
partial-molar-volume table states none: the harvested mean of the table's stated
uncertainties (`NONBIO_MEAN_UNCERTAINTY` of `BulkElectronDensity`, which `bysl precommit`
keeps current). It widens the prior on ρₑ for such a solute and nothing else. **Not
recommended to change**: a smaller value claims a precision the table does not have. Must
be above 0.
"""
const PMV_FALLBACK_UNCERT = BulkElectronDensity.NONBIO_MEAN_UNCERTAINTY

"""
Upper bound on the cavity occupancy φ = `ρ_cavity/ρ₀`. Water in a cavity can
be at most modestly denser than bulk: the densest well-attested hydration
water is Merzel & Smith's first layer at 1.15·ρ₀, so `φ_max` = 1.25 leaves
margin above it while excluding unphysical over-dense "water" (e.g. the
δρ3 = 4, φ ≈ 1.36, seen when δρ3 was unconstrained).
"""
const φ_max = 1.25

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
Default NUTS target acceptance rate, as a percentage in (0, 100), for
[`run_model`](@ref BAYSOL.Pipeline.run_model) /
[`Inference.infer`](@ref BAYSOL.Inference.infer): 95 %, above Stan's usual 80 %. The
posteriors here are strongly curved and often multimodal; on the 53 fits of a validation
run (since removed, in git history under `test/validation/rhat_retry/`) 95 % removed the
divergences (the three fits above 1 % went to 0.04 % or less) for 1.3× the leapfrog steps.
"""
const TARGET_ACCEPT = 95

"""
Number of L-BFGS starts of the pre-NUTS MAP search
([`Inference.infer`](@ref BAYSOL.Inference.infer)): the seed's own initial point plus
`MAP_N_STARTS - 1` further prior draws (64: the search takes tens of milliseconds, and
a basin that attracts a few percent of the starts is missed by 32 of them with
probability `(1 − p)^32`, 8.5 % for `p` = 7.4 %, a hit rate measured on SASDLP4 in a
validation run, since removed, in git history under `test/validation/optima_recall/`).
"""
const MAP_N_STARTS = 64

"""
How many optima the MAP search keeps: of all the distinct optima it finds, the best ones
(lowest −log π first) are compared by their Laplace mass (`−f − ½ log det H`, one
Hessian each) to choose the basin the sampler is whitened at, and they are the optima
[`infer`](@ref) knows about (see [`OPTIMUM_MIN_SHARE`](@ref)). The others are not
considered.
"""
const MAP_OPTIMA_KEPT = 8

"Iteration cap of each L-BFGS start of the MAP search."
const MAP_MAX_ITER = 500

"""
Successive iterations w/ a decrease below [`MAP_F_ABSTOL`](@ref) that end an L-BFGS start.
"""
const MAP_F_SUCCESSIVE = 3

# More optima: jitter, harvest, chains started at optima without chains

"""
Radii, in posterior standard deviations under an optimum's own Hessian, of the
jittered L-BFGS starts the MAP search makes around the optima it has found
([`MAP_JITTER_DIRECTIONS`](@ref) random directions at each radius).
"""
const MAP_JITTER_RADII = (3.0, 6.0, 12.0)

"Random directions per radius of the jittered starts ([`MAP_JITTER_RADII`](@ref))."
const MAP_JITTER_DIRECTIONS = 2

"""
The jittered starts go around at most this many distinct optima, the lowest first, and
only those within [`MAP_JITTER_WITHIN_NATS`](@ref) of the lowest.
"""
const MAP_JITTER_MAX_OPTIMA = 4

"Nats above the lowest optimum within which an optimum is jittered around."
const MAP_JITTER_WITHIN_NATS = 15.0

"""
After the first round of chains, [`infer`](@ref) runs L-BFGS from this many draws chosen
by farthest-point cover (the draw of highest log π first, then repeatedly the draw
farthest, in the whitened coordinates, from those taken), to find optima the chains
visit and the random starts did not reach.
"""
const HARVEST_COVER = 16

"As [`HARVEST_COVER`](@ref), for the divergent draws: at most this many, also by cover."
const HARVEST_DIVERGENT = 8

"""
Mahalanobis radius, under an optimum's own Hessian, within which a draw counts as
being at that optimum; a chain is at the optimum when at least
[`OPTIMUM_CHAIN_FRACTION`](@ref) of its draws are (4 contains 99 % of a Gaussian
in four dimensions).
"""
const OPTIMUM_CHAIN_RADIUS = 4.0

"The share of a chain's draws that must lie at an optimum for the chain to be at it."
const OPTIMUM_CHAIN_FRACTION = 0.5

"""
An optimum that carries mass ([`OPTIMUM_MIN_SHARE`](@ref)) should have at least this many
chains at it; if fewer are, [`infer`](@ref) starts the missing ones there (chains that did
not mix into it cannot give its draws their weight).
"""
const OPTIMUM_MIN_CHAINS = 2

"The most chains [`infer`](@ref) starts at optima in all."
const OPTIMUM_CHAIN_CAP = 6

# Chains: starts, pooling

"""
Number of NUTS chains [`infer`](@ref) runs by default: 8. Fixed, not the
number of Julia threads: the number of threads only decides how many chains
run at the same time (two rounds on four cores), so the posterior never
depends on the machine. Where the chains start: [`chain_radius`](@ref).
"""
const N_CHAINS = 8

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
Default `rng_seed` of [`infer`](@ref) and [`run_model`](@ref BAYSOL.Pipeline.run_model):
0, so every run is reproducible by default: the same inputs and seed give the same draws,
at any number of threads. Any other integer gives another, equally reproducible run. (The
API also accepts `nothing`, which draws a fresh 53-bit seed from the default RNG, so that
`Random.seed!` before the call fixes it.)
"""
const RNG_SEED = 0

"""
If the best post-warm-up draw of the first round of chains beats log π at the MAP the
sampler was whitened at by more than this many nats, the MAP search missed a better basin
(a draw of a four-parameter posterior sits about 1.7 nats below its mode, so this is clear
evidence): the sampler re-whitens at that draw's basin and runs the chains once more.
"""
const BASIN_RESTART_NATS = 2.0

"""
Warm-up iterations per chain of the rerun [`infer`](@ref) does when R̂ is above
[`RHAT_OK`](@ref). The rerun always runs its own warm-up of this length, whatever
the first run used, followed by [`RETRY_N_DRAWS`](@ref) post-warm-up iterations.
"""
const RETRY_N_ADAPT = 2000

"""
Post-warm-up iterations per chain of the rerun, see [`RETRY_N_ADAPT`](@ref).
"""
const RETRY_N_DRAWS = 2000

# Several modes: grouping and bridge sampling

@assert(
    BOUNDS_δρ₁₂[1] < MODE_δρ₁₂ < BOUNDS_δρ₁₂[2],
    "MODE_δρ₁₂ must lie inside BOUNDS_δρ₁₂"
)

@assert(
    0 < EXCL_VOL_CORR_EPS <= (EXCL_VOL_CORR_BOUNDS[2] - EXCL_VOL_CORR_BOUNDS[1]),
    "EXCL_VOL_CORR_EPS must be in (0, cmax-cmin]"
)

# Sanity limits: positive, inside their range, and never a zero where the code divides.
# (A user may still choose a poor value inside them; these only keep a setting meaningful.)
@assert(BOUNDS_δρ₁₂[1] < BOUNDS_δρ₁₂[2], "BOUNDS_δρ₁₂ must be (lo, hi) with lo < hi")
@assert(κ_δρ₁₂ > 0 && κ_δρ₃ > 0, "the prior concentrations κ must be positive")
@assert(φ_max > 0, "φ_max must be positive")
@assert(
    0 < EXCL_VOL_CORR_BOUNDS[1] < EXCL_VOL_CORR_BOUNDS[2],
    "EXCL_VOL_CORR_BOUNDS must be (lo, hi) with 0 < lo < hi"
)
@assert(0 < TARGET_ACCEPT < 100, "TARGET_ACCEPT must be a percentage in (0, 100)")
@assert(N_CHAINS ≥ 1, "N_CHAINS must be at least 1")
@assert(RNG_SEED isa Integer, "RNG_SEED must be an integer")
@assert(
    MAP_N_STARTS ≥ 1 && MAP_OPTIMA_KEPT ≥ 1 && MAP_MAX_ITER ≥ 1 && MAP_F_SUCCESSIVE ≥ 1,
    "MAP_N_STARTS, MAP_OPTIMA_KEPT, MAP_MAX_ITER and MAP_F_SUCCESSIVE must be at least 1"
)
@assert(
    all(>(0), MAP_JITTER_RADII) && MAP_JITTER_DIRECTIONS ≥ 1 && MAP_JITTER_MAX_OPTIMA ≥ 1 &&
    MAP_JITTER_WITHIN_NATS > 0,
    "the MAP_JITTER_* settings must be positive (counts at least 1)"
)
@assert(
    HARVEST_COVER ≥ 0 && HARVEST_DIVERGENT ≥ 0,
    "the HARVEST_* counts must not be negative"
)
@assert(
    OPTIMUM_CHAIN_RADIUS > 0 && 0 < OPTIMUM_CHAIN_FRACTION ≤ 1 && OPTIMUM_MIN_CHAINS ≥ 1 &&
    OPTIMUM_CHAIN_CAP ≥ 0,
    "OPTIMUM_CHAIN_RADIUS > 0, OPTIMUM_CHAIN_FRACTION in (0, 1], OPTIMUM_MIN_CHAINS ≥ 1, " *
    "OPTIMUM_CHAIN_CAP ≥ 0"
)
@assert(all(>(0), CHAIN_START_RADII), "CHAIN_START_RADII must all be positive")
@assert(BASIN_RESTART_NATS > 0, "BASIN_RESTART_NATS must be positive")
@assert(
    RETRY_N_ADAPT ≥ 1 && RETRY_N_DRAWS ≥ 1,
    "RETRY_N_ADAPT and RETRY_N_DRAWS must be at least 1"
)

"""
The limits of each setting above that has one, read by the terminal interface when a user
edits a value (`dev/scripts/harvest_defaults.jl` copies them to `default_settings.edn`).
Each limit is `above` or `below` (strict) or `at_least` or `at_most` (inclusive). Limits
that tie settings together (`MODE_δρ₁₂` inside `BOUNDS_δρ₁₂`, `EXCL_VOL_CORR_EPS` within the
width of `EXCL_VOL_CORR_BOUNDS`) and those of the tuple settings stay in the checks above.
"""
const SETTING_LIMITS = (
    N_CHAINS = (at_least = 1,),
    TARGET_ACCEPT = (above = 0, below = 100),
    MAP_N_STARTS = (at_least = 1,),
    MAP_OPTIMA_KEPT = (at_least = 1,),
    MAP_MAX_ITER = (at_least = 1,),
    MAP_F_SUCCESSIVE = (at_least = 1,),
    MAP_JITTER_DIRECTIONS = (at_least = 1,),
    MAP_JITTER_MAX_OPTIMA = (at_least = 1,),
    MAP_JITTER_WITHIN_NATS = (above = 0,),
    BASIN_RESTART_NATS = (above = 0,),
    HARVEST_COVER = (at_least = 0,),
    HARVEST_DIVERGENT = (at_least = 0,),
    OPTIMUM_CHAIN_RADIUS = (above = 0,),
    OPTIMUM_CHAIN_FRACTION = (above = 0, at_most = 1),
    OPTIMUM_MIN_CHAINS = (at_least = 1,),
    OPTIMUM_CHAIN_CAP = (at_least = 0,),
    RETRY_N_ADAPT = (at_least = 1,),
    RETRY_N_DRAWS = (at_least = 1,),
    κ_δρ₁₂ = (above = 0,),
    κ_δρ₃ = (above = 0,),
    φ_max = (above = 0,),
    PMV_FALLBACK_UNCERT = (above = 0,),
    EXCL_VOL_CORR_EPS = (above = 0,),
)

"""
The rules that tie settings above together, or that a tuple setting must obey, which a set
of values must obey as a whole; each is a `(rule, setting, ...)` and is read by the
terminal interface and by [`load_settings`](@ref BAYSOL.Pipeline.load_settings).
`:inside`: `setting` lies strictly between the two numbers of the setting `of`;
`:within_width`: `setting` is above 0 and at most the width of the pair `of`; `:ordered`:
the pair `setting` has its first number below its second, and above `above` if there is
one; `:all_above`: every number of `setting` is above `bound`.
"""
const SETTING_RELATIONS = (
    (rule = :ordered, setting = :BOUNDS_δρ₁₂, above = nothing),
    (rule = :inside, setting = :MODE_δρ₁₂, of = :BOUNDS_δρ₁₂),
    (rule = :ordered, setting = :EXCL_VOL_CORR_BOUNDS, above = 0),
    (rule = :within_width, setting = :EXCL_VOL_CORR_EPS, of = :EXCL_VOL_CORR_BOUNDS),
    (rule = :all_above, setting = :CHAIN_START_RADII, bound = 0),
    (rule = :all_above, setting = :MAP_JITTER_RADII, bound = 0),
)

"""
The constants above that are settings, the ones a user may change: the terminal interface
shows each on a page of its own, and [`load_settings`](@ref BAYSOL.Pipeline.load_settings)
accepts a saved value for these and for no other name.
"""
const SETTING_NAMES = (
    :RETRY_N_ADAPT, :RETRY_N_DRAWS, :N_CHAINS, :CHAIN_START_RADII,
    :OPTIMUM_CHAIN_CAP, :RNG_SEED, :TARGET_ACCEPT, :MAP_MAX_ITER, :MAP_N_STARTS,
    :MAP_F_SUCCESSIVE, :MAP_OPTIMA_KEPT, :OPTIMUM_MIN_CHAINS, :MAP_JITTER_RADII,
    :MAP_JITTER_DIRECTIONS, :MAP_JITTER_MAX_OPTIMA, :MAP_JITTER_WITHIN_NATS,
    :BASIN_RESTART_NATS, :HARVEST_COVER, :HARVEST_DIVERGENT, :OPTIMUM_CHAIN_RADIUS,
    :OPTIMUM_CHAIN_FRACTION, :BOUNDS_δρ₁₂, :MODE_δρ₁₂, :κ_δρ₁₂, :κ_δρ₃, :φ_max,
    :EXCL_VOL_CORR_BOUNDS, :EXCL_VOL_CORR_EPS, :PMV_FALLBACK_UNCERT,
)

"""
The name of each part of the tuple settings above, in order, which the terminal interface
shows beside the part when a user edits it. A setting that is a tuple has exactly one name
for each of its parts.
"""
const SETTING_PARTS = (
    BOUNDS_δρ₁₂ = ("low", "high"),
    EXCL_VOL_CORR_BOUNDS = ("low", "high"),
    CHAIN_START_RADII = ("first", "second", "third"),
    MAP_JITTER_RADII = ("first", "second", "third"),
)
