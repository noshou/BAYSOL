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

With several Julia threads the pause has one rule: **only the thread that began it collects.** `GC.enable` is a per-thread switch (the collector is off while any thread has switched it off), so a worker thread's `GC.enable(true)` does nothing and its `GC.enable(false)` would leave the collector off for the rest of the process. `gc_checkpoint()` therefore returns at once on any other thread, and `Parallel.tmap_items` has the pausing thread call it while it waits for its tasks. The byte budget counts what all threads allocated (`Base.gc_bytes()`, not the live-heap counter, which does not see worker allocations until a collection).

## Parallel

The threaded stages are built on a few small tools, so that **a result never depends on the number of Julia threads**.

- `draw_base()` draws one `UInt64` for a run from the default RNG (so `Random.seed!` before a run fixes it); the run's `rng_seed` keyword replaces it, and it is printed in the report's `=== Run ===` section.
- `stream(base, purpose, index)` is the random stream of one *work item* (MAP start `i`, chain `k`): a `Xoshiro` seeded by SplitMix64 mixing of the base, a fixed integer naming the use, and the item's index. A stream belongs to the item, not to the thread that runs it. SplitMix64 is written out here (not `hash`) so a published seed gives the same streams on every Julia version.
- `tmap_items(f, xs)` is an ordered map with one task per element ([OhMyThreads.jl](https://github.com/JuliaFolds2/OhMyThreads.jl), no chunking, since each item is heavy); serial with one thread or at most one item. An exception in a task is rethrown as itself, not wrapped. While it waits, the calling thread runs the garbage-collector checkpoint (see GCPause).
- `tmap_blocks(f, n, block; threaded)` applies `f` to the blocks `lo:hi` of `1:n` in block order, on the threads when `threaded` (the caller's size rule: below some input size the tasks cost more than they save), else in a plain loop.
- `with_blas_single(f)` runs `f` with OpenBLAS limited to one thread when Julia has several (concurrent tasks calling a threaded BLAS oversubscribe the cores) and restores it when the outermost scope ends; with one Julia thread it changes nothing, so BLAS keeps its own threads. `worker_count()` is the number of default-pool threads.
- Test hooks: `with_workers(f, n)` makes the stages split their work for `n` workers (1 forces the serial paths) and `with_chaos(f, d)` delays every task by a random time up to `d` seconds. They let `test_concurrency.jl` compare worker counts and scheduling orders in one process.

### Using several threads

Julia starts with one thread. To use more, start it with `julia -t auto` (all logical CPUs) or `julia -t 6,1` (six workers and one interactive thread, which keeps a REPL or plot window responsive); the developer tools take `--threads N` and pass it on. Nothing else changes: a fit gives **bit-identical results at any thread count** (checked at 1, 2, 3, 4, 6, 7 and 8 threads), memory stays bounded (peak resident size of the largest structure's build is 1.7 GB at any thread count), and small inputs (under 4,096 atoms or hydration beads) run exactly as before, because the tasks would cost more than they save.

What runs on the threads, and what it buys on the three largest fitting tests (SASDUN5 60,302 atoms, SASDVG2 21,581, SASDJ62 9,679), measured on an Apple M2 (four performance and four efficiency cores), best of three warm builds:

- the multipole expansion of the forward cache (`compute_B_lm`: the atoms are cut into tiles, dealt to 24 groups fixed by the input, summed per group and added in group order), the excluded volumes, the SASA surface and the bead classification, and the amplitude fills (`_gaussian_dummy`, `form_factors`);
- `forward_cache` plus SASA take about 2.1× less time at 4 threads and about 2.5× at 6–8 (the largest structure's `forward_cache` alone goes from 3.4 s to 1.2 s at 8 threads, 2.8×), and the vacuum + excluded-volume `B_lm` pass alone about 2.4× at 6; the gain flattens above four threads because the efficiency cores are slower than the performance cores and every wave of groups waits for its slowest worker;
- not threaded: the MAP search and its Hessian (the whole search is about 8 ms warm, and threading it measured 0.71×, slower), the NUTS chain (sequential by nature; several chains are the way to use more cores there), and PROPKA and pdb2pqr (external processes).

The details and the criteria these numbers were judged against are in the threading validation (`test/validation/threading/`).
