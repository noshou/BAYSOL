# SPDX-License-Identifier: LGPL-2.1-or-later

# write_report's `=== Run ===` and `=== Timing ===` sections.

"""
The report's `=== Run ===` section: `n_atoms`, lMax, the measured and fitted point counts and the NUTS sizes, then how
the measured curve was reduced to the fitted one (the scatterer cloud's maximum diameter `Dₘₐₓ`, the Shannon channels, the
binning), as recorded in the run's [`Timing.StageLog`](@ref). `n_atoms`, if
given, overrides the logged count. Writes nothing when there is neither a log nor an `n_atoms`.
"""
function _write_run_info(io::IO, log::Union{Nothing,Timing.StageLog}; n_atoms::Union{Nothing,Integer} = nothing)
    info = log === nothing ? Dict{String,Any}() : copy(log.info)
    n_atoms === nothing || (info["n_atoms"] = n_atoms)
    isempty(info) && return nothing
    println(io, "=== Run ===")
    for k in ("n_atoms", "lMax", "n_q_raw", "n_q", "n_samples", "n_adapt")
        haskey(info, k) && @printf(io, "%-14s = %d\n", k, info[k])
    end
    if haskey(info, "D")
        @printf(io, "%-14s = %.1f Å (atoms and hydration-shell beads)\n", "Dₘₐₓ", info["D"])
        @printf(io, "%-14s = %.1f (q range × D / π)\n", "channels", info["n_channels"])
        if info["rebin"] > 0
            @printf(io, "%-14s = %d per channel: %d measured → %d fitted points (%d non-positive dropped)\n",
                    "rebin", info["rebin"], info["n_q_raw"], info["n_q"], info["n_nonpositive"])
        else
            @printf(io, "%-14s = none: %d measured → %d fitted points (%d non-positive dropped)\n",
                    "rebin", info["n_q_raw"], info["n_q"], info["n_nonpositive"])
        end
    end
    println(io)
    return nothing
end

"""
Seconds as the timing table prints them: two decimals, or, below 0.01 s, in scientific notation with two significant
figures (`3.0e-03`), so a stage that took a few milliseconds is not shown as a block of zeros. Exactly 0 prints as `0`.
"""
_fmt_seconds(x::Real) = x == 0 ? "0" : abs(x) < 0.01 ? @sprintf("%.1e", x) : @sprintf("%.2f", x)

"""
The report's `=== Timing ===` section, written last. The wall clock runs from the
creation of `log` (the start of [`seed_model`](@ref)) to now, i.e. to the end of the report.
`t_report` is the [`Timing.tick`](@ref) taken when [`write_report`](@ref) began, so the
`report write` line is the time spent writing every section before this one.
Nothing is written when `log` is `nothing`.

Stages print in the order they were recorded, indented two spaces per depth, with
the group lines (static build, sampling) summing their depth-1 stages. The label
column is as wide as the longest label so the seconds column always lines up.
"""
function _write_timing(io::IO, log::Union{Nothing,Timing.StageLog}, t_report)
    log === nothing && return nothing
    report_s = (time_ns() - t_report[1]) / NS_PER_S
    report_c = (Base.cumulative_compile_time_ns()[1] - t_report[2]) / NS_PER_S
    total_c  = (Base.cumulative_compile_time_ns()[1] - log.compile0) / NS_PER_S
    wall = (time_ns() - log.t0) / NS_PER_S
    st, st_c, st_g = Timing.stage_seconds(log, :static)
    sp, sp_c, sp_g = Timing.stage_seconds(log, :sampling)
    unacc = wall - st - sp - report_s
    # compile time not inside any stage: the first call of run_model, infer and
    # write_report compiles before their bodies (and so their stages) begin
    unacc_c = total_c - st_c - sp_c - report_c

    # (label, seconds, % of wall, JIT seconds); the last two are nothing on plain stage lines
    rows = Tuple{String,Float64,Union{Nothing,Float64},Union{Nothing,Float64}}[]
    push!(rows, ("wall clock  (seed_model → end of report)", wall, 100.0, total_c))
    for (group, label, tot, comp) in ((:static, "static build", st, st_c), (:sampling, "sampling", sp, sp_c))
        push!(rows, ("  " * label, tot, 100 * tot / wall, comp))
        for stage in log.stages
            stage.group === group || continue
            name = stage.note == "" ? stage.name : rpad(stage.name, 22) * stage.note
            push!(rows, ("  "^(stage.depth + 1) * name, stage.seconds, nothing, nothing))
        end
    end
    push!(rows, ("  report write", report_s, nothing, nothing))
    push!(rows, ("  unaccounted", unacc, nothing, max(unacc_c, 0.0)))

    w = maximum(length(r[1]) for r in rows)
    println(io)
    @printf(io, "%-*s %10s %9s %8s\n", w, "=== Timing ===", "seconds", "% wall", "(JIT)")
    for (label, secs, pct, jit) in rows
        @printf(io, "%-*s %10s", w, label, _fmt_seconds(secs))
        pct === nothing || @printf(io, " %9.1f", pct)
        jit === nothing || @printf(io, " %8s", @sprintf("(%.1f)", jit))
        println(io)
    end
    @printf(io, "GC: %s s\n", _fmt_seconds(st_g + sp_g))
    return nothing
end
