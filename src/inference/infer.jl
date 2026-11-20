# SPDX-License-Identifier: LGPL-3.0-or-later

# ---------------------------------------------------------------------------
#   infer: the driver of a run (MAP search, chains, optima, modes, pooling, retry)
# ---------------------------------------------------------------------------
#
# The result of a run, what one chain returns, and `infer` itself with its retry. The
# pieces it calls live where they belong by topic: the MAP search, chain starts and optima
# in map.jl; modes, bridge sampling and the convergence gates in modes.jl; the NUTS chain
# runner and the re-profile of the draws in posterior.jl; the seed in posterior.jl.

"""
    Inferred{S,N}

The result of [`infer`](@ref) (and, minus the warm-up draws, of
`BAYSOL.runModel`): the posterior draws of the physical parameters ξ =
(ρₑ, δρ₁, δρ₂, δρ₃), one (scale, `bkgrndCorr`, c1) triple and predicted
curve per draw, and AdvancedHMC.jl's own per-iteration diagnostics.

# Fields
- `samples::Vector{SVector{N,Float64}}`: posterior draws of ξ, `nSamples` per pooled chain.
- `stats::Vector{S}`: AdvancedHMC.jl's per-iteration diagnostics, matching
    samples index-for-index.
- `scale::Vector{Float64}`: the WLS estimate of the scale correction at samples[i].
- `bkgrndCorr::Vector{Float64}`: the WLS estimate
    of the background correction at samples[i].
- `c1::Vector{Float64}`: the profiled excluded-volume correction
    ([`profiledCorrs`](@ref)) at samples[i]. Profiled, not sampled -- it
    has no prior and therefore no z-score, unlike `samples`.
- `chisqRed::Vector{Float64}`:  the reduced χ² of the WLS estimate
- `curves::Matrix{Float64}, (Q, nSamples)`: the detector-scale predicted
    curve `I_calc(q)` = scale[i]·`yModel(q)` + `bkgrndCorr[i]` for each
    samples[i], column-matching `scale/bkgrndCorr`, with the model `yModel` the
    five-species contraction v(q)ᵀ G(q) v(q) at samples[i] and c1[i].
- `chain::Vector{Int}`: the chain each draw comes from (only the pooled chains are kept, see
    [`ChainDiagnostics`](@ref)); the draws are stored chain after chain.
- `iteration::Vector{Int}`: the draw's iteration within its
    chain, 1 to `nSamples` (the first `nAdapt` are warm-up).
- `diagnostics::ChainDiagnostics`: which chains were pooled and why not, the
    start scale of each, and the split R̂ and ESS of the pooled post-warm-up draws.
- `timing::Union{Nothing,StageLog}`: the run's stage log (from the `Seed`), if timing is on.
"""
struct Inferred{S,N}
    samples::Vector{SVector{N,Float64}}
    stats::Vector{S}
    scale::Vector{Float64}
    bkgrndCorr::Vector{Float64}
    c1::Vector{Float64}
    chisqRed::Vector{Float64}
    curves::Matrix{Float64}
    chain::Vector{Int}
    iteration::Vector{Int}
    diagnostics::ChainDiagnostics
    timing::Union{Nothing,StageLog}
end

"""
What one NUTS chain tallied while it ran (kept for the run statistics, nothing recomputed):
`ws` its draws in the whitened coordinates, `nGrad` the gradient evaluations, `nNonFinite`
those where the log density or a component of its gradient was not finite, and `curvature`
the quotient ‖Δ∇ℓπ‖/‖Δw‖ of every pair of successive gradient evaluations (the leapfrog
states of the trajectories, in order), `fromPost` the index of the first one of the
sampling phase. Each quotient is a lower bound of the largest eigenvalue of −∇²ℓπ (the
norm of the Hessian applied to a vector is at most λ_max times the vector's norm, exactly
so for a quadratic target), never an estimate of it.
"""
struct _ChainTally
    ws::Vector{Vector{Float64}}
    nGrad::Int
    nNonFinite::Int
    curvature::Vector{Float64}
    fromPost::Int
end

"""
What one NUTS chain returned: its draws, its diagnostics, the step size the adaptation
started from (`ε0`), what it tallied (`tally`), or the error that stopped it (then `stats`
is `nothing`, `ε0` NaN and `tally` `nothing`).
"""
struct _ChainRun{N,S}
    k::Int
    ξ::Vector{SVector{N,Float64}}
    stats::S
    error::Union{Nothing,Exception}
    seconds::Float64
    ε0::Float64
    tally::Union{Nothing,_ChainTally}
