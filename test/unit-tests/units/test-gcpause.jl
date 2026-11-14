# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests for src/runtime/gc-pause.jl: the garbage collector paused around a call,
# nested pauses, restoration on an exception, and the byte-budget checkpoint.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Runtime: withGcPaused, gcCheckpoint, GC_PAUSE_BUDGET

# GC.enable returns the previous state
gcEnabled() = (prev = GC.enable(true); GC.enable(prev); prev)
nCollections() = Base.gc_num().pause

@testset "GCPause" begin

    # …with the call's value returned
    @testset "the collector is off inside a pause and back on after" begin
        @test gcEnabled()
        v = withGcPaused() do
            @test !gcEnabled()
            42
        end
        @test v == 42
        @test gcEnabled()
    end

    @testset "pauses nest: the collector returns only when the outermost one ends" begin
        withGcPaused() do
            withGcPaused() do
                @test !gcEnabled()
            end
            @test !gcEnabled()
        end
        @test gcEnabled()
    end

    @testset "an exception restores the collector" begin
        @test_throws ErrorException withGcPaused(() -> error("boom"))
        @test gcEnabled()
        @test_throws ErrorException withGcPaused(
            () -> withGcPaused(() -> error("inner")),
        )
        @test gcEnabled()
    end

    @testset "a collector the caller had switched off stays off" begin
        GC.enable(false)
        try
            withGcPaused() do
                @test !gcEnabled()
            end
            @test !gcEnabled()
        finally
            GC.enable(true)
        end
        @test gcEnabled()
    end

    # …and stays quiet before
    @testset "gcCheckpoint collects once the heap has grown past the budget" begin
        # n × 1 MiB, dropped at once
        garbage(n) = [zeros(Float64, 2^17) for _ in 1:n]
        withGcPaused(budget = 8 * 2^20) do
            c0 = nCollections()
            garbage(2)
            gcCheckpoint()
            # 2 MiB: under the budget
            @test nCollections() == c0
            garbage(12)
            gcCheckpoint()
            # 14 MiB: over it, one young collection ran
            @test nCollections() > c0
            # and the pause is still in force
            @test !gcEnabled()
            c1 = nCollections()
            gcCheckpoint()
            # the baseline was reset: nothing to do now
            @test nCollections() == c1
        end
        @test gcEnabled()
    end

    @testset "outside a pause the checkpoint does nothing" begin
        c0 = nCollections()
        garbage = [zeros(Float64, 2^17) for _ in 1:20]
        gcCheckpoint()
        @test nCollections() == c0
        @test length(garbage) == 20
    end

    @testset "the default budget" begin
        @test GC_PAUSE_BUDGET == 2^30
    end

    # …collector off
    @testset "a checkpoint called on a worker thread neither collects nor leaves the" begin
        # GC.enable is a per-thread switch: a worker's GC.enable(true) does
        # nothing and its GC.enable(false) would keep the collector off
        # after the pause. Only the thread that began the pause collects.
        before = Base.gc_num().pause
        withGcPaused(; budget = 1) do
            fetch(Threads.@spawn begin
                x = zeros(2^20)       # allocates past the 1-byte budget
                gcCheckpoint()
                sum(x)
            end)
        end
        @test gcEnabled()
        n = Base.gc_num().pause
        GC.gc()
        @test Base.gc_num().pause > n     # the collector runs again after the pause
    end
end
