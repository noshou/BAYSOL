# SPDX-License-Identifier: LGPL-2.1-or-later

# Diagnostics for the MAP-whitened NUTS pipeline, generic over any `Inference.Seed` (a unit-test
# toy, a SASBDB fit, ...). A developer tool: test/utils/diagnose.jl is its command line, and
# test/unit_tests/units/test_seed_diagnostics.jl keeps it from rotting. Functions only: nothing runs on include. Plain data comes back from
# the measuring functions and `diagnose` / `tolerance_sweep` print it, so a test can assert on the
# numbers and a script can print them.
#
# Needs only `BAYSOL` and the standard library, and borrows StaticArrays / ForwardDiff /
# DiffResults from `BAYSOL.Inference`'s own bindings, so it loads in any environment that has BAYSOL
# (test/, test/fitting_tests/ and test/utils/ alike). It reaches into `Inference` internals (`_logπ`,
# `_sampling_space`, `_fd_hessian`, ...) on purpose, as the unit tests do; keep it in step with them.
#
# Include it once per process (a second include replaces the module).
#
# Coordinates: z is the prior-standardized space L-BFGS runs in, w the whitened space NUTS samples,
# θ = μ + σ·(ẑ + S·w) (see Inference/MAP.jl).

module SeedDiagnostics

using Random, LinearAlgebra, Statistics, Printf
using BAYSOL

const F = BAYSOL.Inference
const R = BAYSOL.Pipeline
const SVector = F.SVector
const ForwardDiff = F.ForwardDiff
const DiffResults = F.DiffResults

export nuts_replica, gradient_w, gradient_noise, local_curvature, lbfgs_starts, hessian_sensitivity,
    axis_scan, mode_table, shell_contrast_ablation, curve_chi2, ess, diagnose, tolerance_sweep,
    warmup_study

# ---------------------------------------------------------------------------
#                                   helpers
# ---------------------------------------------------------------------------

"Prior standardization of `seed` and a function ξ(z)."
function _space(seed::F.Seed)
    μ, σ = F.θ_prior_moments(seed.pr)
    return μ, σ, z -> F.Ξ(μ .+ σ .* SVector{4}(z...), seed.pr)
end

_fz(seed, z, tol, l) = begin
    μ, σ, _ = _space(seed)
    F._neglogπ(SVector{4}(z...), μ, σ, seed, l, tol)
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
    for k in 1:min(maxlag, n - 2)
        ρ = sum(@view(x[1:n-k]) .* @view(x[1+k:n])) / (n * v)
        ρ ≤ 0.05 && break
        τ += 2ρ
    end
    return n / τ
end

# ---------------------------------------------------------------------------
#                       NUTS replica and gradient accuracy
# ---------------------------------------------------------------------------

"""
    gradient_w(seed, sp, w; l = F.PROFILE(), tol = F.EXCL_VOL_CORR_TOL) -> Vector{Float64}

∇_w log π(θ(w)) as NUTS computes it, with c1 profiled to `tol`.

# Arguments
- `seed::Inference.Seed`, `sp`: the seed and its `_SamplingSpace` (whitening).
- `w`: a point in NUTS coordinates.

# Returns
- The gradient, one `ForwardDiff` pass.

# Exceptions
- `WLSError` if the model curve is flat at `w`.
"""
gradient_w(seed, sp, w; l = F.PROFILE(), tol = F.EXCL_VOL_CORR_TOL) =
    ForwardDiff.gradient(
        x -> F._logπ(F._θ_of_w(SVector{4,eltype(x)}(x...), sp), seed.pr, seed.wls, seed.fw, l;
            tab = seed.c1tab, c1_tol = tol),
        collect(Float64, w))

