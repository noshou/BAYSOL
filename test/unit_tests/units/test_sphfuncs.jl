# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Scattering/SphFuncs.jl against closed forms and exact identities
# (Unsold's theorem, the Y = P̄ e^{imφ} definition, the Bessel recurrence).
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Scattering: SphHarmError, sphBess, sphBessRatios!, sphBessStep
using LegendrePolynomials: Plm
using SpecialFunctions: sphericalbesselj

# independent reference for sphHarm: normalized
# P̄_l^m(x), Condon–Shortley phase (GSL convention)
legendre_sphPlm(l, m, x) =
    Plm(float(x), l, m; norm = Val(:normalized), csphase = true) / sqrt(2π)

# jₗ(q·r) for l = 0..lMax, every q, from the two passes a caller runs:
# sphBessRatios! (pass 1), then sphBessStep upward from j₀, j₁ (pass 2)
function bess(r, q::Vector{Float64}, lMax; b = sphBess(length(q), lMax))
    sphBessRatios!(b, Float64(r), q, lMax)
    j = zeros(lMax + 1, length(q))
    for k in eachindex(q)
        j[1, k] = b.jm2[k]
        lMax ≥ 1 && (j[2, k] = b.jm1[k])
    end
    for l in 2:lMax, k in eachindex(q)
        v = sphBessStep(b.jm1[k], b.jm2[k], l, b.lup[k], b.invx[k], b.R[k, l])
        b.jm2[k], b.jm1[k] = b.jm1[k], v
        j[l+1, k] = v
    end
    return j
end

y00 = 1.0 / (2.0 * sqrt(π))
y10(θ) = sqrt(3.0 / (4.0 * π)) * cos(θ)
y11(θ, φ) = (-(sqrt(3.0 / (8.0 * π))) * sin(θ)) * cis(φ)
# l = 2, Condon-Shortley phase included
y20(θ) = sqrt(5.0 / (16.0 * π)) * (3.0 * cos(θ)^2 - 1.0)
y21(θ, φ) = -sqrt(15.0 / (8.0 * π)) * sin(θ) * cos(θ) * cis(φ)
y22(θ, φ) = sqrt(15.0 / (32.0 * π)) * sin(θ)^2 * cis(2φ)
idx(l, m) = l * (l + 1) ÷ 2 + m + 1
nrows(lMax) = (lMax + 1) * (lMax + 2) ÷ 2

# closed forms for the first few spherical Bessel functions
j0(x) = x == 0.0 ? 1.0 : sin(x) / x
j1(x) = x == 0.0 ? 0.0 : sin(x) / (x * x) - cos(x) / x
j2(x) = x == 0.0 ? 0.0 : (3.0 / x^3 - 1.0 / x) * sin(x) - 3.0 * cos(x) / x^2

