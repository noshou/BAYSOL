# Utils

`BAYSOL.Utils` groups the small modules every other module builds on. Each stays a named submodule, re-bound at the package root, so `BAYSOL.PhysicalConstants`, `BAYSOL.Cache`, `BAYSOL.Timing`, `BAYSOL.PlasticSequence` and `BAYSOL.Shannon` are the names to import from (`using BAYSOL.Cache: Lazy`). `Utils` is loaded first, in dependency order: `PhysicalConstants`, `Cache`, `Timing`, `PlasticSequence`, `Shannon`.

## PhysicalConstants

Physical constants and units shared across the package, defined once (`PhysicalConstants.jl`)
so they cannot drift between modules. It is the first module loaded; every other module
imports what it needs by name:

```julia
# src/PartialMolarVolumes/PMV.jl
using ..PhysicalConstants: AVOGADRO, WATER_MOLAR_MASS
```

or, from outside the package, `using BAYSOL.PhysicalConstants: AVOGADRO`.

| constant | value | used by |
|---|---|---|
| `AVOGADRO` | 6.02214076 × 10²³ mol⁻¹ (exact, 2019 SI) | PartialMolarVolumes, Fitting |
| `PLANCK_CONSTANT`, `SPEED_OF_LIGHT`, `ELEMENTARY_CHARGE` | exact 2019 SI values of h, c, e | `HC_EV_ANGSTROM` |
| `HC_EV_ANGSTROM` | h·c ≈ 12398.42 eV·Å; E (eV) = `HC_EV_ANGSTROM` / λ (Å) | fitting scripts |
| `WATER_MOLAR_MASS` | 18.015268 g·mol⁻¹ (IAPWS-95) | PartialMolarVolumes |
| `WATER_ELECTRONS` | 10 | PartialMolarVolumes |
| `WATER_DENSITY_UNCERTAINTY` | 0.02 kg·m⁻³, absolute uncertainty on the Kell water density | PartialMolarVolumes |
| `KELL_DENSITY_NUM`, `KELL_DENSITY_DEN` | Kell (1975) coefficients: `ρ_w(t)` = Σ aₖtᵏ / (1 + b·t), kg·m⁻³, 0–150 °C | PartialMolarVolumes |
| `ANGSTROM3_PER_LITER`, `CM3_PER_LITER`, `ANGSTROM_PER_METER`, `PM_PER_ANGSTROM` | 10²⁷, 10³, 10¹⁰, 100 | PartialMolarVolumes, Fitting, AtomicRadii |
| `NM_INV_PER_ANGSTROM_INV` | 10 (an integer, so `q ./ NM_INV_PER_ANGSTROM_INV` is bit-identical to `q ./ 10`) | fitting scripts |
| `DRO_UNIT` | 0.03 e·Å⁻³, CRYSOL's --dro shell-contrast unit | Scattering, Fitting |
| `NS_PER_S`, `MS_PER_S` | 10⁹, 10³ | Timing, Fitting, Report |
| `STANDARD_TEMPERATURE_C` | 25 °C (298.15 K), the standard reference temperature; backs `PMV_REFERENCE_TEMPERATURE_C` and `DEFAULT_TEMPERATURE_C` so they cannot drift apart | PartialMolarVolumes, Fitting |

