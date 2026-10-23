# SPDX-License-Identifier: LGPL-3.0-or-later

# Diagnostics for the MAP-whitened NUTS pipeline, generic over any `Inference.Seed`
# (a unit-test toy, a SASBDB fit, ...). A developer tool: dev/diagnose.jl is
# its command line, and test/unit_tests/units/test_seed_diagnostics.jl keeps it
# from rotting. Functions only: nothing runs on include. Plain data comes back from
# the measuring functions and `diagnose` prints it, so a test
# can assert on the numbers and a script can print them.
#
# Needs only `BAYSOL` and the standard library, and borrows StaticArrays /
# ForwardDiff / DiffResults from `BAYSOL.Inference`'s own bindings, so it loads in
# any environment that has BAYSOL (test/ and test/fitting_tests/
# alike). It reaches into `Inference` internals (`_logπ`, `_sampling_space`,
# `_fd_hessian`, ...) on purpose, as the unit tests do; keep it in step with them.
#
# Include it once per process (a second include replaces the module).
#
# Coordinates: z is the prior-standardized space L-BFGS runs in, w the
# whitened space NUTS samples, θ = μ + σ·(ẑ + S·w) (see Inference/MAP.jl).

module SeedDiagnostics

using Random, LinearAlgebra, Statistics, Printf
using BAYSOL

const F = BAYSOL.Inference
const R = BAYSOL.Pipeline
const SVector = F.SVector
const ForwardDiff = F.ForwardDiff
const DiffResults = F.DiffResults

export nuts_replica, gradient_w, gradient_noise, local_curvature, lbfgs_starts,
    hessian_sensitivity, axis_scan, mode_table, curve_chi2, ess, diagnose, chain_report

# ---------------------------------------------------------------------------
#                                   helpers
# ---------------------------------------------------------------------------

"Prior standardization of `seed` and a function ξ(z)."
function _space(seed::F.Seed)
    μ, σ = F.θ_prior_moments(seed.pr)
    return μ, σ, z -> F.Ξ(μ .+ σ .* SVector{4}(z...), seed.pr)
end

_fz(seed, z, tol) = begin
    μ, σ, _ = _space(seed)
    F._neglogπ(SVector{4}(z...), μ, σ, seed, tol)
end

_vs(v) = "[" * join((@sprintf("%.4g", x) for x in v), ", ") * "]"
_skew(x) = (m = mean(x); s = std(x); mean(((x .- m) ./ s) .^ 3))
_exkurt(x) = (m = mean(x); s = std(x); mean(((x .- m) ./ s) .^ 4) - 3)

"""
    ess(x; maxlag = 300) -> Float64

Effective sample size of a draw sequence from the initial-positive autocorrelation sum
(stops at the first lag with autocorrelation ≤ 0.05).

# Returns
- `Float64`: ESS, or `NaN` for a constant sequence.

# Exceptions
- None.
"""
function ess(x; maxlag = 300)
    n = length(x)
    x = x .- mean(x)
    v = sum(abs2, x) / n
    v == 0 && return NaN
    τ = 1.0
    for k in 1:min(maxlag, n-2)
        ρ = sum(@view(x[1:(n-k)]) .* @view(x[(1+k):n])) / (n * v)
        ρ ≤ 0.05 && break
        τ += 2ρ
    end
    return n / τ
end

# ---------------------------------------------------------------------------
#                       NUTS replica and gradient accuracy
# ---------------------------------------------------------------------------

"""
    gradient_w(seed, sp, w; tol = F.EXCL_VOL_CORR_TOL) -> Vector{Float64}

∇_w log π(θ(w)) as NUTS computes it, with c1 profiled to `tol`.

# Arguments
- `seed::Inference.Seed`, `sp`: the seed and its `_SamplingSpace` (whitening).
- `w`: a point in NUTS coordinates.

# Returns
- The gradient, one `ForwardDiff` pass.

# Exceptions
- `WLSError` if the model curve is flat at `w`.
"""
gradient_w(seed, sp, w; tol = F.EXCL_VOL_CORR_TOL) =
    ForwardDiff.gradient(
        x ->
            F._logπ(F._θ_of_w(SVector{4,eltype(x)}(x...), sp), seed.pr, seed.wls, seed.fw,
                tab = seed.c1tab, c1_tol = tol),
        collect(Float64, w))

