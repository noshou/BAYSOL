# SPDX-License-Identifier: LGPL-3.0-or-later

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Geometry: Vec3, Vec2, plasticPoints
using BAYSOL.Geometry: PLASTIC_RATIO_2, PLASTIC_RATIO_3
using BAYSOL.Geometry: PLASTIC_RATIO_2_SQR, PLASTIC_RATIO_3_SQR, PLASTIC_RATIO_3_CUBE

nrm(p) = sqrt(p[1]^2 + p[2]^2 + p[3]^2)
dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

@testset "PlasticMap" begin

    @testset "PLASTIC_RATIO_2 is the real root of x³ = x + 1" begin
        ρ = PLASTIC_RATIO_2
        @test 1.0 < ρ < 2.0
        @test checkFloat(ρ^3, ρ + 1.0)
    end

    @testset "plasticPoints: shape, type, edges" begin
        p = plasticPoints(50)
        @test p isa Vector{Vec3}
        @test eltype(p) === NTuple{3,Float64}
        @test length(p) == 50
        @test isempty(plasticPoints(0))
        @test plasticPoints(1) == [plasticPoints(3)[1]]
    end

    @testset "deterministic" begin
        @test plasticPoints(200) == plasticPoints(200)
    end

    @testset "every point is a unit vector" begin
        for p in plasticPoints(5_000)
            # tighter: direct closed-form identity, short op chain
            @test abs(nrm(p) - 1.0) < 1e-3 * DEFAULT_ATOL
        end
    end

    @testset "prefix stability: coarse set is an exact prefix of any finer set" begin
        fine = plasticPoints(1_000)
        for k in (0, 1, 2, 7, 64, 257, 999)
            @test plasticPoints(k) == fine[1:k]
        end
    end

    @testset "error contract" begin
        @test_throws DomainError plasticPoints(-1)
    end

    @testset "even coverage (low-discrepancy sanity)" begin
        n = 4_096
        pts = plasticPoints(n)

        # 1. centroid of a uniform sphere sample sits near the origin
        mx = sum(p -> p[1], pts) / n
        my = sum(p -> p[2], pts) / n
        mz = sum(p -> p[3], pts) / n
        @test sqrt(mx^2 + my^2 + mz^2) < 0.02

        # 2. octants are balanced
        oct = zeros(Int, 8)
        for p in pts
            oct[1+(p[1]>0)+2*(p[2]>0)+4*(p[3]>0)] += 1
        end
        @test all(c -> abs(c - n / 8) < 0.12 * n / 8, oct)

        # 3. height z is uniform on [-1, 1) (the projection is equal-area by construction)
        zb = zeros(Int, 10)
        for p in pts
            zb[clamp(floor(Int, (p[3] + 1.0) / 2.0 * 10) + 1, 1, 10)] += 1
        end
        @test all(c -> abs(c - n / 10) < 0.15 * n / 10, zb)

        # 4. spherical caps hold their area fraction, for a few axes and sizes
        for u in (Vec3((1.0, 0.0, 0.0)),
            Vec3((0.0, 0.0, 1.0)),
            Vec3((1, 1, 1) ./ sqrt(3)),
        )
            for freq in (0.1, 0.25, 0.5)
                cosθ = 1.0 - 2.0 * freq                 # cap of area fraction `freq`
                hit = count(p -> dot3(p, u) ≥ cosθ, pts) / n
                @test abs(hit - freq) < 0.03
            end
        end
    end

    @testset "type stability" begin
        @inferred plasticPoints(16)
        @inferred plasticPoints(16, Val(2))
        @inferred plasticPoints(16, Val(3))
    end

    @testset "precomputed powers of the plastic ratios" begin
        @test checkFloat(PLASTIC_RATIO_2_SQR, PLASTIC_RATIO_2^2)
        @test checkFloat(PLASTIC_RATIO_3_SQR, PLASTIC_RATIO_3^2)
        @test checkFloat(PLASTIC_RATIO_3_CUBE, PLASTIC_RATIO_3^3)
    end

    @testset "PLASTIC_RATIO_3 is the real root of x⁴ = x + 1" begin
        ρ = PLASTIC_RATIO_3
        @test 1.0 < ρ < 2.0
        @test checkFloat(ρ^4, ρ + 1.0)
    end

    @testset "dim=2: shape, type, edges" begin
        p = plasticPoints(50, Val(2))
        @test p isa Vector{Vec2}
        @test eltype(p) === NTuple{2,Float64}
        @test length(p) == 50
        @test isempty(plasticPoints(0, Val(2)))
        @test plasticPoints(1, Val(2)) == [plasticPoints(3, Val(2))[1]]
    end

    @testset "dim=2: deterministic" begin
        @test plasticPoints(200, Val(2)) == plasticPoints(200, Val(2))
    end

    @testset "dim=2: prefix stability: coarse set is an exact prefix of any finer set" begin
        fine = plasticPoints(1_000, Val(2))
        for k in (0, 1, 2, 7, 64, 257, 999)
            @test plasticPoints(k, Val(2)) == fine[1:k]
        end
    end

    @testset "dim=2: range sanity" begin
        for (x, y) in plasticPoints(2_000, Val(2))
            @test 0.0 ≤ x < 1.0
            @test 0.0 ≤ y < 1.0
        end
    end

    @testset "dim=2: error contract" begin
        @test_throws DomainError plasticPoints(-1, Val(2))
    end

    @testset "invalid dim keyword" begin
        @test_throws DomainError plasticPoints(5; dim = 4)
    end

    @testset "dim=3, shape=:surface is the same sequence as bare Val(3)/default" begin
        @test plasticPoints(500, Val(3)) == plasticPoints(500, Val(3), Val(:surface))
        @test plasticPoints(500) == plasticPoints(500, Val(3), Val(:surface))
        @test plasticPoints(500; shape = :surface) == plasticPoints(500)
    end

    @testset "dim=3, shape=:volume: shape, type, edges" begin
        p = plasticPoints(50, Val(3), Val(:volume))
        @test p isa Vector{Vec3}
        @test eltype(p) === NTuple{3,Float64}
        @test length(p) == 50
        @test isempty(plasticPoints(0, Val(3), Val(:volume)))
        @test plasticPoints(1, Val(3), Val(:volume)) ==
              [plasticPoints(3, Val(3), Val(:volume))[1]]
        @test plasticPoints(50; dim = 3, shape = :volume) == p
    end

    @testset "dim=3, shape=:volume: deterministic" begin
        @test plasticPoints(200, Val(3), Val(:volume)) ==
              plasticPoints(200, Val(3), Val(:volume))
    end

    @testset "dim=3, shape=:volume: every point is strictly inside the unit ball" begin
        # (surface points satisfy |p| == 1 exactly; volume points must satisfy |p| < 1,
        # and never exceed it -- this is the property that actually distinguishes the
        # two shapes from each other.)
        for p in plasticPoints(5_000, Val(3), Val(:volume))
            r = nrm(p)
            @test r < 1.0
            @test r ≥ 0.0
        end
    end

    # …of any finer set
    @testset "dim=3, shape=:volume: prefix stability: coarse set is an exact prefix" begin
        fine = plasticPoints(1_000, Val(3), Val(:volume))
        for k in (0, 1, 2, 7, 64, 257, 999)
            @test plasticPoints(k, Val(3), Val(:volume)) == fine[1:k]
        end
    end

    @testset "dim=3, shape=:volume: error contract" begin
        @test_throws DomainError plasticPoints(-1, Val(3), Val(:volume))
        @test_throws DomainError plasticPoints(5, Val(3), Val(:bogus))
        @test_throws DomainError plasticPoints(5; dim = 3, shape = :bogus)
    end

    @testset "dim=3, shape=:volume: even coverage (volume-uniform sanity)" begin
        n = 20_000
        pts = plasticPoints(n, Val(3), Val(:volume))

        # 1. centroid of a volume-uniform ball sample sits near the origin
        mx = sum(p -> p[1], pts) / n
        my = sum(p -> p[2], pts) / n
        mz = sum(p -> p[3], pts) / n
        @test sqrt(mx^2 + my^2 + mz^2) < 0.02

        # 2. octants are balanced (same sanity check as the surface case)
        oct = zeros(Int, 8)
        for p in pts
            oct[1+(p[1]>0)+2*(p[2]>0)+4*(p[3]>0)] += 1
        end
        @test all(c -> abs(c - n / 8) < 0.12 * n / 8, oct)

        # 3. r³ is uniform on [0, 1): the defining property of volume-uniformity
        #    (an r-only radial density uniform in *volume* has CDF(r) = r³, so
        #    r³ itself must be uniform -- this is the discriminating test that a
        #    naive `r = w` radial map, rather than `r = cbrt(w)`, would fail:
        #    it would cluster mass near the centre, and mean(r³) would sit well
        #    below 0.5).
        r3 = [nrm(p)^3 for p in pts]
        @test abs(sum(r3) / n - 0.5) < 0.02

        # 4. concentric shells hold their volume fraction: a ball of radius `ρ`
        #    holds fraction `ρ³` of the unit ball's volume.
        for ρ in (0.25, 0.5, 0.75)
            frac = count(p -> nrm(p) ≤ ρ, pts) / n
            @test abs(frac - ρ^3) < 0.02
        end
    end

    @testset "dim=3, shape=:volume: type stability" begin
        # The direct `Val` form is always inferred, by construction (dispatch,
        # not a branch). The `dim`/`shape` keyword form is documented as a
        # convenience only, and does NOT carry the same @inferred guarantee
        # once a non-default value is passed explicitly (Julia's constant
        # propagation reliably eliminates the *default*-elision fast path,
        # but not an explicit literal keyword through the `Val(dim), Val(shape)`
        # dispatch) -- so only the `Val`-direct call is asserted here.
        @inferred plasticPoints(16, Val(3), Val(:volume))
    end
end
