# Utils

`BAYSOL.Utils` groups the small scientific helpers every other module builds on. Each stays a named submodule, re-bound at the package root (`using BAYSOL.PhysicalConstants: AVOGADRO`). Load order: `PhysicalConstants`, `Shannon`. Caching, timing, GC pausing and threading live in [`Runtime`](@ref BAYSOL.Runtime); point sets, excluded volumes and SASA in [`Geometry`](@ref BAYSOL.Geometry).

## PhysicalConstants

Every physical constant and unit conversion, defined once so it cannot drift between modules; other modules import by name (`using ..PhysicalConstants: AVOGADRO, WATER_MOLAR_MASS`).


| constant                                                                        | value                                                                              | used by                                     |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------- |
| `AVOGADRO`                                                                      | 6.02214076 × 10²³ mol⁻¹ (exact, 2019 SI)                                      | BulkElectronDensity, Inference              |
| `PLANCK_CONSTANT`, `SPEED_OF_LIGHT`, `ELEMENTARY_CHARGE`                        | exact 2019 SI values of h, c, e                                                    | `HC_EV_ANGSTROM`                            |
| `HC_EV_ANGSTROM`                                                                | h·c ≈ 12398.42 eV·Å; <br />`E = HC_EV_ANGSTROM / λ`                          | fitting scripts                             |
| `WATER_MOLAR_MASS`                                                              | 18.015268 g·mol⁻¹ (IAPWS-95)                                                    | BulkElectronDensity                         |
| `WATER_ELECTRONS`                                                               | 10                                                                                 | BulkElectronDensity                         |
| `WATER_DENSITY_UNCERTAINTY`                                                     | 0.02 kg·m⁻³ on the Kell density                                                 | BulkElectronDensity                         |
| `KELL_DENSITY_NUM`, `KELL_DENSITY_DEN`                                          | Kell (1975) coefficients, kg·m⁻³, 0–150 °C                                    | BulkElectronDensity                         |
| `ANGSTROM3_PER_LITER`, `CM3_PER_LITER`, `ANGSTROM_PER_METER`, `PM_PER_ANGSTROM` | 10²⁷, 10³, 10¹⁰, 100                                                          | BulkElectronDensity, Inference, AtomicRadii |
| `NM_INV_PER_ANGSTROM_INV`                                                       | 10 (an integer, so `q ./ NM_INV_PER_ANGSTROM_INV` is bit-identical to `q ./ 10`)   | fitting scripts                             |
| `UNIT_OF_δρ`                                                                  | 0.03 e·Å⁻³, CRYSOL's `--dro` unit                                              | Scattering, Inference                       |
| `NS_PER_S`, `MS_PER_S`                                                          | 10⁹, 10³                                                                         | Timing, Inference, Pipeline                 |
| `STANDARD_TEMPERATURE_C`                                                        | 25 °C (298.15 K); backs `PMV_REFERENCE_TEMPERATURE_C` and `DEFAULT_TEMPERATURE_C` | BulkElectronDensity, Inference              |

Every other tunable is a module-level constant in its owning module.

## Shannon

The data reduction that precedes the fit. For a particle whose scatterers lie in a set of diameter `D`,

```math
I(q)=\int_0^D p(r)\,\frac{\sin qr}{qr}\,dr
```

with `p(r)` the distance distribution, zero beyond `D` because the autocorrelation of a function supported on a set of diameter `D` vanishes beyond `D`. Hence `F(q) = qI(q) = ∫₀^D (p(r)/r) sin(qr) dr` is the Fourier transform of a function supported on `[−D, D]` (odd extension), and the Whittaker–Shannon theorem (expand it in a Fourier series on `[−D, D]`) gives

```math
F(q)=\sum_{n\in\mathbb Z}F\!\Big(\frac{n\pi}{D}\Big)\,\mathrm{sinc}\!\Big(\frac{Dq}{\pi}-n\Big)
```

The curve is fully determined by its values on the grid `Δq = π/D` (one *Shannon channel*), so a range `[q_min, q_max]` holds only `N_s = (q_max − q_min)·D/π` independent values (the median fitting test had 62 points per channel). Fitting every point makes the Gaussian likelihood claim far more independent data than exist, and it is an upper bound on how many parameters the curve can constrain. `N_s` is `n_channels` of `ShannonInfo`, printed in the report.

