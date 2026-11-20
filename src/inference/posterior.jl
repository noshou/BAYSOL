# SPDX-License-Identifier: LGPL-3.0-or-later

# The log-posterior in the sampled coordinates: the
# likelihood, the prior and the Jacobian.

"""
Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The forward
model produces a predicted curve `yModel(q)`, but the data `I_exp(q)` sits at
some unknown overall scale scale and background offset `bkgrndCorr`, i.e.
`I_calc` = scale·`yModel` + `bkgrndCorr`. `wlsFit` (profiled-corrs.jl) fits
(scale, `bkgrndCorr`) in closed form (2-parameter weighted linear regression),
and the likelihood is the profile log-likelihood: (scale, `bkgrndCorr`) are
pinned at their best-fit values (a point estimate), [`wlsProfLl`](@ref):

    -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

# Arguments
-   `wls::WLSData`: precomputed data-only weighted sums over (`iExp`, `σ_exp`),
    from [`WLSData`](@ref); forwarded to [`profiledCorrs`](@ref).
-   `ξ::SVector{N,<:Real}`: the physical fit parameters, (ρₑ, δρ₁, δρ₂, δρ₃) for `N = 4`.
-   `fw::ForwardCache`: the structure's static cache, from
    [`BAYSOL.Scattering.forwardCache`](@ref).

# Keywords
- `tab::Union{Nothing,_C1Tables} = nothing`, `c1Tol = EXCL_VOL_CORR_TOL`: forwarded to
    [`profiledCorrs`](@ref) as `tables`/`tol`.

# Returns
- `Real`: the log-likelihood, composing by addition with the log-prior terms.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{N,<:Real},
    fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1Tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N}
    _, fit, _ = profiledCorrs(wls, ξ, fw; tables = tab, tol = c1Tol)
    return wlsProfLl(fit)
end

"""
[`_ll`](@ref) at a ForwardDiff dual ξ: the
value and the gradient with respect to ξ come from [`_profileLlGrad`](@ref)
(analytic, no dual-number vectors through the forward model), and are
composed with the partials of ξ, so `ForwardDiff.gradient` of any
function of θ sees the exact chain rule.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{N,D},
    fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1Tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N,D<:ForwardDiff.Dual{<:Any,Float64}}
    tb = tab === nothing ? _C1Tables(fw) : tab
    ll, g = _profileLlGrad(wls, SVector{N,Float64}(ForwardDiff.value.(ξ)), fw, tb, c1Tol)
    return _dualOf(ll, g, ξ)
end

"""
The ForwardDiff dual with value `ll` and the partials of ℓ(ξ) for the gradient `g` with
respect to ξ and the dual ξ: the chain rule of [`_ll`](@ref) at a dual ξ.
"""
function _dualOf(ll::Float64, g::SVector{N,Float64}, ξ::SVector{N,D}) where {N,D}
    parts = ntuple(
        j -> sum(ntuple(k -> g[k] * ForwardDiff.partials(ξ[k], j), Val(N))),
        Val(ForwardDiff.npartials(D)),
    )
    return ForwardDiff.Dual{ForwardDiff.tagtype(D)}(ll, ForwardDiff.Partials(parts))
end

"""
[`_ll`](@ref) of the five-parameter ξ = (ρₑ, δρ₁, δρ₂, δρ₃, c1), c1 sampled instead of
profiled ([`_llGradC1`](@ref)).
"""
function _ll(
    wls::WLSData, ξ::SVector{5,Float64}, fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing, c1Tol::Float64 = EXCL_VOL_CORR_TOL,
)
    return _llGradC1(wls, ξ, fw, tab === nothing ? _C1Tables(fw) : tab, c1Tol)[1]
end

function _ll(
    wls::WLSData, ξ::SVector{5,D}, fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing, c1Tol::Float64 = EXCL_VOL_CORR_TOL,
) where {D<:ForwardDiff.Dual{<:Any,Float64}}
    tb = tab === nothing ? _C1Tables(fw) : tab
    ll, g = _llGradC1(wls, SVector{5,Float64}(ForwardDiff.value.(ξ)), fw, tb, c1Tol)
    return _dualOf(ll, g, ξ)
