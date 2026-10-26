# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Runtime/Timing.jl (`StageLog`, `timed!`, `tick`/`tock!`,
# `fmt_count`) and the timing table.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Runtime: StageLog, Stage, timed!, tick, tock!, stage_seconds, fmt_count
using BAYSOL.Pipeline: _write_timing

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

    @testset "_write_timing writes nothing without a log" begin
        io = IOBuffer()
        @test _write_timing(io, nothing, tick()) === nothing
        @test isempty(take!(io))
    end

    @testset "_write_timing: sections, nesting, and an aligned seconds column" begin
        log = StageLog()
        push!(log.stages, Stage(:static, 1, "pdb2pqr", 21.3, 0.0, 0.0, "[cache miss]"))
        push!(log.stages, Stage(:static, 1, "forward_cache", 25.9, 0.0, 0.0, ""))
        push!(log.stages, Stage(:static, 1, "resolve_structure", 0.0023, 0.0, 0.0, ""))
        push!(
            log.stages,
            Stage(:static, 1, "seed_sampler (priors, WLS)", 0.0, 0.0, 0.0, ""),
        )
        push!(log.stages, Stage(:static, 2, "hydration (SASA + B_lm)", 19.8, 0.0, 0.0, ""))
        push!(
            log.stages,
            Stage(
                :sampling,
                1,
                "NUTS  (2k iters, 14.21k leapfrog, 4.8 ms/step)",
                68.0,
                0.0,
                0.0,
                "",
            ),
        )
        io = IOBuffer()
        _write_timing(io, log, tick())
        lines = split(String(take!(io)), '\n'; keepempty = false)
        @test startswith(lines[1], "stage") && !any(contains("=== Timing ==="), lines)
        @test occursin("seconds", lines[1]) && occursin("% wall", lines[1]) &&
              occursin("(JIT)", lines[1])
        @test any(startswith("wall clock  (seed_model → end of timings)"), lines)
        @test any(l -> startswith(l, "  static build"), lines)
        # a stage's note is a line of its own under it
        i = findfirst(l -> startswith(l, "    pdb2pqr"), lines)
        @test i !== nothing && occursin(r"21\.30\s*$", lines[i]) &&
              strip(lines[i+1]) == "[cache miss]"
        # no line of the table is wider than the label column plus the numbers
        @test maximum(length, lines) <= 90
        # depth 2 → 6 spaces
        @test any(l -> startswith(l, "      hydration (SASA + B_lm)"), lines)
        @test any(l -> startswith(l, "  report write"), lines) &&
              any(l -> startswith(l, "  unaccounted"), lines)
        # the GC line, then the two halves of the wall clock as the last two lines
        @test startswith(lines[end-2], "GC: ")
        @test startswith(lines[end-1], "fit timing  = ") &&
              startswith(lines[end], "plot timing = ")
        # a stage of a few milliseconds is not rounded
        # to 0.00: it prints in scientific notation
        @test any(
            l -> startswith(l, "    resolve_structure") && occursin(r"2\.3e-03\s*$", l),
            lines,
        )
        @test any(l -> startswith(l, "    seed_sampler") && occursin(r"\s0\s*$", l), lines)
        # a long note is wrapped to NOTE_WIDTH and loses no word
        long = join(("word$i" for i in 1:40), " ")
        wrapped = BAYSOL.Pipeline._wrap_note(long, 30)
        @test length(wrapped) > 1 && all(l -> length(l) <= 30, wrapped) &&
              join(wrapped, " ") == long
        @test BAYSOL.Pipeline._wrap_note("", 30) == String[]
        @test BAYSOL.Pipeline._fmt_seconds(25.9) == "25.90" &&
              BAYSOL.Pipeline._fmt_seconds(0.01) == "0.01" &&
              BAYSOL.Pipeline._fmt_seconds(0.0099) == "9.9e-03" &&
              BAYSOL.Pipeline._fmt_seconds(0) == "0"
        # the seconds column ends at the same character on every stage line
        # (character positions, not byte offsets: the wall-clock label contains "→")
        charend(l, r) = length(l[1:something(findfirst(r, l)).stop])
        ends = [
            charend(l, r"\d+\.\d\d(?=( |$))") for l in lines[2:(end-1)]
            if occursin(r"^\s*\S.*\d+\.\d\d", l)
        ]
        @test length(ends) ≥ 6
        header_end = charend(lines[1], r"seconds")
        @test all(==(header_end), ends)
    end
end