"""
    nuts_replica(seed; c1_tol, n_samples, n_adapt, δ, rng_seed, sp) -> NamedTuple

`infer` re-implemented step for step (MAP search and whitening, then NUTS with the
same adaptor), but with the c1 profiling tolerance `c1_tol` chosen by the caller
and the adapted metric, step size and per-iteration statistics returned. It draws
from the global RNG (the MAP starts, the step-size search and the sampler), which
`rng_seed` seeds first; `infer` itself derives its streams from its own
`rng_seed`, so the two give statistically equivalent, not identical, chains.

# Arguments
- `seed::Inference.Seed`.

# Keywords
- `n_samples = Pipeline.DEFAULT_N_SAMPLES`,
    `n_adapt = Pipeline.DEFAULT_N_ADAPT` (the `run_model`
    defaults), `δ = Inference.DEFAULT_TARGET_ACCEPT / 100` (target acceptance as a fraction,
    the same constant `run_model` uses, so this tool cannot drift from the pipeline).
- `c1_tol = F.EXCL_VOL_CORR_TOL`: tolerance for the NUTS log density
    and gradient (the MAP search always uses the package default).
- `rng_seed = nothing`: `Random.seed!` this before NUTS.
- `sp = F._sampling_space(seed)`: reuse a whitening already computed.

# Returns
- `(; sp, ε0, ε, W, post, stats, seconds, n_leapfrog)`: `W` all draws (4 × n_samples) in w,
    `post` the post-warmup columns, `stats` AdvancedHMC's per-iteration statistics.

# Exceptions
- `ArgumentError` if `n_adapt ≥ n_samples`.
"""
function nuts_replica(seed::F.Seed; c1_tol = F.EXCL_VOL_CORR_TOL,
    n_samples = R.DEFAULT_N_SAMPLES,
    n_adapt = R.DEFAULT_N_ADAPT, δ = F.DEFAULT_TARGET_ACCEPT / 100, rng_seed = nothing,
    sp = nothing)
    n_adapt < n_samples || throw(ArgumentError("n_adapt must be < n_samples"))
    # seed first: the MAP starts (when `sp` is not given), the
    # step-size search and the sampler all draw from this RNG
    rng_seed === nothing || Random.seed!(rng_seed)
    sp === nothing && (sp = F._sampling_space(seed))
    # again: computing `sp` consumed draws, a given `sp` did not
    rng_seed === nothing || Random.seed!(rng_seed)
    ℓπ =
        w -> F._logπ(F._θ_of_w(SVector{4,eltype(w)}(w...), sp), seed.pr, seed.wls, seed.fw,
            tab = seed.c1tab, c1_tol = c1_tol)
    ∂ = w -> begin
        r = DiffResults.GradientResult(w)
        ForwardDiff.gradient!(r, ℓπ, w)
        (DiffResults.value(r), DiffResults.gradient(r))
    end
    metric = F.DenseEuclideanMetric(4)
    ham = F.Hamiltonian(metric, ℓπ, ∂)
    ε0 = F.find_good_stepsize(Random.default_rng(), ham, zeros(4))
    integ = F.Leapfrog(ε0)
    adaptor = F.StanHMCAdaptor(F.MassMatrixAdaptor(metric), F.StepSizeAdaptor(δ, integ))
    kernel = F.HMCKernel(F.Trajectory{F.MultinomialTS}(integ, F.GeneralisedNoUTurn()))
    seconds = @elapsed samples, stats = F.sample(
        Random.default_rng(),
        ham,
        kernel,
        zeros(4),
        n_samples,
        adaptor,
        n_adapt;
        progress = false,
        verbose = false,
    )
    W = reduce(hcat, samples)
    return (; sp, ε0, ε = stats[end].step_size, W, post = W[:, (n_adapt+1):end], stats,
        seconds, n_leapfrog = sum(getproperty.(stats, :n_steps)))
end

"""
    gradient_noise(seed, sp, W; tol, ref_tol, n) -> NamedTuple

How wrong NUTS's gradient is because c1 is only profiled to `tol`: at `n`
evenly spaced columns of `W`, ‖∇ℓπ(tol) − ∇ℓπ(ref_tol)‖₂ in w coordinates,
next to the true gradient norm. In w the posterior is ≈ N(0, I), so a
gradient error comparable to 1 is as large as the force NUTS is integrating.

# Arguments
- `seed`, `sp`, `W`: the seed, its whitening, and draws (columns) in w.

# Keywords
- `tol = F.EXCL_VOL_CORR_TOL`, `ref_tol = 1e-11`, `n = 40`.

# Returns
- `(; noise, grad_norm)`: vectors of length `n`.

# Exceptions
- `WLSError` if a draw has a flat model curve.
"""
function gradient_noise(
    seed,
    sp,
    W;
    tol = F.EXCL_VOL_CORR_TOL,
    ref_tol = 1e-11,
    n = 40,
)
    idx = unique(round.(Int, range(1, size(W, 2), length = n)))
    ref = [gradient_w(seed, sp, W[:, k]; tol = ref_tol) for k in idx]
    noise = [norm(gradient_w(seed, sp, W[:, k]; tol) .- r) for (k, r) in zip(idx, ref)]
    return (; noise, grad_norm = norm.(ref))