end

"""
Log prior density of ξ = (ρₑ, δρ₁, δρ₂, δρ₃) in ξ-space. The δρ `LocationScale`
priors carry their own -ln W terms.
"""
_lp(ξ::SVector{4,<:Real}, p::ξ_priors) =
    logpdf(p.ρₑPrior, ξ[1]) +
    logpdf(p.δρ₁Prior, ξ[2]) +
    logpdf(p.δρ₂Prior, ξ[3]) +
    logpdf(p.δρ₃Prior, ξ[4])

"""
[`_lp`](@ref) of the five-parameter ξ = (ρₑ, δρ₁, δρ₂, δρ₃, c1): the c1 term is the
`Uniform` prior of c1 on its bounds.
"""
_lp(ξ::SVector{5,<:Real}, p::ξ_priors) =
    _lp(SVector{4}(ξ[1], ξ[2], ξ[3], ξ[4]), p) + logpdf(p.c1Prior, ξ[5])

"""
    _ξOfθ(θ, p, wls, fw, tab) -> (ξ, t)

NUTS's θ back to physical ξ for the five-parameter run, whose last coordinate is the
c1 shift z = t − t̂(ξ₄) ([`_c1Centre`](@ref)): ξ₄ = Ξ(θ₁..₄), t = t̂(ξ₄) + z and
c1 = lo + W·σ(t). The four-parameter θ has no shift and is [`Ξ`](@ref).

# Returns
- `(ξ, t)`: the physical ξ (c1 in its last entry) and the logit coordinate `t` of c1
    (`nothing` for four parameters).

# Exceptions
- `WLSError`: as [`_c1Centre`](@ref).
"""
function _ξOfθ(
    θ::SVector{5,<:Real}, p::ξ_priors, wls::WLSData, fw::ForwardCache, tab::_C1Tables,
)
    θ4 = SVector{4}(θ[1], θ[2], θ[3], θ[4])
    lo, hi = extrema(p.c1Prior)
    t = _c1Centre(wls, Ξ(θ4, p), fw, tab, lo, hi - lo) + θ[5]
    return Ξ(SVector{5}(θ4..., t), p), t
end

_ξOfθ(θ::SVector{4,<:Real}, p::ξ_priors, ::WLSData, ::ForwardCache, ::_C1Tables) =
    (Ξ(θ, p), nothing)

"""
[`_ξOfθ`](@ref) of a seed, `ξ` only.
"""
_ξOfθ(θ::SVector, seed::Seed) = _ξOfθ(θ, seed.pr, seed.wls, seed.fw, seed.c1tab)[1]

"""
    _θOfξ(ξ, p, wls, fw, tab) -> θ

The inverse of [`_ξOfθ`](@ref): ξ to NUTS's θ, the five-parameter c1 as its shift
z = logit((c1 − lo)/W) − t̂(ξ₄) ([`Θ`](@ref) for four parameters).

# Exceptions
- `WLSError`: as [`_c1Centre`](@ref).
"""
function _θOfξ(
    ξ::SVector{5,<:Real}, p::ξ_priors, wls::WLSData, fw::ForwardCache, tab::_C1Tables,
)
    ξ4 = SVector{4}(ξ[1], ξ[2], ξ[3], ξ[4])
    lo, hi = extrema(p.c1Prior)
    t = logit((ξ[5] - lo) / (hi - lo))
    θ4 = Θ(ξ4, p)[1]
    return SVector{5}(θ4..., t - _c1Centre(wls, ξ4, fw, tab, lo, hi - lo))
end

_θOfξ(ξ::SVector{4,<:Real}, p::ξ_priors, ::WLSData, ::ForwardCache, ::_C1Tables) =
    Θ(ξ, p)[1]

_θOfξ(ξ::SVector, seed::Seed) = _θOfξ(ξ, seed.pr, seed.wls, seed.fw, seed.c1tab)