"""
    nuts_replica(seed; l, c1_tol, n_samples, n_adapt, δ, rng_seed, sp) -> NamedTuple

`infer` re-implemented step for step (MAP search and whitening, then NUTS with the same
adaptor), but with the c1 profiling tolerance `c1_tol` chosen by the caller and the adapted
metric, step size and per-iteration statistics returned. With `rng_seed === nothing` the global RNG
is left alone, so a call right after `F._sampling_space(seed, l)` is bit-identical to `infer`.

# Arguments
- `seed::Inference.Seed`.

# Keywords
- `l = F.PROFILE()`, `n_samples = Pipeline.DEFAULT_N_SAMPLES`, `n_adapt = Pipeline.DEFAULT_N_ADAPT` (the `run_model` defaults), `δ = 0.8` (target acceptance).
- `c1_tol = F.EXCL_VOL_CORR_TOL`: tolerance for the NUTS log density and gradient (the MAP search
    always uses the package default).
- `rng_seed = nothing`: `Random.seed!` this before NUTS.
- `sp = F._sampling_space(seed, l)`: reuse a whitening already computed.

# Returns
- `(; sp, ε0, ε, W, post, stats, seconds, n_leapfrog)`: `W` all draws (4 × n_samples) in w,
    `post` the post-warmup columns, `stats` AdvancedHMC's per-iteration statistics.

# Exceptions
- `ArgumentError` if `n_adapt ≥ n_samples`.
"""
function nuts_replica(seed::F.Seed; l = F.PROFILE(), c1_tol = F.EXCL_VOL_CORR_TOL, n_samples = R.DEFAULT_N_SAMPLES,
    n_adapt = R.DEFAULT_N_ADAPT, δ = 0.8, rng_seed = nothing, sp = F._sampling_space(seed, l))
    n_adapt < n_samples || throw(ArgumentError("n_adapt must be < n_samples"))
    ℓπ = w -> F._logπ(F._θ_of_w(SVector{4,eltype(w)}(w...), sp), seed.pr, seed.wls, seed.fw, l;
        tab = seed.c1tab, c1_tol = c1_tol)
    ∂ = w -> begin
        r = DiffResults.GradientResult(w)
        ForwardDiff.gradient!(r, ℓπ, w)
        (DiffResults.value(r), DiffResults.gradient(r))
    end
    metric = F.DenseEuclideanMetric(4)
    ham = F.Hamiltonian(metric, ℓπ, ∂)
    ε0 = F.find_good_stepsize(ham, zeros(4))
    integ = F.Leapfrog(ε0)
    adaptor = F.StanHMCAdaptor(F.MassMatrixAdaptor(metric), F.StepSizeAdaptor(δ, integ))
    kernel = F.HMCKernel(F.Trajectory{F.MultinomialTS}(integ, F.GeneralisedNoUTurn()))
    rng_seed === nothing || Random.seed!(rng_seed)
    seconds = @elapsed samples, stats = F.sample(ham, kernel, zeros(4), n_samples, adaptor, n_adapt; progress = false, verbose = false)
    W = reduce(hcat, samples)
    return (; sp, ε0, ε = stats[end].step_size, W, post = W[:, n_adapt+1:end], stats,
        seconds, n_leapfrog = sum(getproperty.(stats, :n_steps)))
end

"""
    gradient_noise(seed, sp, W; l, tol, ref_tol, n) -> NamedTuple

How wrong NUTS's gradient is because c1 is only profiled to `tol`: at `n` evenly spaced columns of
`W`, ‖∇ℓπ(tol) − ∇ℓπ(ref_tol)‖₂ in w coordinates, next to the true gradient norm. In w the posterior
is ≈ N(0, I), so a gradient error comparable to 1 is as large as the force NUTS is integrating.

# Arguments
- `seed`, `sp`, `W`: the seed, its whitening, and draws (columns) in w.

# Keywords
- `l = F.PROFILE()`, `tol = F.EXCL_VOL_CORR_TOL`, `ref_tol = 1e-11`, `n = 40`.

# Returns
- `(; noise, grad_norm)`: vectors of length `n`.

# Exceptions
- `WLSError` if a draw has a flat model curve.
"""
function gradient_noise(seed, sp, W; l = F.PROFILE(), tol = F.EXCL_VOL_CORR_TOL, ref_tol = 1e-11, n = 40)
    idx = unique(round.(Int, range(1, size(W, 2), length = n)))
    ref = [gradient_w(seed, sp, W[:, k]; l, tol = ref_tol) for k in idx]
    noise = [norm(gradient_w(seed, sp, W[:, k]; l, tol) .- r) for (k, r) in zip(idx, ref)]
    return (; noise, grad_norm = norm.(ref))
end

