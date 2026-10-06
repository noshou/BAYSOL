# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Timing/Timing.jl (`StageLog`, `timed!`, `tick`/`tock!`,
# `fmt_count`) and the report's `=== Run ===` / `=== Timing ===` sections.
include(joinpath(@__DIR__, "testsetup.jl"))

using BAYSOL.Timing: StageLog, Stage, timed!, tick, tock!, stage_seconds, fmt_count
using BAYSOL.Report: _write_timing, _write_run_info

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

    @testset "_write_run_info / _write_timing write nothing without a log" begin
        io = IOBuffer()
        @test _write_run_info(io, nothing) === nothing
        _write_run_info(io, nothing; n_atoms = 327)       # a bare n_atoms still gets a Run section
        @test occursin(r"=== Run ===\nn_atoms\s+= 327", String(take!(io)))
        @test _write_timing(io, nothing, tick()) === nothing
        @test isempty(take!(io))
    end

    @testset "_write_timing: sections, nesting, and an aligned seconds column" begin
        log = StageLog()
        log.info["n_atoms"] = 602; log.info["lMax"] = 12; log.info["n_q"] = 60; log.info["n_samples"] = 2000; log.info["n_adapt"] = 1000
        push!(log.stages, Stage(:static, 1, "pdb2pqr", 21.3, 0.0, 0.0, "[cache miss]"))
        push!(log.stages, Stage(:static, 1, "forward_cache", 25.9, 0.0, 0.0, ""))
        push!(log.stages, Stage(:static, 2, "hydration (SASA + B_lm)", 19.8, 0.0, 0.0, ""))
        push!(log.stages, Stage(:sampling, 1, "NUTS  (2k iters, 14.21k leapfrog, 4.8 ms/step)", 68.0, 0.0, 0.0, ""))
        io = IOBuffer()
        _write_run_info(io, log)
        run_txt = String(take!(io))
        @test occursin("=== Run ===", run_txt)
        @test occursin(r"n_atoms\s+= 602", run_txt) && occursin(r"lMax\s+= 12", run_txt)
        @test findfirst("n_atoms", run_txt).start < findfirst("lMax", run_txt).start
        @test occursin(r"n_samples\s+= 2000", run_txt)

        _write_timing(io, log, tick())
        lines = split(String(take!(io)), '\n'; keepempty = false)
        @test startswith(lines[1], "=== Timing ===")
        @test occursin("seconds", lines[1]) && occursin("% wall", lines[1]) && occursin("(JIT)", lines[1])
        @test any(startswith("wall clock  (seed_model → end of report)"), lines)
        @test any(l -> startswith(l, "  static build"), lines)
        @test any(l -> startswith(l, "    pdb2pqr") && occursin("[cache miss]", l), lines)
        @test any(l -> startswith(l, "      hydration (SASA + B_lm)"), lines)   # depth 2 → 6 spaces
        @test any(l -> startswith(l, "  report write"), lines) && any(l -> startswith(l, "  unaccounted"), lines)
        @test startswith(lines[end], "GC: ")
        # the seconds column ends at the same character on every stage line
        # (character positions, not byte offsets: the wall-clock label contains "→")
        charend(l, r) = length(l[1:something(findfirst(r, l)).stop])
        ends = [charend(l, r"\d+\.\d\d(?=( |$))") for l in lines[2:end-1]
                if occursin(r"^\s*\S.*\d+\.\d\d", l)]
        @test length(ends) ≥ 6
        header_end = charend(lines[1], r"seconds")
        @test all(==(header_end), ends)
    end
end
