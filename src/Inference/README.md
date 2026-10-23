# Inference

Given a measured curve `I_exp(q) ± σ_exp(q)` and the geometry-only `ForwardCache` of `Scattering`, sample the posterior of four physical parameters with NUTS ([AdvancedHMC.jl](https://github.com/TuringLang/AdvancedHMC.jl)). Scale, background and CRYSOL's excluded-volume correction `c1` are nuisance parameters removed by profiling at every evaluation, so the sampled density is a *profiled pseudo-posterior* (see "Profiling is not marginalising").

## Parameters

`ξ = (ρₑ, δρ₁, δρ₂, δρ₃)`:

- `ρₑ ∈ (0, ∞)`: electron density of the **buffer** (CRYSOL's dns).
- `δρ₁, δρ₂ ∈ (−10, 2)`: convex and concave hydration-shell contrasts, in units of `UNIT_OF_δρ = 0.03 e·Å⁻³`.
- `δρ₃ ∈ (−ρ̄ₑ/0.03, (φ_max − 1)·ρ̄ₑ/0.03)`: cavity contrast, written through the cavity occupancy `φ = ρ_cavity/ρₑ` as `δρ₃ = (φ − 1)ρₑ/0.03`. `φ` only derives the bounds; it is not sampled.

`c1` is not part of `ξ`: it is a mean-field bookkeeping factor (one population-mean radius `r_m` over per-atom volumes), not an identifiable physical unknown, so no defensible prior width exists. Scale `m` and background `b` (`I_calc = m·ĥ + b`) are linear and solved in closed form.

The sampler, MAP search, likelihood and report are generic in the number `N` of sampled parameters (`Seed{T,N}`, `Inferred{S,N}`); only the transform `Θ`/`Ξ`, `θ_prior_moments` and the log-prior are specific to the four-parameter priors (`nparams`, `param_keys`). The Gram matrix stays five-species.

## Likelihood

### Scale and background (WLS)

With weights `wᵢ = 1/σᵢ²` and model values `hᵢ`, the objective `χ² = Σ wᵢ(yᵢ − m hᵢ − b)²` is quadratic in `(m, b)`, so the normal equations reduce to scalar sums `S_w, S_y, S_yy` (data only, precomputed in `WLSData`) and `S_h, S_hy, S_hh` (model, one O(Q) pass):

```math
D=S_{hh}S_w-S_h^2,\quad \hat m=\frac{S_{hy}S_w-S_hS_y}{D},\quad \hat b=\frac{S_{hh}S_y-S_hS_{hy}}{D},\quad
\chi^2_{\min}=S_{yy}-\hat m S_{hy}-\hat b S_y
```

`D ≥ 0` by Cauchy–Schwarz, with equality only for a flat model; `wls_fit` throws `WLSError` for `D ≤ 0`, `n < 3` or `σᵢ ≤ 0`. Geometrically the fit projects the data onto `span{h, 1}`: `χ²_min = S_yy^c(1 − r²)` with `r` the weighted correlation of data and model, so the likelihood sees only the *shape* of the model curve (invariant under `h → αh + β`). Under a correct model `χ²_min ~ χ²_{Q−2}`, independent of `(m̂, b̂)`, whose covariance is `(XᵀWX)⁻¹`. `WLSFit` stores `dof = Q − 2`; the report's χ² is evaluated on the measured grid with `n_raw − 3` degrees of freedom (scale, background, `c1`), the FoXS/depositor convention. These are conventions, not exact degrees of freedom: the four sampled parameters are not subtracted.

The profiled log-likelihood (`wls_prof_ll`, fixed σ) is

```math
\ell(\xi)=-\tfrac12\chi^2_{\min}-\tfrac12\sum_i\ln\sigma_i^2-\tfrac Q2\ln 2\pi
```

### Profiling c1

At fixed `ξ`, `ĥ(q;c1) = A + g B + g² C` (see Scattering), so `profiled_corrs` builds `A, B, C` once and finds the `c1` minimising `χ²` in two gradient-free stages:

1. A **scan** over `(c_min−ε):ε:(c_max+ε)` (28 points at `EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)`, `ε = EXCL_VOL_CORR_EPS = 0.02`). The three model sums are polynomials in `g`; with `A_i, B_i, C_i, wᵢ, yᵢ` per point

   ```math
   S_h=\sum w A+\sum g\,(wB+g\,wC),\qquad
   S_{hh}=\sum wA^2+\sum g\big(2wAB+g\,(w(B^2{+}2AC)+g\,(2wBC+g\,wC^2))\big)
   ```

   (`S_hy` likewise), so after eight coefficient vectors are formed once each grid point is one fused SIMD Horner pass over `q`, `g` read from the table `_C1Tables.g1`.
2. **Brent's method** (`Optim.jl`) in the bracket of the best grid point's neighbours (the padded edge if it is first or last), to `EXCL_VOL_CORR_TOL = 1e-8`. Every `c1` visited lies within half a grid step of a grid point `cⱼ`, so `g(q;c1) = g(q;cⱼ)(c1/cⱼ)³ exp(−q²[k(c1)−k(cⱼ)])` and the exponential is a degree-8 Taylor polynomial (library `exp` beyond `ENVELOPE_TAYLOR_LIMIT`, error < 6e-18).

The scan exists because `χ²(c1)` need not be unimodal when `ξ` is far from the truth. It can miss a basin narrower than the grid step; a value outside `(c_min, c_max)` is reported by `excl_vol_saturation` (−1/+1) and is a diagnostic, not proof of a wrong model. The bounds are a hard window, not a prior, and saturating at them is intended.

**Why the tolerance is 1e-8.** By the envelope theorem (next section) the gradient is exact only at the exact `c1` optimum. For `ĉ = c* + δ`, `F(ξ,ĉ) − F(ξ,c*) = ½F_cc δ²` (second order) but `∇_ξF(ξ,ĉ) − ∇_ξF_prof = F_ξc δ` (**first order**). The spurious force does work `ΔH = −e·Δw` along a trajectory regardless of the step size, so the dual-averaging step size collapses (≈0.6 → 0.001–0.03) and trees grow to 100–1000 leapfrog steps. At 1e-5 six fits ran at the depth limit; the gradient error in whitened coordinates is 1.0–1.5 at 1e-5, 0.02–0.18 at 1e-6 and ≤ 0.007 at 1e-8 (costing ~1.24× per step). The same tolerance is used for the MAP search, its Hessian and every NUTS evaluation.

### Gradient

For `Φ(ξ, η)` maximised over nuisance `η`, `∇_ξ Φ_prof = ∇_ξΦ(ξ, η*)` (envelope theorem; Danskin's theorem extends it to a fixed compact set such as the `c1` window, even at the boundary, provided the maximiser is unique; it fails where two basins exchange dominance and the profile has a kink). With residuals `rᵢ = yᵢ − m hᵢ − b` and `pᵢ = wᵢrᵢ`,

```math
\frac{\partial\ell}{\partial\xi_k}=m\sum_i p_i\frac{\partial h_i}{\partial\xi_k},
```

assembled from 15 contractions of the packed Gram columns, `T^{(0)}=Σ p G_c`, `T^{(1)}=Σ p g G_c`, `T^{(2)}=Σ p g² G_c`:

```math
\frac{\partial\ell}{\partial\rho_e}=m\Big(-2\sum_i a_iT^{(1)}_{i,ex}+2\rho_eT^{(2)}_{ex,ex}\Big),\qquad
\frac{\partial\ell}{\partial\delta\rho_i}=2m\,u_\rho\Big(\sum_j a_jT^{(0)}_{ij}-\rho_eT^{(1)}_{i,ex}\Big)
```

The gradient is a **hybrid**: one `ForwardDiff.gradient!` over the whole target (prior, Jacobian, transform), with the likelihood injected through a method of `_ll` for ForwardDiff duals that evaluates `ℓ` and `g = ∇_ξℓ` analytically (`_profile_ll_grad`) and returns a Dual whose partials are `Σ_k g_k ∂ξ_k/∂u_j`, which is exactly the chain rule. The work vectors are Bumper-allocated (267 → 6 bytes per q point per call). Tested against ForwardDiff at fixed `c1` (rtol 1e-7), end to end (within the `c1` sensitivity) and against finite differences of the full log density.

**Information.** After eliminating `(m, b)` the Fisher information about `ξ` is `m² Jᵀ W^{1/2}(I − P)W^{1/2} J` with `J_k = ∂h/∂ξ_k` and `P` the projector onto `span{h, 1}`: a direction is constrained only through the part of `J_k` orthogonal to `{h, 1}` (and, with `c1` profiled, `∂h/∂c1`). `ρₑ` and `c1` act through the same excluded-volume Gram columns and are nearly degenerate; `δρ₃` with almost no cavity beads has `J ≈ 0` and samples its prior (the report's `cavity_frac` flags it). Eigenvalues of the information matrix in prior-standardised coordinates run from 1 to 9·10⁵ on the difficult fits.

### Profiling is not marginalising

Integrating `(m, b)` out under a flat prior gives `ℓ_marg = ℓ_prof − ½ ln D + ln 2π`, an Occam factor that is not invariant to the units of `h` (a flat prior on `m` is not flat on `m/λ`), whereas the profile is invariant under `h → λh + β`. In the Gaussian approximation both have the same width; they differ in location and shape through the variation of `ln D(ξ)`, which matters in weakly constrained directions. `c1` is profiled in both. The reported probabilities are posterior probabilities of `ξ` *given the profile construction*.

## Priors

`δρ_prior(κ_δρ₁₂, κ_δρ₃, ρ̄ₑ)` returns `LocationScale(L, W, Beta(α, β))` priors. For a Beta with mode `m_u` and concentration `κ = α + β − 2 > 0`:

```math
\alpha=1+\kappa m_u,\qquad \beta=1+\kappa(1-m_u)
```

- **δρ₁, δρ₂**: support `[−10, 2]` (`BOUNDS_δρ₁₂`, CRYSOL 3's limits), mode CRYSOL's default 1, `m_u = 11/12`, `α = 1 + 11κ/12`, `β = 1 + κ/12`. At `κ = 14`: Beta(13.83, 2.17), SD(δρ) ≈ 1.00 (the spread of the Normal(1, 1) it replaced), mean 0.375, median 0.56, `P(δρ<0)` ≈ 30 %. The mode of a skewed Beta is not its mean. Older single-shell CRYSOL fits in the fixtures report `Dro` ≈ 0.075–0.083 e·Å⁻³ (δρ ≈ 2.5–2.8), above the upper bound.
- **δρ₃**: bounds from `φ ∈ [0, φ_max]` with `ρₑ` fixed at the prior mean `ρ̄ₑ`: `L₃ = −ρ̄ₑ/u_ρ`, `W₃ = φ_max ρ̄ₑ/u_ρ` (`u_ρ = 0.03`), so `δρ₃ = (ρ̄ₑ/u_ρ)(φ_max u − 1)`. Mode at bulk density, `m_u = 1/φ_max`: `α = 1 + κ/φ_max`, `β = 1 + (1 − 1/φ_max)κ`. Defaults `κ = 1.25`, `φ_max = 1.25` give Beta(2, 1.25) on ≈ [−11.1, 2.8]: mean occupancy 0.77, `P(φ<1)` = 0.73, SD(δρ₃) = 3.3, a deliberately weak prior. Fixing `ρ̄ₑ` makes the support constant (no coupling to the sampled `ρₑ`, which would complicate the Jacobian); the implied `φ` can leave `[0, φ_max]` by the relative uncertainty of `ρₑ` (≤ 0.06 % on the buffers checked).
- **ρₑ**: `ρₑ_prior(pH, σ_pH, solutes; t)` takes `(μ, σ)` from `BulkElectronDensity.ρₑ` and returns the moment-matched LogNormal (`ρₑ > 0` is built in; for small `σ/μ` it is nearly Gaussian):

  ```math
  \sigma_{ln}^2=\ln\!\big(1+\sigma^2/\mu^2\big),\qquad \mu_{ln}=\ln\mu-\tfrac12\sigma_{ln}^2
  ```

  The solutes describe the buffer only: **never list the measured macromolecule** (buffer subtraction has removed it; other copies of it are separate scatterers whose displaced volume only shifts the baseline `b` absorbs). An empty list is pure water.

`_calc_ξ_priors` composes the four priors; `_ξ₀` draws an initial `ξ`.

## Coordinates

Four coordinate systems appear; confusing them is the commonest mistake.


| coordinates  | map                       | used by                            |
| -------------- | --------------------------- | ------------------------------------ |
| `ξ`         | `ξ = Ξ(θ)`             | priors, likelihood, reported draws |
| `θ ∈ ℝ⁴` | `θ = μ_θ + σ_θ ⊙ z` | transform, Jacobian, target        |
| `z`          | `z = ẑ + S w`            | L-BFGS, Hessian, Laplace           |
| `w`          | whitened                  | NUTS, bridge sampling              |

Only `Ξ` is nonlinear; the maps `θ ↔ z ↔ w` are affine with constant Jacobian, so densities in them differ by additive constants that cancel in every ratio (mass ratios, shares).

### ξ ↔ θ

 Hamiltonian trajectories need an unconstrained space. With `σ(t) = 1/(1+e⁻ᵗ)`:

```math
\theta=(a,t_1,t_2,t_3),\quad a=\ln\rho_e,\quad t_k=\mathrm{logit}\frac{\delta\rho_k-L_k}{W_k};\qquad
\Xi(\theta)=\big(e^a,\ L_k+W_k\,\sigma(t_k)\big)
```

The density of `θ` picks up the Jacobian, `log π(θ) = log p_ξ(Ξ(θ)) + log J(θ)` (omitting it samples `p_ξ/J`, shifting mass toward the bounds and small `ρₑ`), with `σ' = σ(1−σ)`:

```math
\log J=a+\sum_{k=1}^{3}\big[\ln W_k+\mathrm{loglogistic}(t_k)+\mathrm{loglogistic}(-t_k)\big]
```

evaluated with `loglogistic(t) = −log1p(e^{−t})` (`t ≥ 0`) or `t − log1p(e^t)` (`t < 0`), accurate at all `t`. A Beta prior in logit coordinates becomes

```math
\log p_t(t)=\alpha\,\mathrm{loglogistic}(t)+\beta\,\mathrm{loglogistic}(-t)-\ln B(\alpha,\beta)
```

(the `ln W_k` cancel), which is **strictly concave** with bounded force `α(1−σ) − βσ ∈ (−β, α)` and exponential tails `e^{−β t}`, `e^{−α|t|}`. The hard bounds therefore never become stiff walls: a likelihood pulling toward a bound meets only this bounded force, and draws pile up against it. With a pull `g` the balance point is `t* ≈ ln(W g/β)`, at distance ∝ `β/(Wg)` from the bound, with curvature `β` independent of `g`. A pinned posterior is a correct feature of the model. For `|t| ≳ 37`, `δρ` rounds to the bound in double precision and the finite-difference Hessian can fail to be positive definite (such an optimum carries no Laplace mass).

The sampled target, up to a constant, is

```math
\log\pi(\theta)=-\frac{(a-\mu_{ln})^2}{2\sigma_{ln}^2}+\sum_{k=1}^{3}\big[\alpha_k\,\mathrm{loglogistic}(t_k)+\beta_k\,\mathrm{loglogistic}(-t_k)\big]+\ell(\Xi(\theta))
```

(the `+a` of the Jacobian cancels the `−a` of the log-normal density, leaving a Normal in `a`). It is `_lp + _ll + logjac` in `Posterior.jl`. The prior part is concave; the likelihood is not (its Hessian is a Gauss–Newton term plus an indefinite residual term, `ℓ` is a pointwise maximum over `c1`, and `A` is quadratic in the contrasts, so the squared residual is quartic and can have several local minima). The posteriors are often multimodal. Modes of `π_θ` are not modes of `p_ξ` (they differ by `∇ log J`): the L-BFGS optimum and the reported MAP draw are modes of the sampled density.

### Standardisation

The coordinates have prior scales differing by orders of magnitude (`σ(ρₑ)` ~ 10⁻³–10⁻², `t` of order 1), so `θ ↦ z = (θ − μ_θ)/σ_θ` with the exact prior moments (`θ_prior_moments`): `a` is Normal, and for `t = logit u`, `u ~ Beta(α, β)`, the cumulant generating function `ln Γ(α+s) + ln Γ(β−s) − ln Γ(α) − ln Γ(β)` gives

```math
\mathbb E[t]=\psi(\alpha)-\psi(\beta),\qquad \mathrm{Var}[t]=\psi_1(\alpha)+\psi_1(\beta)
```

(defaults: shell 2.065 ± 0.812, cavity 0.650 ± 1.357). This equalises marginal prior scales; it does not remove correlations, and the posterior is often far narrower than the prior (σ_z down to ~10⁻⁴ along δρ₁/δρ₂).

## Mode search, Laplace approximation and whitening

Stan's windowed adaptation, which AdvancedHMC copies, starts from `M⁻¹ = I` and shrinks every covariance estimate toward `10⁻³ I` with weight `5/(n+5)`. For a true variance of 10⁻⁸ that regulariser is 10⁴–10⁵ times too large, forcing tiny steps and deep trees all through warm-up. `infer` therefore first calls `_sampling_space(seed, l)`:

1. **Multi-start L-BFGS** (`Optim.jl`, memory 10, Hager–Zhang line search) on `f(z) = −log π` from the seed's `ξ₀` and `MAP_N_STARTS − 1` further prior draws, then `MAP_JITTER_RADII × MAP_JITTER_DIRECTIONS` jittered starts around each of at most `MAP_JITTER_MAX_OPTIMA` optima within `MAP_JITTER_WITHIN_NATS` of the lowest (radius in posterior sd under that optimum's own Hessian). Many cheap starts (~1 ms each, N = 4) replace one careful one: a basin with hit rate `p` is missed by `K` starts with probability `(1−p)^K` (0.7 % for `p = 7.4 %`, `K = 64`; after `K` misses the 95 % bound on `p` is `3/K`). L-BFGS is needed because the problem is conditioned ~10⁶ in z-space: steepest descent would take ~κ/2 iterations (≈10⁶ against the cap `MAP_MAX_ITER = 500`) while L-BFGS behaves like a preconditioned method (26 iterations on a toy with the measured spectrum). A start ends at the gradient tolerance `MAP_G_TOL`, after four consecutive iterations with `|Δf| ≤ MAP_F_ABSTOL = 1e-6` (Optim stops when its counter *exceeds* `MAP_F_SUCCESSIVE = 3`), or at `MAP_MAX_ITER`. The `f`-test exists because near a minimum `|∇f| = √(2λ(f−f*))`: a gradient of 1e-6 along the stiffest direction (`λ = 9·10⁵`) is `f − f* ≈ 5·10⁻¹⁹`, far below anything meaningful. Non-finite values and `WLSError` count as +Inf; `f` always has an interior minimum because the Jacobian is included.
2. **Laplace approximation.** At a minimum `ẑ` with Hessian `H ≻ 0`, `π ≈ N(ẑ, H⁻¹)` and the mass of the basin is

   ```math
   \mathcal Z_L=\int e^{-f}\,dz\approx e^{-f(\hat z)}(2\pi)^{N/2}\det(H)^{-1/2},\qquad \ln\mathcal Z_L=-f-\tfrac12\sum_i\ln\lambda_i+\tfrac N2\ln 2\pi
   ```

   with relative error `1 + O(1/λ)` (in 1-D the first correction is `1 − f₄/8f₂² + 5f₃²/24f₂³`, exact for the Gamma function against Stirling's series). Laplace masses are exactly covariant under affine maps (ratios are unchanged), but the approximation under-weights skewed basins (off by a factor 2 or more) and under-states the width of weakly constrained logit coordinates (δρ₃ of SASDEP6 `fit1_model1` and SASDLP4 `fit1_model2` come out 2–4× wider; elsewhere σ_z is 0.93–1.5× the Laplace σ_z). They decide where the sampler looks, not how much a region counts.
3. **Hessian** by symmetrised central differences of the envelope gradient (`2N = 8` gradient evaluations), in two passes: step `MAP_HESS_STEP = 1e-4`, then `MAP_HESS_REL_STEP` (0.1) × each coordinate's Laplace σ from the first pass. The truncation error of a column is `h²/6 · ∇⁴f` and the noise `ε_g/h` (the gradient error of the `c1` tolerance), so the step must scale with σ_i; this is where the 1e-8 tolerance matters most.
4. `H = V diag(λ) Vᵀ`, eigenvalues **floored** at `MAP_HESS_EIG_FLOOR = 1` (a ridge, saddle or direction wider than the prior keeps the prior scaling), `S = V diag(λ̃)^{−1/2}`. The whitening factor, the clustering metric and the basin comparison use the floored eigenvalues; the stored `logmass = −f − ½Σ ln λ_i` (and so the shares) uses the unfloored ones, and is NaN if any `λ_i ≤ 0`. The optima are clustered (Mahalanobis distance ≤ `MAP_MODE_SEP = 3`); the best `MAP_MAX_BASINS = 8` are compared by floored Laplace mass, and the heaviest becomes the whitening centre (not necessarily the lowest optimum).

NUTS samples `w` with `θ = μ_θ + σ_θ ⊙ (ẑ + S w)` (`_θ_of_w`), in which the posterior is ≈ `N(0, I)` and the chain starts at the mode (`w₀ = 0`). Without flooring `Sᵀ H S = I`; the whitened Hessian elsewhere measures only the non-Gaussian remainder (condition number ~1–10 instead of 10⁶). Whitening *is* the choice of the initial HMC metric: HMC with mass matrix `M = LLᵀ` in `x` is step-for-step identical to identity-metric HMC in `u = Lᵀx`. For a leapfrog step on a mode of curvature `λ` the stable range is `ε√λ < 2`, and a trajectory needs ~`(π/2)√(λ_max/λ_min)` steps, which is why the conditioning governs the cost. If no start reaches a finite optimum, `ẑ = z₀` and `S = I`; likewise if the Hessian is non-finite. Draws need no Jacobian to be mapped back; only converting a density does.

**Re-whitening.** For a Gaussian target `f(z) − f(ẑ) ~ ½χ²_N` (mean 2, median 1.68 nats for `N = 4`), so a non-divergent draw more than `BASIN_RESTART_NATS = 2` above `log π(ẑ)` is evidence of a missed basin. The sampler then re-runs the search from that draw, re-whitens there and re-runs the chains, once (`rewhitened` in the report).

## NUTS

`infer(...; rng_seed)` is reproducible at any thread count: the `UInt64` seed is mixed (SplitMix64) with each draw's purpose and index into that item's own `Xoshiro` stream (MAP start `i`, chain `k`; bridge proposals; the chain-start directions from the separate `jitter_seed`). The seed is printed in the report's `=== Run ===` section. The MAP search stays serial (threading measured slower, `test/validation/threading/`).

Each chain uses multinomial NUTS with the generalised U-turn criterion (as in Stan; max tree depth 10, divergence threshold Δ_max = 1000), a `DenseEuclideanMetric(N)` (full covariance: the parameters multiply each other in `Î`, and a diagonal metric would cost ~√((1+r)/(1−r)) more steps for a pair with correlation `r`), `Leapfrog`, and `StanHMCAdaptor`:

- **Dynamics.** `H(x, p) = U(x) + ½ pᵀM⁻¹p`; kick–drift–kick leapfrog is volume-preserving, reversible and symplectic (second order, energy error ≈ O(ε²) bounded within the stability range), so the weights `e^{−H}` are the whole correction: the next state is drawn from the trajectory with probability ∝ `e^{−H}` (biased progressive sampling at the top level) and no accept–reject step is needed. The criterion stops when `ρ·p♯₋ ≤ 0` or `ρ·p♯₊ ≤ 0`, `ρ` the sum of the momenta.
- **Step size.** Nesterov dual averaging in `log ε` (γ = 0.05, t₀ = 10, κ = 0.75, shrinkage point `log 10ε₀`) toward a tree-averaged acceptance `α̅ = mean_leaves min(1, e^{−(H'−H₀)})` of `DEFAULT_TARGET_ACCEPT = 95` percent. The posteriors are strongly curved and often multimodal; on the 53 fits δ = 0.95 removed the divergences (three fits above 1 % went to ≤ 0.04 %) for 1.3× the steps of Stan's 0.8.
- **Metric windows** (`n_adapt = 300`): ε only for iterations 1–75, covariance windows ending at 100, 150, 250, ε only for 251–300; at each window end the metric becomes `n/(n+5) Σ̂ + 10⁻³·5/(n+5) I` and dual averaging restarts. The retry (`n_adapt = 2000`) has windows ending at 100, 150, 250, 450, 850, 1950.
- **Divergences.** A subtree diverges when `H' − H₀ > 1000` or `H'` is non-finite. They mark curvature the step cannot follow. A chain is dropped only if it errored or more than `CHAIN_MAX_DIVERGENT = 0.5` of its transitions diverged; the 1 % and 5-draws-per-fit figures are validation criteria, not tests in the program. Divergent draws are excluded from the MAP and the summaries, and up to `HARVEST_DIVERGENT` seed the optimum harvest. **E-BFMI** `= Σ(H_t − H_{t−1})² / Σ(H_t − H̄)² ≈ 2(1 − ρ₁)` is reported for the worst chain (below ~0.3 the energy random-walks slowly).

## Chains, modes and pooling

NUTS chains do not hop between separated modes (the tail probability of a kinetic energy exceeding a barrier ΔU is `(1+ΔU)e^{−ΔU}`, ≈ 5·10⁻⁴ at 10 nats), so the pooled sample needs an explicit statement of how much each mode counts.

**Starts.** `n_chains = DEFAULT_N_CHAINS = 8`, whatever the thread count. Chains 1 and 2 start at the mode (independent streams: independent ESS in the main mode and a baseline for R̂); chains 3–8 form three **mirrored pairs** at `+r_p û_p` and `−r_p û_p`, `r_p ∈ CHAIN_START_RADII = (4, 10, 20)` whitened standard deviations (a typical draw is at ≈ 2; a start at `r` has potential energy `r²/2` above the mode), with random directions from the `jitter_seed`; both sides matter because the posteriors are skewed against hard bounds. A start with non-finite density or gradient is pulled halfway back, up to eight times. `n_chains = 1` is exactly one chain, with none of the machinery below.

**Optima beyond the search.** A basin that attracts almost no random start is missed (SASDX52's third optimum, ~4 % of the Laplace mass, was hit by none of 500 starts). After the first round, L-BFGS is run from a farthest-point cover of `HARVEST_COVER = 16` post-warm-up draws (each the draw farthest from those chosen; a 2-approximation of the k-center problem) and up to `HARVEST_DIVERGENT = 8` divergent ones, and the optima merged with the search's (100 % recall in the recall study at ≈1.5× the evaluations). An optimum with Laplace share `s_k = e^{L_k−L_max}/Σ e^{L_j−L_max} ≥ OPTIMUM_MIN_SHARE = 1 %` should have at least `OPTIMUM_MIN_CHAINS = 2` chains **at** it (≥ `OPTIMUM_CHAIN_FRACTION` of a chain's draws within Mahalanobis radius `OPTIMUM_CHAIN_RADIUS = 4`, which holds > 99 % of a Gaussian mass in 4-D); the missing ones are started at the optimum, at most `OPTIMUM_MAX_EXTRA_CHAINS = 6` extra *chains* in all (not optima). A chain started at a sparse excursion from the main mode may leave it (SASDX52).

**Grouping.** `chain_modes` links two chains if the rank-normalised split R̂ of their pair is ≤ `MODE_RHAT = 1.25` for the four parameters and `log π`; a mode is a connected component. Chains in disjoint modes give 1.83 (pair) to 1.66 (many chains), within-mode chains ≈ 1, so 1.25 sits in the gap. There is deliberately no "all-chain R̂ small, so one mode" shortcut.

**Bridge sampling.** The mass `Z_m = ∫_{B_m} π_w dw` of each mode (`Modes.jl`, hand-written: BridgeSampling.jl requires Turing, BAT.jl's version is experimental) is estimated by the optimal iterative estimator of Meng and Wong. For draws `w₁ᵢ ~ p/Z` and proposal draws `w₂ⱼ ~ g`, with `ℓ = p/g` and `s₁ = N₁/(N₁+N₂)`, `s₂ = 1 − s₁`, the bridge function minimising the relative mean-square error is `α* ∝ 1/(s₁p + s₂Zg)` and gives the fixed-point iteration (unique root)

```math
r_{t+1}=\frac{\frac1{N_2}\sum_j \dfrac{\ell_{2j}}{s_1\ell_{2j}+s_2r_t}}{\frac1{N_1}\sum_i\dfrac{1}{s_1\ell_{1i}+s_2r_t}}\ \longrightarrow\ \hat Z
```

`g` is a Gaussian fitted to one half of the mode's draws and the estimate is made on the other half, both ways round; the mean of the two is `log Z_m` and half their difference its error in nats. Weights are `w_m = softmax(log Z)`; they are **not applied** when the bridge error of a mode that could matter exceeds `BRIDGE_MAX_ERR = 1` nat (the modes that can matter are then pooled by chain count). Each mode's chains are thinned (`draws_per_chain`) so the pooled sample carries `w_m`: with `top = max w_m/c_m` over live modes, each chain of mode `m` keeps `round(n_post · (w_m/c_m)/top)` evenly spaced draws; a mode below `MODE_NEGLIGIBLE = 1e-4` keeps none. Convergence is judged on the unthinned draws. Without thinning, the mode share would be the share of chains, which reflects the starts, not the posterior mass. Four fits have a second mode with mass in the chain study (minor shares 4–19 %: SASDKQ8, SASDN32, SASDWZ9, SASDZC6).

## Convergence and retry

Within each mode (modes differ by construction), on the unthinned post-warm-up draws, `convergence` computes (MCMCDiagnosticTools.jl, Vehtari et al. 2021):

- **Split R̂** on `2M` half-chains: `W` the mean within-sequence variance, `B` the between-sequence variance of means, `var⁺ = (n−1)/n W + B/n`, `R̂ = √(var⁺/W)`, so `R̂² − 1 ≈ τ_μ²/W` is the between-mean variance as a fraction of the within variance (1.01 ⇔ means within ≈ 0.14 within-sd). Rank normalisation (Blom scores) makes it location-robust; the folded version (about the median) catches differences of scale and tails; the larger is kept.
- **ESS** `= S/τ̂`, `τ = 1 + 2Σρ_t`, the autocorrelation from the variogram (`ρ̂_t = 1 − (W − γ̄_t)/var⁺`) truncated by Geyer's initial positive/monotone pair sequence (max lag 250). A Monte Carlo standard error of a mean is `σ/√ESS`, of a 16/84 % interval end `1.52σ/√ESS` (a few percent of σ at the default 5600 draws). The **tail ESS** is the one the intervals stand on; the rule of thumb is R̂ < 1.01 and ESS ≥ 100 per chain.

The worst values over the diagnosed modes are reported (`rhat_max` flagged above `RHAT_OK = 1.01`, `ess_min`, `ess_tail_min`). **Retry:** if the worst R̂ exceeds `RETRY_RHAT = 1.01` and the run was shorter than the retry, the whole procedure is run once more with `RETRY_N_ADAPT = RETRY_N_DRAWS = 2000` and seeds derived by an odd-constant multiplication of `rng_seed` and `jitter_seed` (`RETRY_SEED_OFFSET`: a different search, streams and directions, still deterministic), and the run with the smaller worst R̂ is kept (`retry = false` disables it; the report's `retry` line and `diagnostics.first_rhat`, `retry_kept` say what happened). It cannot repair a structural failure (a second mode explored by a single chain keeps R̂ ≈ 1.7). Outcomes: `test/validation/rhat_retry/` (53/53 at R̂ ≤ 1.01 on the latest run, 8 retries). Convergence statistics detect chains that disagree, not chains that agree on a wrong region.

## Draws and summaries

`infer` returns an `Inferred{S,N}`: the draws of `ξ` of the pooled chains, chain after chain (warm-up included; `chain`, `iteration`), AdvancedHMC's per-iteration statistics, and for every draw its **re-profiled** scale, `bkgrnd_corr`, `c1`, reduced χ² and predicted curve `m ĥ(q; ξ, c1) + b` on the fitted grid (scale and background are discarded at every density evaluation, so they are recomputed to match). `BAYSOL.run_model` hands back the same type with the first `n_adapt` draws dropped.

- **MAP.** The reported "MAP" is the non-divergent draw of highest `log π` (a draw of the sampled density in `θ`, not the L-BFGS end point and not the mode of the physical-space density). In the Gaussian case the best of `S` draws has `χ²_min` median `√(8 ln 2/S)`: ≈ 0.18 posterior sd and 0.016 nats from the mode at `S = 5600`.
- **Intervals.** `"16-84"` quantiles (default; `"0-0"` is the extremes) with Julia's linear-interpolation definition, and `"bounds"`, the smallest and largest actual draws inside them. Curve bands apply the same operation at each `q`: they are **pointwise** (the whole curve lies inside with probability at most 68 %) bands of the *fitted function*, not a posterior predictive (which would add `σᵢ²` and the variance of the nuisance parameters), and should not be compared with the scatter of the data. Divergent draws are removed, which biases the bands slightly narrow.
- **χ² on the measured grid.** `model_on_raw` interpolates the binned model onto the raw `q` by a cubic spline (`n_raw − 3` degrees of freedom). For a systematic misfit of `εσ` per raw point and `n` raw points per bin, the raw χ²_red ≈ `1 + ε²` and the binned ≈ `1 + nε²`: the binned statistic matches the independent-channel likelihood that is sampled, the measured-grid one is comparable with other programs.

## Usage

```julia
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource, resolve_structure, load_molecule
using BAYSOL.Hydrogenator: propka_pKas, resolve_hydrogens, Propka
using BAYSOL.Scattering: forward_cache
using BAYSOL.BulkElectronDensity: Solute, NonBiological
using BAYSOL.Inference: seed_sampler

PH, σ_PH, T_C = 7.5, 0.1, 20.0
SOLUTES = Solute[                       # buffer only: the measured protein is not a solute
    NonBiological(0.200, 0.002, "sodium chloride"),
    NonBiological(0.010, 0.0002, "tris"),
    NonBiological(0.005, 0.0001, "dtt"),
]

path  = resolve_structure(LocalPathSource(pdb_path))
hpath = resolve_hydrogens(path, PH; titration = Propka(propka_pKas(path)))
mol   = load_molecule(hpath)
fw    = forward_cache(mol, q_fit, lMax, energy_eV)
seed  = seed_sampler(fw, I_fit, σ_fit, PH, σ_PH, SOLUTES; t = T_C)

result = BAYSOL.run_model(seed)
BAYSOL.write_report(result)
```

## Constants

Module level in `Inference.jl`, in three groups.

- **Priors**: `DEFAULT_TEMPERATURE_C` (25.0), `BOUNDS_δρ₁₂ = (-10, 2)` (with the derived `LOWER_BOUND_δρ₁₂`, `WIDTH_δρ₁₂`), `MODE_δρ₁₂ = 1`, `κ_δρ₁₂ = 14`, `κ_δρ₃ = 1.25`, `φ_max = 1.25` (`seed_sampler`/`seed_model` take `κ_δρ₁₂`/`κ_δρ₃` keywords).
- **Profiled `c1`**: `EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)`, `EXCL_VOL_CORR_EPS = 0.02`, `EXCL_VOL_CORR_TOL = 1e-8`, `ENVELOPE_TAYLOR_LIMIT`.
- **Sampler**: `DEFAULT_TARGET_ACCEPT` (95), `DEFAULT_N_CHAINS` (8), `CHAIN_START_RADII`, `CHAIN_MAX_DIVERGENT`, `BASIN_RESTART_NATS`, the MAP search (`MAP_N_STARTS`, `MAP_MAX_ITER`, `MAP_G_TOL`, `MAP_F_ABSTOL`, `MAP_F_SUCCESSIVE`, `MAP_HESS_STEP`, `MAP_HESS_REL_STEP`, `MAP_HESS_EIG_FLOOR`, `MAP_MODE_SEP`, `MAP_MAX_BASINS`, the jitter constants), the harvest and extra chains (`HARVEST_*`, `OPTIMUM_*`), the pooling (`MODE_RHAT`, `MODE_NEGLIGIBLE`, `BRIDGE_*`) and the retry (`RHAT_OK`, `RETRY_*`).
