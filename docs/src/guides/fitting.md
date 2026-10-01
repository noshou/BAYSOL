 

# Fitting

Given a measured SAXS/SANS curve `I_exp(q)` ± `σ_exp(q)` and a molecular structure's geometry-only forward-model cache (ForwardCache from `Scattering.forward_cache`), sample the posterior over four physical contrast/scale parameters using NUTS (No-U-Turn Sampler) via AdvancedHMC.jl, then fit background correction/scale parameters via WLS.

## Parameters

Four parameters with priors, ξ = (ρₑ, δρ₁, δρ₂, δρ₃):

- ρₑ ∈ (0,∞): bulk electron density of the buffer (CRYSOL's dns), displaced by the solute's excluded volume.
- δρ₁, δρ₂ ∈ (−10, 2): CRYSOL-style hydration-shell contrasts of the convex and concave dummy beads, in units of 0.03 e·Å⁻³.
- δρ₃ ∈ (−ρ̄ₑ/0.03, (φ_max − 1)·ρ̄ₑ/0.03): the contrast of the enclosed-cavity beads, in the same units. It is the excess electron density of cavity water over the bulk, written through the cavity occupancy φ = ρ_cavity/ρₑ as δρ₃ = (φ − 1)·ρₑ/0.03. φ is only the derivation of the bounds; it is not a parameter.

CRYSOL's excluded-volume correction c1 is **not** part of ξ (see `Scattering.excluded_volume_factor`) -- it rescales the excluded-volume species by a single population-mean radius `r_m`, a mean-field bookkeeping trick over the already individually-computed per-atom volumes (`MolecularStructure.ExcludedVolumes`), not an independently identifiable physical unknown, so there is no defensible prior width to put on it. Instead it is profiled out at each ξ rather than sampled -- see `ProfiledCorrs.jl` below.

Two linear parameters, scale and `bkgrnd_corr` (`I_calc(q)` = scale · `y_model(q)` + `bkgrnd_corr`), are **not** sampled via HMC. At a fixed ξ, the forward-model curve `y_model(q)` is known, so (scale, `bkgrnd_corr`) is a closed-form two-parameter weighted linear regression (WLS.jl), refit at every ξ the sampler visits.

## Weighted least squares

### WLS.jl

`I_exp`/`σ_exp` are fixed for an entire NUTS run; only `y_model(q)` changes between evaluations. `WLSData(I_exp, σ_exp)` precomputes everything that doesn't depend on `y_model` once -- the per-point weights wᵢ = 1/σᵢ², and the data-only weighted sums Sw, Swy, Swyy, Σ log σᵢ². `wls_fit(y_model, data::WLSData)` is the hot-path entry point: at a given ξ, forward produces `y_model(q)`, and `wls_fit` only has to accumulate the three model-dependent sums (SwI, SwII, SwIy) to solve the 2×2 normal equations for (scale, `bkgrnd_corr`), in one O(n) pass with no allocation. A `wls_fit(y_model, I_exp, σ_exp)` convenience overload builds a `WLSData` on the fly for one-off fits outside the sampler.

`Seed` holds a `WLSData` (built once in `seed_fitting`) rather than raw `I_exp`/`σ_exp`, so `_ll`/`_logπ` and `ProfiledCorrs.jl`'s c1 search below all reuse the same precomputed sums instead of rebuilding them on every gradient evaluation.

It returns WLSFit, containing:

- Point estimates for scale and `bkgrnd_corr`
- Their (XᵀWX)⁻¹ covariance
- χ²
- dof = n - 2
  - Standard in SAXS fitting, since the 4 physical parameters (and the profiled c1) are not well defined and are not "truly" free.
- det(XᵀWX)
- Σ log σᵢ²

It throws WLSError if:

- n < 3
- any σᵢ ≤ 0
- det(XᵀWX) ≤ 0

Two log-likelihood variants are built on top, selected by a LIKELIHOOD tag (PROFILE() or MARGINAL()):

- PROFILE(): (scale, `bkgrnd_corr`) are pinned at their WLS point estimates:

  ```text
  -½χ² - ½Σlog σᵢ² - ½n·log2π
  ```
- MARGINAL(): (scale, `bkgrnd_corr`) are integrated out analytically under a flat prior (a closed-form Gaussian integral, since the problem is linear in them). This adds:

  ```text
  -½log det(XᵀWX) + log(2π)
  ```

  to `wls_prof_ll`, allowing scale/background uncertainty to propagate into the posterior on ξ instead of being frozen at a point estimate.

### ProfiledCorrs.jl

Since c1 has no defensible prior (see above), it's profiled out by direct optimization instead of sampled: `profiled_corrs(wls, ξ, fw; cmin=EXCL_VOL_CORR_BOUNDS[1], cmax=EXCL_VOL_CORR_BOUNDS[2], eps=EXCL_VOL_CORR_EPS)` finds the c1 minimizing reduced χ² at a fixed ξ, with (scale, `bkgrnd_corr`) re-fit by `wls_fit` at every trial c1 -- nonlinear in c1 (see `Scattering.excluded_volume_factor`'s `c1³·exp(...)` form), unlike the closed-form scale/background fit, so it needs an iterative 1-D search rather than a closed form.