Every other tunable is a module-level constant in its owning module (see that module's README).

## Cache

Thread-safe memoization primitives, guarded by a ReentrantLock so concurrent callers racing on the same computation never double-compute or observe a torn store.

### Lazy {T} / force

A single deferred, memoized value of type T:

```julia
mutable struct Lazy{T}
    const f::Any            # zero-arg thunk
    const lock::ReentrantLock
    done::Bool
    value::T
end
```

- Lazy{T}(f) builds an unforced cache wrapping the zero-arg thunk f.
- force(c::Lazy{T})::T runs f once, under c's lock, the first time it's called; every subsequent call (concurrent or not) returns the already-computed value without re-running f.

```julia
using ..Cache: Lazy, force

struct Molecule
    ...
    _radii  :: Lazy{Vector{Float64}}
    _vols   :: Lazy{Vector{Float64}}
    _r_max  :: Lazy{Float64}
end

rad  = Lazy{Vector{Float64}}(() -> _compute_radii(es))
rmax = Lazy{Float64}(() -> maximum(force(rad)))
tree = Lazy{KDTree}(() -> KDTree(cart))
vol  = Lazy{Vector{Float64}}(() -> excluded_volume(cart, force(rad), force(tree), force(rmax)))

radii(m::Molecule)::Vector{Float64} = force(m._radii)
vols(m::Molecule)::Vector{Float64}  = force(m._vols)
r_max(m::Molecule)::Float64         = force(m._r_max)
```

### KeyedCache {K,V}

```julia
struct KeyedCache{K,V}
    store::Dict{K,V}
    lock::ReentrantLock
end
```

- Base.get!(f::Union{Function,Type}, c::KeyedCache{K,V}, key::K)::V: returns the cached value for key, computing it via the zero-arg thunk f and storing it on a cache miss.
- Base.haskey(c::KeyedCache{K,V}, key::K)::Bool: whether key has already been memoized, also taken under the lock.

```julia
using ..Cache: KeyedCache

const _ρₑ_w_cache = KeyedCache{Int64, Tuple{Float64, Float64}}()
const _ϕ°_p_cache  = KeyedCache{Tuple{String, Float64, Float64}, Tuple{Int64, Float64, Float64}}()   # (sequence, pH, σ_pH)
const _ϕ°_s_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
const _ϕ°_d_cache  = KeyedCache{Tuple{String, Float64, Float64}, Tuple{Int64, Float64, Float64}}()   # (sequence, pH, σ_pH)
const _ϕ°_r_cache  = KeyedCache{Tuple{String, Float64, Float64}, Tuple{Int64, Float64, Float64}}()   # (sequence, pH, σ_pH)
```

## Timing

`StageLog` records wall-clock, JIT-compile and GC seconds per named stage of a run. `seed_model` creates one (so the wall clock starts at the top of `seed_model`), hands it to `forward_cache(...; stage_log=)` and `seed_fitting(...; timing=)`, and it rides in `Seed.timing` → `FitResult.timing`. `write_report` ends with a `=== Timing ===` section (static build vs sampling, per-stage, plus `report write` and `unaccounted`) and starts with `=== Run ===` (`n_atoms`, lMax, `n_q`, `n_samples`, `n_adapt`). Everything is a no-op when the log is `nothing`. `unaccounted` on a cold session is first-call JIT of `run_model`/`run_fitting`/`write_report`, which compiles before their own stages begin; the `(JIT)` column on that line shows it.

## GCPause

Julia collects whenever the heap has grown by an adaptive amount; with a small live heap and large temporary arrays that is often, and GC was a fifth of the wall clock of the fitting tests (37.6 of 185 s, unchanged by cutting the gradient's allocations: it sits in the static build). `with_gc_paused(f; budget)` runs `f` with automatic collection off (re-entrant: pauses nest, the collector comes back when the outermost ends, also on an exception, and only if it was on before) and `gc_checkpoint()`, called in the loops that allocate, runs one young collection (`GC.gc(false)`) once the live heap has grown by more than `budget` (default 1 GiB, `GC_PAUSE_BUDGET`) since the last one. `seed_model` and `run_fitting` run inside a pause; checkpoints sit in the `B_lm` chunk loop, the MAP objective, the NUTS gradient and the re-profile loop. Garbage is thus bounded by the budget and cleared in a few large young collections.

## PlasticSequence

Even point sets drawn from the plastic (`R_d`) family of additive low-discrepancy sequences (Roberts, M. (2018). The Unreasonable Effectiveness of Quasirandom Sequences.). Consumers: `SASA` (surface sampling directions) and `MolecularStructure.excluded_volume` (`plastic_points(N_VOL_SHELL, Val(3), Val(:volume))`).

- The plastic ratios are module-level constants in `PlasticSequence.jl`: `PLASTIC_RATIO_2` ≈ 1.324718 (real root of x³ = x + 1) and `PLASTIC_RATIO_3` ≈ 1.220744 (real root of x⁴ = x + 1), plus the precomputed powers `PLASTIC_RATIO_2_SQR`, `PLASTIC_RATIO_3_SQR` and `PLASTIC_RATIO_3_CUBE`. They are hardcoded rather than solved for at load time, so the package no longer depends on Roots.jl.
- Vec2, Vec3: NTuple{2,Float64}/NTuple{3,Float64} point types.
- `plastic_points`(n::Int, ::Val{2}) -> Vector{Vec2}: the first n raw 2-D R₂ terms (frac(i/ρ), frac(i/ρ²)), uniform on [0, 1)².
- `plastic_points`(n::Int, ::Val{3}) -> Vector{Vec3} (same as Val{3}, Val{:surface}): those same 2-D R₂ terms read as (azimuth, height) and lifted onto the **surface** of the unit sphere via Lambert's cylindrical equal-area projection. Points are uniform in *area*, |p| == 1 .
- `plastic_points`(n::Int, ::Val{3}, ::Val{:volume}) -> Vector{Vec3}: the 3-D R₃ terms lifted to **fill** the unit ball, a 3-D region built from the R₃ generator (the extra coordinate becomes a radius, inverse-CDF-corrected for the sphere's r²dr volume element). Points are uniform in *volume*, 0 ≤ |p| < 1.
- `plastic_points`(n::Int; dim::Int=3, shape::Symbol=:surface): keyword convenience dispatching to the Val methods above; shape is only consulted when dim == 3.

Both 3-D layouts are deterministic and prefix-stable, term i never changes as n grows, so `plastic_points`(k, args...) == `plastic_points`(n, args...)[1:k] for any k ≤ n.

```julia
using BAYSOL.PlasticSequence: plastic_points

pts2d = plastic_points(500, Val(2))                 # Vector{Vec2}, [0,1)^2
surf  = plastic_points(256)                         # Vector{Vec3}, sphere surface (default)
ball  = plastic_points(256, Val(3), Val(:volume))   # Vector{Vec3}, fills the sphere volume
```

## Shannon

A particle of diameter D scatters a curve that carries no information at a q spacing finer than π/D (one *Shannon channel*), so a curve of thousands of points holds only N_s = (q_max − q_min)·D/π independent values: the median fitting test had 62 points per channel. Fitting all of them costs time in every forward-model evaluation and makes the Gaussian likelihood claim far more independent data than exist. `Shannon` is the data reduction that precedes the fit:

- `cloud_diameter(points)`: the exact diameter of a `(3, n)` point cloud. The farthest pair of a set always lies on its convex hull, so the hull is built with [Quickhull.jl](https://github.com/augustt198/Quickhull.jl) and only its vertices (~100 of thousands of points) are compared pairwise; fewer than four points or a degenerate (collinear, coplanar, repeated) cloud is compared directly. `seed_model` applies it to the atoms **and** the hydration-shell beads (the actual scatterer cloud, 5-6 Å wider than the atoms alone).
- `shannon_data(q, I, σ; D, rebin, lMax, drop_nonpositive)`: inverse-variance binning of the curve to `rebin` bins per channel (bin width π/(rebin·D); each bin carries the weighted-mean q and I and σ = 1/√Σw, which keeps Σw·I and Σw, the sufficient statistics of the linear fit, unchanged), the drop of bins with non-positive mean intensity, and the band limit `auto_lmax(D, q_max) = ceil(q_max·D)`. It returns a `ShannonInfo` (also stored as `Fitting.Seed.shannon`) with both the fitted and the raw curve. `SHANNON_REBIN = 12` is the default.
- `model_on_raw(info, y)`: the model curve on the measured grid (an interpolating cubic spline from Dierckx.jl/FITPACK, error 0.001 σ for 1 % data at the default `rebin`), which gives the reduced χ² on the measured points that a depositor's χ² refers to.
- `residual_structure(r)`: lag-1 autocorrelation (StatsBase.jl) and Wald–Wolfowitz runs-test z-score (HypothesisTests.jl) of the normalized residuals. White residuals have both ≈ 0; the fits are far from that (lag-1 up to 0.89 on the unbinned curves), which means the posterior widths are optimistic by the factor the residual correlation implies. Binning does not cure that (it assumes independent errors, as the likelihood does); it is reported in the `=== Residuals at the MAP ===` section so the claim is checkable.

Dropping non-positive points is not neutral: it removes the negative half of the noise at high q, so what remains is biased upwards. It is the default (`drop_nonpositive = true`, as the fitting scripts always did, but after binning rather than before, where it removes far fewer points). `test/validation/shannon_binning/` is a per-fit screen of the effect of the binning and of the filter on the MAP and the Laplace width (run by `tclsh test/run/validate.tcl shannon_binning`). Per-fit shifts measured in the unbinned σ are a poor judge (that σ is overconfident), so the default `rebin = 12` is judged by distributions over the 53 fitting tests against the committed unbinned results, with criteria fixed before that rerun:

1. **Fit quality:** the median χ² on the measured grid within ±2 % and the quartiles within ±5 %; at most 3 fits worse by more than 5 % (better fits are not penalized).
2. **Parameter distribution** (MAP δρ₁, δρ₂, δρ₃, ρₑ, c1 across fits): each median moves by less than 0.25 of its interquartile range; the counts of fits at a prior bound, with c1 saturated, or beyond 3σ from the δρ₃ prior change by at most 3.
3. **Health of the regression:** fits with more than 1 % divergent transitions increase by at most 2; the median steps per iteration and the median tree depth are not more than 25 % worse; E-BFMI stays above 0.3 where it was; no chain fails outright; the MAP search finds the same number of modes (±1) in at least 90 % of the fits.

