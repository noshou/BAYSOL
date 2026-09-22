# BayesolUtils

Leaf-level shared utilities

```julia
module BayesolUtils
    include("Constants.jl")
    include("Cache.jl")
    using .Constants: Constants
    using .Cache:      Cache
end
```

`src/BayeSol.jl` re-exports both submodules as `BayeSol.Constants` and
`BayeSol.Cache`.

## `Constants.jl`

A flat leaf module of `const` primitives, grouped by comment header into:

- **Floating-point accuracy** -- `DEFAULT_ATOL = 1.0e-9`, a shared default
  tolerance for `isapprox`/equality checks a few orders of magnitude above
  `Float64` roundoff.
- **Forward-model constants** -- defaults consumed by `Scattering`:
  `SHELL_THICKNESS` (3.0 Å hydration-shell thickness, CRYSOL's border-layer
  default), `PROBE_RADIUS` (1.4 Å water probe, forwarded to
  `SASA.shell_points`), `SHELL_N_TARGET` (`nothing` by default, lets
  `SASA.shell_points` size the hydration-shell dummy cloud from accessible
  area instead of a fixed count), `DRO_UNIT` (0.03 e·Å⁻³, CRYSOL's `--dro`
  shell-contrast unit), `B_LM_CHUNK` (`UInt64(2048)`, atoms/dummies per pass
  in `compute_B_lm`).
- **Physical constants** -- CODATA-exact SI constants used across the
  forward model and electrostatics: `AVOGADRO`, `ELEMENTARY_CHARGE`,
  `VACUUM_PERMITTIVITY`, `BOLTZMANN`, `ANGSTROM` (metres per Å),
  `MV_PER_CM`; plus two domain-derived constants: `PHOSPHATE_NET_CHARGE`
  (-0.24 e, the Manning-condensation-reduced net charge of a B-DNA
  phosphate group, derived in the docstring from Laage/Elsaesser/Hynes
  2017 §5.1) and `BOND_CUTOFF` (1.75 Å covalent-bond distance cutoff, used
  as the only connectivity proxy available since `Molecule` carries no
  bonding table).
- **Electrostatics/solution** -- `IONIC_STRENGTH_M` (0.15 mol/L,
  `debye_length`'s default ionic strength), `WATER_EPS_R` (80.0, water's
  static relative permittivity), `DEBYE_TEMPERATURE_K` (300.0 K),
  `CUTOFF_DEBYE_LENGTHS` (5.0 -- charge sites beyond this many Debye
  lengths from a bead are dropped from screened-electrostatic
  aggregation, since `exp(-5) ≈ 0.007` is already negligible next to the
  screened `1/r` prefactor).
- **Sampler defaults** -- `DEFAULT_TEMPERATURE_C` (25.0°C, the
  solution-temperature default for `_ρₑ`/`ρₑ_prior`'s bulk electron
  density calculation -- the docstring flags that this is *not* currently
  reconciled with `DEBYE_TEMPERATURE_K`, each keeps its own
  pre-existing default) and `C1_PRIOR_MASS_PERCENT` (95, the default
  percentage of `c1_prior`'s prior mass required to fall within CRYSOL's
  bound `[0.96, 1.04]` around `c_1 = 1`).

### Usage

Downstream modules `using` individual constants by name, e.g.:

```julia
# src/Scattering/Scattering.jl
using ..BayesolUtils.Constants: SHELL_THICKNESS, PROBE_RADIUS, SHELL_N_TARGET, DRO_UNIT, B_LM_CHUNK

# src/Solvation/Electrostatics.jl
using ...BayesolUtils.Constants: ELEMENTARY_CHARGE, VACUUM_PERMITTIVITY, BOLTZMANN, BOND_CUTOFF, ...

# src/PartialMolarVolumes/PMV.jl
using ..BayesolUtils.Constants: AVOGADRO
```

or, from outside the package, via the top-level re-export:

```julia
using BayeSol.Constants: AVOGADRO
```

as `test/unit_tests/test_dns.jl` does to independently re-derive the
`_ρₑ` formula for testing.

## `Cache.jl`

Two thread-safe memoization primitives, guarded by a `ReentrantLock` so concurrent callers racing on the same computation never double-compute or observe a torn store.

### `Lazy{T}` / `make` / `force`

A single deferred, memoized value of type `T`:

```julia
mutable struct Lazy{T}
    const f::Any            # zero-arg thunk
    const lock::ReentrantLock
    done::Bool
    value::T
end
```

- `make(::Type{T}, f) -> Lazy{T}` builds an unforced cache wrapping the
  zero-arg thunk `f`.
- `force(c::Lazy{T})::T` runs `f` once, under `c`'s lock, the first time it's called; every subsequent call (concurrent or not) returns the already-computed `value` without re-running `f`.

```julia
using ..BayesolUtils.Cache: Lazy, force

struct Molecule
    ...
    _radii  :: Lazy{Vector{Float64}}
    _vols   :: Lazy{Vector{Float64}}
    _r_max  :: Lazy{Float64}
end

rad  = Lazy{Vector{Float64}}(() -> _compute_radii(radii_source, es))
vol  = Lazy{Vector{Float64}}(() -> sphere_volume.(force(rad)))
rmax = Lazy{Float64}(() -> maximum(force(rad)))

radii(m::Molecule)::Vector{Float64} = force(m._radii)
vols(m::Molecule)::Vector{Float64}  = force(m._vols)
r_max(m::Molecule)::Float64         = force(m._r_max)
```

Note `vol`'s thunk itself calls `force(rad)`, so forcing `vols` also forces (and caches) `radii` as a side effect if it hasn't been forced already.

### `KeyedCache{K,V}`

A thread-safe keyed memoization cache -- effectively a `Dict{K,V}` behind a lock, with `K`/`V` kept as concrete type parameters (never `Any`) so that `Base.get!` specializes the way a bare `Dict` lookup would:

```julia
struct KeyedCache{K,V}
    store::Dict{K,V}
    lock::ReentrantLock
end
```

- `Base.get!(f::Union{Function,Type}, c::KeyedCache{K,V}, key::K)::V`:
  returns the cached value for `key`, computing it via the zero-arg
  thunk `f` and storing it on a cache miss. Lookup, compute-on-miss, and
  store all happen under `c`'s lock, so two threads racing on the same
  missing key can't double-store or see a partially-written `Dict`.
- `Base.haskey(c::KeyedCache{K,V}, key::K)::Bool`: whether `key` has
  already been memoized, also taken under the lock.

```julia
using ..BayesolUtils.Cache: KeyedCache

const _ρₑ_w_cache = KeyedCache{Int64, Tuple{Float64, Float64}}()
const _ϕ°_p_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
const _ϕ°_s_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
const _ϕ°_d_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
const _ϕ°_r_cache  = KeyedCache{String, Tuple{Int64, Float64, Float64}}()
```