- `cloud_diameter(points)`: the exact diameter of a `(3, n)` cloud. A convex function's maximum over the hull is at a vertex, so the farthest pair lies on the convex hull; it is built with [Quickhull.jl](https://github.com/augustt198/Quickhull.jl) and only its vertices (~100 of thousands) are compared pairwise (fewer than four points or a degenerate cloud is compared directly). `seed_model` applies it to the atoms **and** the hydration beads (the actual scatterer cloud, 5–6 Å wider than the atoms alone).
-
- `shannon_data(q, I, σ; D, rebin, max_bin_bias, lMax, drop_nonpositive)`: **inverse-variance binning** to `rebin` bins per channel (width `π/(rebin·D)`), each bin carrying

  ```math
  \bar q=\frac{\sum w_jq_j}{\sum w_j},\quad \bar I=\frac{\sum w_jI_j}{\sum w_j},\quad \bar\sigma=\Big(\sum w_j\Big)^{-1/2},\quad w_j=\sigma_j^{-2}
  ```

  This is the minimum-variance unbiased linear estimator (Gauss–Markov; Lagrange multiplier on `Σλ_j = 1` gives `λ_j ∝ w_j`) and keeps `Σw·I` and `Σw`, the sufficient statistics of the linear fit, unchanged: by the weighted analysis-of-variance identity binning is lossless exactly when the model is constant over the bin. It assumes independent errors; correlated errors make `σ̄` too small (the variance of an equicorrelated mean tends to `ρ_cσ²`, not 0), which is why the binned χ² of a smooth misfit exceeds the raw one by about the number of points per bin and the report quotes χ² on the measured grid. Bins with non-positive mean are dropped (`drop_nonpositive = true`); this removes the negative half of the noise at high q, biasing the survivors upward by ≈ 0.8σ̄ at a true value 0, 0.06σ̄ at 2σ̄ and < 0.005σ̄ above 3σ̄.
- **Bin bias and `rebin`.** A bin is the mean of the curve over its width, not its value at the mean q: `E[Ī] − I(q̄) ≈ ½ I″ Var_w(q) = (Δ²/24) I″` (relative: `Δ²/24 · |I″/I|`). Taking `|I″/I| ≤ (D/2)²` gives the worst-case relative bias `π²/(96·rebin²)` (7.1·10⁻⁴ at 12); this is a design heuristic (it holds for the monotone decay of compact particles, not as a theorem). `bin_bias_ratio` divides it by the smallest binned relative error; `shannon_data` raises `rebin` (`k ← max(k+1, ⌈k√(ℛ_k/0.3)⌉)`, at most 64 times, using `β_k ∝ k⁻²`) until the ratio is at most `BIN_BIAS_MAX = 0.3` (`max_bin_bias = Inf` keeps `rebin` as given), and fits the curve unbinned once the binned one holds at least 90 % as many points. `SHANNON_REBIN = 12` is the default and a minimum; the report prints the `rebin` used and the achieved `bin bias` (warn above 0.3).
- **Band limit.** `auto_lmax(D, q_max) = max(1, ⌈q_max·D⌉)`: the degree-`l` moment of a scatterer at `r ≤ D` is ∝ `j_l(qr)`, negligible once `l` exceeds `q_max D` by a few `x^{1/3}` (Scattering); conservative by up to 2 for a centred cloud, safe for any origin. The moment count grows as `(lMax+1)²`, a further reason to bin before building the forward model. For `D = 100 Å`, `q ∈ [0.01, 0.3]`: `N_s ≈ 9.2`, ~110 binned points, `lMax = 30`.
- `model_on_raw(info, y)`: the model on the measured grid by an interpolating cubic spline (Dierckx.jl/FITPACK; error 0.001σ for 1 % data at the default `rebin`), giving the reduced χ² on the measured points that a depositor's χ² refers to.
- `residual_structure(r)`: lag-1 autocorrelation (StatsBase.jl) and Wald–Wolfowitz runs-test z (HypothesisTests.jl) of the normalised residuals. White residuals have both ≈ 0; the fits are often far from that (lag-1 up to 0.89 on unbinned curves), a smooth misfit of the conventional model. Not in the report; `bb diagnose --residuals ID` prints them.

**Validation.** A validation run (removed; git history under `test/validation/shannon_binning/`) screened the effect of binning and of the filter. Per-fit shifts in the unbinned σ are a poor judge (that σ is overconfident), so `rebin = 12` was judged by distributions over the 53 fits against the unbinned results, with criteria fixed beforehand: median χ² on the measured grid within ±2 % (quartiles ±5 %, at most 3 fits worse by > 5 %); parameter medians moving < 0.25 of their interquartile range; no more than +2 fits above 1 % divergences, median steps per iteration and tree depth not > 25 % worse, E-BFMI above 0.3, the number of modes ±1 in ≥ 90 % of fits. The one failed clause (5 fits > 5 % worse, limit 3) is a definitional gap: the new χ² includes non-positive raw points, as FoXS does.