end

# A run without its initial step size or tally (a chain that stopped on an error, or a
# hand-made one): it is `unavailable` in the statistics, never a zero.
_ChainRun(k, ξ::Vector{SVector{N,Float64}}, stats, error, seconds) where {N} =
    _ChainRun(k, ξ, stats, error, seconds, NaN, nothing)
_ChainRun(k, ξ::Vector{SVector{N,Float64}}, stats, error, seconds, ε0) where {N} =
    _ChainRun(k, ξ, stats, error, seconds, ε0, nothing)

"""
Run NUTS on [`_logπ`](@ref) starting from seed, returning posterior draws
of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one (scale,
`bkgrndCorr`) pair per draw (see # Returns below), and AdvancedHMC.jl's
own per-iteration diagnostics.

# The Hamiltonian

HMC adds an auxiliary momentum r ~ N(0, M) (M the mass matrix) and defines
a Hamiltonian:

    H(θ, r) = -log π(θ) + ½ rᵀM⁻¹r

with potential energy as the negative log-posterior, and Gaussian kinetic energy.
Leapfrog integration simulates the system's dynamics forward in time,
alternating half-steps in r with full steps in θ:

    r ← r - (ε/2)·∇[-log π(θ)]
    θ ← θ + ε·M⁻¹r
    r ← r - (ε/2)·∇[-log π(θ)]

which needs ∇[log π(θ)] at every step.

Because energy is conserved, leapfrog proposes long, correlated jumps through
parameter space far more cheaply than random-walk Metropolis. NUTS removes the
need to hand-pick a trajectory length: it grows the leapfrog trajectory by
doubling a binary tree of steps, forward and backward in time, until the trajectory
starts to double back on itself (a "U-turn"), then samples from the valid part of that tree.

# MAP search and whitening

Before NUTS, [`_samplingSpace`](@ref) runs multi-start L-BFGS on the same log π
to find its mode, takes a central-difference Hessian there, and NUTS then samples
w with θ = μ + σ·(ẑ + S·w), in which the posterior is ≈ N(0, I) and the chain
starts at the mode. The map is affine, so the target is unchanged; it only puts
Stan's adaptation (identity starting metric, covariance shrunk toward 1e-3·I) on
the O(1) scales it assumes, instead of posteriors up to ~10⁴ times narrower
than the prior along some directions.

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first `nAdapt` iterations,
StepSizeAdaptor tunes the leapfrog step size ε via dual-averaging so the empirical
acceptance rate converges to δ; too-small ε wastes computation taking tiny steps,
too-large ε causes leapfrog's discretization error (and therefore the rejection
rate) to blow up. A gradient that is inconsistent with the value (a loosely
profiled c1, see [`EXCL_VOL_CORR_TOL`](@ref)) has the same effect and shows up as
a step size far below what the local curvature allows. MassMatrixAdaptor learns M
(here the full parameter covariance, since ρₑ/δρ are physically coupled through
the forward model) from the trajectory's sample covariance.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `nSamples::Int64`: total number of NUTS iterations.
- `nAdapt::Int64`: number of warm-up iterations spent adapting the step
                        size and mass matrix before sampling proper.

# Keywords
- `δ::Real=TARGET_ACCEPT`: target acceptance rate as a percentage,
                                (0, 100) exclusive; the default,
                                [`TARGET_ACCEPT`](@ref), is 95%.
- `nChains::Int=N_CHAINS`: number of NUTS chains
                                ([`N_CHAINS`](@ref) = 8, whatever the number of
                                Julia threads; the threads only decide how many run at
                                once). Chain 1 starts at the MAP, the others at
                                deterministic distances from it ([`chainRadius`](@ref)).
                                Each chain adapts on its own; chains that did not fail
                                are pooled, the modes they settled in weighted by their
                                mass (see [`bridgeLogmass`](@ref)). With `nChains = 1`
                                the run is the single-chain run of earlier versions.
- `retry::Bool=RETRY` (true): when the run does not count as converged (worst R̂ above
    [`RHAT_OK`](@ref), an ESS below [`ESS_MIN`](@ref), or either not computable), sample
                                once more with [`RETRY_N_ADAPT`](@ref) warm-up and
                                [`RETRY_N_DRAWS`](@ref) post-warm-up iterations per chain,
                                from `rngSeed` offset deterministically
                                ([`RETRY_SEED_OFFSET`](@ref)), and keep the run with the
                                smaller worst R̂. The same seeds always give the same
                                result, retried or not. `diagnostics.firstRhat` and
                                `retryKept` record what happened. The rerun always
                                adapts again, however long the first run was.
- `rngSeed::Union{Nothing,Integer}=RNG_SEED` (0): the run's
                                random seed. Every random draw of the run (the extra MAP
                                starts, the NUTS chain) comes from a stream derived from
                                it by the draw's index, so the same `rngSeed` reproduces
                                the run exactly, whatever the number of Julia threads.
                                `nothing` draws a fresh one from the default RNG (so
                                `Random.seed!` before the call also fixes it). It is
                                the `rngSeed` row of the run log and the `run` sheet.
- `options::SamplerOptions = SamplerOptions()`: the rerun's length, the chain starts, the
                                MAP search, its jitter, the harvest and the basin
                                restart (see [`SamplerOptions`](@ref)); the defaults are
                                the constants of `params.jl`.

# Returns
An [`Inferred`](@ref) of the pooled chains, chain after chain. Includes the
`nAdapt` warm-up draws of each chain; a caller that wants a warm-up-free
posterior drops the draws with `iteration ≤ nAdapt` out of every field itself.

# Exceptions
- `DomainError` for `nChains < 1`, `δ` outside (0, 100) or `nAdapt ≥ nSamples`.
- The first chain's error if no chain could be run.
"""
function infer(
    seed::Seed,
    nSamples::Int64,
    nAdapt::Int64;
    δ::Real = TARGET_ACCEPT,
    rngSeed::Union{Nothing,Integer} = RNG_SEED,
    nChains::Int = N_CHAINS,
    retry::Bool = RETRY,
    options::SamplerOptions = SamplerOptions(),
)::Inferred
    nChains ≥ 1 || throw(DomainError(nChains, "nChains must be ≥ 1"))
    base = rngSeed === nothing ? drawBase() : (rngSeed % UInt64)
    go =
        (ns, na, b) -> withGcPaused(
            () -> _infer(
                seed, ns, na; δ = δ, base = b, nChains = nChains,
                options = options,
            ),
        )
    r1 = go(nSamples, nAdapt, base)
    worst = _worstRhat(r1.diagnostics)
    if !_retryNeeded(r1.diagnostics, retry, _divergentShare(r1))
        sb = statBuffer(seed.timing)
        statKeep!(sb, statAttempts(sb), retry ? "it passed its gates" : "retry is off")
        return r1
    end

    # R̂ above the limit: once more, longer, from streams and jitter directions derived
    # from the seeds (a different draw of the starts too, since a bad R̂ can be seed luck)
    info = seed.timing === nothing ? nothing : copy(seed.timing.info)
    sbuf = statBuffer(seed.timing)
    statNext!(
        sbuf,
        "retry with a longer warm-up: " *
        join(_convergenceProblems(r1.diagnostics), "; "),
    )
    statLabel!(sbuf, "retry, longer warm-up",
        join(_convergenceProblems(r1.diagnostics), "; ");
        class = "convergence", rung = "longer warm-up and run")
    r2 = go(
        options.retryNAdapt + options.retryNDraws, options.retryNAdapt,
        _retrySeed(base),
    )
    kept =
        (
            isempty(_convergenceProblems(r2.diagnostics)) &&
            _divergentShare(r2) < MAX_DIVERGENT_RATE
        ) || _worstRhat(r2.diagnostics) ≤ worst
    best = kept ? r2 : r1
    n2 = statAttempts(sbuf)
    statKeep!(sbuf, kept ? n2 : n2 - 1,
        kept ?
        "the retry passed its gates or was no worse in R̂ (worst R̂ " *
        "$(round(_worstRhat(r2.diagnostics); digits = 4)) against " *
        "$(round(worst; digits = 4)))" :
        "the retry was worse in R̂ ($(round(_worstRhat(r2.diagnostics); digits = 4))" *
        " against $(round(worst; digits = 4)))")
    if seed.timing !== nothing
        # what the report says about the run is that of the kept attempt, with the
        # caller's seed (the rerun's is derived from it)
        kept || merge!(seed.timing.info, info)
        seed.timing.info["rngSeed"] = base
        seed.timing.info["nAdapt"] = best.diagnostics.nAdapt
        seed.timing.info["nSamples"] =
            best.diagnostics.nAdapt + (kept ? options.retryNDraws : nSamples - nAdapt)
    end
    d = best.diagnostics
    return Inferred(best.samples, best.stats, best.scale, best.bkgrndCorr, best.c1,
        best.chisqRed, best.curves, best.chain, best.iteration,
        ChainDiagnostics(d.nChains, d.startScale, d.pooled, d.reason, d.rhat, d.ess,
            d.essTail, d.rewhitened, d.mode, d.modeWeight, d.modeLogmass, d.modeErr,
            d.weightsUncertain, d.nAdapt, worst, kept, d.nExtra, d.optima),
        best.timing)
