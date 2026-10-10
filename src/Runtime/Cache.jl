# SPDX-License-Identifier: LGPL-2.1-or-later

# Thread safe caching primitives.

export Lazy, force, KeyedCache

"""
A cache of a value of type T, built unforced as `Lazy{T}(f)` from a zero-arg
thunk f; f runs once, on the first [`force`](@ref). `done` is atomic, so the
common already-built case reads the value without taking the lock.
"""
mutable struct Lazy{T}
    const f::Any
    const lock::ReentrantLock
    @atomic done::Bool
    value::T
    Lazy{T}(f) where {T} = new{T}(f, ReentrantLock(), false)
end

"""
Run c's thunk once, under its lock, then return
the stored value on every call.

# Arguments
    - `c`: the cache to force.
"""
function force(c::Lazy{T})::T where {T}
    (@atomic :acquire c.done) && return c.value
    @lock c.lock begin
        if !c.done
            c.value = c.f()::T
            @atomic :release c.done = true
        end
    end
    return c.value
end

"""
    KeyedCache{K,V}()

A thread-safe keyed memoization cache: a Dict{K,V} guarded by one
ReentrantLock. K/V stay concrete type parameters (never Any)
so Base.get! specializes like a bare Dict lookup would.
"""
struct KeyedCache{K,V}
    store::Dict{K,V}
    lock::ReentrantLock
    KeyedCache{K,V}() where {K,V} = new{K,V}(Dict{K,V}(), ReentrantLock())
end

"""
Return the cached value for key, computing it via the zero-arg thunk f
and storing it on the first miss. The lookup, compute-on-miss, and store are
all done under c's lock, so concurrent callers racing on the same missing
key never double-store or observe a torn Dict.

# Arguments
- `f`: zero-arg thunk, run only on a cache miss for key.
- `c`: the cache to look up/store into.
- `key`: the lookup key.
"""
function Base.get!(
    f::Union{Function,Type},
    c::KeyedCache{K,V},
    key::K,
)::V where {K,V}
    @lock c.lock begin
        haskey(c.store, key) && return c.store[key]
        v = f()::V
        c.store[key] = v
        return v
    end
end

"""
Whether key has already been memoized in c, taken under c's lock.
"""
Base.haskey(
    c::KeyedCache{K,V},
    key::K,
) where {K,V} = @lock c.lock haskey(c.store, key)