"""
By change of variables, a density trasnfromed from ξ-space into θ-space picks
up the Jacobian of ξ(θ):

    log π(θ) = log p(ξ(θ)) + log|det(∂ξ/∂θ)|

Every coordinate is reparameterized (see [`Θ`](@ref)):

    - ρₑ  = eᵃ
    - δρ₁ = -10 + 12·σ(t₁)
    - δρ₂ = -10 + 12·σ(t₂)
    - δρ₃ = L₃ + W₃·σ(t₃)

So ∂ξ/∂θ is diagonal, giving:

    log|det(∂ξ/∂θ)| = a + Σₖ [ln Wₖ + ln σ(tₖ) + ln(1 - σ(tₖ))] ([`logjac`](@ref))

with W₁ = W₂ = 12 and (L₃, W₃) the δρ₃ prior's location and scale.

log p(ξ(θ)) is the sum of the log-prior and log-likelihood:

    log p(ξ | data) = log p(ξ) + log p(data | ξ) = _lp(ξ, p) + _ll(wls, ξ, fw)

giving:

    log π(θ) = _lp(ξ(θ), p) + _ll(wls, ξ(θ), fw) + logjac(θ)

# Arguments
- `θ::SVector{N,<:Real}`: the current NUTS position, (a, t₁, t₂, t₃) for `N = 4`.
- `p::ξ_priors`: the physical priors, forwarded to [`_lp`](@ref).
- `wls::WLSData`: the precomputed data, forwarded to [`_ll`](@ref).
- `fw::ForwardCache`: the structure's geometry-only cache, forwarded to [`_ll`](@ref).

# Keywords
- `tab`, `c1Tol`: forwarded to [`_ll`](@ref).

# Returns
- `Real`: log π(θ), up to the additive constant NUTS doesn't need.
"""
function _logπ(
    θ::SVector{N,<:Real},
    p::ξ_priors,
    wls::WLSData,
    fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1Tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N}
    ξ = Ξ(θ, p)  # unconstrained θ-space -> physical ξ-space
    return _lp(ξ, p) + _ll(wls, ξ, fw; tab = tab, c1Tol = c1Tol) + logjac(θ, p)
end

# The five-parameter run samples the c1 shift z (see `_c1Centre`): the density of
# (θ₁..₄, z) equals that of (θ₁..₄, t) because t = t̂(θ₁..₄) + z has Jacobian 1.
function _logπ(
    θ::SVector{5,<:Real},
    p::ξ_priors,
    wls::WLSData,
    fw::ForwardCache;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1Tol::Float64 = EXCL_VOL_CORR_TOL,
)
    tb = tab === nothing ? _C1Tables(fw) : tab
    ξ, t = _ξOfθ(θ, p, wls, fw, tb)
    θt = SVector{5}(θ[1], θ[2], θ[3], θ[4], t)
    return _lp(ξ, p) + _ll(wls, ξ, fw; tab = tb, c1Tol = c1Tol) + logjac(θt, p)
end

# ---------------------------------------------------------------------------
#   Seed: the start of a run
# ---------------------------------------------------------------------------

