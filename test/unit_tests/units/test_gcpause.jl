# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Runtime/GCPause.jl: the garbage collector paused around a call, nested pauses, restoration on an
# exception, and the byte-budget checkpoint.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.GCPause: with_gc_paused, gc_checkpoint, GC_PAUSE_BUDGET

gc_enabled() = (prev = GC.enable(true); GC.enable(prev); prev)     # GC.enable returns the previous state
n_collections() = Base.gc_num().pause

@testset "GCPause" begin

    @testset "the collector is off inside a pause and back on after, with the call's value returned" begin
        @test gc_enabled()
        v = with_gc_paused() do
            @test !gc_enabled()
            42
        end
        @test v == 42
        @test gc_enabled()
    end

    @testset "pauses nest: the collector returns only when the outermost one ends" begin
        with_gc_paused() do
            with_gc_paused() do
                @test !gc_enabled()
            end
            @test !gc_enabled()
        end
        @test gc_enabled()
    end

    @testset "an exception restores the collector" begin
        @test_throws ErrorException with_gc_paused(() -> error("boom"))
        @test gc_enabled()
        @test_throws ErrorException with_gc_paused(() -> with_gc_paused(() -> error("inner")))
        @test gc_enabled()
    end

    @testset "a collector the caller had switched off stays off" begin
        GC.enable(false)
        try
            with_gc_paused() do
                @test !gc_enabled()
            end
            @test !gc_enabled()
        finally
            GC.enable(true)
        end
        @test gc_enabled()
    end

    @testset "gc_checkpoint collects once the heap has grown past the budget, and stays quiet before" begin
        garbage(n) = [zeros(Float64, 2^17) for _ in 1:n]            # n × 1 MiB, dropped at once
        with_gc_paused(budget = 8 * 2^20) do
            c0 = n_collections()
            garbage(2); gc_checkpoint()
            @test n_collections() == c0                             # 2 MiB: under the budget
            garbage(12); gc_checkpoint()
            @test n_collections() > c0                              # 14 MiB: over it, one young collection ran
            @test !gc_enabled()                                     # and the pause is still in force
            c1 = n_collections()
            gc_checkpoint()
            @test n_collections() == c1                             # the baseline was reset: nothing to do now
        end
        @test gc_enabled()
    end

    @testset "outside a pause the checkpoint does nothing" begin
        c0 = n_collections()
        garbage = [zeros(Float64, 2^17) for _ in 1:20]
        gc_checkpoint()
        @test n_collections() == c0
        @test length(garbage) == 20
    end

    @testset "the default budget" begin
        @test GC_PAUSE_BUDGET == 2^30
    end
end