@testset "SphFuncs" begin

    @testset "sphHarm known values" begin
        for (θv, φv) in ((π / 2, 0.0), (0.0, 0.7))
            y = sphHarm(1, [θv], [φv])
            @test check_complex(complex(y00), y[idx(0, 0), 1])
            @test check_complex(complex(y10(θv)), y[idx(1, 0), 1])
            @test check_complex(y11(θv, φv), y[idx(1, 1), 1])
        end
    end

    @testset "sphHarm known values through l = 2" begin
        for (θv, φv) in ((0.37, 0.9), (2.1, -1.3), (π / 2, π), (1.0, 0.0))
            y = sphHarm(2, [θv], [φv])
            @test check_complex(complex(y00), y[idx(0, 0), 1])
            @test check_complex(complex(y10(θv)), y[idx(1, 0), 1])
            @test check_complex(y11(θv, φv), y[idx(1, 1), 1])
            @test check_complex(complex(y20(θv)), y[idx(2, 0), 1])
            @test check_complex(y21(θv, φv), y[idx(2, 1), 1])
            @test check_complex(y22(θv, φv), y[idx(2, 2), 1])
        end
    end

    @testset "sphHarm packing: shape and row index" begin
        θ = [0.3, 1.1, 2.7]
        φ = [0.2, -1.0, 3.0]
        for lMax in 0:5
            y = sphHarm(lMax, θ, φ)
            @test y isa Matrix{ComplexF64}
            @test size(y) == (nrows(lMax), 3)
        end
        # the packing is dense and collision-free over the (l, m) triangle
        seen = [idx(l, m) for l in 0:5 for m in 0:l]
        @test sort(seen) == collect(1:nrows(5))
        # a bigger lMax only appends rows; the shared prefix is bit-identical
        @test sphHarm(2, θ, φ) == sphHarm(5, θ, φ)[1:nrows(2), :]
    end

    @testset "sphHarm columns are independent points" begin
        θ = [0.3, 1.1, 2.7, 0.0, π]
        φ = [0.2, -1.0, 3.0, 0.5, 1.5]
        y = sphHarm(4, θ, φ)
        for i in eachindex(θ)
            @test y[:, i] == sphHarm(4, [θ[i]], [φ[i]])[:, 1]
        end
    end

    @testset "sphHarm: Unsold's theorem, sum_m |Y_lm|^2 = (2l+1)/4pi" begin
        # Y_{l,-m} = (-1)^m conj(Y_{lm}), so the stored m ≥ 0 half determines
        # the full sum; this pins normalization and phase convention exactly.
        θ = [0.05, 0.7, 1.5707, 2.4, 3.09]
        φ = [0.0, 1.2, -2.5, 3.0, 0.4]
        lMax = 6
        y = sphHarm(lMax, θ, φ)
        for i in eachindex(θ), l in 0:lMax
            s =
                abs2(y[idx(l, 0), i]) +
                2 * sum(abs2(y[idx(l, m), i]) for m in 1:l; init = 0.0)
            @test check_float(s, (2l + 1) / (4π))
        end
    end

    @testset "sphHarm: Y_lm = legendre_sphPlm(l, m, cos θ) * exp(i m φ)" begin
        θ = [0.3, 1.1, 2.7]
        φ = [0.2, -1.0, 3.0]
        y = sphHarm(4, θ, φ)
        for i in eachindex(θ), l in 0:4, m in 0:l
            @test check_complex(
                y[idx(l, m), i],
                legendre_sphPlm(l, m, cos(θ[i])) * cis(m * φ[i]),
            )
        end
    end

    @testset "sphHarm: m = 0 harmonics are real and phi-independent" begin
        for l in 0:4
            a = sphHarm(4, [0.8], [0.0])[idx(l, 0), 1]
            b = sphHarm(4, [0.8], [2.5])[idx(l, 0), 1]
            @test check_float(imag(a), 0.0)
            @test check_complex(a, b)
        end
    end

    @testset "sphHarm: phi enters only as the phase exp(i m phi)" begin
        θ = [0.8, 2.2]
        y0 = sphHarm(4, θ, [0.0, 0.0])
        for φv in (0.3, 1.9, -2.2, 2π)
            y = sphHarm(4, θ, [φv, φv])
            for i in 1:2, l in 0:4, m in 0:l
                @test check_complex(y[idx(l, m), i], y0[idx(l, m), i] * cis(m * φv))
                @test check_float(abs(y[idx(l, m), i]), abs(y0[idx(l, m), i]))
            end
        end
    end

    @testset "sphHarm at the poles: only m = 0 survives" begin
        for θv in (0.0, π)
            y = sphHarm(4, [θv], [0.9])
            for l in 0:4
                @test check_float(abs(y[idx(l, 0), 1]), sqrt((2l + 1) / (4π)))
                for m in 1:l
                    @test check_float(abs(y[idx(l, m), 1]), 0.0)
                end
            end
        end
    end

    @testset "sphHarm accepts non-Float64 and non-Vector 1-D inputs" begin
        @test sphHarm(2, [0, 1], [0, 1]) ≈ sphHarm(2, [0.0, 1.0], [0.0, 1.0])
        @test sphHarm(2, 0.0:1.0:1.0, 0.0:1.0:1.0) ≈ sphHarm(2, [0.0, 1.0], [0.0, 1.0])
        @test all(isfinite, sphHarm(6, [0.0, π, 1e-12, π - 1e-12], fill(0.3, 4)))
    end

    @testset "sphHarm exception contract" begin
        @test_throws SphHarmError sphHarm(-1, [1.0], [1.0])
        @test_throws SphHarmError sphHarm(-5, [1.0], [1.0])
        @test_throws SphHarmError sphHarm(2, [1.0], [1.0, 2.0])
        @test_throws SphHarmError sphHarm(2, [1.0, 2.0], [1.0])
        @test_throws SphHarmError sphHarm(2, Float64[], Float64[])
        @test_throws SphHarmError sphHarm(2, Float64[], [1.0])
        @test_throws SphHarmError sphHarm(2, [1.0], Float64[])
        @test_throws SphHarmError sphHarm(2, zeros(2, 2), [1.0])
        @test_throws SphHarmError sphHarm(2, [1.0], zeros(2, 2))
        # lMax = 0 is the boundary of the valid range, not an error
        @test size(sphHarm(0, [1.0], [1.0])) == (1, 1)
    end

    @testset "Gautschi sweep: closed forms for l = 0, 1, 2" begin
        q = [0.0, 0.25, 0.5, 1.0, 2.0, 3.7, 7.4]
        for r in (0.0, 1.0, 2.3)
            j = bess(r, q, 2)
            for (k, qk) in enumerate(q)
                x = qk * r
                @test check_float(j[1, k], j0(x))
                @test check_float(j[2, k], j1(x))
                @test check_float(j[3, k], j2(x))
            end
        end
    end

    @testset "Gautschi sweep matches SpecialFunctions.sphericalbesselj" begin
        # includes zeros of j₀ (x = kπ), the switch point near x ≈ l, and x on both
        # sides of lMax
        xs = vcat([1e-6, 1e-3, 0.1, 0.999, 1.0, 1.001, π, 2π, 4.4934, 25.0, 25.5, 26.0],
            collect(range(0.05, 120.0; length = 300)), [150.0, 200.5, 300.0, 400.0])
        for lMax in (0, 1, 5, 25, 60)
            j = bess(1.0, xs, lMax)
            for (k, x) in enumerate(xs)
                ref = [sphericalbesselj(l, x) for l in 0:lMax]
                # error relative to the largest |jₗ(x)| over all orders, not just ≤ lMax:
                # with lMax = 0 near a zero of j₀ that scale would itself be ~0
                scale = maximum(abs(sphericalbesselj(l, x)) for l in 0:(ceil(Int, x)+10))
                @test maximum(abs.(j[:, k] .- ref)) ≤ 1e-13 * scale
            end
        end
    end

    @testset "Gautschi sweep: j_l(0) = delta_{l0} exactly" begin
        for (r, q) in ((0.0, [1.0]), (1.0, [0.0]), (0.0, [0.0]))
            @test bess(r, q, 5)[:, 1] == [1.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        end
    end

    @testset "Gautschi sweep satisfies the three-term recurrence" begin
        # j_{l-1}(x) + j_{l+1}(x) = (2l+1)/x * j_l(x), on both sides of the switch point
        lMax = 8
        xs = [0.1, 1.0, 2.5, 7.3, 30.0]
        j = bess(1.0, xs, lMax)
        for (k, x) in enumerate(xs), l in 1:(lMax-1)
            @test check_float(j[l, k] + j[l+2, k], (2l + 1) / x * j[l+1, k])
        end
    end

    @testset "Gautschi sweep: bounds and small-x asymptotics" begin
        j = bess(1.0, collect(0.05:0.37:10.0), 6)
        @test all(isfinite, j)
        @test all(v -> abs(v) ≤ 1.0 + 1e-12, j)      # |j_l(x)| ≤ 1 for real x ≥ 0
        # j_l(x) -> x^l / (2l+1)!! as x -> 0 (j₁ here comes from j₀·r₁, not the
        # closed form, which cancels catastrophically at this x)
        x = 1.0e-3
        js = bess(x, [1.0], 4)
        dfact = 1.0
        for l in 0:4
            l > 0 && (dfact *= (2l + 1))
            @test isapprox(js[l+1, 1], x^l / dfact; rtol = 1e-5)
        end
    end

    @testset "Gautschi sweep: no overflow at small x and large lMax" begin
        # the ratios stay bounded; orders too small for Float64 underflow to 0
        j = bess(1.0, [1e-300, 1e-100, 1e-6, 1e-3, 0.5], 200)
        @test all(isfinite, j)
        @test check_float(j[1, 1], 1.0)
        @test isapprox(j[3, 4], (1e-3)^2 / 15; rtol = 1e-6)
    end

    @testset "sphBessRatios!: each q is independent of the rest of the grid" begin
        q = [0.0, 0.05, 0.3, 1.1, 4.0, 9.5]
        j = bess(2.0, q, 10)
        for (k, qk) in enumerate(q)
            @test j[:, k] == bess(2.0, [qk], 10)[:, 1]
        end
        # and only the product q*r matters
        @test bess(2.0, [3.0], 4) == bess(3.0, [2.0], 4)
    end

    @testset "sphBessRatios!: outputs" begin
        q = [0.0, 0.1, 0.3, 3.0]                        # x = 0, 1, 3, 30
        b = sphBess(6, 8)                               # buffers may be larger than needed
        @test sphBessRatios!(b, 10.0, q, 5) === nothing
        @test b.x[1:4] == 10.0 .* q
        @test b.invx[1] == 0.0 && b.invx[2:4] ≈ 1 ./ (10.0 .* q[2:4])
        @test b.lup[1:4] == floor.(Int, 10.0 .* q)
        # ⌊x⌋ = 30 ≥ lMax: the sweep would start above x, but no ratio of this q is read
        @test b.N[4] ≥ 30
        @test all(b.N[2:3] .≥ max.(5, ceil.(Int, 10.0 .* q[2:3])))
        @test b.jm2[1] == 1.0 && b.jm1[1] == 0.0        # j₀(0), j₁(0)
        @test bess(10.0, q, 5; b = sphBess(6, 8)) == bess(10.0, q, 5)
    end

    @testset "sphBessStep: recurrence up to ⌊x⌋, ratio above" begin
        # l ≤ ⌊x⌋
        @test sphBessStep(2.0, 1.0, 3, 5, 0.5, 0.25) == muladd(5 * 0.5, 2.0, -1.0)
        # l > ⌊x⌋
        @test sphBessStep(2.0, 1.0, 6, 5, 0.5, 0.25) == 2.0 * 0.25
        @test sphBessStep(2.0, 1.0, 3, 5, 0.5, 0.25) isa Float64
    end

    @testset "sphBess / sphBessRatios! exception contract" begin
        @test_throws DomainError sphBess(-1, 2)
        @test_throws DomainError sphBess(2, -1)
        # too few q
        @test_throws ArgumentError sphBessRatios!(sphBess(2, 2), 1.0, [0.1, 0.2, 0.3], 2)
        # too few orders
        @test_throws ArgumentError sphBessRatios!(sphBess(3, 2), 1.0, [0.1, 0.2, 0.3], 4)
        @test_throws DomainError sphBessRatios!(sphBess(1, 2), -1.0, [0.1], 2)
        @test_throws DomainError sphBessRatios!(sphBess(1, 2), 1.0, [0.1], -1)
        # 0 is on the allowed side of every boundary
        @test sphBessRatios!(sphBess(1, 0), 0.0, [0.0], 0) === nothing
    end

    @testset "reference P̄_l^m closed forms" begin
        for x in (-1.0, -0.6, 0.0, 0.25, 1.0)
            @test check_float(legendre_sphPlm(0, 0, x), 1.0 / (2.0 * sqrt(π)))
            @test check_float(legendre_sphPlm(1, 0, x), sqrt(3.0 / (4.0 * π)) * x)
            # Condon-Shortley phase: P̄_1^1 is negative for x in (-1, 1)
            @test check_float(
                legendre_sphPlm(1, 1, x),
                -sqrt(3.0 / (8.0 * π)) * sqrt(max(0.0, 1.0 - x^2)),
            )
            @test check_float(
                legendre_sphPlm(2, 0, x),
                sqrt(5.0 / (16.0 * π)) * (3x^2 - 1.0),
            )
            @test check_float(
                legendre_sphPlm(2, 2, x),
                sqrt(15.0 / (32.0 * π)) * (1.0 - x^2),
            )
        end
        @test legendre_sphPlm(3, 2, 0.5) isa Float64
        @test legendre_sphPlm(2, 0, 1) isa Float64        # Integer x is accepted
    end
end
