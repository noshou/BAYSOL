# SPDX-License-Identifier: LGPL-2.1-or-later

# Concurrency and race tests for the threaded stages. A real race detector is
# not available for Julia code, so these tests stress the architecture instead:
#
#   * results are bit-identical at every worker count (1, 2, 3, 5, 7,
#     8, 24) and under "chaos" scheduling (every task starts after a
#     random delay, so start and finish orders change on every run);
#   * the same kernels called from several tasks at once give
#     each caller its own serial result (no hidden shared state);
#   * the primitives (`tmap_items`, `tmap_blocks`, `with_blas_single`, the
#     GC pause) behave under nesting, exceptions, and many tasks at once;
#   * repeated threaded builds leave nothing behind (the garbage-collector
#     bug of 2026-10-09 left the collector off and the heap growing to 6 GB).
#
# `Parallel.with_workers(n)` makes the stages split their work for n workers (1
# forces the serial paths) and `Parallel.with_chaos(d)` delays every task by a random
# time up to d seconds, so the matrix of worker counts is exercised in one process
# whatever `-t` it was started with. The suite is most meaningful with several Julia
# threads: `precommit.tcl` also runs it with `-t 6,1`; run by hand with
#   julia --project=test -t 6,1 dev/unittests.jl concurrency

include(joinpath(@__DIR__, "..", "testsetup.jl"))
include(joinpath(@__DIR__, "..", "..", "utils", "geometry.jl"))   # jittered_lattice

using BAYSOL.Runtime: worker_count, stream, tmap_items, tmap_blocks, with_blas_single,
    with_workers, with_chaos
using BAYSOL.Runtime: with_gc_paused, gc_checkpoint
using BAYSOL.Runtime: Lazy, force, KeyedCache
using BAYSOL.MolecularStructure: create, vols
using BAYSOL.Scattering: species_multipoles, SharedAmplitude
using BAYSOL.Geometry: sasa
using LinearAlgebra: BLAS
using Random

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

"""
A fingerprint of a result: a hash of the bits of every float
(so -0.0, NaN payloads and last-bit differences count).
"""
fpr(x::AbstractArray{Float64}) = hash(reinterpret(UInt64, vec(collect(x))))
fpr(x::AbstractArray{ComplexF64}) =
    hash(reinterpret(UInt64, vec(collect(reinterpret(Float64, vec(collect(x)))))))
fpr(x::AbstractArray) = hash(Int.(vec(collect(x))))        # enums such as the bead classes
fpr(t::Tuple) = hash(map(fpr, t))
fpr(x) = hash(x)

"""
Whether `f()` gives the same bits at every worker count in `workers`
under chaos scheduling as with the serial paths (`with_workers(1)`);
`reps` repeats per count. Reports the first mismatching count.
"""
function identical_across_workers(f; workers = (2, 3, 5, 7, 8, 24), chaos = 0.003, reps = 1)
    ref = fpr(with_workers(f, 1))
    for n in workers, r in 1:reps
        got = with_workers(n) do
            with_chaos(chaos) do
                f()
            end
        end
        fpr(got) == ref || (
            @info "result differs from the serial one" workers = n repetition = r;
            return false
        )
    end
    return true
end

"""
A protein-sized synthetic molecule: a 17³ jittered
lattice (4,913 atoms, above every size threshold).
"""
function conc_mol(n = 17)
    pts = jittered_lattice(n; a = 2.2)
    els =
        String[("c", "n", "o", "c", "c", "s", "c", "n")[mod1(i, 8)] for i in eachindex(pts)]
    return create("conc", els, pts)
end

"""
Random multipole-expansion inputs: spherical
coordinates (r, θ, φ), q grid, per-atom amplitudes.
"""
function conc_blm_inputs(seed; N = 5120, Q = 210, lMax = 10)
    rng = Xoshiro(seed)
    sph = vcat(1.0 .+ 29.0 .* rand(rng, 1, N), π .* rand(rng, 1, N), 2π .* rand(rng, 1, N))
    q = collect(range(0.01, 0.3; length = Q))
    f1 = rand(rng, N, Q) .+ 0.5
    fs = vec(rand(rng, Q)) .+ 0.5
    return (; sph, q, f = (f1, SharedAmplitude(fs, N)), lMax)
end

blm(inp) = BAYSOL.Scattering._compute_B_lm(inp.sph, inp.q, inp.f, inp.lMax, UInt64(2048))

n_collections() = Base.gc_num().pause