"""
Runs initial seeding for the sampler.

# Arguments
- `fw::ForwardCache`: Cache of the forward model
- `I_exp::AbstractVector`: Experimental intensity curve
- `σ_exp::AbstractVector`: Per-q standard deviation
- `pH::Real`: pH of the solution; forwarded to `BulkElectronDensity.ρₑ` for
    Protein solutes.
- `σ_pH::Real`: standard uncertainty on pH, propagated through each Protein
    solute's titration term.
- `solutes::Vector{Solute}`: the species in solution.

# Keywords
- `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`ρₑ_prior`](@ref).
- `κ_δρ₁₂::Real = κ_δρ₁₂`, `κ_δρ₃::Real = κ_δρ₃`:
    prior concentrations, forwarded to [`δρ_prior`](@ref).
- `pmvFallbackUncert::Real = PMV_FALLBACK_UNCERT`: uncertainty, cm³ mol⁻¹, of a
    non-biological solute whose table row states none, forwarded to [`ρₑ_prior`](@ref).
- `bounds_δρ₁₂::NTuple{2,<:Real} = BOUNDS_δρ₁₂`, `mode_δρ₁₂::Real = MODE_δρ₁₂`,
    `φ_max::Real = φ_max`: the δρ₁/δρ₂ support and mode and the cavity-occupancy bound,
    forwarded to [`δρ_prior`](@ref).
- `exclVolCorrBounds::NTuple{2,<:Real} = EXCL_VOL_CORR_BOUNDS`,
    `exclVolCorrEps::Real = EXCL_VOL_CORR_EPS`: the c1 bounds and the search's padding
    and grid step, for the `c1tab` of the `Seed`.
- `timing::Union{Nothing,StageLog} = nothing`: stored in the returned `Seed`.
- `shannon::Union{Nothing,ShannonInfo} = nothing`: stored in the returned `Seed`.

# Returns
- `Seed`: priors, initial point, forward cache, and data. The initial point is drawn from a
    stream of [`RNG_SEED`](@ref), not the global RNG, so a seed is the same every time.
"""
function seedSampler(
    fw::ForwardCache,
    iExp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
    pmvFallbackUncert::Real = PMV_FALLBACK_UNCERT,
    bounds_δρ₁₂::NTuple{2,<:Real} = BOUNDS_δρ₁₂,
    mode_δρ₁₂::Real = MODE_δρ₁₂,
    φ_max::Real = φ_max,
    exclVolCorrBounds::NTuple{2,<:Real} = EXCL_VOL_CORR_BOUNDS,
    exclVolCorrEps::Real = EXCL_VOL_CORR_EPS,
    timing::Union{Nothing,StageLog} = nothing,
    shannon::Union{Nothing,ShannonInfo} = nothing,
)::Seed
    pr = _calc_ξ_priors(
        pH, σ_pH, solutes;
        t = t, κ_δρ₁₂ = κ_δρ₁₂, κ_δρ₃ = κ_δρ₃,
        pmvFallbackUncert = pmvFallbackUncert,
        bounds_δρ₁₂ = bounds_δρ₁₂, mode_δρ₁₂ = mode_δρ₁₂, φ_max = φ_max,
    )
    ξ₀ = _ξ₀(pr, stream(RNG_SEED % UInt64, _RNG_INITIAL_POINT, 0))
    θ₀, _ = Θ(ξ₀, pr)
    wls = WLSData(iExp, σ_exp)
    c1tab = _C1Tables(
        fw; cmin = Float64(exclVolCorrBounds[1]),
        cmax = Float64(exclVolCorrBounds[2]),
        eps = Float64(exclVolCorrEps),
    )
    return Seed(pr, θ₀, fw, wls, timing, c1tab, shannon)
end

"""
    sampleC1(seed::Seed{T,4}) -> Seed{T,5}

The same problem with c1 as a fifth sampled parameter: ξ = (ρₑ, δρ₁, δρ₂, δρ₃, c1), c1 with
the `Uniform` prior on its bounds (`seed.pr.c1Prior`, logit-transformed like the δρ). The
bounds are those of the seed's c1 tables ([`withC1Prior`](@ref)), and the start is one draw
from each prior. This is what
[`runModel`](@ref BAYSOL.Pipeline.runModel) runs after [`KinkDetected`](@ref): there is no
profile left to kink.

# Returns
- `Seed{T,5}` sharing everything but the priors and the start with `seed`.

# Exceptions
None.
"""
function sampleC1(seed::Seed{T,4}) where {T}
    pr = withC1Prior(seed.pr, seed.c1tab.cmin, seed.c1tab.cmax)
    ξ₀ = _ξ₀(pr, Val(5), stream(RNG_SEED % UInt64, _RNG_INITIAL_POINT, 0))
    θ₀ = _θOfξ(ξ₀, pr, seed.wls, seed.fw, seed.c1tab)
    return Seed(pr, θ₀, seed.fw, seed.wls, seed.timing, seed.c1tab, seed.shannon)
end


