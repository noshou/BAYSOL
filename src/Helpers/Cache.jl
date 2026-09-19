# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Small caching primitives shared across the codebase.
"""
module Cache

export Lazy, make, force, KeyedCache

"A cache of a value of type `T`. The thunk runs on the first [`force`](@ref)."
mutable struct Lazy{T}
    const f::Any
    const lock::ReentrantLock
    done::Bool
    value::T
    Lazy{T}(f) where {T} = new{T}(f, ReentrantLock(), false)
end

"""
    make(::Type{T}, f) -> Lazy{T}

Build an unforced cache of the `T`-valued thunk `f`.

# Arguments
    - `::Type{T}`: element type the thunk returns.
    - `f`: zero-arg thunk, run once on the first [`force`](@ref).
"""
make(::Type{T}, f) where {T} = Lazy{T}(f)

"""
    force(c::Lazy{T}) -> T

Run `c`'s thunk once, under its lock, then return the stored value on every call.

# Arguments
    - `c`: the cache to force.
"""
function force(c::Lazy{T})::T where {T}
    @lock c.lock begin
        if !c.done
            c.value = c.f()::T
            c.done = true
        end
    end
    return c.value
end

"""
    KeyedCache{K,V}()

A thread-safe keyed memoization cache: a `Dict{K,V}` guarded by one
`ReentrantLock`. `K`/`V` stay concrete type parameters (never `Any`) 
so `Base.get!` specializes like a bare `Dict` lookup would.
"""
struct KeyedCache{K,V}
    store::Dict{K,V}
    lock::ReentrantLock
    KeyedCache{K,V}() where {K,V} = new{K,V}(Dict{K,V}(), ReentrantLock())
end

"""
    Base.get!(f::Union{Function,Type}, c::KeyedCache{K,V}, key::K) -> V

Return the cached value for `key`, computing it via the zero-arg thunk `f`
and storing it on the first miss. The lookup, compute-on-miss, and store are
all done under `c`'s lock, so concurrent callers racing on the same missing
key never double-store or observe a torn `Dict`.

# Arguments
- `f`: zero-arg thunk, run only on a cache miss for `key`.
- `c`: the cache to look up/store into.
- `key`: the lookup key.
"""
function Base.get!(f::Union{Function,Type}, c::KeyedCache{K,V}, key::K)::V where {K,V}
    @lock c.lock begin
        haskey(c.store, key) && return c.store[key]
        v = f()::V
        c.store[key] = v
        return v
    end
end

"""
    Base.haskey(c::KeyedCache{K,V}, key::K) -> Bool

Whether `key` has already been memoized in `c`, taken under `c`'s lock.
"""
Base.haskey(c::KeyedCache{K,V}, key::K) where {K,V} = @lock c.lock haskey(c.store, key)

end # module Cache