end

"""
The `base` of the rerun [`infer`](@ref) does when the run is not converged,
derived from the run's own by [`RETRY_SEED_OFFSET`](@ref).
"""
_retrySeed(base::UInt64) = (base + RETRY_SEED_OFFSET) * 0x9e3779b97f4a7c15

"""
Whether [`infer`](@ref) reruns: `retry` is on and the run does not count as converged
(R̂ above [`RHAT_OK`](@ref) or not computable, or an ESS below [`ESS_MIN`](@ref) or
not computable) or the divergent share reaches [`MAX_DIVERGENT_RATE`](@ref). The
rerun always adapts again, whatever the length of the run.
"""
function _retryNeeded(d::ChainDiagnostics, retry::Bool, divergent::Real = 0.0)
    return retry && (!isempty(_convergenceProblems(d)) || divergent ≥ MAX_DIVERGENT_RATE)
end

"""
The share of the post-warm-up transitions of `r` flagged as divergent (numerical errors),
the same population as the divergence gate of the statistics: the warm-up transitions
(`r.iteration ≤ r.diagnostics.nAdapt`) do not count, since the step size is still being
found there and a few non-finite evaluations are routine.

# Returns
- The share in [0, 1], 0 if there is no post-warm-up transition.

# Exceptions
- None.
"""
function _divergentShare(r::Inferred)
    nAdapt = r.diagnostics.nAdapt
    n = 0
    bad = 0
    @inbounds for i in eachindex(r.stats)
        r.iteration[i] > nAdapt || continue
        n += 1
        bad += r.stats[i].numerical_error
    end
    return n == 0 ? 0.0 : bad / n