# ---------------------------------------------------------------------------
#   Sampling the posterior: the NUTS chains and what is read off their draws
# ---------------------------------------------------------------------------

"""
ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates
w (the target the chains sample and bridge sampling integrates).
"""
function _valueTarget(seed::Seed{<:Real,N}, sp) where {N}
    return w -> _logπ(
        _θ_of_w(SVector{N,eltype(w)}(w...), sp),
        seed.pr,
        seed.wls,
        seed.fw;
        tab = seed.c1tab,
    )
end

# The kink watch's record for the statistics: how many checks chain `k` made, the last one's
# result and the draw count it fired at (`at` 0: it did not fire). Nothing for a chain that
# did not watch.
function _kinkRow(b, k, log)
    statKink!(b, k, log.checks[], log.looked[], log.two[], log.at[])
    return nothing
end

"""
The NUTS loop of one chain: AdvancedHMC's `sample`, step for step (the same calls in the
same order on the same stream, so the draws are the ones `sample` returns), but without its
logging and diagnostics, which is why it is here. `sample`'s keyword body specialises on
this
package's chain closures, and the specialisations were never kept by the precompilation:
its `@info` branch calls `EBFMI` and the keyword machinery on abstractly typed values,
and a compiled method that depends on such callees does not survive loading the package,
so every first fit in a process compiled the sampler again (about 2 s, plus everything
that calls it). This loop has only the calls the run needs, on concrete types.

`onIteration(pm, stat)` is called once per iteration after the adaptation step (as `sample`
calls its `pm_next!`): with the progress meter and the full statistics if `showProgress`,
with `nothing` and `(iterations = i,)` otherwise.

# Returns
-   `Tuple` `(θs, stats)`: the position of every iteration (warm-up included) and its
    statistics `NamedTuple`, with `is_adapt` added.

# Exceptions
Whatever the gradient or `onIteration` throws (the kink watch throws `KinkDetected`).
"""
function _nutsSample(rng, h, κ, θ::T, nSamples::Int, adaptor, nAdapt::Int,
    onIteration::F, showProgress::Bool) where {T<:AbstractVector{<:Real},F}
    θs = Vector{T}(undef, nSamples)
    stats = Vector{NamedTuple}(undef, nSamples)
    h, t = AdvancedHMC.sample_init(rng, h, θ)
    pm =
        showProgress ?
        AdvancedHMC.ProgressMeter.Progress(nSamples; desc = "Sampling", barlen = 31) :
        nothing
    nDivergent = 0
    nDivergentAdapt = 0
    for i in 1:nSamples
        t = AdvancedHMC.transition(rng, h, κ, t.z)
        tstat = AdvancedHMC.stat(t)
        h, κ, isadapted =
            AdvancedHMC.adapt!(h, κ, adaptor, i, nAdapt, t.z, tstat.acceptance_rate)
        if isadapted
            nDivergentAdapt += tstat.numerical_error
        else
            nDivergent += tstat.numerical_error
        end
        tstat = merge(tstat, (is_adapt = isadapted,))
        if showProgress
            onIteration(
                pm,
                (
                    iterations = i,
                    ratio_divergent_transitions = round(
                        nDivergent / max(i - nAdapt, 1); digits = 2),
                    ratio_divergent_transitions_during_adaption = round(
                        nDivergentAdapt / min(i, nAdapt); digits = 2),
                    tstat...,
                    mass_matrix = h.metric,
                ),
            )
        else
            onIteration(nothing, (iterations = i,))
        end
        θs[i], stats[i] = t.z.θ, tstat
    end
    return θs, stats
end

