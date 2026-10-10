# Utils

`BAYSOL.Utils` groups the small scientific helpers every other module builds on. Each stays a named submodule, re-bound at the package root, so `BAYSOL.PhysicalConstants` and `BAYSOL.Shannon` are the names to import from (`using BAYSOL.PhysicalConstants: AVOGADRO`). `Utils` is loaded first, in dependency order: `PhysicalConstants`, `Shannon`. The process machinery (caching, timing, GC pausing, threading) lives in [`Runtime`](@ref BAYSOL.Runtime) and the point sets, excluded volumes and SASA in [`Geometry`](@ref BAYSOL.Geometry);

## PhysicalConstants

Physical constants and units shared across the package, defined once (`PhysicalConstants.jl`)
so they cannot drift between modules. It is the first module loaded; every other module
imports what it needs by name:

```julia
# src/BulkElectronDensity/BulkElectronDensity.jl
using ..PhysicalConstants: AVOGADRO, WATER_MOLAR_MASS
```

or, from outside the package, `using BAYSOL.PhysicalConstants: AVOGADRO`.

| constant | value | used by |
|---|---|---|
| `AVOGADRO` | 6.02214076 × 10²³ mol⁻¹ (exact, 2019 SI) | BulkElectronDensity, Inference |
| `PLANCK_CONSTANT`, `SPEED_OF_LIGHT`, `ELEMENTARY_CHARGE` | exact 2019 SI values of h, c, e | `HC_EV_ANGSTROM` |
| `HC_EV_ANGSTROM` | h·c ≈ 12398.42 eV·Å; E (eV) = `HC_EV_ANGSTROM` / λ (Å) | fitting scripts |
| `WATER_MOLAR_MASS` | 18.015268 g·mol⁻¹ (IAPWS-95) | BulkElectronDensity |
| `WATER_ELECTRONS` | 10 | BulkElectronDensity |
| `WATER_DENSITY_UNCERTAINTY` | 0.02 kg·m⁻³, absolute uncertainty on the Kell water density | BulkElectronDensity |
| `KELL_DENSITY_NUM`, `KELL_DENSITY_DEN` | Kell (1975) coefficients: `ρ_w(t)` = Σ aₖtᵏ / (1 + b·t), kg·m⁻³, 0–150 °C | BulkElectronDensity |
| `ANGSTROM3_PER_LITER`, `CM3_PER_LITER`, `ANGSTROM_PER_METER`, `PM_PER_ANGSTROM` | 10²⁷, 10³, 10¹⁰, 100 | BulkElectronDensity, Inference, AtomicRadii |
| `NM_INV_PER_ANGSTROM_INV` | 10 (an integer, so `q ./ NM_INV_PER_ANGSTROM_INV` is bit-identical to `q ./ 10`) | fitting scripts |
| `UNIT_OF_δρ` | 0.03 e·Å⁻³, CRYSOL's --dro shell-contrast unit | Scattering, Inference |
| `NS_PER_S`, `MS_PER_S` | 10⁹, 10³ | Timing, Inference, Pipeline |
| `STANDARD_TEMPERATURE_C` | 25 °C (298.15 K), the standard reference temperature; backs `PMV_REFERENCE_TEMPERATURE_C` and `DEFAULT_TEMPERATURE_C` so they cannot drift apart | BulkElectronDensity, Inference |

Every other tunable is a module-level constant in its owning module (see that module's README).

## Shannon

A particle of diameter D scatters a curve that carries no information at a q spacing finer than π/D (one *Shannon channel*), so a curve of thousands of points holds only `N_s` = (`q_max` − `q_min`)·D/π independent values: the median fitting test had 62 points per channel. Inference all of them costs time in every forward-model evaluation and makes the Gaussian likelihood claim far more independent data than exist. `Shannon` is the data reduction that precedes the fit:

- `cloud_diameter(points)`: the exact diameter of a `(3, n)` point cloud. The farthest pair of a set always lies on its convex hull, so the hull is built with [Quickhull.jl](https://github.com/augustt198/Quickhull.jl) and only its vertices (~100 of thousands of points) are compared pairwise; fewer than four points or a degenerate (collinear, coplanar, repeated) cloud is compared directly. `seed_model` applies it to the atoms **and** the hydration-shell beads (the actual scatterer cloud, 5-6 Å wider than the atoms alone).
- `shannon_data(q, I, σ; D, rebin, max_bin_bias, lMax, drop_nonpositive)`: inverse-variance binning of the curve to `rebin` bins per channel (bin width π/(rebin·D); each bin carries the weighted-mean q and I and σ = 1/√Σw, which keeps Σw·I and Σw, the sufficient statistics of the linear fit, unchanged), the drop of bins with non-positive mean intensity, and the band limit `auto_lmax(D, q_max) = ceil(q_max·D)`. It returns a `ShannonInfo` (also stored as `Inference.Seed.shannon`) with both the fitted and the raw curve. `SHANNON_REBIN = 12` is the default and a minimum: a bin is the mean of the curve over its width, not its value at the mean q, which shifts a bin by at most π²/(96·`rebin`²) of its value whatever the particle (`bin_bias_ratio` divides that bound by the curve's smallest relative error), so a precise curve needs finer bins. `shannon_data` therefore raises `rebin` until that ratio is at most `BIN_BIAS_MAX` = 0.3 (`max_bin_bias = Inf` keeps `rebin` as given), and fits the curve as measured once the bins are as fine as its points. The `rebin` the report prints is the one used.
- `model_on_raw(info, y)`: the model curve on the measured grid (an interpolating cubic spline from Dierckx.jl/FITPACK, error 0.001 σ for 1 % data at the default `rebin`), which gives the reduced χ² on the measured points that a depositor's χ² refers to.
- `residual_structure(r)`: lag-1 autocorrelation (StatsBase.jl) and Wald–Wolfowitz runs-test z-score (HypothesisTests.jl) of the normalized residuals. White residuals have both ≈ 0; the fits are often far from that (lag-1 up to 0.89 on the unbinned curves), a smooth misfit of the conventional model. The statistics are not in the report; `tclsh dev/diagnose.tcl --residuals ID` prints them for a fit (fitted and measured grid).

Dropping non-positive points is not neutral: it removes the negative half of the noise at high q, so what remains is biased upwards. It is the default (`drop_nonpositive = true`, as the fitting scripts always did, but after binning rather than before, where it removes far fewer points). `test/validation/shannon_binning/` is a per-fit screen of the effect of the binning and of the filter on the MAP and the Laplace width (run by `tclsh dev/validate.tcl shannon_binning`). Per-fit shifts measured in the unbinned σ are a poor judge (that σ is overconfident), so the default `rebin = 12` is judged by distributions over the 53 fitting tests against the committed unbinned results, with criteria fixed before that rerun:

1. **Fit quality:** the median χ² on the measured grid within ±2 % and the quartiles within ±5 %; at most 3 fits worse by more than 5 % (better fits are not penalized).
2. **Parameter distribution** (MAP δρ₁, δρ₂, δρ₃, ρₑ, c1 across fits): each median moves by less than 0.25 of its interquartile range; the counts of fits at a prior bound, with c1 saturated, or beyond 3σ from the δρ₃ prior change by at most 3.
3. **Health of the regression:** fits with more than 1 % divergent transitions increase by at most 2; the median steps per iteration and the median tree depth are not more than 25 % worse; E-BFMI stays above 0.3 where it was; no chain fails outright; the MAP search finds the same number of modes (±1) in at least 90 % of the fits.

