# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Runtime/Timing.jl (`StageLog`, `timed!`, `tick`/`tock!`,
# `fmt_count`) and the timing table.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Runtime:
    StageLog, Stage, timed!, tick, tock!, stage_seconds, fmt_count, process_age_s

@testset "Timing" begin
    @testset "fmt_count: plain below 1000, else thousands with trimmed decimals" begin
        @test fmt_count(0) == "0"
        @test fmt_count(999) == "999"
        @test fmt_count(1000) == "1k"
        @test fmt_count(1500) == "1.5k"
        @test fmt_count(2000) == "2k"
        @test fmt_count(14210) == "14.21k"
        @test fmt_count(100000) == "100k"
    end

    @testset "the startup: the age of the process when the log starts" begin
        @test process_age_s() ≥ 0
        log = StageLog()
        @test log.startup ≥ 0
        if isfile("/proc/self/stat")
            # counted from the start of the process: longer than the time since this log
            @test log.startup > 0.1
            @test process_age_s() ≥ log.startup
        end
        # the compile and GC counters at the start are those of the process
        @test log.compile0 ≤ Base.cumulative_compile_time_ns()[1]
        @test log.gc0 ≤ Base.gc_time_ns()
    end

    @testset "timed!: returns f's value; a parent is recorded before its children" begin
        log = StageLog()
        v = timed!(log, :static, 1, "outer"; note = "[cache hit]") do
            timed!(log, :static, 2, "inner") do
                sleep(0.01)
                7
            end
        end
        @test v == 7
        @test [s.name for s in log.stages] == ["outer", "inner"]
        @test [s.depth for s in log.stages] == [1, 2]
        @test log.stages[1].note == "[cache hit]"
        @test log.stages[1].seconds ≥ log.stages[2].seconds ≥ 0.01
    end

    @testset "a nothing log is a no-op that still runs f" begin
        @test timed!(() -> 3, nothing, :static, 1, "x") == 3
        @test tock!(nothing, :static, 1, "x", tick()) === nothing
    end

    @testset "stage_seconds sums only a group's depth-1 stages" begin
        log = StageLog()
        push!(log.stages, Stage(:static, 1, "a", 2.0, 0.5, 0.1, ""))
        push!(log.stages, Stage(:static, 2, "a.child", 1.5, 0.4, 0.1, ""))
        push!(log.stages, Stage(:sampling, 1, "b", 3.0, 0.0, 0.2, ""))
        @test stage_seconds(log, :static) == (2.0, 0.5, 0.1)
        @test stage_seconds(log, :sampling) == (3.0, 0.0, 0.2)
    end

    @testset "_timing_table: wall clock, startup, groups, nesting, the halves" begin
        log = StageLog()
        push!(log.stages, Stage(:static, 1, "pdb2pqr", 21.3, 0.1, 0.2, "[cache miss]"))
        push!(log.stages, Stage(:static, 1, "forward_cache", 25.9, 0.0, 0.0, ""))
        push!(log.stages, Stage(:static, 2, "hydration (SASA + B_lm)", 19.8, 0.0, 0.0, ""))
        push!(
            log.stages,
            Stage(:sampling, 1, "NUTS  (2k iters, 14.21k leapfrog, 4.8 ms/step)", 68.0,
                0.0, 0.0, ""),
        )
        push!(log.stages, Stage(:plot, 1, "fit", 0.5, 0.2, 0.0, ""))
        t = BAYSOL.Pipeline._timing_table(log, tick())
        names = [r.name for r in t.rows]
        @test startswith(names[1], "wall clock") && t.rows[1].depth == 0
        @test t.rows[1].pct == 100.0
        @test names[2] == "startup" && t.rows[2].secs == log.startup
        # a group sums its depth-1 stages; a stage is a level below its group
        static = only(filter(r -> r.name == "static build", t.rows))
        @test static.secs ≈ 21.3 + 25.9 && static.depth == 1
        @test only(filter(r -> startswith(r.name, "hydration"), t.rows)).depth == 3
        # the stages are in the order they were recorded, then report write and unaccounted
        @test names[(end-1):end] == ["report write", "unaccounted"]
        # every row has its JIT and GC seconds; the halves of the wall clock add up
        pdb = only(filter(r -> r.name == "pdb2pqr", t.rows))
        @test pdb.jit == 0.1 && pdb.gc == 0.2 && pdb.note == "[cache miss]"
        @test t.fit + t.plot ≈ t.rows[1].secs
        @test t.plot ≈ 0.5
        # without a plot stage there is no plotting group, and the plot timing is 0
        t2 = BAYSOL.Pipeline._timing_table(StageLog(), tick())
        @test !any(r -> r.name == "plotting", t2.rows) && t2.plot == 0
    end

    @testset "_timing_text: the table as a person reads it" begin
        P = BAYSOL.Pipeline
        log = StageLog()
        push!(log.stages, Stage(:static, 1, "pdb2pqr", 21.3, 0.1, 0.2, "[cache miss]"))
        push!(log.stages, Stage(:static, 1, "resolve_structure", 0.0023, 0.0, 0.0, ""))
        push!(log.stages, Stage(:static, 2, "hydration (SASA + B_lm)", 19.8, 0.0, 0.0, ""))
        push!(
            log.stages,
            Stage(:sampling, 1, "NUTS  (2k iters, 14.21k leapfrog, 4.8 ms/step)", 68.0,
                0.0, 0.0, ""),
        )
        lines = P._timing_text(P._timing_table(log, tick()))
        @test startswith(lines[1], "stage") && occursin("% wall", lines[1])
        @test occursin("(JIT)", lines[1]) && occursin("(GC)", lines[1])
        @test endswith(lines[1], "notes")
        @test startswith(lines[2], "wall clock") &&
              endswith(lines[2], "process start to end")
        @test any(startswith("  static build"), lines)
        # a stage's note is in a column of its own, on the stage's line, without brackets
        i = findfirst(l -> startswith(l, "    pdb2pqr"), lines)
        @test i !== nothing && occursin(r"21\.30\s", lines[i]) &&
              endswith(lines[i], "(0.2)  cache miss")
        # what a name carries in parentheses is a note too, and the name is clean
        @test only(filter(l -> startswith(l, "    NUTS"), lines)) |>
              l ->
            endswith(l, "2k iters, 14.21k leapfrog, 4.8 ms/step")
        @test !any(contains("["), lines[2:(end-3)])
        # a level is two more spaces; a stage of a few milliseconds is not rounded to 0.00
        @test any(
            l -> startswith(l, "      hydration") && endswith(l, "SASA + B_lm"),
            lines,
        )
        @test any(l -> startswith(l, "    resolve_structure") && occursin("2.3e-03", l),
            lines)
        # every row has its share of the wall clock, its JIT and its GC
        row = only(filter(l -> startswith(l, "    pdb2pqr"), lines))
        @test occursin(r"\d+\.\d\s+\(0\.1\)\s+\(0\.2\)", row)
        # the GC line, then the two halves of the wall clock, are the last three lines
        @test startswith(lines[end-2], "GC: ") && startswith(lines[end-1], "fit timing  = ")
        @test startswith(lines[end], "plot timing = ")
        # the seconds column ends at the same character on every stage row (character
        # positions, not byte offsets)
        tail = r"\S+(?=\s+-?[\d.]+\s+\([\d.]+\)\s+\([\d.]+\))"
        charend(l) = length(l[1:something(findfirst(tail, l)).stop])
        rows = filter(l -> occursin(r"\(\d+\.\d\)\s+\(\d+\.\d\)", l), lines)
        @test length(rows) ≥ 6 && length(unique(charend.(rows))) == 1
        @test P._fmt_seconds(25.9) == "25.90" && P._fmt_seconds(0.01) == "0.01" &&
              P._fmt_seconds(0.0099) == "9.9e-03" && P._fmt_seconds(0) == "0"
    end
end