end

"""
    local_curvature(seed, sp, W; tol, n, step) -> NamedTuple

Extreme eigenvalues of the Hessian of −ℓπ in w at `n` evenly spaced columns of
`W`, by central differences of the gradient (use a tight `tol`: the Hessian
divides gradient error by `step`). Leapfrog is stable only for ε < 2/√λ_max, so
these bound the step size the geometry allows independently of any gradient error.

# Returns
- `(; λmax, λmin)`: vectors of length `n` (negative `λmin` means locally non-convex).

# Exceptions
- `WLSError` if a probe point has a flat model curve.
"""
function local_curvature(seed, sp, W; tol = 1e-11, n = 40, step = 0.05)
    idx = unique(round.(Int, range(1, size(W, 2), length = n)))
    λmax = Float64[]
    λmin = Float64[]
    for k in idx
        w = W[:, k]
        cols = ntuple(4) do i
            e = zeros(4)
            e[i] = step
            (
                -gradient_w(seed, sp, w .+ e; tol) .+
                gradient_w(seed, sp, w .- e; tol)
            ) ./ (2step)
        end
        H = hcat(cols...)
        ev = eigvals(Symmetric((H + H') / 2))
        push!(λmax, ev[end])
        push!(λmin, ev[1])
    end
    return (; λmax, λmin)
end

# ---------------------------------------------------------------------------
#                          MAP search, modes, Hessian
# ---------------------------------------------------------------------------

"""
    lbfgs_starts(seed; n_starts, rng_seed, ref_tol) -> Vector{NamedTuple}

The MAP search's L-BFGS starts replayed one by one (the seed's θ₀, then prior
draws), recording how each stopped. `grad_gap` is ‖∇f(tol) − ∇f(ref_tol)‖∞ at
the stopping point (z space): when it is larger than `F.MAP_G_TOL` the
optimizer cannot be told apart from converged by its gradient.

# Keywords
- `n_starts = F.MAP_N_STARTS`, `rng_seed = nothing`, `ref_tol = 1e-11`.

# Returns
- One `(; start, z, f, iters, g_converged, f_converged, iteration_limit, grad_gap, c1, ξ)`
    per feasible start.

# Exceptions
- None; infeasible starts are skipped.
"""
function lbfgs_starts(
    seed::F.Seed;
    n_starts = F.MAP_N_STARTS,
    rng_seed = nothing,
    ref_tol = 1e-11,
)
    μ, σ, ξ_of = _space(seed)
    f0 = z -> F._neglogπ(SVector{4}(z...), μ, σ, seed, F.EXCL_VOL_CORR_TOL)
    function fg!(G, z)
        dr = DiffResults.GradientResult(z)
        ForwardDiff.gradient!(dr, f0, z)
        G === nothing || (G .= DiffResults.gradient(dr))
        DiffResults.value(dr)
    end
    g!(G, z) = (fg!(G, z); G)
    opts = F.Options(g_abstol = F.MAP_G_TOL, iterations = F.MAP_MAX_ITER)
    rng_seed === nothing || Random.seed!(rng_seed)
    z₀ = F._standardize(seed.θ₀, seed.pr)
    zs = vcat(
        [z₀],
        [F._standardize(F.Θ(F._ξ₀(seed.pr), seed.pr)[1], seed.pr) for _ in 2:n_starts],
    )
    out = NamedTuple[]
    for (i, z) in enumerate(zs)
        isfinite(f0(Vector(z))) || continue
        res = F.optimize(
            F.OnceDifferentiable(f0, g!, fg!, Vector(z)),
            Vector(z),
            F.LBFGS(),
            opts,
        )
        ẑ = SVector{4}(F.Optim.minimizer(res)...)
        gap = maximum(
            abs,
            F._neglogπ_grad(ẑ, μ, σ, seed, F.EXCL_VOL_CORR_TOL) .-
            F._neglogπ_grad(ẑ, μ, σ, seed, ref_tol),
        )
        c1 = F.profiled_corrs(
            seed.wls,
            ξ_of(ẑ),
            seed.fw;
            tables = seed.c1tab,
            tol = ref_tol,
        )[3]
        push!(
            out,
            (; start = i, z = ẑ, f = F.Optim.minimum(res), iters = F.Optim.iterations(res),
                g_converged = F.Optim.g_converged(res),
                f_converged = F.Optim.f_converged(res),
                iteration_limit = F.Optim.iteration_limit_reached(res), grad_gap = gap, c1,
                ξ = ξ_of(ẑ)),
        )
    end
    return out
end

"""
    hessian_sensitivity(seed, ẑ; rels) -> NamedTuple

Eigenvalues of the MAP Hessian of −log π (z space) from the first pass (absolute step
`F.MAP_HESS_STEP`) and from second passes at each `rels` × the Laplace σ. Eigenvalues that
move with the step size mean the finite differences are measuring noise, not curvature.

# Returns
- `(; pass1, pass2, σ_lap)`: `pass1` eigenvalues, `pass2` a
    `Dict(rel => eigenvalues)`, `σ_lap` the first-pass Laplace σ per coordinate.

# Exceptions
- None; non-finite Hessians give `NaN` eigenvalues.
"""
function hessian_sensitivity(
    seed::F.Seed,
    ẑ;
    rels = (0.3, 0.1, 0.03, 0.01),
)
    μ, σ, _ = _space(seed)
    H1 = F._fd_hessian(
        SVector{4}(ẑ...),
        F.MAP_HESS_STEP .* ones(SVector{4,Float64}),
        μ,
        σ,
        seed,
    )
    ev(H) = all(isfinite, H) ? eigvals(Symmetric(Matrix(H))) : fill(NaN, 4)
    λ1, V1 = F._floored_eigen(H1)
    σ_lap = sqrt.(diag(V1 * ((1 ./ λ1) .* V1')))
    pass2 = Dict(
        r => ev(F._fd_hessian(SVector{4}(ẑ...), r .* σ_lap, μ, σ, seed)) for r in rels
    )
    return (; pass1 = ev(H1), pass2, σ_lap)
end

"""
    mode_table(seed, optima, sp) -> Vector{NamedTuple}

Distinct optima (Mahalanobis distance > `F.MAP_MODE_SEP` under the MAP
Hessian) with the Laplace log-mass −f − ½ log det H of each, so a mode that
merely exists can be told from one that carries posterior probability.

# Arguments
- `optima`: `lbfgs_starts` output. `sp`: the seed's `_SamplingSpace`.

# Returns
- `(; z, f, λ, log_mass)` per mode, best first; `log_mass`
    is `NaN` if the Hessian there is not positive definite.

# Exceptions
- None.
"""
function mode_table(seed::F.Seed, optima, sp)
    μ, σ, _ = _space(seed)
    Hf = Symmetric(Matrix(inv(sp.S * sp.S')))
    modes = NamedTuple[]
    for o in sort(optima, by = x -> x.f)
        any(m -> sqrt((o.z - m.z)' * Hf * (o.z - m.z)) ≤ F.MAP_MODE_SEP, modes) ||
            push!(modes, (; z = o.z, f = o.f))
    end
    return map(modes) do m
        H = F._fd_hessian(m.z, 1e-3 .* ones(SVector{4,Float64}), μ, σ, seed)
        λ = all(isfinite, H) ? eigvals(Symmetric(Matrix(H))) : fill(NaN, 4)
        (; m.z, m.f, λ, log_mass = all(>(0), λ) ? -m.f - 0.5 * sum(log, λ) : NaN)
    end
end

"""
    axis_scan(seed, sp; svals, grid, h) -> Vector{NamedTuple}

Shape of −log π along each whitened axis of the MAP: `ratio[s] = Δf / (s²/2)` at each
of `svals` (1 for a Gaussian; < 1 or > 1 means a flatter or steeper wall), and over
`grid` points in [−3, 3] the largest disagreement between the production and a tight
c1 tolerance (`noise`), the second difference `f''` (a kink shows as `f''` ≫ its
median), and how far c1* moves (`c1_jumps` counts steps above 5e-3, a regime switch).

# Returns
- One `(; axis, svals, ratio, noise, f2_median, f2_max, f2_at, c1_range, c1_jumps)`
    per axis.

# Exceptions
- None.
"""
function axis_scan(seed::F.Seed, sp;
    svals = (-10, -5, -3, -2, -1, -0.5, 0.5, 1, 2, 3, 5, 10),
    grid = 241, h = 6 / (grid - 1), ref_tol = 1e-11)
    _, _, ξ_of = _space(seed)
    f(z, tol) = _fz(seed, z, tol)
    fmin = f(sp.ẑ, ref_tol)
    ss = range(-3, 3, length = grid)
    map(1:4) do i
        ratio = [(f(sp.ẑ + sp.S[:, i] * s, ref_tol) - fmin) / (s^2 / 2) for s in svals]
        fc = Float64[]
        ff = Float64[]
        c1s = Float64[]
        for s in ss
            z = sp.ẑ + sp.S[:, i] * s
            push!(fc, f(z, F.EXCL_VOL_CORR_TOL))
            push!(ff, f(z, ref_tol))
            push!(
                c1s,
                try
                    F.profiled_corrs(
                        seed.wls,
                        ξ_of(z),
                        seed.fw;
                        tables = seed.c1tab,
                        tol = F.EXCL_VOL_CORR_TOL,
                    )[3]
                catch
                    NaN
                end,
            )
        end
        d2 = [(ff[k+1] - 2ff[k] + ff[k-1]) / h^2 for k in 2:(length(ff)-1)]
        a = abs.(d2)
        fin = filter(isfinite, a)
        km = argmax(replace(a, NaN => -Inf))
        c1ok = filter(isfinite, c1s)
        (; axis = i, svals, ratio, noise = maximum(abs.(fc .- ff)), f2_median = median(fin),
            f2_max = maximum(fin),
            f2_at = ss[km+1], c1_range = extrema(c1ok),
            c1_jumps = count(abs.(diff(c1s)) .> 5e-3))
    end
end

# ---------------------------------------------------------------------------
#                              reference curves
# ---------------------------------------------------------------------------

"""
    curve_chi2(q, I, σ, q_ref, I_ref) -> NamedTuple

Reduced χ² of a reference curve (a CRYSOL / OLIGOMER / EOM `.fit`
column) on the data points it covers, linearly interpolated: as given
(`raw`), and with a free scale and offset (`fitted`, 2 fewer degrees
of freedom), so curves in a different normalization compare fairly.

# Returns
- `(; n, raw, fitted)`.

# Exceptions
- `ArgumentError` if the reference covers no data point.
"""
function curve_chi2(q, I, σ, q_ref, I_ref)
    p = sortperm(q_ref)
    qf = q_ref[p]
    If = I_ref[p]
    ok = [qf[1] ≤ x ≤ qf[end] for x in q]
    any(ok) || throw(ArgumentError("the reference curve covers none of the data points"))
    Ii = map(q[ok]) do x
        j = clamp(searchsortedlast(qf, x), 1, length(qf) - 1)
        w = (x - qf[j]) / (qf[j+1] - qf[j])
        If[j] * (1 - w) + If[j+1] * w
    end
    y = I[ok]
    s = σ[ok]
    n = length(y)
    raw = sum(((y .- Ii) ./ s) .^ 2) / n
    X = hcat(Ii, ones(n))
    # weighted least squares by QR: the normal equations square the condition number
    β = (X ./ s) \ (y ./ s)
    return (; n, raw, fitted = sum(((y .- X * β) ./ s) .^ 2) / (n - 2))
end

# ---------------------------------------------------------------------------
#                                    reports
# ---------------------------------------------------------------------------

"""
    diagnose(io, seed; label, reference, n_samples, n_adapt)

Full sampler diagnosis of one seed, written to `io`: MAP starts and how they
stopped, Hessian sensitivity, the NUTS replica (step size, tree depth, posterior
sd and Laplace agreement in w, ESS), bound proximity, shape along the whitened
axes, modes and their Laplace mass, whether L-BFGS's mode is the best point NUTS
found, gradient error from the c1 tolerance, and local curvature along the chain.

# Arguments
- `io`, `seed`.

# Keywords
- `label = ""`, `n_samples`, `n_adapt` (default: the
    `run_model` defaults, `Pipeline.DEFAULT_N_SAMPLES`, `DEFAULT_N_ADAPT`).
- `reference = nothing`: `(; q, I, σ, q_ref, I_ref)`
    to add the reference curve's χ² on the same points.

# Returns
- `nothing`.

# Exceptions
- None beyond those of the functions it calls.
"""
function diagnose(io::IO, seed::F.Seed; label = "", reference = nothing,
    n_samples = R.DEFAULT_N_SAMPLES, n_adapt = R.DEFAULT_N_ADAPT)
    p(args...) = (println(io, args...); flush(io))
    pr = seed.pr
    μ, σ, ξ_of = _space(seed)
    p("="^100)
    p(
        (
        "$label   n_q=$(length(seed.fw.qvals))  n_atoms=$(seed.fw.n_atoms) " *
        " lMax=$(seed.fw.lMax)  c1 tol=$(F.EXCL_VOL_CORR_TOL)"
    ),
    )
    p("δρ₃ support = [", @sprintf("%.4g", pr.δρ₃Prior.μ), ", ",
        @sprintf("%.4g", pr.δρ₃Prior.μ + pr.δρ₃Prior.σ),
        "]   δρ₁,₂ support = [", F.LOWER_BOUND_δρ₁₂, ", ",
        F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂, "]")
    if reference !== nothing
        c = curve_chi2(
            reference.q,
            reference.I,
            reference.σ,
            reference.q_ref,
            reference.I_ref,
        )
        p(
            @sprintf(
                "reference curve on our q-set (n=%d): χ²_red \
                    raw = %.3f, with free scale+offset = %.3f",
                c.n,
                c.raw,
                c.fitted
            )
        )
    end

    t_map = @elapsed sp = F._sampling_space(seed)
    p(
        @sprintf(
            "MAP search: %.1fs  n_ok=%d/%d  n_modes=%d  whitened=%s",
            t_map,
            sp.n_ok,
            sp.n_starts,
            sp.n_modes,
            sp.whitened
        )
    )
    r = nuts_replica(seed; n_samples, n_adapt, sp)
    st = r.stats[(n_adapt+1):end]
    ns = getproperty.(r.stats, :n_steps)
    dp = getproperty.(r.stats, :tree_depth)
    post = r.post
    p(
        @sprintf(
            "NUTS: %.1fs  init ε=%.4g  final ε=%.4g  mean n_steps=%.1f \
                 mean depth=%.2f  frac(depth≥10)=%.3f  diverged=%d",
            r.seconds, r.ε0, r.ε, mean(ns[(n_adapt+1):end]), mean(dp[(n_adapt+1):end]),
            mean(dp[(n_adapt+1):end] .>= 10),
            count(getproperty.(st, :numerical_error)))
    )
    # Stan's warmup phases (initial buffer, doubling windows,
    # final buffer), then sampling; clipped to the run
    wins = [
        (a, min(b, n_samples)) for (a, b) in (
            (1, 75),
            (76, 450),
            (451, n_adapt - 50),
            (n_adapt - 49, n_adapt),
            (n_adapt + 1, n_samples),
        )
        if a ≤ min(b, n_samples) && b ≤ n_samples + 450
    ]
    p(
        "mean n_steps by window: ",
        join((@sprintf("[%d:%d]=%.0f", a, b, mean(ns[a:b])) for (a, b) in wins), "  "),
    )
    p(
        @sprintf("mean accept = %.3f   mean |ΔH| = %.3f",
            mean(getproperty.(st, :acceptance_rate)),
            mean(abs.(getproperty.(st, :hamiltonian_energy_error))))
    )
    Σw = cov(post')
    p(
        "post-warmup w: sd = ",
        _vs(std(post, dims = 2)),
        "   (1 = the Laplace whitening is right)",
    )
    p("  cov(w) eigenvalues = ", _vs(eigvals(Symmetric(Σw))), "   skew = ",
        _vs([_skew(post[i, :]) for i in 1:4]),
        "   ESS = ", _vs([ess(post[i, :]) for i in 1:4]))
    ℓ0 = F._logπ(
        F._θ_of_w(SVector{4}(0.0, 0.0, 0.0, 0.0), sp),
        pr,
        seed.wls,
        seed.fw,
        tab = seed.c1tab,
    )
    ℓs = getproperty.(st, :log_density)
    p(
        @sprintf(
            "ℓπ at L-BFGS mode = %.4f   best draw = %.4f   median \
                draw = %.4f   (4-D Gaussian: median ≈ mode − 1.7)",
            ℓ0,
            maximum(ℓs),
            median(ℓs)
        )
    )

    # distance to the support bounds
    ξs = [F.Ξ(F._θ_of_w(SVector{4}(post[:, k]...), sp), pr) for k in 1:size(post, 2)]
    bnd = ((0.0, Inf), (F.LOWER_BOUND_δρ₁₂, F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂),
        (F.LOWER_BOUND_δρ₁₂, F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂),
        (pr.δρ₃Prior.μ, pr.δρ₃Prior.μ + pr.δρ₃Prior.σ))
    p("coordinate   median ξ       sd ξ     distance to nearest support bound / sd")
    for (k, nm) in enumerate(("ρₑ", "δρ₁", "δρ₂", "δρ₃"))
        xs = getindex.(ξs, k)
        lo, hi = bnd[k]
        p(
            @sprintf(
                "  %-5s %12.5g %11.3g     %10.3g",
                nm,
                median(xs),
                std(xs),
                min(median(xs) - lo, hi - median(xs)) / std(xs)
            )
        )
    end

    starts = lbfgs_starts(seed; rng_seed = 12345)
    p("L-BFGS starts (z space):")
    for o in starts
        p(
            @sprintf(
                "  start %d: f=%.4f iters=%3d g_conv=%s \
                    iter_limit=%s |∇f(tol) − ∇f(ref)|∞=%.2e c1=%.4f",
                o.start, o.f, o.iters, o.g_converged, o.iteration_limit, o.grad_gap, o.c1)
        )
    end
    hs = hessian_sensitivity(seed, sp.ẑ)
    p(
        "MAP Hessian eigenvalues (floor ",
        F.MAP_HESS_EIG_FLOOR,
        "): pass 1 = ",
        _vs(hs.pass1),
    )
    for rel in sort(collect(keys(hs.pass2)); rev = true)
        p(@sprintf("  pass 2, step %.2f·σ_lap: ", rel), _vs(hs.pass2[rel]))
    end
    Zs = reduce(hcat, [sp.ẑ + sp.S * post[:, k] for k in 1:size(post, 2)])
    p(
        "sampled sd in z / Laplace σ_z = ",
        _vs(vec(std(Zs, dims = 2)) ./ sqrt.(diag(sp.S * sp.S'))),
    )
    p(
        "Δf/(s²/2) along whitened axes (1 = Gaussian), s = ",
        join(("$s" for s in (-10, -5, -3, -2, -1, -0.5, 0.5, 1, 2, 3, 5, 10)), ","),
    )
    scans = axis_scan(seed, sp)
    for a in scans
        p("  w$(a.axis): ", join((@sprintf("%8.3g", x) for x in a.ratio), " "))
    end
    for a in scans
        p(
            @sprintf(
                "  w%d scan: c1-tol noise=%.2e  f''(median)=%.3g \
                    f''(max)=%.3g at s=%.2f  c1 range=[%.4f,%.4f] jumps=%d",
                a.axis, a.noise, a.f2_median, a.f2_max, a.f2_at, a.c1_range..., a.c1_jumps)
        )
    end
    modes = mode_table(seed, starts, sp)
    p("distinct optima: ", length(modes))
    for (k, m) in enumerate(modes)
        p(
            @sprintf(
                "  mode %d: f=%.3f ξ=%s  H-eig=%s  log \
                    Laplace mass=%.3f (Δ vs best = %.3g nats)",
                k,
                m.f,
                _vs(ξ_of(m.z)),
                _vs(m.λ),
                m.log_mass,
                m.log_mass - modes[1].log_mass
            )
        )
    end
    gn = gradient_noise(seed, sp, post)
    p("gradient error from the c1 tolerance in w: min/median/max = ",
        _vs([minimum(gn.noise), median(gn.noise), maximum(gn.noise)]),
        "  vs |∇ℓπ| median = ", @sprintf("%.3g", median(gn.grad_norm)),
        "   (posterior-scale gradient ≈ 1)")
    lc = local_curvature(seed, sp, post)
    p("local λ_max(−∇²ℓπ) min/median/max = ",
        _vs([minimum(lc.λmax), median(lc.λmax), maximum(lc.λmax)]),
        "  → stable ε < ", _vs(2 ./ sqrt.([maximum(lc.λmax), median(lc.λmax)])),
        " (worst, median);  adapted ε = ", @sprintf("%.4g", r.ε))
    return nothing
end

# ---------------------------------------------------------------------------
#                                 chain_report
# ---------------------------------------------------------------------------

"""
    chain_report(io, seed; label, n_samples, n_adapt, rng_seed, rerun, max_listed)

Runs [`Inference.infer`](@ref BAYSOL.Inference.infer) (all its chains, as `run_model`
does) and prints, per chain: its start (signed distance from the MAP in posterior
standard deviations), the posterior mode it settled in, whether it was pooled, and over
its post-warm-up draws that were kept: the number of divergent transitions, the
final step size, the mean leapfrog steps, the mean acceptance and the mean log π; then
each divergent draw (ξ, log π against its chain's median, leapfrog steps, tree depth),
at most `max_listed`. Shows which chains the divergences of a fit come from.

Only the draws the pool keeps are seen: a chain in a mode that keeps no draws, or a
chain that was not pooled, has none to report (its line says so). `rng_seed` is the run's
(pass the `rng_seed` of a report's `=== Run ===` section to look at that very run). With
`rerun = true` it is the run `infer` does when R̂ is above the limit instead (the
`RETRY_N_ADAPT` / `RETRY_N_DRAWS` size, seeds from `Inference._retry_seeds`), whether or
not that run was kept.

# Returns
- A vector of `(; k, start, mode, pooled, n_post, div, div_warm, ε, steps, accept,
    logπ)`, one per chain; `div` and the other post-warm-up fields are `missing`
    for a chain with no kept post-warm-up draws.

# Exceptions
- None beyond those of [`Inference.infer`](@ref BAYSOL.Inference.infer).
"""
function chain_report(io::IO, seed::F.Seed; label = "",
    n_samples = R.DEFAULT_N_SAMPLES, n_adapt = R.DEFAULT_N_ADAPT, rng_seed = 7,
    rerun = false, max_listed = 12)
    if rerun
        base, jitter = F._retry_seeds(rng_seed % UInt64, F.DEFAULT_JITTER_SEED)
        n_samples, n_adapt = F.RETRY_N_ADAPT + F.RETRY_N_DRAWS, F.RETRY_N_ADAPT
        fit = F.infer(seed, n_samples, n_adapt; rng_seed = base, jitter_seed = jitter,
            retry = false)
    else
        fit = F.infer(seed, n_samples, n_adapt; rng_seed, retry = false)
    end
    d = fit.diagnostics
    na = d.n_adapt
    println(io, label, ": ", d.n_chains, " chains, ", na, " warm-up + ",
        n_samples - n_adapt,
        " draws, rng_seed ", rng_seed, ", δ ", F.DEFAULT_TARGET_ACCEPT,
        rerun ? "  (the rerun)" : "")
    println(io, "chain  start σ   mode  pooled  kept  div  div%  warm-up div       ε",
        "  steps  accept   mean log π")
    out = NamedTuple[]
    listed = String[]
    for k in 1:d.n_chains
        idx = findall(==(k), fit.chain)
        post = filter(i -> fit.iteration[i] > na, idx)
        warm = setdiff(idx, post)
        st = fit.stats
        wdiv = count(i -> st[i].numerical_error, warm)
        if isempty(post)
            @printf(io, "%5d  %+7.2f  %5d  %-6s  %4d  %s\n", k, d.start_scale[k],
                d.mode[k], d.pooled[k] ? "yes" : "no", 0,
                d.pooled[k] ? "no post-warm-up draws kept (negligible mode)" :
                "not pooled: " * d.reason[k])
            push!(
                out,
                (; k, start = d.start_scale[k], mode = d.mode[k],
                    pooled = d.pooled[k], n_post = 0, div = missing, div_warm = wdiv,
                    ε = missing, steps = missing, accept = missing, logπ = missing),
            )
            continue
        end
        nd = count(i -> st[i].numerical_error, post)
        ld = [st[i].log_density for i in post]
        row = (; k, start = d.start_scale[k], mode = d.mode[k], pooled = d.pooled[k],
            n_post = length(post), div = nd, div_warm = wdiv,
            ε = mean(st[i].step_size for i in post),
            steps = mean(st[i].n_steps for i in post),
            accept = mean(st[i].acceptance_rate for i in post), logπ = mean(ld))
        push!(out, row)
        @printf(io,
            "%5d  %+7.2f  %5d  %-6s  %4d  %3d  %4.1f  %11d  %6.4f  %5.1f  %6.3f  %11.2f\n",
            k, row.start, row.mode, "yes", row.n_post, nd, 100nd / row.n_post, wdiv,
            row.ε, row.steps, row.accept, row.logπ)
        med = median(ld)
        for i in post
            st[i].numerical_error || continue
            push!(
                listed,
                @sprintf("  chain %d iteration %d  ξ = [%s]  log π %+.2f vs chain median \
                %+.2f  steps %d  depth %d", k, fit.iteration[i],
                    join((@sprintf("%.5g", x) for x in fit.samples[i]), ", "),
                    st[i].log_density, med, st[i].n_steps, st[i].tree_depth)
            )
        end
    end
    tot = sum(r.n_post for r in out)
    nd = sum(r -> ismissing(r.div) ? 0 : r.div, out)
    @printf(io, "pooled kept draws: %d, divergent: %d (%.2f %%)\n", tot, nd,
        tot == 0 ? 0.0 : 100nd / tot)
    if !isempty(listed)
        println(io, "divergent draws",
            length(listed) > max_listed ?
            " (first $max_listed of $(length(listed)))" : "", ":")
        foreach(s -> println(io, s), first(listed, max_listed))
    end
    return out
end

end # module SeedDiagnostics
