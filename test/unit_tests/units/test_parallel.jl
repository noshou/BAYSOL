# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Runtime/Parallel.jl: the per-item random streams (deterministic,
# distinct, independent of the order they are asked for), the ordered task map,
# and the BLAS scope. Thread-count independence of the results built on them is
# checked where they are used (MAP search in test_sampler.jl).

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Runtime: worker_count, draw_base, stream, tmap_items, with_blas_single
using LinearAlgebra: BLAS
using Random

@testset "Parallel" begin

    # …of them is a different one
    @testset "stream: the same (base, purpose, index) is the same stream; any change" begin
        draws(s) = rand(s, 8)
        @test draws(stream(UInt64(0x1234), 1, 1)) == draws(stream(UInt64(0x1234), 1, 1))
        @test draws(stream(UInt64(0x1234), 1, 1)) != draws(stream(UInt64(0x1234), 1, 2))
        @test draws(stream(UInt64(0x1234), 1, 1)) != draws(stream(UInt64(0x1234), 2, 1))
        @test draws(stream(UInt64(0x1234), 1, 1)) != draws(stream(UInt64(0x1235), 1, 1))
        # the purpose and the index are not interchangeable
        @test draws(stream(UInt64(0x1234), 1, 2)) != draws(stream(UInt64(0x1234), 2, 1))
    end

    @testset "stream: independent of the order and the number of streams made" begin
        a = [rand(stream(UInt64(0xabc), 1, i)) for i in 1:6]
        b = reverse([rand(stream(UInt64(0xabc), 1, i)) for i in 6:-1:1])
        @test a == b
        @test allunique(a)
    end

    # …so a published seed means the same on every Julia version
    @testset "stream: the mixing is SplitMix64 itself" begin
        # the first output of the reference SplitMix64
        # generator seeded with 0 (state 0 + γ, then the mix)
        @test BAYSOL.Runtime._splitmix(0x9e3779b97f4a7c15) == 0xe220a8397b1dcdaf
    end

    @testset "draw_base: follows Random.seed!" begin
        Random.seed!(5)
        a = draw_base()
        Random.seed!(5)
        b = draw_base()
        @test a == b && a isa UInt64
        @test draw_base() != a
    end

    @testset "tmap_items: results in input order, whatever order the tasks finish in" begin
        n = 12
        out = tmap_items(1:n) do i
            sleep(0.002 * (n - i))      # the last items finish first
            i^2
        end
        @test out == [i^2 for i in 1:n]
        @test tmap_items(identity, Int[]) == Int[]
        @test_throws ErrorException tmap_items(1:3) do i
            i == 2 && error("boom")
            i
        end
    end

    # …restored after; nests
    @testset "with_blas_single: one BLAS thread inside when Julia has several" begin
        before = BLAS.get_num_threads()
        inside = with_blas_single() do
            with_blas_single() do
                BLAS.get_num_threads()
            end
        end
        @test BLAS.get_num_threads() == before
        worker_count() > 1 ? (@test inside == 1) : (@test inside == before)
        # restored on an exception
        @test_throws ErrorException with_blas_single(() -> error("x"))
        @test BLAS.get_num_threads() == before
        @test with_blas_single(() -> 7) == 7
    end
end