The search is entirely gradient-free, in two stages:

1. A coarse pre-scan over the grid `(cmin-eps):eps:(cmax+eps)` -- one `forward` + `wls_fit` per point, no autodiff. Grid size ≈ `((cmax+eps) - (cmin-eps)) / eps + 1`, so `eps` controls both the padding described below *and* this scan's cost; at the shipped defaults (`cmin=0.8, cmax=1.3, eps=0.02`) that's 28 points, trivial, but tightening `eps` for a finer saturation test grows this proportionally (e.g. `eps=1e-4` → 5401 points) -- tune with that trade-off in mind if overriding the defaults.
2. `Optim.jl`'s `Brent()`, bracketed around the best grid point (its two grid neighbours, or the padded edge if the best point is first/last), polishes to full precision.

Both stages search directly on a bounded interval, so -- unlike an earlier unconstrained-reparameterization approach -- there is nothing that can run away chasing an asymptote when the true optimum lies at or beyond a bound; the search just converges to the bound itself. The bounds actually searched are padded by `eps` past the nominal `(cmin, cmax)` on purpose: landing exactly on `cmin`/`cmax` from a search that could have gone slightly further (and didn't) is then distinguishable from a search that's still improving right up to the edge of its padded room -- see `excl_vol_saturation` below, which classifies c1_star against the *un*-padded `(cmin, cmax)` to make that call. c1_star itself is returned exactly as found, including outside `(cmin, cmax)` proper (but still inside the padded window) -- nothing clamps it back.

If called from inside a NUTS log-density evaluation, ξ must be stripped to Float64 first: c1_star (and its WLSFit) are meant to be plugged back into the surrounding Dual evaluation as fixed constants. This is valid by the envelope theorem -- at a true optimum ∂χ²/∂c1 = 0, so the total derivative of the profiled likelihood w.r.t. the outer ξ equals its partial derivative holding c1 fixed at c1_star.

`profiled_corrs` takes the same `WLSData` as `_ll`, so repeated re-fits across the inner c1 search reuse the precomputed data-only sums rather than rebuilding them per trial c1. It's wired into both `Sampler.jl`'s hot path (`_ll` calls it on every log-density/gradient evaluation) and `run_fitting`'s posterior-draw loop (re-profiled per draw for reporting; see `FitResult.c1`).

`excl_vol_saturation(c1; cmin, cmax)` is a free (no re-solve) classification of a profiled c1_star against the physical bounds: `-1`/`+1` if it landed outside `(cmin, cmax)` even with the padded window's extra room (genuine saturation, not a hard-clamp artifact), `0` otherwise. It's meant to be called once, on a single reported value (`BAYSOL.run_model` calls it on the MAP draw's c1 only) -- transient saturation on some posterior draws, especially during warmup, is expected and not itself diagnostic.

## Prior distributions

The prior modules define distributions over fit parameters, allowing HMC to sample over a distribution of possible parameters instead of fixing them to single values.

### DeltaRho.jl

CRYSOL's dro ("delta rho" ) parameters, which are the change in electron density of water beads at the hydration layer:

- dro1: convex beads, δρ₁ in this codebase.
- dro2: concave beads, δρ₂ in this codebase.
- dro3: cavity beads, δρ₃ in this codebase.

CRYSOL's own default is dr1 = dr2 = 1.0, dr3 = 0.

`δρ_prior(κ_δρ₁₂, κ_δρ₃, ρ̄ₑ)` returns (δρ₁, δρ₂, δρ₃) priors. Each is a Beta stretched onto a bounded interval, `LocationScale(L, W, Beta(α, β))`, with its mode at CRYSOL's default. The concentration κ = α + β − 2 > 0 sets the spread without moving the mode. `seed_fitting`/`seed_model` take `κ_δρ₁₂`/`κ_δρ₃` keywords, which default to `DRO12_CONCENTRATION`/`DRO3_CONCENTRATION`. ρ̄ₑ is the mean of the ρₑ prior.

- **δρ₁, δρ₂**: support [−10, 2] (`DRO_BOUNDS`, CRYSOL3's fitting limits), mode 1, α = 1 + 11κ/12, β = 1 + κ/12. The default κ = 14 gives SD(δρ) ≈ 1.00 (the spread of the Normal(1, 1) δρ₂ prior it replaced), mean ≈ 0.38 and P(δρ < 0) ≈ 30%. The prior is left-skewed because the mode sits near the upper bound. Note that some older single-shell CRYSOL fits in the SASBDB fixtures report `Dro` ≈ 0.075–0.083 e·Å⁻³ (δρ ≈ 2.5–2.8), above the upper bound.
- **δρ₃ (cavity contrast)**: support δρ₃ ∈ [−ρ̄ₑ/0.03, (φ_max − 1)·ρ̄ₑ/0.03] ≈ [−11.2, 2.8], from φ ∈ [0, φ_max] (an empty void up to φ_max = 1.25) with ρₑ fixed at the prior mean ρ̄ₑ. Mode at δρ₃ = 0 (φ = 1, bulk-density cavity water), α = 1 + κ/φ_max, β = 1 + (1 − 1/φ_max)·κ. The default κ = 1.25 gives Beta(2, 1.25) on the unit interval: ~21% of the mass is below half occupancy (φ < 0.5) and ~3.5% below φ = 0.2. The sampler draws δρ₃ directly from this prior. Fixing ρₑ at ρ̄ₑ leaves φ = 1 + 0.03·δρ₃/ρₑ within the relative uncertainty of ρₑ of [0, φ_max], at most ~0.06% for the buffers checked. When a structure has almost no cavity beads, δρ₃ has no likelihood and simply samples its prior; the report's `cavity_frac` line flags this.
- **δρ4**: The condensed-cation layer for nucleotides based on Manning theory is not implemented yet.

### DensityOfSolvent.jl

ρₑ corresponds to CRYSOL's dns ("density of solvent") parameter, the bulk electron density of the **buffer**. Buffer-subtracted SAXS measures contrast against the buffer, so the solutes list describes the buffer only: **never list the measured macromolecule itself** (other copies of it are separate scatterers, and the volume they displace only changes the flat buffer-subtraction baseline, which `bkgrnd_corr` absorbs). `ρₑ_prior(pH, σ_pH, solutes; t=25.0)` returns a LogNormal prior for the bulk solution electron density ρₑ (e·Å⁻³), moment-matched to the (μ, σ) computed by `_ρₑ`. LogNormal is used because ρₑ has support only on (0, ∞); at the coefficient of variation, this model agrees with a normal approximation in the bulk.

The model is linear in solute concentration:

```text
ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)
```

Here, `ϕ°_j` is solute j's partial molar volume at infinite dilution (cm³/mol). Water's density ρ_w(T) is evaluated at the sample temperature t exactly. The ϕ° tables are 25 °C values; away from 25 °C their temperature drift is not modelled but folded into the uncertainty, σ_ϕ°,T = `PMV_FRACTIONAL_EXPANSIBILITY` · ϕ° · |t − 25| (3.0 × 10⁻³ K⁻¹, an upper bound over the 42 multi-temperature series bundled with the tables; unverified for electrolytes). Uncertainty is propagated to first order, assuming independence:

```text
σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w² + Σ_j k_j² · σ_C_j² + Σ_j (C_j·ρ_w/1e3)² · (σ_ϕ°_j² + σ_ϕ°_j,T²)
```

where:

```text
k_j = N_A·Z_j/1e27 − ρ_w·ϕ°_j/1e3
```

Given μ = ρₑ and σ = √σ², the corresponding LogNormal parameters are:

```text
σ_ln = √(ln(1 + σ²/μ²))
μ_ln = ln(μ) − σ_ln²/2
```

An empty solutes list is pure water. Supported solute types are:

- Protein (a buffer component such as a carrier protein, not the measured species)
- NonBiological
- DNA *note: not yet validated end to end, but calculations work*
- RNA *note: not yet validated end to end, but calculations work*

Each solute carries molarity, `molarity_uncertainty`, and an arg (sequence or name) resolved through PartialMolarVolumes.ϕ°.

### Prior composition

`_calc_ξ_priors` composes the ρₑ prior and the three δρ priors into one `ξ_priors` struct (δρ₃'s bounds fixed at the ρₑ prior's mean), and `_ξ₀` draws an initial ξ from that composition.

## Parameter transform: ParamTransform.jl

### ξ-space ↔ θ-space

NUTS/HMC requires an unconstrained ℝⁿ space. The domain of ξ is:

- ρₑ is positive.
- δρ₁ and δρ₂ lie in (L, L + W) = (−10, 2).
- δρ₃ lies in (L₃, L₃ + W₃), the support of its prior (a `LocationScale`'s location and scale).

Therefore Θ and Ξ log-transform ρₑ and scaled-logit-transform the three bounded coordinates:

```text
θ = (a, t₁, t₂, t₃)

a  = ln(ρₑ)
t₁ = logit((δρ₁ − L)/W)
t₂ = logit((δρ₂ − L)/W)
t₃ = logit((δρ₃ − L₃)/W₃)

Ξ(θ) = (eᵃ, L + W·σ(t₁), L + W·σ(t₂), L₃ + W₃·σ(t₃)),   σ(t) = 1/(1 + e⁻ᵗ)
```

Θ also returns the log-Jacobian correction (`logjac`):

```text
corr = ln|det(∂ξ/∂θ)| = a + Σₖ [ln Wₖ + ln σ(tₖ) + ln(1 − σ(tₖ))],   W₁ = W₂ = 12
```

Each bounded coordinate has a stretched-Beta prior. In θ-space its prior plus Jacobian term is α ln σ(tₖ) + β ln(1 − σ(tₖ)) − ln B(α, β): the ln Wₖ terms cancel, the result is log-concave, and its gradient is bounded in (−β, α). So the hard bounds never produce stiff walls for the integrator. If the likelihood wants to go past a bound, draws pile up against it, just as c1 saturates.

This correction is required because a density transported through a change of variables picks up the Jacobian:

```text
log π(θ) = log p(ξ(θ)) + log|det(∂ξ/∂θ)|
```

## Sampler

### Log-posterior: `_logπ`

```text
log π(θ) = _lp(ξ(θ), priors) + _ll(wls, ξ(θ), fw, l) + logjac(θ)
```

`_lp` sums the four Distributions.logpdf values over ξ (each `LocationScale` density carries its own −ln W term). `_ll` calls `profiled_corrs(wls, ξ, fw)`, which profiles c1 and fits (scale, `bkgrnd_corr`) by `wls_fit` against the precomputed `WLSData`, and reports `wls_prof_ll` or `wls_marg_ll` according to the l argument. The final term is Θ's Jacobian correction.

### Seeding and initialization

`seed_fitting` draws one ξ₀ from the composed priors (`_ξ₀`) and transforms it to θ₀ (Θ), packaging it with the priors, the ForwardCache, and the data -- precomputed once into a `WLSData` -- into a Seed. `run_fitting` does **not** run NUTS directly in raw θ-space. The four coordinates of θ have substantially different prior scales; for example, ρₑ's prior standard deviation can be orders of magnitude tighter than δρ₁'s. Meanwhile, AdvancedHMC.jl's `find_good_stepsize` initially explores using an identity mass matrix, before mass-matrix adaptation has run. This can create severe instabilities: a step size that is appropriate for one dimension may push another dimension into a nonphysical region. The forward model can then fail, triggering `wls_fit`'s det(XᵀWX) ≤ 0 guard before adaptation has a chance to correct the scale mismatch. To address this, `_standardize` maps:

```text
θ ↦ z = (θ - μ) / σ
```

using each coordinate's own prior mean and standard deviation in θ-space from `θ_prior_moments` (exact for all four: a is Normal under ρₑ's LogNormal prior, and for each t = logit(u), u ~ Beta(α, β), E[t] = ψ(α) − ψ(β) and Var[t] = ψ₁(α) + ψ₁(β)). Sampling in z-space makes a generic kick approximately one prior standard deviation in every coordinate. `_destandardize` inverts this mapping. The affine map's Jacobian, Πσᵢ, is constant and independent of z, so it is omitted from the `_logπ` wrapper in standardized space. NUTS only needs Hamiltonian differences, so this constant does not affect sampling.

### NUTS via AdvancedHMC.jl

`run_fitting(seed, n_samples, n_adapt; l=PROFILE(), δ=80)` proceeds as follows:

1. Wrap `_logπ` ∘ `_destandardize` as ℓπ: z ↦ log π(θ(z)), and compute its gradient using one ForwardDiff.gradient! pass (∂ℓπ/∂z).
2. Build a DenseEuclideanMetric(4) and a Hamiltonian(metric, ℓπ, ∂ℓπ/∂z), with:

   ```text
   H(θ, r) = -log π(θ) + ½rᵀM⁻¹r
   ```

   A full covariance matrix is used instead of a diagonal matrix because the four parameters are highly coupled through the forward model.
3. Use `find_good_stepsize` and a Leapfrog integrator. StanHMCAdaptor combines:

   - A MassMatrixAdaptor, which learns M from trajectory covariance.
   - A StepSizeAdaptor, which uses dual averaging to target an acceptance rate of δ/100.

   Adaptation runs over the first `n_adapt` iterations.
4. Construct the NUTS kernel:

   ```text
   HMCKernel(Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()))
   ```

   Leapfrog trajectories grow by doubling a binary tree until a U-turn occurs, after which a draw is taken from the valid part of the tree using multinomial trajectory sampling.
5. Run AdvancedHMC.sample for `n_samples` iterations.
6. Destandardize every returned z and decode it back to ξ via Ξ. For each ξ, re-profile c1 with `profiled_corrs` and recompute scale, `bkgrnd_corr`, c1, χ², and the predicted curve (`wls_predict`, `reduced_chi2`). When the seed carries a `Timing.StageLog`, NUTS setup, sampling (with leapfrog count and ms/step) and this re-profile loop are recorded in it.

```julia
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource, resolve_structure, load_molecule,
    propka_pKas, resolve_hydrogens
using BAYSOL.Scattering: forward_cache
using BAYSOL.Fitting: Solute, NonBiological, PROFILE, seed_fitting

PH, σ_PH, T_C = 7.5, 0.1, 20.0
# buffer only -- the measured protein is not a solute
SOLUTES = Solute[
    NonBiological(0.200, 0.002, "sodium chloride"),
    NonBiological(0.010, 0.0002, "tris"),
    NonBiological(0.005, 0.0001, "dtt"),
]

path = resolve_structure(LocalPathSource(pdb_path))
pKa_records = propka_pKas(path)
hpath = resolve_hydrogens(path, pKa_records, PH; add = true)
mol, _ = load_molecule(hpath)

fw = forward_cache(mol, q_fit, lMax, energy_eV)

seed = seed_fitting(fw, I_fit, σ_fit, PH, σ_PH, SOLUTES; t = T_C)

result = BAYSOL.run_model(seed, 2000, 1000; l = PROFILE())

fit, divergence_rate, map_result, quantile_result = result
BAYSOL.write_report(result)
```
