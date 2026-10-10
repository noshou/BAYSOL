# SPDX-License-Identifier: LGPL-2.1-or-later

# Everything about a run: the chains it runs (where they start, which are pooled,
# the convergence statistics), the data it starts from (`Seed`, `seed_sampler`),
# what it returns (`Inferred`), the entry point `infer`, and the NUTS chains
# themselves (starts, the sampler per chain, the re-profiled curves).

# ---------------------------------------------------------------------------
#   Chains: starts, pooling, convergence statistics
# ---------------------------------------------------------------------------

using MCMCDiagnosticTools: MCMCDiagnosticTools
using Statistics: mean


"""
The nominal signed distance from the MAP, in posterior standard deviations, at which
chain `k` of `n` starts: a single chain at the MAP (0); with several, chains 1 and 2
both at the MAP (two independent chains of their own random streams from the same point:
independent effective sample size within the main mode and a baseline for R̂ there), and
chains 3 and up in mirrored pairs at the radii of [`CHAIN_START_RADII`](@ref) (the first
of a pair positive, the second negative: the same random direction, opposite sides).

# Returns
- `Float64`.

# Exceptions
- None.
"""
function chain_radius(k::Int, n::Int)::Float64
    (n == 1 || k ≤ 2) && return 0.0
    r = CHAIN_START_RADII[min((k - 1) ÷ 2, length(CHAIN_START_RADII))]
    return isodd(k) ? r : -r
end


"""
Convergence statistics of the pooled chains' post-warm-up draws, from MCMCDiagnosticTools.jl
(Vehtari et al., 2021): the rank-normalized split R̂ (`rhat(kind = :rank)`: the larger of
the value on the rank-normalized draws, which asks whether the chains agree in location, and
on the rank-normalized draws folded around the median, which asks whether they agree in
scale and tails), the bulk effective sample size (how many independent draws the centre of
the distribution is worth) and the tail effective sample size (the same for the 5 % and 95 %
quantiles, which the report's intervals and curve bands are made of). Every chain is split
in halves first, so a chain that drifts shows up as two that disagree.

# Arguments
- `x::AbstractArray{<:Real,3}`: the draws, `draws × chains × quantities`.

# Returns
- `NamedTuple` `(rhat, ess, ess_tail)` of vectors with one entry per quantity; all
  `NaN` when a chain has fewer than 8 draws (the statistics need at least 4 per half).

# Exceptions
- None.
"""
function convergence(x::AbstractArray{<:Real,3})
    n, _, q = size(x)
    n < 8 && return (rhat = fill(NaN, q), ess = fill(NaN, q), ess_tail = fill(NaN, q))
    return (rhat = vec(MCMCDiagnosticTools.rhat(x; kind = :rank)),
        ess = vec(MCMCDiagnosticTools.ess(x; kind = :bulk)),
        ess_tail = vec(MCMCDiagnosticTools.ess(x; kind = :tail)))
end

