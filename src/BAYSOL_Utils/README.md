# BAYSOL_Utils

Leaf-level shared utilities

```julia
module BAYSOL_Utils
    include("Constants.jl")
    include("Cache.jl")
    include("Timing.jl")
    using .Constants: Constants
    using .Cache:     Cache
    using .Timing:    Timing
end
```

src/BAYSOL.jl re-exports Constants, Cache and Timing at the top level
(BAYSOL.Constants, BAYSOL.Cache, BAYSOL.Timing).

## Constants.jl

A flat leaf module of const primitives, grouped by comment header into:

- **Floating-point accuracy**  `DEFAULT_ATOL = 1.0e-9`, the unit for every absolute floating-point tolerance: tests compare with `DEFAULT_ATOL` or `k * DEFAULT_ATOL`, never a bare literal. (Method tolerances, e.g. finite-difference or Monte Carlo checks, and the c1 search step `EXCL_VOL_CORR_EPS` are separate.)
- **Forward-model constants** `SHELL_THICKNESS` (3.0 Å hydration-shell thickness, CRYSOL's border-layer default), `PROBE_RADIUS` (1.4 Å water probe, forwarded to [`SASA.shell_points`](@ref BAYSOL.SASA.shell_points)), `SHELL_N_TARGET` (nothing by default, lets [`SASA.shell_points`](@ref BAYSOL.SASA.shell_points) size the hydration-shell dummy cloud from accessible area instead of a fixed count), `N_VOL_SHELL` (2145 quasi-random points per atom for the power-diagram excluded-volume estimate in `MolecularStructure.excluded_volume`), `DRO_UNIT` (0.03 e·Å⁻³, CRYSOL's --dro shell-contrast unit), `B_LM_CHUNK` (`UInt64(2048)`, atoms/dummies per pass in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm)), `B_LM_TILE` (256 atoms per inner tile, the inner dimension of each per-degree BLAS product) and `B_LM_W_BYTES` (64 MiB budget for the per-tile W buffer, which sets the q-tile length).
- **Plastic-sequence constants** `PLASTIC_RATIO_2` (≈ 1.324718, real root of x³ = x + 1), `PLASTIC_RATIO_3` (≈ 1.220744, real root of x⁴ = x + 1) and their precomputed powers `_PLASTIC_RATIO_SQR`, `_PLASTIC_RATIO_3_SQR`, `_PLASTIC_RATIO_3_CUBE`, used by `Geometry.PlasticSequence`. Hardcoded rather than root-solved at load time.
- **SASA bead classification** `SHELL_AREA_PER_POINT`, `SHELL_MIN_POINTS`, `_SHELL_SAMPLE`, `_BEAD_RAY_RANGE`, `_BEAD_RAY_DIRS`, `_BEAD_CONVEX_ESCAPE` (see the SASA README), and the defaults of `SASA.sasa`: `SASA_N_OCC = 512` and `SASA_N_EXP = 4096` (sphere points per atom in the occlusion-witness and exposed-fraction passes) and `SASA_AREA_TOL = 2.0` (Å²: if an atom with no witness in the occlusion pass could still expose less than this, the exposure pass is skipped and it is treated as buried).
- **Run defaults** `DEFAULT_QUANTILES` (`"16-84"`, the default `quantiles` of `run_model`), `DEFAULT_TARGET_ACCEPT` (80, the default NUTS target acceptance rate `δ`, in percent, of `run_model`/`Fitting.run_fitting`; Stan's usual default).
- **Physical constants**  `AVOGADRO`, `WATER_MOLAR_MASS` (18.015268 g·mol⁻¹, IAPWS-95), `WATER_ELECTRONS` (10), and the unit conversions `ANGSTROM3_PER_LITER` (10²⁷) and `CM3_PER_LITER` (10³) used by the solvent electron-density calculation. Peptide backbone unit, added once per residue by the protein partial-molar-volume backend: `BACKBONE_PMV = (37.4, 0.1)` cm³·mol⁻¹ (value, uncertainty) and `BACKBONE_ELECTRONS = 30`.
- **Form factors** `WK_S_MAX = 6.0` (upper bound of the Waasmaier–Kirfel f0 parameterisation's s range) and `F2_LOG_FLOOR = 1e-99` (floor applied to Chantler f2 before log-log interpolation).
- **Timing** `NS_PER_S` (10⁹, nanoseconds per second; converts `time_ns()` and Base's `*_time_ns()` counters to seconds in `Timing` and the report's `=== Timing ===` section).
- **Spherical Bessel functions** `GAUTSCHI_MARGIN` (`(16, 6.0)`): the continued-fraction start order in [`Scattering.SphFuncs.sphBessRatios!`](@ref BAYSOL.Scattering.SphFuncs.sphBessRatios!) is max(lMax, ⌈x⌉) + 16 + ⌈6·x^(1/3)⌉. `BESSEL_CUTOFF` (1e-9): below it jₗ(q·r) is treated as zero in `compute_B_lm` (columns with q·r_max < x_cut(l) are skipped; see the Scattering README).
- **Sampler defaults** `DEFAULT_TEMPERATURE_C` (25.0°C, the default sample temperature for `_ρₑ`/[`Fitting.ρₑ_prior`](@ref BAYSOL.Fitting.ρₑ_prior)'s bulk electron density calculation; pass the real one), `PMV_REFERENCE_TEMPERATURE_C` (25.0°C, the temperature the partial-molar-volume tables are tabulated at) and `PMV_FRACTIONAL_EXPANSIBILITY` (3.0 × 10⁻³ K⁻¹, the bound used to widen a solute's 25°C ϕ° uncertainty away from 25°C; derivation in its docstring). `c1` is no longer a sampled parameter with its own prior — it is profiled out per posterior draw by [`Fitting.profiled_corrs`](@ref BAYSOL.Fitting.profiled_corrs) over `EXCL_VOL_CORR_BOUNDS = (cmin=0.8, cmax=1.3)`, searched with an `EXCL_VOL_CORR_EPS = 0.02` padding/grid-step (see [`Fitting.profiled_corrs`](@ref BAYSOL.Fitting.profiled_corrs)'s own docstring for the exact search and the grid-size formula, `((cmax+eps)-(cmin-eps))/eps + 1`, if tuning `eps` away from the default). Hydration-shell prior constants: `DRO_BOUNDS = (-10, 2)` (CRYSOL3's δρ₁/δρ₂ fitting limits), `DRO12_MODE = 1` (CRYSOL3's default δρ₁ = δρ₂, the prior mode; the Beta parameters are derived from it and `DRO_BOUNDS`), `φ_max = 1.25` (upper bound on cavity occupancy, fixing δρ₃'s upper bound), and the Beta-prior concentrations `DRO12_CONCENTRATION = 14` and `DRO3_CONCENTRATION = 1.25` (see [`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)).

### Usage

Downstream modules using individual constants by name, e.g.:

```Julia
# src/Scattering/Scattering.jl
using ..BAYSOL_Utils.Constants: SHELL_THICKNESS, PROBE_RADIUS, SHELL_N_TARGET, DRO_UNIT, B_LM_CHUNK

# src/PartialMolarVolumes/PMV.jl
using ..BAYSOL_Utils.Constants: AVOGADRO
```

or, from outside the package, via the top-level re-export:

```julia
using BAYSOL.Constants: AVOGADRO
```

## Cache.jl

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
using ..BAYSOL_Utils.Cache: Lazy, force

struct Molecule
    ...
    _radii  :: Lazy{Vector{Float64}}
    _vols   :: Lazy{Vector{Float64}}
    _r_max  :: Lazy{Float64}
end

rad  = Lazy{Vector{Float64}}(() -> _compute_radii(radii_source, es))
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
using ..BAYSOL_Utils.Cache: KeyedCache

const _ρₑ_w_cache = KeyedCache{Int64, Tuple{Float64, Float64}}()
const _ϕ°_p_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
const _ϕ°_s_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
const _ϕ°_d_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
const _ϕ°_r_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
```

## Timing.jl

`StageLog` records wall-clock, JIT-compile and GC seconds per named stage of a run. `seed_model` creates one (so the wall clock starts at the top of `seed_model`), hands it to `forward_cache(...; stage_log=)` and `seed_fitting(...; timing=)`, and it rides in `Seed.timing` → `FitResult.timing`. `write_report` ends with a `=== Timing ===` section (static build vs sampling, per-stage, plus `report write` and `unaccounted`) and starts with `=== Run ===` (n_atoms, lMax, n_q, n_samples, n_adapt). Everything is a no-op when the log is `nothing`. `unaccounted` on a cold session is first-call JIT of `run_model`/`run_fitting`/`write_report`, which compiles before their own stages begin; the `(JIT)` column on that line shows it.
