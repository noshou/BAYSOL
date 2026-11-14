# Runtime

The process machinery the other modules run on (`BAYSOL.Runtime`): `cache.jl`, `timing.jl`, `gc-pause.jl`, `parallel.jl`. Names are imported from `Runtime` (`using ..Runtime: Lazy, tmapItems`).

## Cache

Thread-safe memoisation, guarded by a `ReentrantLock` so concurrent callers on one computation never double-compute or see a half-written store (the lock is held while the thunk runs, acceptable because thunks are short or run once).

- `Lazy{T}(f)`: a deferred, memoised value; `force(c)` runs the zero-argument thunk `f` once, under the lock, and returns the stored value to every later caller. `Molecule` uses it for its radii, volumes, `rMax` and k-d tree, so each is computed on first use by exactly one thread.
- `KeyedCache{K,V}`: a lock-guarded `Dict` with `get!(f, cache, key)` (compute on a miss) and `haskey`. It memoises the water density by temperature and the partial molar volume of a protein or nucleic-acid sequence by `(sequence, pH, σ_pH)`, and (as `KeyedCache{String,ReentrantLock}`) serialises one `propka3` run per structure in Hydrogenator.

```julia
using ..Runtime: Lazy, force, KeyedCache

rad  = Lazy{Vector{Float64}}(() -> _computeRadii(es))
rmax = Lazy{Float64}(() -> maximum(force(rad)))
radii(m::Molecule) = force(m._radii)

const _ρₑ_w_cache = KeyedCache{Int64, Tuple{Float64, Float64}}()
```

## Timing

`StageLog` records wall-clock, JIT-compile and GC seconds per named stage. `seedModel` creates one (the run starts at its top; the log also keeps the `startup`, the age of the process then, from `processAgeS()` (Linux: `/proc`; elsewhere the time since `Runtime` was loaded), and the compile and GC counters and the machine's load and free memory of that moment), hands it to `forwardCache(...; stageLog=)` and `seedSampler(...; timing=)`, and it rides in `Seed.timing` → `Inferred.timing`. `writeLog` writes the timing table into the run log (static build vs sampling, the `plotting` stages that `results` records, per stage, `report write`, `unaccounted`, with the seconds, JIT and GC of each; the wall clock starts with the process, `startup` being the time before `seedModel`), ending with `fit` (everything but the plotting) and `plot`; the run's settings (`nAtoms`, `lMax`, `nQ`, `nSamples`, `nAdapt`) are in the `run` sheet of the workbook and in the log. Everything is a no-op when the log is `nothing`. `unaccounted` in a cold session is the first-call JIT of `runModel`/`infer`/`writeLog`, compiled before their own stages begin (the JIT column shows it).

## GCPause

With a small live heap and large temporary arrays Julia collects often; GC was a fifth of the wall clock of the fitting tests. `withGcPaused(f; budget)` runs `f` with automatic collection off (re-entrant: pauses nest, the collector returns when the outermost ends, also on an exception, and only if it was on before), and `gcCheckpoint()` in the allocating loops runs one young collection (`GC.gc(false)`) once more than `budget` bytes (default 1 GiB, `GC_PAUSE_BUDGET`) have been allocated since the last. `seedModel` and `infer` run inside a pause, with checkpoints in the `bLm` chunk loop, the MAP objective, the NUTS gradient and the re-profile loop, so garbage is bounded by the budget and cleared in a few large collections.

With several threads there is one rule: **only the thread that began the pause collects.** `GC.enable` is a per-thread switch (the collector is off while any thread has switched it off): a worker's `GC.enable(true)` does nothing and its `GC.enable(false)` would leave the collector off for the process. `gcCheckpoint()` returns at once on any other thread, `tmapItems` has the pausing thread call it while it waits, and the budget counts what all threads allocated (`Base.gc_bytes()`).

## Parallel

**A result never depends on the number of Julia threads.** A floating-point sum depends on the order of its additions, so every threaded reduction is grouped by the input, never by the thread count, and every random stream is a function of its label.

- `drawBase()`: one `UInt64` of 53 bits for a run from the default RNG (so `Random.seed!` before a run fixes it; 53 bits so that a spreadsheet, whose numbers are `Float64`, holds the seed exactly); a given `rngSeed` (0 by default) replaces it, and the `run` sheet of the workbook and the run log record it.
- `stream(base, purpose, index)`: the random stream of one work item (MAP start `i`, chain `k`, bridge proposal for mode `m`): a `Xoshiro` seeded by SplitMix64 mixing of the base, a fixed integer naming the use, and the index. SplitMix64 (`z = xor(z, z >> 30) * 0xbf58476d1ce4e5b9`, `z = xor(z, z >> 27) * 0x94d049bb133111eb`, `xor(z, z >> 31)`, a bijection on `UInt64`) is written out rather than using `hash`, so a published seed gives the same streams on every Julia version. Reproducibility rests on each stream being a deterministic function of its `(seed, purpose, index)` label, not on the independence of the streams.
- `tmapItems(f, xs)`: ordered map with one `Threads.@spawn` task per element (no chunking: each item is heavy); serial with one thread or at most one item. The job struct stores `f` and the items as `Any`, so the task code is compiled once and not per closure. A closure capturing a reassigned variable (a boxed capture) raises `ArgumentError`; a task's exception is rethrown as itself. While waiting, the calling thread runs the GC checkpoint.
- `tmapBlocks(f, n, block; threaded)`: applies `f` to the blocks `lo:hi` of `1:n` in block order, on the threads when `threaded` (the caller's size rule), else in a plain loop.
- `withBlasSingle(f)`: OpenBLAS limited to one thread while several Julia threads run (a threaded BLAS in concurrent tasks oversubscribes the cores); with one Julia thread it changes nothing. `workerCount()` is the number of default-pool threads.
- Test hooks: `withWorkers(f, n)` (1 forces the serial paths) and `withChaos(f, d)` (delays every task by up to `d` s) let `test-concurrency.jl` compare worker counts and scheduling orders.

### Using several threads

Start Julia with `julia -t auto` or `julia -t 6,1` (six workers and one interactive thread, which keeps a REPL or plot window responsive); the dev tools take `--threads N`. A fit gives bit-identical results at any thread count, memory stays bounded, and inputs under 4,096 atoms or beads run as before. On the threads: the multipole expansion (`computeBLm`: tiles dealt to 24 groups fixed by the input, summed per group, added in group order), the excluded volumes, SASA, bead classification and the amplitude fills (`_gaussianDummy`, `formFactors`). The gain flattens above four threads (efficiency cores are slower and every wave waits for its slowest worker). Not threaded: the MAP search and its Hessian (measured slower, 0.71× at four threads), each NUTS chain (sequential by nature; the chains run side by side, one task each) and PROPKA/pdb2pqr (external processes). Criteria and numbers: a validation run, removed, in git history under `test/validation/threading/`.
