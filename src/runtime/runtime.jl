# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Thread-safe memoization ([`Lazy`](@ref), [`KeyedCache`](@ref)), per-stage timing
([`StageLog`](@ref)), garbage-collector pausing ([`withGcPaused`](@ref)) and the
threading helpers (random streams per work item, ordered task maps, the BLAS scope).
"""
module Runtime

# --- constants and shared state (the included files use them) ---

# Fixed internals, not settings: changing them could break a run.

"Default byte budget of [`withGcPaused`](@ref): garbage allowed to
pile up before a checkpoint collects it (1 GiB)."
const GC_PAUSE_BUDGET = 1 << 30

const _LOCK = ReentrantLock()
# The counters are atomic because gcCheckpoint reads them without
# the lock, from any thread; every write happens under _LOCK.
const _DEPTH = Threads.Atomic{Int}(0)  # nesting depth of withGcPaused
# the thread that began the outermost pause: only
# it can switch the collector (see gcCheckpoint)
const _OWNER = Threads.Atomic{Int}(0)
# the collector's state when the outermost pause began (under _LOCK only)
const _WAS_ENABLED = Ref(true)
# bytes allocated (all threads) at the last collection this pause caused (or at its start)
const _LAST_ALLOC = Threads.Atomic{Int}(0)
const _BUDGET     = Threads.Atomic{Int}(GC_PAUSE_BUDGET)

"Seed offset of the SplitMix64 sequence (the 64-bit golden-ratio constant)."
const _SPLITMIX_GAMMA = 0x9e3779b97f4a7c15

const _WORKERS_OVERRIDE = Threads.Atomic{Int}(0)

const _CHAOS = Ref(0.0)

const _BLAS_LOCK  = ReentrantLock()
const _BLAS_DEPTH = Ref(0)
const _BLAS_SAVED = Ref(1)

include("cache.jl")
include("timing.jl")
include("gc-pause.jl")
include("parallel.jl")

end # module
