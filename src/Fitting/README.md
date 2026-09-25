 

# Fitting

Given a measured SAXS/SANS curve I_exp(q) ± σ_exp(q) and a molecular structure's geometry-only forward-model cache (ForwardCache from Scattering.forward_cache), sample the posterior over five physical contrast/scale parameters using NUTS (No-U-Turn Sampler) via AdvancedHMC.jl, then fit background correction/scale parameters via WLS.

## Parameters

Five parameters with priors, ξ = (dns, δρ1, δρ2, δρ3, c1):

- dns ∈ (0,∞): mean bulk electron density displaced by solvent atoms.
- δρ1 ∈ (0,∞), δρ2 ∈ ℝ, δρ3 ∈ ℝ: CRYSOL-style hydration-shell border-layer contrast, split by dummy-bead geometry (convex / concave / cavity).
- c1 ∈ (0,∞): the global excluded-volume expansion factor (CRYSOL's c1 = r0/r_m), bounded in practice to [0.96, 1.04].

Two linear parameters, scale and bkgrnd_corr (I_calc(q) = scale · y_model(q) + bkgrnd_corr), are **not** sampled via HMC. At a fixed ξ, the forward-model curve y_model(q) is known, so (scale, bkgrnd_corr) is a closed-form two-parameter weighted linear regression (WLS.jl), refit at every ξ the sampler visits.

## Weighted least squares

### WLS.jl

At a given ξ, forward produces y_model(q). wls_fit(y_model, I_exp, σ_exp) solves the 2×2 normal equations for (scale, bkgrnd_corr) under weights wᵢ = 1/σᵢ² in one O(n) pass.

It returns WLSFit, containing:

- Point estimates for scale and bkgrnd_corr
- Their (XᵀWX)⁻¹ covariance
- χ²
- dof = n - 2
  - Standard in SAXS fitting, since the 5 physical parameters are not well defned and are not "truly" free.
- det(XᵀWX)
- Σ log σᵢ²

It throws WLSError if:

- n < 3
- any σᵢ ≤ 0
- det(XᵀWX) ≤ 0

Two log-likelihood variants are built on top, selected by a LIKELIHOOD tag (PROFILE() or MARGINAL()):

- PROFILE(): (scale, bkgrnd_corr) are pinned at their WLS point estimates:

  ```text
  -½χ² - ½Σlog σᵢ² - ½n·log2π
  ```
- MARGINAL(): (scale, bkgrnd_corr) are integrated out analytically under a flat prior (a closed-form Gaussian integral, since the problem is linear in them). This adds:

  ```text
  -½log det(XᵀWX) + log(2π)
  ```

  to wls_prof_ll, allowing scale/background uncertainty to propagate into the posterior on ξ instead of being frozen at a point estimate.

## Prior distributions

The prior modules define distributions over fit parameters, allowing HMC to sample over a distribution of possible parameters instead of fixing them to single values.

### Priors/DeltaRho.jl

CRYSOL's dro ("delta rho" ) parameters, which are the change in electron density of water beads at the hydration layer:

- dro1: convex beads, δρ1 in this codebase.
- dro2: concave beads, δρ2 in this codebase.
- dro3: cavity beads, δρ3 in this codebase.

CRYSOL's own default is dr1 = dr2 = 1.0, dr3 = 0.

δρ_prior(μ_χ=0; σ_χ=0.0) returns (dro1, dro2, dro3):

- **δρ1**: LogNormal(0, σ_ln) with median 1 (matching CRYSOL's default exactly) and mean 1.15, since convex beads run approximately 15% denser on the surface. The source is Merzel & Smith, *PNAS* 99(8):5378–5383 (2002), doi:10.1073/pnas.082335099, which provides an MD explanation of the SAS/SANS measurement of Svergun et al., *PNAS* 95:2267–2272 (1998). The log-scale standard deviation satisfies:

  ```text
  mean = exp(σ_ln² / 2) = 1.15 => σ_ln = √(2 · ln(1.15))
  ```
- **δρ2**: Normal(1, 0.15). This represents concave beads and is mostly positive but can take either sign.
- **δρ3**: Normal(μ_χ, σ_χ). This represents cavity-water contrast. It defaults to a point mass at 0, matching standard CRYSOL's fixed dr3 = 0. μ_χ and σ_χ can be set manually or supplied by an electrostatics calculation.
- **δρ4**: The condensed-cation layer for nucleotides based on Manning theory is not implemented yet.

Depending on the molecular system, μ_χ and σ_χ may be obtained from a screened Debye–Hückel electrostatic signal, such as Solvation.Electrostatics.nucleic_acid_cavity_electrostatics for nucleic-acid phosphate charges or the corresponding protein cavity-electrostatics routine.

### Priors/DensityOfSolvent.jl

ρₑ corresponds to CRYOL's dns ("density of solvent") paramter, estimating the bulk electron density of the solution. ρₑ_prior(pH, σ_pH, solutes; t=25.0) returns a LogNormal prior for the bulk solution electron density ρₑ (e·Å⁻³), moment-matched to the (μ, σ) computed by _ρₑ. LogNormal is used because ρₑ has support only on (0, ∞); at the coefficient of variation, this model agrees with a normal approximation in the bulk.

The model is linear in solute concentration:

```text
ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)
```

Here, ϕ°_j is solute j's partial molar volume at infinite dilution (cm³/mol). Uncertainty is propagated to first order, assuming independence:

```text
σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w² + Σ_j k_j² · σ_C_j² + Σ_j (C_j·ρ_w/1e3)² · σ_ϕ°_j²
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

Supported solute types are:

- Protein
- NonBiological
- DNA *note: not yet implemeted, but calculations work*
- RNA *note: not yet implemeted, but calculations work*

Each solute carries molarity, molarity_uncertainty, and an arg (sequence or name) resolved through PartialMolarVolumes.ϕ°.

### Priors/ExcludedVolume.jl

CRYSOL's excluded-volume correction is a single global expansion factor:

```text
c1 = r0 / r_m
```

It is applied to every dummy atom's radius, where r0 is the fitted excluded-volume radius and r_m is the structure's mean atomic radius (see Scattering.excluded_volume_factor). CRYSOL bounds the factor to:

```text
c1 ∈ [0.96, 1.04]
```

c1_prior(n) returns a LogNormal over c1. It first constructs a Normal(μ=1, σ) in linear space such that n% of its mass falls within z standard deviations of μ = 1, with μ ± zσ spanning CRYSOL's bound exactly:

```text
z = √2 · erf⁻¹(n/100)
σ = 0.04 / z
```

The value 0.04 is half the width of the interval [0.96, 1.04].

The normal distribution is then moment-matched into LogNormal parameters:

```text
σ_ln = √(ln(1 + σ²))
μ_ln = -σ_ln² / 2
```

The resulting LogNormal(μ_ln, σ_ln) has mean exactly 1 for every n.

The parameter n controls how much of CRYSOL's stated bound is treated as typical rather than as a hard edge:

- Higher n concentrates more mass near c1 = 1, producing a tighter prior.
- Lower n allows more spread before the bound is considered met.
- n = 100 is the degenerate limit, a point mass at c1 = 1.

There is no single correct n implied by CRYSOL's paper alone because [0.96, 1.04] is a stated fitting range, not a reported confidence interval. n = 85 is a reasonable default in the absence of a stronger reason to choose another value.

### Prior composition

_calc_ξ_priors composes the three priors into one _ξ_priors struct, and _ξ₀ draws an initial ξ from that composition.

## Parameter transform: ParamTransform.jl

### ξ-space ↔ θ-space

NUTS/HMC requires an unconstrained ℝⁿ space. The domain of ξ is mixed:

- dns, δρ1, and c1 are positive.
- δρ2 and δρ3 are unconstrained real values.

Therefore, Θ and Ξ log-transform only the three positive coordinates:

```text
θ = (a, b, δρ2, δρ3, c)

a = ln(dns)
b = ln(δρ1)
c = ln(c1)

Ξ(θ) = (eᵃ, eᵇ, δρ2, δρ3, eᶜ)
```

Θ also returns the log-Jacobian correction:

```text
corr = ln|det(∂ξ/∂θ)| = a + b + c
```

This correction is required because a density transported through a change of variables picks up the Jacobian:

```text
log π(θ) = log p(ξ(θ)) + log|det(∂ξ/∂θ)|
```

## Sampler

### Log-posterior: _logπ

```text
log π(θ) = _lp(ξ(θ), priors) + _ll(I_exp, σ_exp, ξ(θ), fw, l) + (θ[1] + θ[2] + θ[5])
```

_lp sums the five Distributions.logpdf values over ξ. _ll runs forward at ξ, then calls wls_fit, wls_prof_ll, or wls_marg_ll according to the l argument. The final term is Θ's Jacobian correction.

### Seeding and initialization

seed_fitting draws one ξ₀ from the composed priors (_ξ₀) and transforms it to θ₀ (Θ), packaging it with the priors, the ForwardCache, and the data into a Seed. run_fitting does **not** run NUTS directly in raw θ-space. The five coordinates of θ have substantially different prior scales; for example, dns's prior standard deviation can be orders of magnitude tighter than δρ1's. Meanwhile, AdvancedHMC.jl's find_good_stepsize initially explores using an identity mass matrix, before mass-matrix adaptation has run. This can create severe instabilities: a step size that is appropriate for one dimension may push another dimension into a nonphysical region. The forward model can then fail, triggering wls_fit's det(XᵀWX) ≤ 0 guard before adaptation has a chance to correct the scale mismatch. To address this, _standardize maps:

```text
θ ↦ z = (θ - μ) / σ
```

using each coordinate's own prior mean and standard deviation from _θ_prior_moments. Sampling in z-space makes a generic kick approximately one prior standard deviation in every coordinate. _destandardize inverts this mapping. The affine map's Jacobian, Πσᵢ, is constant and independent of z, so it is omitted from the _logπ wrapper in standardized space. NUTS only needs Hamiltonian differences, so this constant does not affect sampling.

### NUTS via AdvancedHMC.jl

run_fitting(seed, n_samples, n_adapt; l=PROFILE(), δ=80) proceeds as follows:

1. Wrap _logπ ∘ _destandardize as ℓπ: z ↦ log π(θ(z)), and compute its gradient using one ForwardDiff.gradient! pass (∂ℓπ/∂z).
2. Build a DenseEuclideanMetric(5) and a Hamiltonian(metric, ℓπ, ∂ℓπ/∂z), with:

   ```text
   H(θ, r) = -log π(θ) + ½rᵀM⁻¹r
   ```

   A full covariance matrix is used instead of a diagonal matrix because the five parameters are highly coupled through the forward model.
3. Use find_good_stepsize and a Leapfrog integrator. StanHMCAdaptor combines:

   - A MassMatrixAdaptor, which learns M from trajectory covariance.
   - A StepSizeAdaptor, which uses dual averaging to target an acceptance rate of δ/100.

   Adaptation runs over the first n_adapt iterations.
4. Construct the NUTS kernel:

   ```text
   HMCKernel(Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()))
   ```

   Leapfrog trajectories grow by doubling a binary tree until a U-turn occurs, after which a draw is taken from the valid part of the tree using multinomial trajectory sampling.
5. Run AdvancedHMC.sample for n_samples iterations.
6. Destandardize every returned z and decode it back to ξ via Ξ. For each ξ, recompute scale, bkgrnd_corr, χ², and the predicted curve using wls_fit, wls_predict, and reduced_chi2.

```julia
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource, resolve_structure, load_molecule,
    propka_pKas, resolve_hydrogens, Ionization
using BAYSOL.Solvation: protein_cavity_electrostatics
using BAYSOL.Scattering: forward_cache
using BAYSOL.Fitting: Solute, Protein, NonBiological, PROFILE, seed_fitting

PH, σ_PH = 7.5, 0.1
SOLUTES = Solute[
    Protein(0.504e-3, 0.05 * 0.504e-3, NSP7_SEQ),
    NonBiological(0.200, 0.002, "sodium chloride"),
    NonBiological(0.010, 0.0002, "tris"),
    NonBiological(0.005, 0.0001, "dtt"),
]

path = resolve_structure(LocalPathSource(pdb_path))
pKa_records = propka_pKas(path)
hpath = resolve_hydrogens(path, pKa_records, PH; add = true)
mol, residues = load_molecule(hpath)

fw = forward_cache(mol, q_fit, lMax, energy_eV)

ionization = Ionization(residues, pKa_records, PH, σ_PH)
μ_χ, σ_χ = protein_cavity_electrostatics(
    mol,
    residues,
    ionization;
    ionic_strength_M = 0.2,
)

seed = seed_fitting(
    fw,
    I_fit,
    σ_fit,
    PH,
    σ_PH,
    SOLUTES;
    μ_χ = μ_χ,
    σ_χ = σ_χ,
)

result = BAYSOL.run_model(seed, 2000, 1000; l = PROFILE())

fit, divergence_rate, map_result, quantile_result = result
BAYSOL.write_report(result)
```