"""
The pieces shared by every NUTS chain on the whitened target of `sp`: ℓπ (value),
∂ℓπ∂w (value and gradient, one ForwardDiff pass) and `runChain(k, w₀)`, which runs chain
`k` from the whitened start `w₀` with its own metric, Hamiltonian, adaptor and random
stream (the stream belongs to the chain index, not to the thread that happens to run it)
and shares only the read-only seed.

# Returns
- `(ℓπ, ∂ℓπ∂w, runChain)`; `runChain` returns a [`_ChainRun`](@ref).
"""
function _chainRunner(seed::Seed{<:Real,N}, sp, nSamples::Int64,
    nAdapt::Int64, δ::Real, base::UInt64, showProgress::Bool;
    kinked::Union{Nothing,Threads.Atomic{Bool}} = nothing) where {N}
    # ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates w.
    ℓπ = @closure w -> _logπ(
        _θ_of_w(SVector{N,eltype(w)}(w...), sp),
        seed.pr,
        seed.wls,
        seed.fw;
        tab = seed.c1tab,
    )

    # ∂ℓπ∂w: w ↦ (log π(θ(w)), ∇_w log π(θ(w))), computed in one ForwardDiff pass.
    ∂ℓπ∂w = @closure w -> begin
        gcCheckpoint()
        result = DiffResults.GradientResult(w)
        ForwardDiff.gradient!(result, ℓπ, w)
        (DiffResults.value(result), DiffResults.gradient(result))
    end

    sbufK = statBuffer(seed.timing)

    # One NUTS chain. Every chain has its own metric, Hamiltonian, adaptor
    # and random stream (the stream belongs to the chain index, not to the
    # thread that happens to run it), and shares only the read-only seed.
    runChain =
        (k, w₀) -> begin
            t0 = time_ns()
            # what the kink watch did (checks made, the draws of the last one and how
            # many had two basins, the draw count where it fired), for the statistics
            kinkLog = (; checks = Ref(0), looked = Ref(0), two = Ref(0), at = Ref(0))
            try
                # The kink watch (profiled runs only: `kinked` is `nothing` otherwise).
                # AdvancedHMC's `sample` had no per-draw callback, so the draws are
                # taken where it does call out: `pm_next!` (once per iteration, after
                # it) arms a recorder, and the next gradient call, which starts the
                # next iteration at the draw just made, stores that point. Only
                # draws after the warm-up count (its mass matrix is not yet adapted).
                # The check runs when `C1_KINK_DRAWS` draws are in, then every
                # `C1_KINK_EVERY` draws after that (each on at most `C1_KINK_DRAWS`
                # draws spread over those so far, so it stays cheap), and once more on
                # all of the chain's draws when it ends unless a check just covered
                # them: a short run, down to one draw, is checked only then, so no
                # minimum is assumed.
                watch = kinked !== nothing
                nPost = nSamples - nAdapt
                recorded = SVector{N,Float64}[]
                armed = Ref(false)
                checked = Ref(0)      # how many draws the last check had
                kinkCheck =
                    draws -> begin
                        checked[] = length(draws)
                        r = _c1KinkCount(seed.fw, seed.wls, seed.c1tab, draws)
                        kinkLog.checks[] += 1
                        kinkLog.looked[] = r.nLooked
                        kinkLog.two[] = r.nKinked
                        if r.nLooked > 0 && r.nKinked ≥ C1_KINK_SHARE * r.nLooked
                            kinked[] = true
                            kinkLog.at[] = length(draws)
                            throw(KinkDetected())
                        end
                    end
                # The tallies of the run statistics, one pass over what the gradient
                # already returns: the count of non-finite results and the quotient
                # ‖Δg‖/‖Δw‖ of each evaluation against the one before it (a few
                # multiply-adds on N numbers, against a forward pass and its gradient).
                nGrad = Ref(0)
                nBad = Ref(0)
                haveLast = Ref(false)
                lastW = zeros(N)
                lastG = zeros(N)
                curv = sizehint!(Float64[], 24 * nSamples)
                fromPost = Ref(1)
                ∂watched =
                    w -> begin
                        watch && kinked[] && throw(KinkDetected())
                        if watch && armed[]
                            armed[] = false
                            push!(
                                recorded,
                                Ξ(_θ_of_w(SVector{N,Float64}(w...), sp), seed.pr),
                            )
                            gap = checked[] == 0 ? C1_KINK_DRAWS : C1_KINK_EVERY
                            if nPost > C1_KINK_DRAWS && length(recorded) ≥ checked[] + gap
                                kinkCheck(recorded)
                            end
                        end
                        v, g = ∂ℓπ∂w(w)
                        nGrad[] += 1
                        # The finite check looks at every component itself, in plain IEEE
                        # arithmetic (no @fastmath: that flag lets the compiler assume no
                        # NaN or Inf, and a sum of large finite components can overflow to
                        # Inf, so neither a fast-math nor a summed test is safe). Only when
                        # all of them are finite do the squared steps against the previous
                        # evaluation give the curvature quotient, in one fused pass with no
                        # allocation. Here too @simd stands without @fastmath on purpose: a
                        # squared step can overflow to Inf, which fast-math would turn into
                        # undefined behaviour, and the guard below has to see it.
                        ok = isfinite(v)
                        @inbounds @simd for i in 1:N
                            ok &= isfinite(g[i]) & isfinite(w[i])
                        end
                        dw = 0.0
                        dg = 0.0
                        if ok && haveLast[]
                            @inbounds @simd for i in 1:N
                                dw += abs2(w[i] - lastW[i])
                                dg += abs2(g[i] - lastG[i])
                            end
                        end
                        if ok
                            # A quotient that overflowed (huge gradient steps) is not
                            # recorded: it would poison the curvature statistics.
                            if haveLast[] && dw > 0
                                q = sqrt(dg / dw)
                                isfinite(q) && push!(curv, q)
                            end
                            @inbounds for i in 1:N
                                lastW[i] = w[i]
                                lastG[i] = g[i]
                            end
                            haveLast[] = true
                        else
                            nBad[] += 1
                            haveLast[] = false
                        end
                        return (v, g)
                    end
                iterationDone =
                    (pm, stat) -> begin
                        armed[] = watch && stat.iterations > nAdapt
                        stat.iterations == nAdapt && (fromPost[] = length(curv) + 1)
                        showProgress && pm_next!(pm, stat)
                        return nothing
                    end
                # DenseEuclideanMetric allows the adaptation to learn
                # correlations between parameters. Since we are only fitting
                # a handful of params and they are highly coupled, it is
                # worth it here. After the whitening it starts (M⁻¹ = I) close to right.
                metric = DenseEuclideanMetric(N)

                # combines "potential energy" (ℓπ) and kinetic energy (from metric)
                hamiltonian = Hamiltonian(metric, ℓπ, ∂watched)

                # the chain's own stream: the step-size
                # search and the sampler both draw from it
                rng = stream(base, _RNG_NUTS, k)

                # HMC numerically integrates the Hamiltonian,
                # so we need to guess a good step size.
                initStepSize = find_good_stepsize(rng, hamiltonian, copy(w₀))

                # Leapfrog integration evaluates kinetic energy first, then
                # "skips over" that evaluated position to the next one for potential energy.
                integrator = Leapfrog(initStepSize)

                # Initial step sizes are likely non-ideal, so sampler
                # learns mass matrix/metric and step size as it goes along.
                adaptor = StanHMCAdaptor(
                    MassMatrixAdaptor(metric),
                    StepSizeAdaptor(δ, integrator),
                )

                # the sampler in w-space
                kernel = HMCKernel(
                    Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()),
                )

                ws, stats = _nutsSample(
                    rng, hamiltonian, kernel, copy(w₀), nSamples, adaptor, nAdapt,
                    iterationDone, showProgress,
                )
                ξs = [_ξOfθ(_θ_of_w(SVector{N,Float64}(s...), sp), seed) for s in ws]
                if watch
                    kinked[] && throw(KinkDetected())
                    checked[] < nPost && kinkCheck(ξs[(nAdapt+1):end])
                end
                _kinkRow(sbufK, k, kinkLog)
                return _ChainRun(
                    k, ξs, stats, nothing, (time_ns() - t0) / NS_PER_S, initStepSize,
                    _ChainTally(
                        [Vector{Float64}(s) for s in ws], nGrad[], nBad[], curv,
                        fromPost[],
                    ),
                )
            catch e
                e isa InterruptException && rethrow()
                e isa KinkDetected && _kinkRow(sbufK, k, kinkLog)
                return _ChainRun(
                    k,
                    SVector{N,Float64}[],
                    nothing,
                    e,
                    (time_ns() - t0) / NS_PER_S,
                )
            end
        end

    return ℓπ, ∂ℓπ∂w, runChain