"""
    ChainDiagnostics

What the chains of one [`infer`](@ref) call looked like.

# Fields
- `n_chains::Int`: chains run.
- `start_scale::Vector{Float64}`: per chain, the signed distance of its start
    from the MAP in posterior standard deviations (negative: the mirrored chain
    of a pair; 0: the MAP): the distance actually used, after any halving, see
    [`CHAIN_JITTER_MAX_HALVINGS`](@ref) and [`chain_radius`](@ref).
- `pooled::Vector{Bool}`: per chain, whether it was pooled.
- `reason::Vector{String}`: per chain, `"ok"` or why it was not pooled.
- `rhat::Vector{Float64}`: [`convergence`](@ref)'s R̂ over each mode's
    chains' post-warm-up draws (the worst of the modes that keep draws,
    see [`MODE_NEGLIGIBLE`](@ref)), one entry per coordinate of ξ followed
    by log π (with one chain in a mode it compares its two halves).
- `ess::Vector{Float64}`: the bulk effective sample size, same layout.
- `ess_tail::Vector{Float64}`: the tail effective sample size, same layout.
- `rewhitened::Float64`: 0, or the nats by which the first round of chains
    found a better basin than the MAP search ([`BASIN_RESTART_NATS`](@ref)):
    the sampler was then re-whitened there and the chains rerun, and these
    diagnostics are those of the second round.
- `mode::Vector{Int}`: per chain, the posterior mode it settled in (chains
    that agree, [`chain_modes`](@ref)); 0 for a chain that was not pooled.
- `mode_weight::Vector{Float64}`: per mode, its share of
    the posterior mass; the pooled draws carry these shares.
- `mode_logmass::Vector{Float64}`: per mode, the bridge-sampling
    estimate of log mass ([`bridge_logmass`](@ref)).
- `mode_err::Vector{Float64}`: per mode, its approximate standard error in nats.
- `weights_uncertain::Bool`: whether a bridge-sampling error was too large to apply
    the weights ([`weights_uncertain`](@ref)): the chains of the modes that can matter
    were then pooled as they came, and `mode_weight` is each mode's share of those
    chains (0 for a mode that is negligible even at its most optimistic estimate).
"""
struct ChainDiagnostics
    n_chains::Int
    start_scale::Vector{Float64}
    pooled::Vector{Bool}
    reason::Vector{String}
    rhat::Vector{Float64}
    ess::Vector{Float64}
    ess_tail::Vector{Float64}
    rewhitened::Float64
    mode::Vector{Int}
    mode_weight::Vector{Float64}
    mode_logmass::Vector{Float64}
    mode_err::Vector{Float64}
    weights_uncertain::Bool
end

"""
Which chains are pooled: every chain that ran, unless it failed or more than
[`CHAIN_MAX_DIVERGENT`](@ref) of its post-warm-up transitions diverged. (A
chain in a poorer mode is not dropped for that: the modes are weighted by their
mass, see [`bridge_logmass`](@ref).) `div_rate[j]` is chain `j`'s divergent
fraction and `error[j]` is `nothing` or why the chain could not be run.

# Returns
- `(pooled::Vector{Bool}, reason::Vector{String})`,
    the reason being `"ok"` for a pooled chain.

# Exceptions
- None.
"""
function select_chains(div_rate::AbstractVector{<:Real}, error::AbstractVector)
    pooled = fill(true, length(error))
    reason = fill("ok", length(error))
    for j in eachindex(error)
        if error[j] !== nothing
            pooled[j] = false
            reason[j] = "sampler error: $(error[j])"
        elseif div_rate[j] > CHAIN_MAX_DIVERGENT
            pooled[j] = false
            reason[j] = "$(round(Int, 100 * div_rate[j])) % of transitions diverged"
        end
    end
    return pooled, reason
end

# ---------------------------------------------------------------------------
#   Seed and Inferred
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
- `timing::Union{Nothing,StageLog} = nothing`: stored in the returned `Seed`.
- `shannon::Union{Nothing,ShannonInfo} = nothing`: stored in the returned `Seed`.

# Returns
- `Seed`: priors, initial point, forward cache, and data.
"""
function seed_sampler(
    fw::ForwardCache,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
    timing::Union{Nothing,StageLog} = nothing,
    shannon::Union{Nothing,ShannonInfo} = nothing,
)::Seed
    pr = _calc_ξ_priors(pH, σ_pH, solutes; t = t, κ_δρ₁₂ = κ_δρ₁₂, κ_δρ₃ = κ_δρ₃)
    ξ₀ = _ξ₀(pr)
    θ₀, _ = Θ(ξ₀, pr)
    wls = WLSData(I_exp, σ_exp)
    return Seed(pr, θ₀, fw, wls, timing, _C1Tables(fw), shannon)
end

"""
    Inferred{S,N}

