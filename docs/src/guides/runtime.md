# Runtime

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

`StageLog` records wall-clock, JIT-compile and GC seconds per named stage of a run. `seed_model` creates one (so the wall clock starts at the top of `seed_model`), hands it to `forward_cache(...; stage_log=)` and `seed_sampler(...; timing=)`, and it rides in `Seed.timing` → `Inferred.timing`. `write_report` ends with a `=== Timing ===` section (static build vs sampling, per-stage, plus `report write` and `unaccounted`) and starts with `=== Run ===` (`n_atoms`, lMax, `n_q`, `n_samples`, `n_adapt`). Everything is a no-op when the log is `nothing`. `unaccounted` on a cold session is first-call JIT of `run_model`/`infer`/`write_report`, which compiles before their own stages begin; the `(JIT)` column on that line shows it.

## GCPause

Julia collects whenever the heap has grown by an adaptive amount; with a small live heap and large temporary arrays that is often, and GC was a fifth of the wall clock of the fitting tests (37.6 of 185 s, unchanged by cutting the gradient's allocations: it sits in the static build). `with_gc_paused(f; budget)` runs `f` with automatic collection off (re-entrant: pauses nest, the collector comes back when the outermost ends, also on an exception, and only if it was on before) and `gc_checkpoint()`, called in the loops that allocate, runs one young collection (`GC.gc(false)`) once the live heap has grown by more than `budget` (default 1 GiB, `GC_PAUSE_BUDGET`) since the last one. `seed_model` and `infer` run inside a pause; checkpoints sit in the `B_lm` chunk loop, the MAP objective, the NUTS gradient and the re-profile loop. Garbage is thus bounded by the budget and cleared in a few large young collections.