end

"""
The body of [`infer`](@ref), run with the garbage collector paused
(see [`withGcPaused`](@ref BAYSOL.Runtime.withGcPaused)): the MAP
objective, the NUTS gradient and the re-profile loop call
[`gcCheckpoint`](@ref BAYSOL.Runtime.gcCheckpoint),
which collects once per byte budget.
"""
function _infer(
    seed::Seed{<:Real,N},
    nSamples::Int64,
    nAdapt::Int64;
    δ::Real = TARGET_ACCEPT,
    base::UInt64 = drawBase(),
    nChains::Int = N_CHAINS,
    options::SamplerOptions = SamplerOptions(),
)::Inferred where {N}

    if δ ≤ 0 || δ ≥ 100
        throw(DomainError(δ, "δ must satisfy: 0 < δ < 100"))
    end
    δ = δ / 100

    if nAdapt ≥ nSamples
        throw(DomainError((nAdapt, nSamples), "nAdapt must be < nSamples"))
    end

    # MAP search + Laplace whitening (map.jl): NUTS samples w, θ = μ + σ·(ẑ + S·w),
    # in which the posterior is ≈ N(0, I) and the chain starts at the MAP.
    tMap = tick()
    seed.timing === nothing || (seed.timing.info["rngSeed"] = base)
    sbuf = statBuffer(seed.timing)
    statAttempt!(sbuf, seed.timing)
    statSettings!(sbuf, seed, nSamples, nAdapt, 100δ, base, nChains, options)
    c1Base = c1Counts(seed.c1tab.counts)
    sp = _samplingSpace(seed; base = base, options = options)
    statMapSearch!(sbuf, statProblem(seed), sp, (time_ns() - tMap[1]) / NS_PER_S)
    if seed.timing !== nothing
        seed.timing.info["mapModes"] = sp.nModes
        tock!(seed.timing, :sampling, 1,
            "MAP search + whitening ($(sp.nOk)/$(sp.nStarts) starts, $(sp.nModes) " *
            "mode$(sp.nModes == 1 ? "" : "s")$(sp.whitened ? "" : ", not whitened"))",
            tMap)
    end

    # the chains; if their best draw beats the MAP the sampler was whitened
    # at, the MAP search missed a better basin: re-whiten there (L-BFGS
    # from that draw, the heaviest basin wins) and run the chains once more
    post = (nAdapt+1):nSamples
    chains = _runChains(
        seed, sp, nSamples, nAdapt, δ, base, nChains; options = options,
    )
    rewhitened = 0.0
    best = _bestDraw(chains.runs, post)
    if best.ld > sp.logπ + options.basinRestartNats
        tRe = tick()
        zBest = _standardize(_θOfξ(best.ξ, seed), seed.pr)
        sp2 = _samplingSpace(
            seed; base = base, extraStarts = [zBest], options = options,
        )
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "re-whitening: a chain found a basin %.1f nats above the MAP",
                best.ld - sp.logπ
            ), tRe)
        if sp2.logπ > sp.logπ
            rewhitened = sp2.logπ - sp.logπ
            sp = sp2
            statMapSearch!(sbuf, statProblem(seed), sp2, (time_ns() - tRe[1]) / NS_PER_S,
                "re-whitening after a chain beat the MAP")
            chains = _runChains(
                seed, sp, nSamples, nAdapt, δ, base, nChains; options = options,
            )
        end
    end
    tNuts = chains.tNuts

    # optima the chains visited that the search did not report, and chains for the ones that
    # carry mass but have too few chains at them (their draws could not get their weight)
    tH = tick()
    ext = _withOptimaChains(
        seed, sp, chains.runs, chains.starts, post, nSamples, nAdapt, δ, base,
        nChains; options = options,
    )
    runs, starts, nExtra = ext.runs, ext.starts, ext.nExtra
    nTotal = length(runs)
    optimaReport = ext.optimaReport
    if seed.timing !== nothing
        seed.timing.info["optima"] = count(o -> o.share ≥ OPTIMUM_MIN_SHARE, optimaReport)
        tock!(seed.timing, :sampling, 1,
            "optima from the draws, $nExtra extra chain$(nExtra == 1 ? "" : "s")", tH)
    end
    nLf = sum(r -> r.stats === nothing ? 0 : sum(getproperty.(r.stats, :n_steps)), runs)

    # which chains are pooled (every chain that ran and did not mostly diverge)
    ran = [r.error === nothing for r in runs]
    # no chain ran: the error is the caller's to see
    any(ran) || throw(first(r.error for r in runs))
    ld = zeros(length(post), nTotal)
    divRate = zeros(nTotal)
    for r in runs
        r.error === nothing || continue
        ld[:, r.k] = getproperty.(r.stats[post], :log_density)
        divRate[r.k] = mean(getproperty.(r.stats[post], :numerical_error))
    end
    pooled, reason = selectChains(
        divRate,
        [r.error === nothing ? nothing : sprint(showerror, r.error) for r in runs],
    )
    if !any(pooled)
        # every chain that ran was rejected (e.g. all diverged): pool them all so
        # the caller's own all-diverged handling applies, as with a single chain
        for k in findall(ran)
            pooled[k] = true
            reason[k] = reason[k] * " (no chain passed: pooled anyway)"
        end
    end
    pk = findall(pooled)

    if seed.timing !== nothing
        seed.timing.info["nChains"] = nTotal
        seed.timing.info["nChainsPooled"] = length(pk)
        seed.timing.info["leapfrog"] = nLf
        # chain-seconds per leapfrog step
        ms = MS_PER_S * sum(r -> r.seconds, runs) / max(nLf, 1)
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "NUTS  (%s iters, %s leapfrog, %.3f ms/step)",
                fmtCount(nTotal * nSamples),
                fmtCount(nLf),
                ms
            ),
            tNuts)
    end

    # draws × chains × (ξ₁…ξ_N, log π) of the pooled chains, after the warm-up
    cube = Array{Float64,3}(undef, length(post), length(pk), N + 1)
    for (c, k) in enumerate(pk)
        for i in 1:N
            cube[:, c, i] = getindex.(runs[k].ξ[post], i)
        end
        cube[:, c, N+1] = ld[:, k]
    end

    # The modes the chains settled in, their mass and the draws each keeps. NUTS chains do
    # not jump between modes, so chains pooled as they come would weight the modes by how
    # many started in each: the mass of each mode is estimated by bridge sampling (from
    # its chains' draws and the density), and the draws are thinned to those shares.
    tModes = tick()
    modeOf = chainModes(cube)
    M = maximum(modeOf)
    logZ = zeros(M)
    err = zeros(M)
    if M > 1
        ℓπ = _valueTarget(seed, sp)
        for m in 1:M
            cs = findall(==(m), modeOf)
            W = reduce(vcat, (_drawsW(seed, sp, runs[pk[c]].ξ[post]) for c in cs))
            logZ[m], err[m] =
                bridgeLogmass(W, reduce(vcat, (ld[:, pk[c]] for c in cs)), ℓπ,
                    stream(base, _RNG_BRIDGE, m))
        end
    end
    chainsIn = [count(==(m), modeOf) for m in 1:M]
    uncertain = M > 1 && weightsUncertain(logZ, err)
    # an error too large to determine the shares: the chains of the modes that
    # can matter are pooled as they came, the modes that are negligible even
    # at their most optimistic estimate are dropped (and the report says so)
    weights =
        M == 1 ? [1.0] :
        uncertain ? uncertainWeights(logZ, err, chainsIn) : modeWeights(logZ)
    keep =
        uncertain ? [w > 0 ? length(post) : 0 for w in weights] :
        drawsPerChain(weights, chainsIn, length(post))
    if M > 1 && seed.timing !== nothing
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "%d posterior modes: mass by bridge sampling%s",
                M,
                uncertain ? " (weights uncertain, not applied)" : ""
            ),
            tModes)
    end

    # the rows each pooled chain contributes: its warm-up
    # rows, and the post-warm-up rows its mode keeps
    rows = [
        vcat(1:nAdapt, nAdapt .+ evenIndices(length(post), keep[modeOf[c]])) for
        c in eachindex(pk)
    ]

    tReprofile = tick()
    # scale/bkgrndCorr are fit in closed form (wlsFit) and discarded on every single
    # ℓπ/gradient evaluation above; re-profile c1 at each posterior draw so the
    # reported curve/χ² match what _ll actually evaluated at that ξ during sampling.
    reprof = tmapItems(c -> _reprofile(seed, runs[pk[c]].ξ[rows[c]]), eachindex(pk))
    tock!(
        seed.timing,
        :sampling,
        1,
        "per-draw c1 re-profile + curves ($(sum(length, rows)) draws)",
        tReprofile,
    )

    # convergence of the chains of each mode (between modes they differ by
    # construction); the worst mode is reported. A mode below MODE_NEGLIGIBLE keeps
    # no draws, so what its chains did is not part of the posterior: not diagnosed.
    live = [m for m in 1:M if weights[m] ≥ MODE_NEGLIGIBLE]
    cvs = [
        convergence(cube[:, findall(==(m), modeOf), :]) for
        m in (isempty(live) ? (1:M) : live)
    ]
    # (NaN entries, from modes too short to judge, are left out; NaN if nothing is left)
    worst(f, init) = [
        (
            v = filter(!isnan, getindex.(getproperty.(cvs, init), q));
            isempty(v) ? NaN : f(v)
        ) for q in 1:(N+1)
    ]
    diag = ChainDiagnostics(nTotal, [starts[k][2] for k in 1:nTotal], pooled, reason,
        worst(maximum, :rhat), worst(minimum, :ess), worst(minimum, :essTail),
        rewhitened, [k in pk ? modeOf[findfirst(==(k), pk)] : 0 for k in 1:nTotal],
        weights, logZ, err, uncertain, nAdapt, NaN, false, nExtra, optimaReport)
    statChains!(sbuf, seed.pr, sp, runs, diag, paramKeys(seed.pr, N), nSamples, nAdapt,
        100δ, base, seed.timing,
        (; pk, rows, c1 = [r.c1 for r in reprof], curves = [r.curves for r in reprof],
            c1base = c1Base, c1now = c1Counts(seed.c1tab.counts),
            iObs = seed.wls.iObs, weights = seed.wls.weights,
            cmin = seed.c1tab.cmin, cmax = seed.c1tab.cmax))

    return Inferred(
        reduce(vcat, (runs[pk[c]].ξ[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (runs[pk[c]].stats[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (r.scale for r in reprof)),
        reduce(vcat, (r.bkgrndCorr for r in reprof)),
        reduce(vcat, (r.c1 for r in reprof)),
        reduce(vcat, (r.χ² for r in reprof)),
        reduce(hcat, (r.curves for r in reprof)),
        reduce(vcat, (fill(pk[c], length(rows[c])) for c in eachindex(pk))),
        reduce(vcat, (rows[c] for c in eachindex(pk))),
        diag,
        seed.timing,
    )
end