end

"""
Runs the `nChains` NUTS chains on the whitened target of `sp`, one task each, from their
starts ([`_chainStart`](@ref)). `δ` is the target acceptance as a fraction. Every chain
has its own metric, Hamiltonian, adaptor and random stream (the stream belongs to the
chain index, not to the thread that happens to run it) and shares only the read-only seed.

# Returns
-   `NamedTuple` `(runs, starts, tNuts)`: the [`_ChainRun`](@ref)s in
    chain order, the starts and the timer started when the chains began.
"""
function _runChains(seed::Seed{<:Real,N}, sp, nSamples::Int64,
    nAdapt::Int64, δ::Real,
    base::UInt64, nChains::Int; options::SamplerOptions = SamplerOptions()) where {N}
    tSetup = tick()
    # (concurrent progress bars would overwrite each other)
    # a profiled (four-parameter) run watches for a kinked c1 profile, the first chain
    # that finds one stops them all (a sampled-c1 run has no profile to kink)
    kinked = (N == 4 && options.watchKink) ? Threads.Atomic{Bool}(false) : nothing
    ℓπ, ∂ℓπ∂w, runChain =
        _chainRunner(seed, sp, nSamples, nAdapt, δ, base, nChains == 1; kinked)

    # The starts: mirrored jittered pairs, or the MAP for a single chain
    # (deterministically, see `_chainStart`). Chosen serially and up front,
    # so neither the starts nor which chain gets which depend on the threads.
    starts = [
        _chainStart(k, nChains, N, ℓπ, ∂ℓπ∂w, base, options.chainStartRadii)
        for k in 1:nChains
    ]

    tock!(seed.timing, :sampling, 1, "NUTS setup (starts, Hamiltonian)", tSetup)
    tNuts = tick()
    runs = tmapItems(k -> runChain(k, starts[k][1]), 1:nChains)
    kinked !== nothing && kinked[] && throw(KinkDetected())
    return (runs = runs, starts = starts, tNuts = tNuts)