"""
    local_curvature(seed, sp, W; l, tol, n, step) -> NamedTuple

Extreme eigenvalues of the Hessian of −ℓπ in w at `n` evenly spaced columns of `W`, by central
differences of the gradient (use a tight `tol`: the Hessian divides gradient error by `step`).
Leapfrog is stable only for ε < 2/√λ_max, so these bound the step size the geometry allows
independently of any gradient error.

# Returns
- `(; λmax, λmin)`: vectors of length `n` (negative `λmin` means locally non-convex).

# Exceptions
- `WLSError` if a probe point has a flat model curve.
"""
function local_curvature(seed, sp, W; l = F.PROFILE(), tol = 1e-11, n = 40, step = 0.05)
    idx = unique(round.(Int, range(1, size(W, 2), length = n)))
    λmax = Float64[]; λmin = Float64[]
    for k in idx
        w = W[:, k]
        cols = ntuple(4) do i
            e = zeros(4); e[i] = step
            (-gradient_w(seed, sp, w .+ e; l, tol) .+ gradient_w(seed, sp, w .- e; l, tol)) ./ (2step)
        end
        H = hcat(cols...)
        ev = eigvals(Symmetric((H + H') / 2))
        push!(λmax, ev[end]); push!(λmin, ev[1])
    end
    return (; λmax, λmin)
end

# ---------------------------------------------------------------------------
#                          MAP search, modes, Hessian
# ---------------------------------------------------------------------------

"""
    lbfgs_starts(seed; l, n_starts, rng_seed, ref_tol) -> Vector{NamedTuple}

The MAP search's L-BFGS starts replayed one by one (the seed's θ₀, then prior draws), recording how
each stopped. `grad_gap` is ‖∇f(tol) − ∇f(ref_tol)‖∞ at the stopping point (z space): when it is
larger than `F.MAP_G_TOL` the optimizer cannot be told apart from converged by its gradient.

# Keywords
- `l = F.PROFILE()`, `n_starts = F.MAP_N_STARTS`, `rng_seed = nothing`, `ref_tol = 1e-11`.

# Returns
- One `(; start, z, f, iters, g_converged, f_converged, iteration_limit, grad_gap, c1, ξ)` per
    feasible start.

# Exceptions
- None; infeasible starts are skipped.
"""
function lbfgs_starts(seed::F.Seed; l = F.PROFILE(), n_starts = F.MAP_N_STARTS, rng_seed = nothing, ref_tol = 1e-11)
    μ, σ, ξ_of = _space(seed)
    f0 = z -> F._neglogπ(SVector{4}(z...), μ, σ, seed, l, F.EXCL_VOL_CORR_TOL)
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
    zs = vcat([z₀], [F._standardize(F.Θ(F._ξ₀(seed.pr), seed.pr)[1], seed.pr) for _ in 2:n_starts])
    out = NamedTuple[]
    for (i, z) in enumerate(zs)
        isfinite(f0(Vector(z))) || continue
        res = F.optimize(F.OnceDifferentiable(f0, g!, fg!, Vector(z)), Vector(z), F.LBFGS(), opts)
        ẑ = SVector{4}(F.Optim.minimizer(res)...)
        gap = maximum(abs, F._neglogπ_grad(ẑ, μ, σ, seed, l, F.EXCL_VOL_CORR_TOL) .-
                           F._neglogπ_grad(ẑ, μ, σ, seed, l, ref_tol))
        c1 = F.profiled_corrs(seed.wls, ξ_of(ẑ), seed.fw; tables = seed.c1tab, tol = ref_tol)[3]
        push!(out, (; start = i, z = ẑ, f = F.Optim.minimum(res), iters = F.Optim.iterations(res),
            g_converged = F.Optim.g_converged(res), f_converged = F.Optim.f_converged(res),
            iteration_limit = F.Optim.iteration_limit_reached(res), grad_gap = gap, c1, ξ = ξ_of(ẑ)))
    end
    return out
end

"""
    hessian_sensitivity(seed, ẑ; l, rels) -> NamedTuple

Eigenvalues of the MAP Hessian of −log π (z space) from the first pass (absolute step
`F.MAP_HESS_STEP`) and from second passes at each `rels` × the Laplace σ. Eigenvalues that move with
the step size mean the finite differences are measuring noise, not curvature.

# Returns
- `(; pass1, pass2, σ_lap)`: `pass1` eigenvalues, `pass2` a `Dict(rel => eigenvalues)`, `σ_lap` the
    first-pass Laplace σ per coordinate.

# Exceptions
- None; non-finite Hessians give `NaN` eigenvalues.
"""
function hessian_sensitivity(seed::F.Seed, ẑ; l = F.PROFILE(), rels = (0.3, 0.1, 0.03, 0.01))
    μ, σ, _ = _space(seed)
    H1 = F._fd_hessian(SVector{4}(ẑ...), F.MAP_HESS_STEP .* ones(SVector{4,Float64}), μ, σ, seed, l)
    ev(H) = all(isfinite, H) ? eigvals(Symmetric(Matrix(H))) : fill(NaN, 4)
    λ1, V1 = F._floored_eigen(H1)
    σ_lap = sqrt.(diag(V1 * ((1 ./ λ1) .* V1')))
    pass2 = Dict(r => ev(F._fd_hessian(SVector{4}(ẑ...), r .* σ_lap, μ, σ, seed, l)) for r in rels)
    return (; pass1 = ev(H1), pass2, σ_lap)
end

"""
    mode_table(seed, optima, sp; l) -> Vector{NamedTuple}

Distinct optima (Mahalanobis distance > `F.MAP_MODE_SEP` under the MAP Hessian) with the Laplace
log-mass −f − ½ log det H of each, so a mode that merely exists can be told from one that carries
posterior probability.

# Arguments
- `optima`: `lbfgs_starts` output. `sp`: the seed's `_SamplingSpace`.

# Returns
- `(; z, f, λ, log_mass)` per mode, best first; `log_mass` is `NaN` if the Hessian there is not
    positive definite.

# Exceptions
- None.
"""
function mode_table(seed::F.Seed, optima, sp; l = F.PROFILE())
    μ, σ, _ = _space(seed)
    Hf = Symmetric(Matrix(inv(sp.S * sp.S')))
    modes = NamedTuple[]
    for o in sort(optima, by = x -> x.f)
        any(m -> sqrt((o.z - m.z)' * Hf * (o.z - m.z)) ≤ F.MAP_MODE_SEP, modes) || push!(modes, (; z = o.z, f = o.f))
    end
    return map(modes) do m
        H = F._fd_hessian(m.z, 1e-3 .* ones(SVector{4,Float64}), μ, σ, seed, l)
        λ = all(isfinite, H) ? eigvals(Symmetric(Matrix(H))) : fill(NaN, 4)
        (; m.z, m.f, λ, log_mass = all(>(0), λ) ? -m.f - 0.5 * sum(log, λ) : NaN)
    end
end

"""
    axis_scan(seed, sp; l, svals, grid, h) -> Vector{NamedTuple}

Shape of −log π along each whitened axis of the MAP: `ratio[s] = Δf / (s²/2)` at each of `svals`
(1 for a Gaussian; < 1 or > 1 means a flatter or steeper wall), and over `grid` points in [−3, 3]
the largest disagreement between the production and a tight c1 tolerance (`noise`), the second
difference `f''` (a kink shows as `f''` ≫ its median), and how far c1* moves (`c1_jumps` counts
steps above 5e-3, a regime switch).

# Returns
- One `(; axis, svals, ratio, noise, f2_median, f2_max, f2_at, c1_range, c1_jumps)` per axis.

# Exceptions
- None.
"""
function axis_scan(seed::F.Seed, sp; l = F.PROFILE(), svals = (-10, -5, -3, -2, -1, -0.5, 0.5, 1, 2, 3, 5, 10),
    grid = 241, h = 6 / (grid - 1), ref_tol = 1e-11)
    _, _, ξ_of = _space(seed)
    f(z, tol) = _fz(seed, z, tol, l)
    fmin = f(sp.ẑ, ref_tol)
    ss = range(-3, 3, length = grid)
    map(1:4) do i
        ratio = [(f(sp.ẑ + sp.S[:, i] * s, ref_tol) - fmin) / (s^2 / 2) for s in svals]
        fc = Float64[]; ff = Float64[]; c1s = Float64[]
        for s in ss
            z = sp.ẑ + sp.S[:, i] * s
            push!(fc, f(z, F.EXCL_VOL_CORR_TOL)); push!(ff, f(z, ref_tol))
            push!(c1s, try F.profiled_corrs(seed.wls, ξ_of(z), seed.fw; tables = seed.c1tab, tol = F.EXCL_VOL_CORR_TOL)[3] catch; NaN end)
        end
        d2 = [(ff[k+1] - 2ff[k] + ff[k-1]) / h^2 for k in 2:length(ff)-1]
        a = abs.(d2); fin = filter(isfinite, a)
        km = argmax(replace(a, NaN => -Inf))
        c1ok = filter(isfinite, c1s)
        (; axis = i, svals, ratio, noise = maximum(abs.(fc .- ff)), f2_median = median(fin), f2_max = maximum(fin),
            f2_at = ss[km+1], c1_range = extrema(c1ok), c1_jumps = count(abs.(diff(c1s)) .> 5e-3))
    end
end

# ---------------------------------------------------------------------------
#                       what the shell contrasts buy
# ---------------------------------------------------------------------------

"""
    shell_contrast_ablation(seed; l, tol) -> NamedTuple

Nested models on the same structure, buffer and data, with c1, scale and background profiled:

- `M1`: one shared contrast δρ₁ = δρ₂ = δρ₃ = d (the single hydration-shell contrast of CRYSOL);
- `M2`: δρ₁ = δρ₂ = d₁₂ and a free δρ₃;
- `M3`: the full model at the pipeline's MAP.

ρₑ is held at its prior median in M1 and M2 (its prior σ is 0.01–0.1 %, so M3 barely moves it). M1 and
M2 are grid searches (481 points; 121 × 121), so M3 ≤ M2 ≤ M1 holds up to grid resolution and
L-BFGS convergence, not exactly.

# Returns
- `(; M1, M2, M3)`, each `(; chi2, ...)` with the reduced χ² and the optimum found.

# Exceptions
- None; probe points with a flat model curve count as infinite χ².
"""
function shell_contrast_ablation(seed::F.Seed; l = F.PROFILE(), tol = F.EXCL_VOL_CORR_TOL)
    μ, σ, ξ_of = _space(seed)
    pr = seed.pr
    ρ0 = exp(μ[1])
    χ(ξ) = try
        _, fit, c1 = F.profiled_corrs(seed.wls, SVector{4}(ξ...), seed.fw; tables = seed.c1tab, tol)
        (F.reduced_chi2(fit), c1)
    catch
        (Inf, NaN)
    end
    lo3, hi3 = pr.δρ₃Prior.μ, pr.δρ₃Prior.μ + pr.δρ₃Prior.σ
    m1 = (chi2 = Inf, d = NaN, c1 = NaN)
    for d in range(F.LOWER_BOUND_δρ₁₂, F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂, length = 481)
        c, c1 = χ((ρ0, d, d, d))
        c < m1.chi2 && (m1 = (chi2 = c, d, c1))
    end
    m2 = (chi2 = Inf, d12 = NaN, d3 = NaN, c1 = NaN)
    for d12 in range(F.LOWER_BOUND_δρ₁₂, F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂, length = 121), d3 in range(lo3, hi3, length = 121)
        c, c1 = χ((ρ0, d12, d12, d3))
        c < m2.chi2 && (m2 = (chi2 = c, d12, d3, c1))
    end
    sp = F._sampling_space(seed, l)
    ξ3 = ξ_of(sp.ẑ)
    c3, c13 = χ(ξ3)
    return (; M1 = m1, M2 = m2, M3 = (chi2 = c3, ξ = ξ3, c1 = c13))
end

"""
    curve_chi2(q, I, σ, q_ref, I_ref) -> NamedTuple

Reduced χ² of a reference curve (a CRYSOL / OLIGOMER / EOM `.fit` column) on the data points it
covers, linearly interpolated: as given (`raw`), and with a free scale and offset (`fitted`, 2 fewer
degrees of freedom), so curves in a different normalization compare fairly.

# Returns
- `(; n, raw, fitted)`.

# Exceptions
- `ArgumentError` if the reference covers no data point.
"""
function curve_chi2(q, I, σ, q_ref, I_ref)
    p = sortperm(q_ref); qf = q_ref[p]; If = I_ref[p]
    ok = [qf[1] ≤ x ≤ qf[end] for x in q]
    any(ok) || throw(ArgumentError("the reference curve covers none of the data points"))
    Ii = map(q[ok]) do x
        j = clamp(searchsortedlast(qf, x), 1, length(qf) - 1)
        w = (x - qf[j]) / (qf[j+1] - qf[j])
        If[j] * (1 - w) + If[j+1] * w
    end
    y = I[ok]; s = σ[ok]; n = length(y)
    raw = sum(((y .- Ii) ./ s) .^ 2) / n
    X = hcat(Ii, ones(n))
    β = (X ./ s) \ (y ./ s)   # weighted least squares by QR: the normal equations square the condition number
    return (; n, raw, fitted = sum(((y .- X * β) ./ s) .^ 2) / (n - 2))
end

# ---------------------------------------------------------------------------
#                                    reports
# ---------------------------------------------------------------------------

"""
    diagnose(io, seed; label, reference, l, n_samples, n_adapt)

Full sampler diagnosis of one seed, written to `io`: MAP starts and how they stopped, Hessian
sensitivity, the NUTS replica (step size, tree depth, posterior sd and Laplace agreement in w,
ESS), bound proximity, shape along the whitened axes, modes and their Laplace mass, whether L-BFGS's
mode is the best point NUTS found, gradient error from the c1 tolerance, and local curvature along the chain.

# Arguments
- `io`, `seed`.

# Keywords
- `label = ""`, `l = F.PROFILE()`, `n_samples`, `n_adapt` (default: the `run_model` defaults, `Pipeline.DEFAULT_N_SAMPLES`, `DEFAULT_N_ADAPT`).
- `reference = nothing`: `(; q, I, σ, q_ref, I_ref)` to add the reference curve's χ² on the same points.

# Returns
- `nothing`.

# Exceptions
- None beyond those of the functions it calls.
"""
function diagnose(io::IO, seed::F.Seed; label = "", reference = nothing, l = F.PROFILE(),
    n_samples = R.DEFAULT_N_SAMPLES, n_adapt = R.DEFAULT_N_ADAPT)
    p(args...) = (println(io, args...); flush(io))
    pr = seed.pr
    μ, σ, ξ_of = _space(seed)
    p("="^100)
    p("$label   n_q=$(length(seed.fw.qvals))  n_atoms=$(seed.fw.n_atoms)  lMax=$(seed.fw.lMax)  c1 tol=$(F.EXCL_VOL_CORR_TOL)")
    p("δρ₃ support = [", @sprintf("%.4g", pr.δρ₃Prior.μ), ", ", @sprintf("%.4g", pr.δρ₃Prior.μ + pr.δρ₃Prior.σ),
        "]   δρ₁,₂ support = [", F.LOWER_BOUND_δρ₁₂, ", ", F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂, "]")
    if reference !== nothing
        c = curve_chi2(reference.q, reference.I, reference.σ, reference.q_ref, reference.I_ref)
        p(@sprintf("reference curve on our q-set (n=%d): χ²_red raw = %.3f, with free scale+offset = %.3f", c.n, c.raw, c.fitted))
    end

    t_map = @elapsed sp = F._sampling_space(seed, l)
    p(@sprintf("MAP search: %.1fs  n_ok=%d/%d  n_modes=%d  whitened=%s", t_map, sp.n_ok, F.MAP_N_STARTS, sp.n_modes, sp.whitened))
    r = nuts_replica(seed; l, n_samples, n_adapt, sp)
    st = r.stats[n_adapt+1:end]
    ns = getproperty.(r.stats, :n_steps); dp = getproperty.(r.stats, :tree_depth)
    post = r.post
    p(@sprintf("NUTS: %.1fs  init ε=%.4g  final ε=%.4g  mean n_steps=%.1f  mean depth=%.2f  frac(depth≥10)=%.3f  diverged=%d",
        r.seconds, r.ε0, r.ε, mean(ns[n_adapt+1:end]), mean(dp[n_adapt+1:end]), mean(dp[n_adapt+1:end] .>= 10),
        count(getproperty.(st, :numerical_error))))
    # Stan's warmup phases (initial buffer, doubling windows, final buffer), then sampling; clipped to the run
    wins = [(a, min(b, n_samples)) for (a, b) in ((1, 75), (76, 450), (451, n_adapt - 50), (n_adapt - 49, n_adapt), (n_adapt + 1, n_samples))
            if a ≤ min(b, n_samples) && b ≤ n_samples + 450]
    p("mean n_steps by window: ", join((@sprintf("[%d:%d]=%.0f", a, b, mean(ns[a:b])) for (a, b) in wins), "  "))
    p(@sprintf("mean accept = %.3f   mean |ΔH| = %.3f", mean(getproperty.(st, :acceptance_rate)),
        mean(abs.(getproperty.(st, :hamiltonian_energy_error)))))
    Σw = cov(post')
    p("post-warmup w: sd = ", _vs(std(post, dims = 2)), "   (1 = the Laplace whitening is right)")
    p("  cov(w) eigenvalues = ", _vs(eigvals(Symmetric(Σw))), "   skew = ", _vs([_skew(post[i, :]) for i in 1:4]),
        "   ESS = ", _vs([ess(post[i, :]) for i in 1:4]))
    ℓ0 = F._logπ(F._θ_of_w(SVector{4}(0.0, 0.0, 0.0, 0.0), sp), pr, seed.wls, seed.fw, l; tab = seed.c1tab)
    ℓs = getproperty.(st, :log_density)
    p(@sprintf("ℓπ at L-BFGS mode = %.4f   best draw = %.4f   median draw = %.4f   (4-D Gaussian: median ≈ mode − 1.7)", ℓ0, maximum(ℓs), median(ℓs)))

    # distance to the support bounds
    ξs = [F.Ξ(F._θ_of_w(SVector{4}(post[:, k]...), sp), pr) for k in 1:size(post, 2)]
    bnd = ((0.0, Inf), (F.LOWER_BOUND_δρ₁₂, F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂), (F.LOWER_BOUND_δρ₁₂, F.LOWER_BOUND_δρ₁₂ + F.WIDTH_δρ₁₂),
        (pr.δρ₃Prior.μ, pr.δρ₃Prior.μ + pr.δρ₃Prior.σ))
    p("coordinate   median ξ       sd ξ     distance to nearest support bound / sd")
    for (k, nm) in enumerate(("ρₑ", "δρ₁", "δρ₂", "δρ₃"))
        xs = getindex.(ξs, k); lo, hi = bnd[k]
        p(@sprintf("  %-5s %12.5g %11.3g     %10.3g", nm, median(xs), std(xs), min(median(xs) - lo, hi - median(xs)) / std(xs)))
    end

    starts = lbfgs_starts(seed; l, rng_seed = 12345)
    p("L-BFGS starts (z space):")
    for o in starts
        p(@sprintf("  start %d: f=%.4f iters=%3d g_conv=%s iter_limit=%s |∇f(tol) − ∇f(ref)|∞=%.2e c1=%.4f",
            o.start, o.f, o.iters, o.g_converged, o.iteration_limit, o.grad_gap, o.c1))
    end
    hs = hessian_sensitivity(seed, sp.ẑ; l)
    p("MAP Hessian eigenvalues (floor ", F.MAP_HESS_EIG_FLOOR, "): pass 1 = ", _vs(hs.pass1))
    for rel in sort(collect(keys(hs.pass2)); rev = true)
        p(@sprintf("  pass 2, step %.2f·σ_lap: ", rel), _vs(hs.pass2[rel]))
    end
    Zs = reduce(hcat, [sp.ẑ + sp.S * post[:, k] for k in 1:size(post, 2)])
    p("sampled sd in z / Laplace σ_z = ", _vs(vec(std(Zs, dims = 2)) ./ sqrt.(diag(sp.S * sp.S'))))
    p("Δf/(s²/2) along whitened axes (1 = Gaussian), s = ", join(("$s" for s in (-10, -5, -3, -2, -1, -0.5, 0.5, 1, 2, 3, 5, 10)), ","))
    scans = axis_scan(seed, sp; l)
    for a in scans
        p("  w$(a.axis): ", join((@sprintf("%8.3g", x) for x in a.ratio), " "))
    end
    for a in scans
        p(@sprintf("  w%d scan: c1-tol noise=%.2e  f''(median)=%.3g f''(max)=%.3g at s=%.2f  c1 range=[%.4f,%.4f] jumps=%d",
            a.axis, a.noise, a.f2_median, a.f2_max, a.f2_at, a.c1_range..., a.c1_jumps))
    end
    modes = mode_table(seed, starts, sp; l)
    p("distinct optima: ", length(modes))
    for (k, m) in enumerate(modes)
        p(@sprintf("  mode %d: f=%.3f ξ=%s  H-eig=%s  log Laplace mass=%.3f (Δ vs best = %.3g nats)", k, m.f, _vs(ξ_of(m.z)), _vs(m.λ), m.log_mass, m.log_mass - modes[1].log_mass))
    end
    gn = gradient_noise(seed, sp, post; l)
    p("gradient error from the c1 tolerance in w: min/median/max = ", _vs([minimum(gn.noise), median(gn.noise), maximum(gn.noise)]),
        "  vs |∇ℓπ| median = ", @sprintf("%.3g", median(gn.grad_norm)), "   (posterior-scale gradient ≈ 1)")
    lc = local_curvature(seed, sp, post; l)
    p("local λ_max(−∇²ℓπ) min/median/max = ", _vs([minimum(lc.λmax), median(lc.λmax), maximum(lc.λmax)]),
        "  → stable ε < ", _vs(2 ./ sqrt.([maximum(lc.λmax), median(lc.λmax)])), " (worst, median);  adapted ε = ", @sprintf("%.4g", r.ε))
    return nothing
end

"""
    tolerance_sweep(io, seed; label, tols, rng_seeds, l, n_samples, n_adapt)

NUTS replica at each c1 profiling tolerance in `tols` and each RNG seed in `rng_seeds` (same MAP
and whitening throughout), one line each: wall time, final ε, steps per iteration, ms per step,
ESS, divergent transitions and posterior sd in w. Shows whether a tolerance is tight enough for the gradient it feeds NUTS.

# Returns
- A vector of `(; tol, rng_seed, seconds, ε, steps, ms_step, min_ess, div)` (`div`: divergent post-warmup transitions).

# Exceptions
- None beyond those of [`nuts_replica`](@ref).
"""
function tolerance_sweep(io::IO, seed::F.Seed; label = "", tols = (1e-5, 1e-8), rng_seeds = (7,),
    l = F.PROFILE(), n_samples = R.DEFAULT_N_SAMPLES, n_adapt = R.DEFAULT_N_ADAPT)
    sp = F._sampling_space(seed, l)
    out = NamedTuple[]
    for tol in tols, rs in rng_seeds
        r = nuts_replica(seed; l, c1_tol = tol, n_samples, n_adapt, rng_seed = rs, sp)
        st = r.stats[n_adapt+1:end]
        steps = mean(getproperty.(st, :n_steps))
        mins = minimum(ess(r.post[i, :]) for i in 1:4)
        div = count(getproperty.(st, :numerical_error))
        row = (; tol, rng_seed = rs, seconds = r.seconds, ε = r.ε, steps, ms_step = 1000r.seconds / r.n_leapfrog, min_ess = mins, div)
        push!(out, row)
        println(io, @sprintf("%s tol=%.0e seed=%s  NUTS=%6.1fs  ε=%.4f  n_steps=%7.1f  ms/step=%.3f  minESS=%6.1f  div=%d  sd(w)=%s  |ΔH|=%.3f",
            label, tol, rs, r.seconds, r.ε, steps, row.ms_step, mins, div, _vs(std(r.post, dims = 2)),
            mean(abs.(getproperty.(st, :hamiltonian_energy_error)))))
        flush(io)
    end
    return out
end

# Posterior summary of a block of draws (rows: parameters) against a reference block: the largest mean shift in
# reference sd units, the largest |log sd ratio|, the smallest ESS.
function _vs_reference(P, μr, σr)
    dm = maximum(abs.(vec(mean(P, dims = 2)) .- μr) ./ σr)
    ds = maximum(abs.(log.(vec(std(P, dims = 2)) ./ σr)))
    return (; dm, ds, min_ess = minimum(ess(P[i, :]) for i in 1:size(P, 1)))
end

"""
    warmup_study(io, seed; label, adapts, n_post, n_ref, n_adapt_ref, rng_seeds, l) -> NamedTuple

How short can the warm-up be, and how many draws are enough? One long reference run (`n_adapt_ref` = 1000 adaptation
iterations, then `n_ref` draws) fixes the posterior in w. Then (1) `WARMUP` lines: its step size ε at
chosen warm-up iterations (Stan's windowed schedule resets the step-size averaging at each window
end); (2) `ADAPT` lines: runs with `a` adaptation iterations in `adapts` and `n_post` draws each, per
RNG seed: final ε, steps per iteration, divergent fraction, smallest ESS, ESS per gradient evaluation,
and the largest mean shift (reference sd units) and |log sd ratio| against the reference; (3) `DRAWS`
lines: the same statistics on the first `n` draws of the reference (biased low, those draws are part of
the reference), and the first `n` in steps of 100 with smallest ESS ≥ 400.

# Returns
- `(; trace, adapt, draws, n_ess400)`.

# Exceptions
- None beyond those of [`nuts_replica`](@ref).
"""
function warmup_study(io::IO, seed::F.Seed; label = "", adapts = (50, 100, 200, 300, 500, 1000), n_post = 1000,
    n_ref = 4000, n_adapt_ref = 1000, rng_seeds = (7,), l = F.PROFILE())
    sp = F._sampling_space(seed, l)
    ref = nuts_replica(seed; l, n_samples = n_adapt_ref + n_ref, n_adapt = n_adapt_ref, rng_seed = 101, sp)
    R = ref.post
    μr = vec(mean(R, dims = 2)); σr = vec(std(R, dims = 2))
    marks = filter(≤(n_adapt_ref), (10, 25, 50, 75, 100, 150, 250, 450, 950, 1000))
    trace = [(i, ref.stats[i].step_size) for i in marks]
    println(io, label, " WARMUP  ", join((@sprintf("%d:%.4f", i, e) for (i, e) in trace), "  "),
        @sprintf("  final=%.4f  steps/it=%.1f", ref.ε, mean(getproperty.(ref.stats[n_adapt_ref+1:end], :n_steps))))
    adapt = NamedTuple[]
    for a in adapts, rs in rng_seeds
        r = nuts_replica(seed; l, n_samples = a + n_post, n_adapt = a, rng_seed = rs, sp)
        st = r.stats[a+1:end]
        steps = mean(getproperty.(st, :n_steps))
        v = _vs_reference(r.post, μr, σr)
        row = (; a, rng_seed = rs, ε = r.ε, steps, div = mean(getproperty.(st, :numerical_error)),
            v.min_ess, ess_per_grad = v.min_ess / sum(getproperty.(st, :n_steps)), v.dm, v.ds, seconds = r.seconds)
        push!(adapt, row)
        println(io, @sprintf("%s ADAPT  a=%4d seed=%s  ε=%.4f  steps=%6.1f  div=%.4f  minESS=%7.1f  ess/grad=%.5f  dm=%.3f  dsd=%.3f  t=%.2fs",
            label, a, rs, row.ε, steps, row.div, row.min_ess, row.ess_per_grad, row.dm, row.ds, row.seconds))
    end
    draws = NamedTuple[]
    for n in (100, 250, 500, 1000, 2000, n_ref)
        n ≤ size(R, 2) || continue
        v = _vs_reference(R[:, 1:n], μr, σr)
        push!(draws, (; n, v...))
        println(io, @sprintf("%s DRAWS  n=%5d  minESS=%7.1f  dm=%.3f  dsd=%.3f", label, n, v.min_ess, v.dm, v.ds))
    end
    n_ess400 = nothing
    for n in 100:100:size(R, 2)
        if minimum(ess(R[i, 1:n]) for i in 1:size(R, 1)) ≥ 400
            n_ess400 = n
            break
        end
    end
    println(io, label, " ESS400  first n with min ESS ≥ 400: ", n_ess400 === nothing ? "none within $(size(R, 2))" : n_ess400)
    return (; trace, adapt, draws, n_ess400)
end

end # module SeedDiagnostics
