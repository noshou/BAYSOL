# SPDX-License-Identifier: LGPL-2.1-or-later

# Helpers for the threaded stages: deterministic per-task random
# streams, a task-per-item ordered map, and a scope that keeps
# OpenBLAS single-threaded while Julia threads do the parallel work.
#
# Results never depend on the number of Julia threads: a stream belongs to the *work item*
# it was derived for (MAP start `i`, chain `k`), not to the thread that happens to run it.

using LinearAlgebra: BLAS
using OhMyThreads: tforeach, DynamicScheduler
using Random: Xoshiro

export worker_count,
    stream, draw_base, tmap_items, tmap_blocks, with_blas_single, with_workers, with_chaos

"""
SplitMix64's output function: a bijective scramble of one `UInt64`. Defined here (not
through `hash`) so a published seed gives the same streams on every Julia version.
"""
@inline function _splitmix(z::UInt64)::UInt64
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return z ⊻ (z >> 31)
end

"""
Number of Julia threads available to parallel stages (the default
thread pool; an interactive thread, `-t N,1`, is left free).

# Returns
- `Int`, at least 1.

# Exceptions
- None.
"""
worker_count()::Int = (o = _WORKERS_OVERRIDE[]) > 0 ? o : Threads.nthreads(:default)

"""
Test hook: runs `f()` with [`worker_count`](@ref) reporting `n` (1 forces every
threaded stage onto its serial path; larger values make the stages split their work
for `n` workers, on however many Julia threads exist), then restores it. For comparing
worker counts inside one process. Not for concurrent use by several callers at once.

# Returns
- Whatever `f()` returns.

# Exceptions
- `ArgumentError` if `n < 1`; whatever `f()` throws (the worker count is restored first).
"""
function with_workers(f, n::Integer)
    n ≥ 1 || throw(ArgumentError("with_workers: n must be ≥ 1"))
    prev = _WORKERS_OVERRIDE[]
    _WORKERS_OVERRIDE[] = n
    try
        return f()
    finally
        _WORKERS_OVERRIDE[] = prev
    end
end

"""
Test hook: runs `f()` with every task of [`tmap_items`](@ref) first
sleeping a random time of up to `max_delay` seconds, so tasks start and
finish in a different order on every run. Results of correct parallel
code must not change. Not for concurrent use by several callers at once.

# Returns
- Whatever `f()` returns.

# Exceptions
- Whatever `f()` throws (the delay is reset first).
"""
function with_chaos(f, max_delay::Real)
    prev = _CHAOS[]
    _CHAOS[] = Float64(max_delay)
    try
        return f()
    finally
        _CHAOS[] = prev
    end
end

"""
One fresh base value for a run, drawn from the default
RNG, so that `Random.seed!` before a run fixes it.

# Returns
- `UInt64`.

# Exceptions
- None.
"""
draw_base()::UInt64 = rand(UInt64)

"""
The random stream of one work item, derived from the run's `base` value.

`purpose` names what the stream is for (a fixed integer per use, e.g. MAP starts), `index`
is the item's position in that use. Distinct `(purpose, index)` pairs give streams that
are independent for all practical purposes; the same triple always gives the same stream.

# Arguments
- `base::UInt64`: the run's base value ([`draw_base`](@ref), or the user's `rng_seed`).
- `purpose::Integer`: which use of randomness this is.
- `index::Integer`: the item's index within that use.

# Returns
- `Xoshiro`, freshly seeded.

# Exceptions
- `InexactError` if `purpose` or `index` is negative.
"""
function stream(base::UInt64, purpose::Integer, index::Integer)::Xoshiro
    z = _splitmix(base + _SPLITMIX_GAMMA * (UInt64(purpose) + 1))
    z = _splitmix(z + _SPLITMIX_GAMMA * (UInt64(index) + 1))
    return Xoshiro(z)
end

"""
`f` applied to every element of `xs`, one task per element (no
chunking: each item is heavy), returned in the order of `xs`. Serial
when only one thread is available or there is at most one item.

An exception raised by `f` is rethrown as itself (not wrapped in a
`TaskFailedException`), so callers see the same error type at any thread count.

# Returns
- `Vector` of the results, `result[i] == f(xs[i])`.

# Exceptions
- Whatever `f` throws.
"""
function tmap_items(f, xs)
    (worker_count() == 1 || length(xs) ≤ 1) && return map(f, xs)
    # The results go into a pre-typed vector (not the task map's own result,
    # whose type inference cannot see), so callers stay type-stable.
    R = Base.promote_op(f, eltype(xs))
    out = Vector{R}(undef, length(xs))
    try
        chaos = _CHAOS[]
        # The map runs as a task; this thread, which may be the one that paused
        # the garbage collector, polls for its end and runs the collector's
        # checkpoint meanwhile (workers cannot, see gc_checkpoint).
        job = Threads.@spawn tforeach(
            eachindex(xs);
            scheduler = DynamicScheduler(; chunking = false),
        ) do i
            chaos > 0 && sleep(rand() * chaos)
            out[i] = f(xs[i])
        end
        # a short job ends within a few yields (this thread runs queued
        # tasks while it yields); a long one is waited for in 1 ms sleeps
        spins = 0
        while !istaskdone(job)
            gc_checkpoint()
            (spins += 1) ≤ 50 ? yield() : sleep(0.001)
        end
        wait(job)
        return out
    catch e
        while e isa TaskFailedException
            e = e.task.result
        end
        throw(e)
    end
end

"""
`f` applied to the consecutive blocks of `block` items of `1:n` (`f(lo:hi)`), in block
order: on the Julia threads ([`tmap_items`](@ref)) when `threaded`, else in a plain
serial loop. For loops whose iterations are independent and write only their own outputs,
so the blocks can run in any order. `threaded` is for the caller's size rule: below some
input size the tasks cost more than they save, and the result does not depend on it.

# Returns
- `Vector` of the blocks' results, in block order.

# Exceptions
- Whatever `f` throws, as itself (see [`tmap_items`](@ref)).
"""
function tmap_blocks(f, n::Integer, block::Integer; threaded::Bool = true)
    blocks = [lo:min(lo+block-1, n) for lo in 1:block:n]
    return threaded ? tmap_items(f, blocks) : map(f, blocks)
end

"""
Runs `f()` with OpenBLAS limited to one thread when Julia has several
(concurrent tasks each calling a threaded BLAS oversubscribe the cores), and
restores the previous BLAS thread count when the outermost scope ends. Scopes
nest. With one Julia thread nothing is changed, so BLAS keeps its own threads.

# Returns
- Whatever `f()` returns.

# Exceptions
- Whatever `f()` throws (the BLAS thread count is restored first).
"""
function with_blas_single(f)
    worker_count() == 1 && return f()
    lock(_BLAS_LOCK) do
        if _BLAS_DEPTH[] == 0
            _BLAS_SAVED[] = BLAS.get_num_threads()
            BLAS.set_num_threads(1)
        end
        _BLAS_DEPTH[] += 1
    end
    try
        return f()
    finally
        lock(_BLAS_LOCK) do
            _BLAS_DEPTH[] -= 1
            _BLAS_DEPTH[] == 0 && BLAS.set_num_threads(_BLAS_SAVED[])
        end
    end
end
