# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Named stage of a run, for the report's `=== Timing ===` section.
A [`StageLog`](@ref) is created when a run starts and is handed down
to whatever should be timed; everything is a no-op when the log is `nothing`.
"""
module Timing

using ...PhysicalConstants: NS_PER_S

export Stage, StageLog, tick, tock!, timed!, stage_seconds, fmt_count

"""
One timed stage. `group` is `:static`, `:sampling` or `:report`; `depth` 1 is a
direct child of its group, 2 a child of the preceding depth-1 stage, and so on.
`compile` and `gc` are the seconds of `seconds` spent compiling and in GC.
`note` is free text printed next to the name (e.g. `[cache hit]`).
"""
struct Stage
    group::Symbol
    depth::Int
    name::String
    seconds::Float64
    compile::Float64
    gc::Float64
    note::String
end

"""
Stages in execution order (a parent precedes its children), the start time of the
run (`t0`, `time_ns()`; `compile0`, the compile counter then), and free-form run
facts (`info`, e.g. lMax, `n_samples`).
"""
mutable struct StageLog
    const t0::UInt64
    const compile0::UInt64
    const stages::Vector{Stage}
    const info::Dict{String,Any}
    const lock::ReentrantLock
    function StageLog()
        Base.cumulative_compile_timing(true)
        return new(
            time_ns(),
            Base.cumulative_compile_time_ns()[1],
            Stage[],
            Dict{String,Any}(),
            ReentrantLock()
        )
    end
end

"A snapshot of the clock, JIT-compile and GC counters. See [`tock!`](@ref)."
tick() = (time_ns(), Base.cumulative_compile_time_ns()[1], Base.gc_time_ns())

"""
Append the stage that began at `t = `[`tick`](@ref)`()` and ends
now, and return its `(seconds, compile, gc)`. A parent stage is
pushed *before* its children by [`timed!`](@ref); with `tick`/`tock!`
push order is finish order.
"""
function tock!(
    log::StageLog,
    group::Symbol,
    depth::Integer,
    name::AbstractString,
    t;
    note::AbstractString = ""
)
    secs, comp, gc = _deltas(t)
    @lock log.lock push!(
        log.stages,
        Stage(group, depth, name, secs, comp, gc, note)
    )
    return secs, comp, gc
end
tock!(::Nothing, args...; kw...) = nothing

_deltas(t) = (
    (time_ns() - t[1]) / NS_PER_S,
    (Base.cumulative_compile_time_ns()[1] - t[2]) / NS_PER_S,
    (Base.gc_time_ns() - t[3]) / NS_PER_S,
)

"""
Run `f()`, recording it as a stage, and return its value. The stage is reserved
before `f` runs, so stages `f` itself records sit after it (as its children).
"""
function timed!(
    f,
    log::StageLog,
    group::Symbol,
    depth::Integer,
    name::AbstractString;
    note::AbstractString = ""
)
    idx = @lock log.lock begin
        push!(log.stages, Stage(group, depth, name, 0.0, 0.0, 0.0, note))
        length(log.stages)
    end
    t = tick()
    v = f()
    secs, comp, gc = _deltas(t)
    @lock log.lock log.stages[idx] = Stage(
                                            group,
                                            depth,
                                            name,
                                            secs,
                                            comp,
                                            gc,
                                            note
                                        )
    return v
end
timed!(f, ::Nothing, args...; kw...) = f()

"""
Total `(seconds, compile, gc)` of a group's depth-1 stages.
"""
function stage_seconds(log::StageLog, group::Symbol)
    s = c = g = 0.0
    @lock log.lock for st in log.stages
        (st.group === group && st.depth == 1) || continue
        s += st.seconds; c += st.compile; g += st.gc
    end
    return s, c, g
end

"""
A count for the timing report: plain below 1000, else
thousands with up to two decimals and no trailing zeros
(2000 → `2k`, 14210 → `14.21k`, 1500 → `1.5k`).
"""
function fmt_count(n::Integer)
    n < 1000 && return string(n)
    x = string(round(n / 1000; digits = 2))
    return rstrip(rstrip(x, '0'), '.') * "k"
end

end # module