The result of [`infer`](@ref) (and, minus the warm-up draws, of
`BAYSOL.run_model`): the posterior draws of the physical parameters ξ =
(ρₑ, δρ₁, δρ₂, δρ₃), one (scale, `bkgrnd_corr`, c1) triple and predicted
curve per draw, and AdvancedHMC.jl's own per-iteration diagnostics.

# Fields
- `samples::Vector{SVector{N,Float64}}`: posterior draws of ξ, `n_samples` per pooled chain.
- `stats::Vector{S}`: AdvancedHMC.jl's per-iteration diagnostics, matching
    samples index-for-index.
- `scale::Vector{Float64}`: the WLS estimate of the scale correction at samples[i].
- `bkgrnd_corr::Vector{Float64}`: the WLS estimate
    of the background correction at samples[i].
- `c1::Vector{Float64}`: the profiled excluded-volume correction
    ([`profiled_corrs`](@ref)) at samples[i]. Profiled, not sampled -- it
    has no prior and therefore no z-score, unlike `samples`.
- `chisq_red::Vector{Float64}`:  the reduced χ² of the WLS estimate
- `curves::Matrix{Float64}, (Q, n_samples)`: the detector-scale predicted
    curve `I_calc(q)` = scale[i]·`y_model(q)` + `bkgrnd_corr[i]` for each
    samples[i], column-matching `scale/bkgrnd_corr`, with the model `y_model` the
    five-species contraction v(q)ᵀ G(q) v(q) at samples[i] and c1[i].
- `chain::Vector{Int}`: the chain each draw comes from (only the pooled chains are kept, see
    [`ChainDiagnostics`](@ref)); the draws are stored chain after chain.
- `iteration::Vector{Int}`: the draw's iteration within its
    chain, 1 to `n_samples` (the first `n_adapt` are warm-up).
- `diagnostics::ChainDiagnostics`: which chains were pooled and why not, the
    start scale of each, and the split R̂ and ESS of the pooled post-warm-up draws.
