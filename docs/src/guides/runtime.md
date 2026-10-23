# Runtime

The process machinery the other modules run on (`BAYSOL.Runtime`): `Cache.jl`, `Timing.jl`, `GCPause.jl`, `Parallel.jl`. Names are imported from `Runtime` (`using ..Runtime: Lazy, tmap_items`).

## Cache

Thread-safe memoisation, guarded by a `ReentrantLock` so concurrent callers on one computation never double-compute or see a half-written store (the lock is held while the thunk runs, acceptable because thunks are short or run once).

- `Lazy{T}(f)`: a deferred, memoised value; `force(c)` runs the zero-argument thunk `f` once, under the lock, and returns the stored value to every later caller. `Molecule` uses it for its radii, volumes, `r_max` and k-d tree, so each is computed on first use by exactly one thread.
- `KeyedCache{K,V}`: a lock-guarded `Dict` with `get!(f, cache, key)` (compute on a miss) and `haskey`. It memoises the water density by temperature and the partial molar volume of a protein or nucleic-acid sequence by `(sequence, pH, σ_pH)`, and (as `KeyedCache{String,ReentrantLock}`) serialises one `propka3` run per structure in Hydrogenator.

```julia
using ..Runtime: Lazy, force, KeyedCache

rad  = Lazy{Vector{Float64}}(() -> _compute_radii(es))
rmax = Lazy{Float64}(() -> maximum(force(rad)))
radii(m::Molecule) = force(m._radii)

const _ρₑ_w_cache = KeyedCache{Int64, Tuple{Float64, Float64}}()
```

## Timing

`StageLog` records wall-clock, JIT-compile and GC seconds per named stage. `seed_model` creates one (the wall clock starts at its top), hands it to `forward_cache(...; stage_log=)` and `seed_sampler(...; timing=)`, and it rides in `Seed.timing` → `Inferred.timing`. `write_report` starts with `=== Run ===` (`n_atoms`, `lMax`, `n_q`, `n_samples`, `n_adapt`) and ends with `=== Timing ===` (static build vs sampling, per stage, `report write`, `unaccounted`). Everything is a no-op when the log is `nothing`. `unaccounted` in a cold session is the first-call JIT of `run_model`/`infer`/`write_report`, compiled before their own stages begin (the `(JIT)` column shows it).

## GCPause

With a small live heap and large temporary arrays Julia collects often; GC was a fifth of the wall clock of the fitting tests. `with_gc_paused(f; budget)` runs `f` with automatic collection off (re-entrant: pauses nest, the collector returns when the outermost ends, also on an exception, and only if it was on before), and `gc_checkpoint()` in the allocating loops runs one young collection (`GC.gc(false)`) once more than `budget` bytes (default 1 GiB, `GC_PAUSE_BUDGET`) have been allocated since the last. `seed_model` and `infer` run inside a pause, with checkpoints in the `B_lm` chunk loop, the MAP objective, the NUTS gradient and the re-profile loop, so garbage is bounded by the budget and cleared in a few large collections.

With several threads there is one rule: **only the thread that began the pause collects.** `GC.enable` is a per-thread switch (the collector is off while any thread has switched it off): a worker's `GC.enable(true)` does nothing and its `GC.enable(false)` would leave the collector off for the process. `gc_checkpoint()` returns at once on any other thread, `tmap_items` has the pausing thread call it while it waits, and the budget counts what all threads allocated (`Base.gc_bytes()`).

## Parallel

**A result never depends on the number of Julia threads.** A floating-point sum depends on the order of its additions, so every threaded reduction is grouped by the input, never by the thread count, and every random stream is a function of its label.

- `draw_base()`: one `UInt64` for a run from the default RNG (so `Random.seed!` before a run fixes it); the `rng_seed` keyword replaces it and the report prints it.
- `stream(base, purpose, index)`: the random stream of one work item (MAP start `i`, chain `k`, bridge proposal for mode `m`): a `Xoshiro` seeded by SplitMix64 mixing of the base, a fixed integer naming the use, and the index. SplitMix64 (`z = xor(z, z >> 30) * 0xbf58476d1ce4e5b9`, `z = xor(z, z >> 27) * 0x94d049bb133111eb`, `xor(z, z >> 31)`, a bijection on `UInt64`) is written out rather than using `hash`, so a published seed gives the same streams on every Julia version. Reproducibility rests on each stream being a deterministic function of its `(seed, purpose, index)` label, not on the independence of the streams.
- `tmap_items(f, xs)`: ordered map with one `Threads.@spawn` task per element (no chunking: each item is heavy); serial with one thread or at most one item. The job struct stores `f` and the items as `Any`, so the task code is compiled once and not per closure. A closure capturing a reassigned variable (a boxed capture) raises `ArgumentError`; a task's exception is rethrown as itself. While waiting, the calling thread runs the GC checkpoint.
- `tmap_blocks(f, n, block; threaded)`: applies `f` to the blocks `lo:hi` of `1:n` in block order, on the threads when `threaded` (the caller's size rule), else in a plain loop.
- `with_blas_single(f)`: OpenBLAS limited to one thread while several Julia threads run (a threaded BLAS in concurrent tasks oversubscribes the cores); with one Julia thread it changes nothing. `worker_count()` is the number of default-pool threads.
- Test hooks: `with_workers(f, n)` (1 forces the serial paths) and `with_chaos(f, d)` (delays every task by up to `d` s) let `test_concurrency.jl` compare worker counts and scheduling orders.

### Using several threads

Start Julia with `julia -t auto` or `julia -t 6,1` (six workers and one interactive thread, which keeps a REPL or plot window responsive); the dev tools take `--threads N`. A fit gives bit-identical results at any thread count, memory stays bounded, and inputs under 4,096 atoms or beads run as before. On the threads: the multipole expansion (`compute_B_lm`: tiles dealt to 24 groups fixed by the input, summed per group, added in group order), the excluded volumes, SASA, bead classification and the amplitude fills (`_gaussian_dummy`, `form_factors`). The gain flattens above four threads (efficiency cores are slower and every wave waits for its slowest worker). Not threaded: the MAP search and its Hessian (measured slower, 0.71× at four threads), each NUTS chain (sequential by nature; the chains run side by side, one task each) and PROPKA/pdb2pqr (external processes). Criteria and numbers: `test/validation/threading/`.