end

"""
(ŷ, WLS fit, c1) of one draw: c1 profiled for a four-parameter ξ, the sampled c1 = ξ[5]
for a five-parameter one.
"""
function _correctedFit(seed::Seed, ξ::SVector{4})
    return profiledCorrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
end

function _correctedFit(seed::Seed, ξ::SVector{5})
    ŷ, fit = fixedC1Corrs(seed.wls, SVector{4}(ξ[1], ξ[2], ξ[3], ξ[4]), seed.fw,
        seed.c1tab, ξ[5])
    return ŷ, fit, ξ[5]
end

"""
The (scale, `bkgrndCorr`, c1, reduced χ², curve)
of every draw `ξs`, c1 re-profiled at each (read off for a five-parameter ξ).

# Returns
- `NamedTuple` of `Vector`s `scale`, `bkgrndCorr`,
    `c1`, `χ²` and the matrix `curves` (Q × draws).
"""
function _reprofile(seed::Seed, ξs::AbstractVector)
    n = length(ξs)
    scale = Vector{Float64}(undef, n)
    bkgrndCorr = Vector{Float64}(undef, n)
    c1 = Vector{Float64}(undef, n)
    χ² = Vector{Float64}(undef, n)
    curves = Matrix{Float64}(undef, length(seed.fw.qvals), n)
    for (i, ξ) in enumerate(ξs)
        gcCheckpoint()
        ŷ, fit, c1Star = _correctedFit(seed, ξ)
        scale[i]       = fit.scale
        bkgrndCorr[i]  = fit.bkgrndCorr
        c1[i]          = c1Star
        χ²[i]          = reducedChi2(fit)
        curves[:, i]   = wlsPredict(fit, ŷ)
    end
    return (; scale, bkgrndCorr, c1, χ², curves)
end