- `likelihood::AbstractString`: the likelihood type
- `timing::Union{Nothing,StageLog}`: the run's stage log (from the `Seed`), if timing is on.
"""
struct Inferred{S,N}
    samples::Vector{SVector{N,Float64}}
    stats::Vector{S}
    scale::Vector{Float64}
    bkgrnd_corr::Vector{Float64}
    c1::Vector{Float64}
    chisq_red::Vector{Float64}
    curves::Matrix{Float64}
    chain::Vector{Int}
    iteration::Vector{Int}
    diagnostics::ChainDiagnostics
    likelihood::AbstractString
    timing::Union{Nothing,StageLog}
end

# ---------------------------------------------------------------------------
#   infer
# ---------------------------------------------------------------------------


"""
Run NUTS on [`_logπ`](@ref) starting from seed, returning posterior draws
of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one (scale,
`bkgrnd_corr`) pair per draw (see # Returns below), and AdvancedHMC.jl's
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

Before NUTS, [`_sampling_space`](@ref) runs multi-start L-BFGS on the same log π
to find its mode, takes a central-difference Hessian there, and NUTS then samples
w with θ = μ + σ·(ẑ + S·w), in which the posterior is ≈ N(0, I) and the chain
starts at the mode. The map is affine, so the target is unchanged; it only puts
Stan's adaptation (identity starting metric, covariance shrunk toward 1e-3·I) on
the O(1) scales it assumes, instead of posteriors up to ~10⁴ times narrower
than the prior along some directions.

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first `n_adapt` iterations,
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
- `n_samples::Int64`: total number of NUTS iterations.
- `n_adapt::Int64`: number of warm-up iterations spent adapting the step
                        size and mass matrix before sampling proper.

# Keywords
- `l::LIKELIHOOD=PROFILE()`: PROFILE() or MARGINAL(), forwarded to
                                [`_logπ`](@ref)/[`_ll`](@ref).
- `δ::Real=DEFAULT_TARGET_ACCEPT`: target acceptance rate as a percentage,
                                (0, 100) exclusive; the default,
                                [`DEFAULT_TARGET_ACCEPT`](@ref), is Stan's usual 80%.
- `n_chains::Int=DEFAULT_N_CHAINS`: number of NUTS chains
                                ([`DEFAULT_N_CHAINS`](@ref) = 8, whatever the number of
                                Julia threads; the threads only decide how many run at
                                once). Chain 1 starts at the MAP, the others at
                                deterministic distances from it ([`chain_radius`](@ref)).
                                Each chain adapts on its own; chains that did not fail
                                are pooled, the modes they settled in weighted by their
                                mass (see [`bridge_logmass`](@ref)). With `n_chains = 1`
                                the run is the single-chain run of earlier versions.
- `jitter_seed::Integer=DEFAULT_JITTER_SEED`: seed
                                of the jittered starts, separate from `rng_seed`:
                                the same `jitter_seed` gives the same starts
                                whatever the `rng_seed` or the thread count.
- `rng_seed::Union{Nothing,Integer}=nothing`: the run's
                                random seed. Every random draw of the run (the extra MAP
                                starts, the NUTS chain) comes from a stream derived from
                                it by the draw's index, so the same `rng_seed`
                                reproduces the run exactly, whatever the number of Julia
                                threads. `nothing` draws a fresh one from the default
                                RNG (so `Random.seed!` before the call also fixes it);
                                it is printed in the report's `=== Run ===` section.

# Returns
An [`Inferred`](@ref) of the pooled chains, chain after chain. Includes the
`n_adapt` warm-up draws of each chain; a caller that wants a warm-up-free
posterior drops the draws with `iteration ≤ n_adapt` out of every field itself.

# Exceptions
- `DomainError` for `n_chains < 1`, `δ` outside (0, 100) or `n_adapt ≥ n_samples`.
- The first chain's error if no chain could be run.
"""
function infer(
    seed::Seed,
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD = PROFILE(),
    δ::Real = DEFAULT_TARGET_ACCEPT,
    rng_seed::Union{Nothing,Integer} = nothing,
    n_chains::Int = DEFAULT_N_CHAINS,
    jitter_seed::Integer = DEFAULT_JITTER_SEED,
)::Inferred
    n_chains ≥ 1 || throw(DomainError(n_chains, "n_chains must be ≥ 1"))
    base = rng_seed === nothing ? draw_base() : (rng_seed % UInt64)
    return with_gc_paused(
        () -> _infer(seed, n_samples, n_adapt; l = l, δ = δ, base = base,
            n_chains = n_chains, jitter_base = jitter_seed % UInt64),
    )
end

"""
The body of [`infer`](@ref), run with the garbage collector paused
(see [`with_gc_paused`](@ref BAYSOL.Runtime.with_gc_paused)): the MAP
objective, the NUTS gradient and the re-profile loop call
[`gc_checkpoint`](@ref BAYSOL.Runtime.gc_checkpoint),
which collects once per byte budget.
"""
function _infer(
    seed::Seed{<:Real,N},
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD = PROFILE(),
    δ::Real = DEFAULT_TARGET_ACCEPT,
    base::UInt64 = draw_base(),
    n_chains::Int = DEFAULT_N_CHAINS,
    jitter_base::UInt64 = DEFAULT_JITTER_SEED,
)::Inferred where {N}

    if δ ≤ 0 || δ ≥ 100
        throw(DomainError(δ, "δ must satisfy: 0 < δ < 100"))
    end
    δ = δ / 100

    if n_adapt ≥ n_samples
        throw(DomainError((n_adapt, n_samples), "n_adapt must be < n_samples"))
    end

    # MAP search + Laplace whitening (MAP.jl): NUTS samples w, θ = μ + σ·(ẑ + S·w),
    # in which the posterior is ≈ N(0, I) and the chain starts at the MAP.
    t_map = tick()
    seed.timing === nothing || (seed.timing.info["rng_seed"] = base)
    sp = _sampling_space(seed, l; base = base)
    if seed.timing !== nothing
        seed.timing.info["map_modes"] = sp.n_modes
        tock!(seed.timing, :sampling, 1,
            "MAP search + whitening ($(sp.n_ok)/$(MAP_N_STARTS) starts, $(sp.n_modes) " *
            "mode$(sp.n_modes == 1 ? "" : "s")$(sp.whitened ? "" : ", not whitened"))",
            t_map)
    end

    # the chains; if their best draw beats the MAP the sampler was whitened
    # at, the MAP search missed a better basin: re-whiten there (L-BFGS
    # from that draw, the heaviest basin wins) and run the chains once more
    post = (n_adapt+1):n_samples
    chains = _run_chains(seed, l, sp, n_samples, n_adapt, δ, base, jitter_base, n_chains)
    rewhitened = 0.0
    best = _best_draw(chains.runs, post)
    if best.ld > sp.logπ + BASIN_RESTART_NATS
        t_re = tick()
        z_best = _standardize(Θ(best.ξ, seed.pr)[1], seed.pr)
        sp2 = _sampling_space(seed, l; base = base, extra_starts = [z_best])
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "re-whitening: a chain found a basin %.1f nats above the MAP",
                best.ld - sp.logπ
            ), t_re)
        if sp2.logπ > sp.logπ
            rewhitened = sp2.logπ - sp.logπ
            sp = sp2
            chains =
                _run_chains(seed, l, sp, n_samples, n_adapt, δ, base, jitter_base, n_chains)
        end
    end
    runs, starts, t_nuts = chains.runs, chains.starts, chains.t_nuts
    n_lf = sum(r -> r.stats === nothing ? 0 : sum(getproperty.(r.stats, :n_steps)), runs)

    # which chains are pooled (every chain that ran and did not mostly diverge)
    ran = [r.error === nothing for r in runs]
    # no chain ran: the error is the caller's to see
    any(ran) || throw(first(r.error for r in runs))
    ld = zeros(length(post), n_chains)
    div_rate = zeros(n_chains)
    for r in runs
        r.error === nothing || continue
        ld[:, r.k] = getproperty.(r.stats[post], :log_density)
        div_rate[r.k] = mean(getproperty.(r.stats[post], :numerical_error))
    end
    pooled, reason = select_chains(
        div_rate,
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
        seed.timing.info["n_chains"]        = n_chains
        seed.timing.info["n_chains_pooled"] = length(pk)
        seed.timing.info["leapfrog"]        = n_lf
        # chain-seconds per leapfrog step
        ms = MS_PER_S * sum(r -> r.seconds, runs) / max(n_lf, 1)
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "NUTS  (%s iters, %s leapfrog, %.3f ms/step)",
                fmt_count(n_chains * n_samples),
                fmt_count(n_lf),
                ms
            ),
            t_nuts)
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
    t_modes = tick()
    mode_of = chain_modes(cube)
    M = maximum(mode_of)
    logZ = zeros(M)
    err = zeros(M)
    if M > 1
        ℓπ = _value_target(seed, l, sp)
        for m in 1:M
            cs = findall(==(m), mode_of)
            W = reduce(vcat, (_draws_w(seed, sp, runs[pk[c]].ξ[post]) for c in cs))
            logZ[m], err[m] =
                bridge_logmass(W, reduce(vcat, (ld[:, pk[c]] for c in cs)), ℓπ,
                    stream(base, _RNG_BRIDGE, m))
        end
    end
    chains_in = [count(==(m), mode_of) for m in 1:M]
    uncertain = M > 1 && weights_uncertain(logZ, err)
    # an error too large to determine the shares: the chains of the modes that
    # can matter are pooled as they came, the modes that are negligible even
    # at their most optimistic estimate are dropped (and the report says so)
    weights =
        M == 1 ? [1.0] :
        uncertain ? uncertain_weights(logZ, err, chains_in) : mode_weights(logZ)
    keep =
        uncertain ? [w > 0 ? length(post) : 0 for w in weights] :
        draws_per_chain(weights, chains_in, length(post))
    if M > 1 && seed.timing !== nothing
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "%d posterior modes: mass by bridge sampling%s",
                M,
                uncertain ? " (weights uncertain, not applied)" : ""
            ),
            t_modes)
    end

    # the rows each pooled chain contributes: its warm-up
    # rows, and the post-warm-up rows its mode keeps
    rows = [
        vcat(1:n_adapt, n_adapt .+ even_indices(length(post), keep[mode_of[c]])) for
        c in eachindex(pk)
    ]

    t_reprofile = tick()
    # scale/bkgrnd_corr are fit in closed form (wls_fit) and discarded on every single
    # ℓπ/gradient evaluation above; re-profile c1 at each posterior draw so the
    # reported curve/χ² match what _ll actually evaluated at that ξ during sampling.
    reprof = tmap_items(c -> _reprofile(seed, runs[pk[c]].ξ[rows[c]]), eachindex(pk))
    tock!(
        seed.timing,
        :sampling,
        1,
        "per-draw c1 re-profile + curves ($(sum(length, rows)) draws)",
        t_reprofile,
    )

    # convergence of the chains of each mode (between modes they differ by
    # construction); the worst mode is reported. A mode below MODE_NEGLIGIBLE keeps
    # no draws, so what its chains did is not part of the posterior: not diagnosed.
    live = [m for m in 1:M if weights[m] ≥ MODE_NEGLIGIBLE]
    cvs = [
        convergence(cube[:, findall(==(m), mode_of), :]) for
        m in (isempty(live) ? (1:M) : live)
    ]
    # (NaN entries, from modes too short to judge, are left out; NaN if nothing is left)
    worst(f, init) = [
        (
            v = filter(!isnan, getindex.(getproperty.(cvs, init), q));
            isempty(v) ? NaN : f(v)
        ) for q in 1:(N+1)
    ]
    diag = ChainDiagnostics(n_chains, [starts[k][2] for k in 1:n_chains], pooled, reason,
        worst(maximum, :rhat), worst(minimum, :ess), worst(minimum, :ess_tail),
        rewhitened, [k in pk ? mode_of[findfirst(==(k), pk)] : 0 for k in 1:n_chains],
        weights, logZ, err, uncertain)

    return Inferred(
        reduce(vcat, (runs[pk[c]].ξ[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (runs[pk[c]].stats[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (r.scale for r in reprof)),
        reduce(vcat, (r.bkgrnd_corr for r in reprof)),
        reduce(vcat, (r.c1 for r in reprof)),
        reduce(vcat, (r.χ² for r in reprof)),
        reduce(hcat, (r.curves for r in reprof)),
        reduce(vcat, (fill(pk[c], length(rows[c])) for c in eachindex(pk))),
        reduce(vcat, (rows[c] for c in eachindex(pk))),
        diag,
        l.type,
        seed.timing,
    )
end

# ---------------------------------------------------------------------------
#   Running the NUTS chains: starts, the sampler per chain, the re-profiled curves
# ---------------------------------------------------------------------------

"""
The draws `ξs` in NUTS's whitened coordinates, one draw per row.

# Returns
- `Matrix{Float64}`, `length(ξs) × N`.
"""
function _draws_w(seed::Seed{<:Real,N}, sp, ξs::AbstractVector) where {N}
    W = Matrix{Float64}(undef, length(ξs), N)
    @inbounds for (i, ξ) in enumerate(ξs)
        w = _w_of_θ(Θ(ξ, seed.pr)[1], sp)
        for j in 1:N
            W[i, j] = w[j]
        end
    end
    return W
end

"""
ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates
w (the target the chains sample and bridge sampling integrates).
"""
function _value_target(seed::Seed{<:Real,N}, l::LIKELIHOOD, sp) where {N}
    return w -> _logπ(
        _θ_of_w(SVector{N,eltype(w)}(w...), sp),
        seed.pr,
        seed.wls,
        seed.fw,
        l;
        tab = seed.c1tab,
    )
end

"""
Runs the `n_chains` NUTS chains on the whitened target of `sp`, one task each, from their
starts ([`_chain_start`](@ref)). `δ` is the target acceptance as a fraction. Every chain
has its own metric, Hamiltonian, adaptor and random stream (the stream belongs to the
chain index, not to the thread that happens to run it) and shares only the read-only seed.

# Returns
-   `NamedTuple` `(runs, starts, t_nuts)`: the [`_ChainRun`](@ref)s in
    chain order, the starts and the timer started when the chains began.
"""
function _run_chains(seed::Seed{<:Real,N}, l::LIKELIHOOD, sp, n_samples::Int64,
    n_adapt::Int64, δ::Real,
    base::UInt64, jitter_base::UInt64, n_chains::Int) where {N}
    t_setup = tick()

    # ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates w.
    ℓπ = @closure w -> _logπ(
        _θ_of_w(SVector{N,eltype(w)}(w...), sp),
        seed.pr,
        seed.wls,
        seed.fw, l;
        tab = seed.c1tab,
    )

    # ∂ℓπ∂w: w ↦ (log π(θ(w)), ∇_w log π(θ(w))), computed in one ForwardDiff pass.
    ∂ℓπ∂w = @closure w -> begin
        gc_checkpoint()
        result = DiffResults.GradientResult(w)
        ForwardDiff.gradient!(result, ℓπ, w)
        (DiffResults.value(result), DiffResults.gradient(result))
    end

    # The starts: mirrored jittered pairs, or the MAP for a single chain
    # (deterministically, see `_chain_start`). Chosen serially and up front,
    # so neither the starts nor which chain gets which depend on the threads.
    starts = [_chain_start(k, n_chains, N, ℓπ, ∂ℓπ∂w, jitter_base) for k in 1:n_chains]
    show_progress = n_chains == 1   # concurrent progress bars would overwrite each other

    # One NUTS chain. Every chain has its own metric, Hamiltonian, adaptor
    # and random stream (the stream belongs to the chain index, not to the
    # thread that happens to run it), and shares only the read-only seed.
    run_chain =
        k -> begin
            w₀, _ = starts[k]
            t0 = time_ns()
            try
                # DenseEuclideanMetric allows the adaptation to learn
                # correlations between parameters. Since we are only fitting
                # a handful of params and they are highly coupled, it is
                # worth it here. After the whitening it starts (M⁻¹ = I) close to right.
                metric = DenseEuclideanMetric(N)

                # combines "potential energy" (ℓπ) and kinetic energy (from metric)
                hamiltonian = Hamiltonian(metric, ℓπ, ∂ℓπ∂w)

                # the chain's own stream: the step-size
                # search and the sampler both draw from it
                rng = stream(base, _RNG_NUTS, k)

                # HMC numerically integrates the Hamiltonian,
                # so we need to guess a good step size.
                init_step_size = find_good_stepsize(rng, hamiltonian, copy(w₀))

                # Leapfrog integration evaluates kinetic energy first, then
                # "skips over" that evaluated position to the next one for potential energy.
                integrator = Leapfrog(init_step_size)

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

                ws, stats = sample(
                    rng,
                    hamiltonian,
                    kernel,
                    copy(w₀),
                    n_samples,
                    adaptor,
                    n_adapt;
                    progress = show_progress,
                    verbose = show_progress,
                )
                ξs = [Ξ(_θ_of_w(SVector{N,Float64}(s...), sp), seed.pr) for s in ws]
                return _ChainRun(k, ξs, stats, nothing, (time_ns() - t0) / NS_PER_S)
            catch e
                e isa InterruptException && rethrow()
                return _ChainRun(
                    k,
                    SVector{N,Float64}[],
                    nothing,
                    e,
                    (time_ns() - t0) / NS_PER_S,
                )
            end
        end

    tock!(seed.timing, :sampling, 1, "NUTS setup (starts, Hamiltonian)", t_setup)
    t_nuts = tick()
    runs = tmap_items(run_chain, 1:n_chains)
    return (runs = runs, starts = starts, t_nuts = t_nuts)
end

"""
The highest post-warm-up log density among the
non-divergent draws of the chains that ran, and its ξ.

# Returns
- `NamedTuple` `(ld, ξ)`; `ld = -Inf` if there is no such draw.
"""
function _best_draw(runs, post)
    best = (ld = -Inf, ξ = nothing)
    for r in runs
        r.error === nothing || continue
        for i in post
            st = r.stats[i]
            st.numerical_error || st.log_density <= best.ld ||
                (best = (ld = st.log_density, ξ = r.ξ[i]))
        end
    end
    return best
end

"""
What one NUTS chain returned: its draws and diagnostics,
or the error that stopped it (then `stats` is `nothing`).
"""
struct _ChainRun{N,S}
    k::Int
    ξ::Vector{SVector{N,Float64}}
    stats::S
    error::Union{Nothing,Exception}
    seconds::Float64
end

"""
Start of chain `k` of `n` in NUTS's whitened coordinates w, with its signed distance
from the MAP in posterior standard deviations ([`chain_radius`](@ref)). The start is
`r·u` for a direction `u` on the unit sphere: a single chain, and chain 1, at the MAP
(`w = 0`); chain 2 also at the MAP (its own random stream makes it an independent
chain); chains 3 and up in mirrored pairs, chains `2p+1` and `2p+2` at `+r_p·u_p` and
`-r_p·u_p`. The directions come from streams of `jitter_base`
([`DEFAULT_JITTER_SEED`](@ref) unless the caller gave a `jitter_seed`; never the run's
`rng_seed`). A start where log π or its gradient is not finite is pulled halfway back
toward the MAP, up to [`CHAIN_JITTER_MAX_HALVINGS`](@ref) times, and the distance
returned is the one used; a start that never becomes usable is the MAP itself (0).

# Returns
- `(w₀::Vector{Float64}, r::Float64)`.
"""
function _chain_start(k::Int, n::Int, N::Int, ℓπ, ∂ℓπ∂w, jitter_base::UInt64)
    r = chain_radius(k, n)
    r == 0 && return zeros(N), 0.0
    z = randn(stream(jitter_base, _RNG_JITTER, (k - 1) ÷ 2), N)
    u = z ./ sqrt(sum(abs2, z))
    for _ in 0:CHAIN_JITTER_MAX_HALVINGS
        w = r .* u
        usable = try
            v, g = ∂ℓπ∂w(w)
            isfinite(v) && all(isfinite, g)
        catch e
            e isa InterruptException && rethrow()
            false
        end
        usable && return w, r
        r /= 2
    end
    return zeros(N), 0.0
end

"""
The (scale, `bkgrnd_corr`, c1, reduced χ², curve)
of every draw `ξs`, c1 re-profiled at each.

# Returns
- `NamedTuple` of `Vector`s `scale`, `bkgrnd_corr`,
    `c1`, `χ²` and the matrix `curves` (Q × draws).
"""
function _reprofile(seed::Seed, ξs::AbstractVector)
    n           = length(ξs)
    scale       = Vector{Float64}(undef, n)
    bkgrnd_corr = Vector{Float64}(undef, n)
    c1          = Vector{Float64}(undef, n)
    χ²          = Vector{Float64}(undef, n)
    curves      = Matrix{Float64}(undef, length(seed.fw.qvals), n)
    for (i, ξ) in enumerate(ξs)
        gc_checkpoint()
        ŷ, fit, c1_star = profiled_corrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
        scale[i]        = fit.scale
        bkgrnd_corr[i]  = fit.bkgrnd_corr
        c1[i]           = c1_star
        χ²[i]           = reduced_chi2(fit)
        curves[:, i]    = wls_predict(fit, ŷ)
    end
    return (; scale, bkgrnd_corr, c1, χ², curves)
end
