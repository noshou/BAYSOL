# SPDX-License-Identifier: LGPL-2.1-or-later

# Pausing Julia's garbage collector around the allocation-heavy stretches of a
# fit, with a byte budget so memory stays bounded.
#
# Julia collects whenever the heap has grown by an adaptive amount, and with a small live
# heap and large temporary arrays (the `Y_lm` blocks of the static build) that is often:
# GC was a fifth of the wall clock of the fitting tests. [`with_gc_paused`](@ref) turns
# automatic collection off for the duration of a call (re-entrant: pauses nest and the
# collector comes back on when the outermost one ends, also on an exception, and only if
# it was on before), and [`gc_checkpoint`](@ref), called in the loops that allocate, runs
# one cheap young collection (`GC.gc(false)`) once more than the budget has been
# allocated since the last one. So garbage piles up at most `budget` bytes beyond the
# live data, and is cleared in a few large young collections rather than many small ones.

export with_gc_paused, gc_checkpoint, GC_PAUSE_BUDGET

"""
Runs `f()` with automatic garbage collection off, and returns its value.

Pauses nest (a depth counter, under a lock): the collector is switched off by
the outermost call and back on, if it was on before, when that call ends, whether
`f` returned or threw. Nested calls keep the smallest budget given.

# Arguments
- `f`: a zero-argument function.

# Keywords
- `budget::Integer = GC_PAUSE_BUDGET`: bytes of heap growth that
    [`gc_checkpoint`](@ref) tolerates before collecting.

# Returns
- Whatever `f()` returns.
"""
function with_gc_paused(f; budget::Integer = GC_PAUSE_BUDGET)
    lock(_LOCK) do
        if _DEPTH[] == 0
            _WAS_ENABLED[] = GC.enable(false)
            _OWNER[] = Threads.threadid()
            _LAST_ALLOC[] = Base.gc_bytes()
            _BUDGET[] = budget
        else
            _BUDGET[] = min(_BUDGET[], budget)
        end
        Threads.atomic_add!(_DEPTH, 1)
    end
    try
        return f()
    finally
        lock(_LOCK) do
            Threads.atomic_sub!(_DEPTH, 1)
            if _DEPTH[] == 0
                # GC.enable is per thread: only the thread that
                # disabled the collector can enable it again
                Threads.threadid() == _OWNER[] ||
                    @warn "with_gc_paused ended on another thread than it began on: " *
                          "the collector stays off"
                _WAS_ENABLED[] && GC.enable(true)
            end
        end
    end
end

"""
Inside [`with_gc_paused`](@ref): if more than the budget in bytes has been allocated (by
all threads: `Base.gc_bytes()`, not the live-heap counter, which does not see what worker
threads allocated until a collection) since the last collection, runs one young
collection (`GC.gc(false)`) and resets the baseline. Does nothing otherwise, and nothing
outside a pause. Cheap enough (atomic reads and a compare) to call once per iteration of
a hot loop. Safe from several threads, but only the thread that began the pause collects:
`GC.enable` is a per-thread switch (the collector is off while any thread has switched it
off), so a worker thread's `GC.enable(true)` does nothing and its `GC.enable(false)`
would leave the collector off for good. Workers' calls return at once; the owning thread
calls this while it waits for them ([`tmap_items`](@ref BAYSOL.Runtime.tmap_items)), and
the budget counts what all threads allocated.
"""
function gc_checkpoint()
    _DEPTH[] > 0 || return nothing
    Threads.threadid() == _OWNER[] || return nothing
    Base.gc_bytes() - _LAST_ALLOC[] > _BUDGET[] || return nothing
    trylock(_LOCK) || return nothing
    try
        if _DEPTH[] > 0 && Base.gc_bytes() - _LAST_ALLOC[] > _BUDGET[]
            # a collection requested while the collector is off would be skipped
            GC.enable(true)
            GC.gc(false)
            GC.enable(false)
            _LAST_ALLOC[] = Base.gc_bytes()
        end
    finally
        unlock(_LOCK)
    end
    return nothing
end