@testset "Concurrency" begin

    @info (
        "concurrency tests: $(Threads.nthreads()) Julia " *
        "threads, worker_count() = $(worker_count())"
    )

    # -----------------------------------------------------------------------
    @testset "the test hooks" begin
        base = worker_count()
        @test with_workers(() -> worker_count(), 5) == 5
        @test worker_count() == base                              # restored
        @test_throws ArgumentError with_workers(() -> 1, 0)
        @test_throws ErrorException with_workers(() -> error("x"), 3)
        # restored after an exception
        @test worker_count() == base
    end

    # -----------------------------------------------------------------------
    @testset "tmap_items: order, nesting, exceptions" begin
        n = 40
        for w in (1, 2, 3, 8, 24), chaos in (0.0, 0.004)
            out = with_workers(w) do
                with_chaos(chaos) do
                    tmap_items(1:n) do i
                        i^2
                    end
                end
            end
            # input order, whatever order the tasks finish in
            @test out == [i^2 for i in 1:n]
        end
        empty_out = with_workers(() -> tmap_items(identity, Int[]), 4)
        one_out = with_workers(() -> tmap_items(x -> 2x, [21]), 4)
        @test empty_out == Int[] && one_out == [42]

        # three nested parallel regions: must finish (a
        # deadlock would hang the suite, hence the timeout)
        t = Threads.@spawn with_workers(4) do
            with_chaos(0.002) do
                tmap_items(1:4) do i
                    sum(tmap_items(1:4) do j
                        sum(tmap_items(1:3) do k
                            i * j * k
                        end)
                    end)
                end
            end
        end
        @test timedwait(() -> istaskdone(t), 120.0) === :ok
        @test fetch(t) == [i * sum(j * sum(k for k in 1:3) for j in 1:4) for i in 1:4]

        # an exception in some tasks comes back as
        # itself, and the machinery works afterwards
        with_workers(4) do
            for chaos in (0.0, 0.003)
                with_chaos(chaos) do
                    @test_throws ArgumentError (tmap_items(1:16) do i
                        i in (3, 7) && throw(ArgumentError("task $i"))
                        i
                    end)
                end
                @test tmap_items(identity, 1:8) == collect(1:8)
            end
        end
    end

    # -----------------------------------------------------------------------
    @testset "tmap_blocks: every index exactly once" begin
        for n in (0, 1, 63, 64, 65, 255, 256, 1000, 4097),
            block in (1, 7, 64, 256),
            threaded in (false, true)

            hits = zeros(Int, n)
            with_workers(5) do
                with_chaos(0.001) do
                    tmap_blocks(n, block; threaded = threaded) do blk
                        for i in blk
                            # blocks are disjoint, so no atomics are needed
                            hits[i] += 1
                        end
                    end
                end
            end
            @test all(==(1), hits)
        end
    end

    # -----------------------------------------------------------------------
    @testset "random streams do not depend on the order tasks run in" begin
        serial = [rand(stream(UInt64(99), 1, i), 4) for i in 1:60]
        for w in (2, 7), chaos in (0.0, 0.003)
            par = with_workers(w) do
                with_chaos(chaos) do
                    tmap_items(1:60) do i
                        rand(stream(UInt64(99), 1, i), 4)
                    end
                end
            end
            @test par == serial
        end
    end

    # -----------------------------------------------------------------------
    @testset "with_blas_single: many tasks entering and leaving" begin
        before = BLAS.get_num_threads()
        inside = with_workers(4) do
            with_chaos(0.002) do
                tmap_items(1:64) do i
                    with_blas_single() do
                        sleep(rand() * 0.001)
                        with_blas_single() do                      # nested scopes too
                            BLAS.get_num_threads()
                        end
                    end
                end
            end
        end
        @test all(==(1), inside)
        # restored once the last scope ended
        @test BLAS.get_num_threads() == before
        @test BAYSOL.Runtime._BLAS_DEPTH[] == 0
        # an exception inside a scope still restores it
        with_workers(4) do
            @test_throws ErrorException with_blas_single(() -> error("boom"))
        end
        @test BLAS.get_num_threads() == before && BAYSOL.Runtime._BLAS_DEPTH[] == 0
    end

    # -----------------------------------------------------------------------
    @testset "Lazy and KeyedCache: many tasks, one computation" begin
        calls = Threads.Atomic{Int}(0)
        lz = Lazy{Int}(() -> (Threads.atomic_add!(calls, 1); sleep(0.01); 42))
        res = fetch.([Threads.@spawn(force(lz)) for _ in 1:64])
        @test all(==(42), res) && calls[] == 1

        kc = KeyedCache{Int,Int}()
        counts = [Threads.Atomic{Int}(0) for _ in 1:8]
        keyed(i) = get!(kc, 1 + (i % 8)) do
            Threads.atomic_add!(counts[1+(i%8)], 1)
            sleep(0.002)
            10 * (1 + (i % 8))
        end
        res = fetch.([Threads.@spawn(keyed(i)) for i in 0:127])
        @test res == [10 * (1 + (i % 8)) for i in 0:127]
        # each key computed exactly once
        @test all(c -> c[] == 1, counts)
    end

    # -----------------------------------------------------------------------
    @testset "the garbage-collector pause under threads" begin
        # allocating tasks under a tiny budget: the pausing thread
        # collects while it waits, the collector is back on
        # afterwards, and it really works (a forced collection counts)
        n0 = n_collections()
        with_gc_paused(; budget = 1 << 20) do
            with_workers(4) do
                tmap_items(1:12) do i
                    x = zeros(2^21)                                # 16 MB each
                    # a worker's checkpoint is a no-op
                    gc_checkpoint()
                    sum(x) + i
                end
            end
            # the owner (this thread) collects: 192 MB were allocated against a 1 MiB budget
            gc_checkpoint()
        end
        # the owner collected during the pause
        @test n_collections() > n0
        n1 = n_collections()
        GC.gc()
        @test n_collections() > n1  # and the collector is on again

        # an exception in a worker leaves the collector on
        @test_throws ArgumentError (with_gc_paused() do
            with_workers(4) do
                tmap_items(1:8) do i
                    i == 5 && throw(ArgumentError("worker"))
                    i
                end
            end
        end)
        n2 = n_collections()
        GC.gc()
        @test n_collections() > n2

        # a pause begun and ended inside a worker task does not disturb the outer one
        with_gc_paused() do
            d0 = BAYSOL.Runtime._DEPTH[]
            with_workers(4) do
                tmap_items(1:8) do i
                    with_gc_paused() do
                        gc_checkpoint()
                        i
                    end
                end
            end
            @test BAYSOL.Runtime._DEPTH[] == d0
        end
        n3 = n_collections()
        GC.gc()
        @test n_collections() > n3
    end

    # -----------------------------------------------------------------------
    @testset "excluded volumes: bit-identical at every worker count, under chaos" begin
        @test identical_across_workers(() -> vols(conc_mol()))
    end

    @testset "SASA cloud and bead classes: bit-identical" begin
        @test identical_across_workers(() -> sasa(conc_mol()); workers = (2, 3, 7, 24))
    end

    @testset "_gaussian_dummy: bit-identical" begin
        v = 20.0 .+ 10.0 .* rand(Xoshiro(3), 6000)
        q = collect(range(0.0, 0.3; length = 150))
        @test identical_across_workers(() -> BAYSOL.Scattering._gaussian_dummy(v, q))
    end

    # …and exception-free under 24 workers
    @testset "compute_B_lm: bit-identical, repeatable" begin
        inp = conc_blm_inputs(1)
        @test identical_across_workers(() -> blm(inp); reps = 2)
        # the same threaded call, repeated: always the
        # same bits (a lost update would show up here)
        ref = fpr(with_workers(() -> blm(inp), 1))
        got = with_workers(6) do
            with_chaos(0.002) do
                [fpr(blm(inp)) for _ in 1:12]
            end
        end
        @test all(==(ref), got)
    end

    @testset "the whole static build (species_multipoles) is bit-identical" begin
        q = collect(range(0.01, 0.3; length = 210))
        @test identical_across_workers(
            () -> species_multipoles(conc_mol(), q, 8, 9000.0);
            workers = (2, 5, 24),
        )
    end

    # -----------------------------------------------------------------------
    # …(no hidden shared state)
    @testset "concurrent callers: each gets its own serial result" begin
        inputs = [conc_blm_inputs(s) for s in 1:4]
        refs = with_workers(() -> [fpr(blm(i)) for i in inputs], 1)
        for chaos in (0.0, 0.003)
            got = with_workers(4) do
                with_chaos(chaos) do
                    tasks = [Threads.@spawn(fpr(blm(i))) for i in inputs]
                    fetch.(tasks)
                end
            end
            @test got == refs
        end
        # the same for the molecule kernels, two molecules at once
        m_refs = with_workers(1) do
            (fpr(vols(conc_mol(15))), fpr(vols(conc_mol(16))))
        end
        m_got = with_workers(4) do
            ts = [Threads.@spawn(fpr(vols(conc_mol(n)))) for n in (15, 16)]
            Tuple(fetch.(ts))
        end
        @test m_got == m_refs
    end

    # -----------------------------------------------------------------------
    @testset "repeated threaded builds leave nothing behind" begin
        inp = conc_blm_inputs(2)
        with_workers(() -> blm(inp), 6)                           # warm up (compile, pools)
        GC.gc()
        GC.gc()
        live0 = Base.gc_live_bytes()
        with_workers(6) do
            for _ in 1:6
                blm(inp)
                vols(conc_mol())
            end
        end
        GC.gc()
        GC.gc()
        # no growth that survives a full collection
        @test Base.gc_live_bytes() - live0 < 150 * 2^20
    end
end
