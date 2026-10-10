# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Inference/Priors.jl: the κ-parameterised bounded-Beta
# δρ₁/δρ₂/δρ₃ priors.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Inference: δρ_prior
using BAYSOL.PhysicalConstants: UNIT_OF_δρ
using BAYSOL.Inference: BOUNDS_δρ₁₂, MODE_δρ₁₂, φ_max, κ_δρ₁₂, κ_δρ₃
using Distributions:
    LocationScale, Continuous, Beta, mode, var, cdf, params, minimum, maximum
using StaticArrays: SVector

include(joinpath(@__DIR__, "..", "..", "utils", "floatcompare.jl"))   # close_

const ρ̄ = 0.3346
const BB = LocationScale{Float64,Continuous,Beta{Float64}}

@testset "DeltaRho" begin

    @testset "δρ_prior: returns three Float64 bounded Betas" begin
        out = δρ_prior(κ_δρ₁₂, κ_δρ₃, ρ̄)
        @test out isa Tuple{BB,BB,BB}
    end

    @testset "δρ₁/δρ₂: support is CRYSOL's [-10, 2], mode at 1, for any κ" begin
        for κ in (0.5, 2.0, 14.0, 100.0)
            d1, d2, _ = δρ_prior(κ, 1.0, ρ̄)
            @test d1 == d2
            @test (minimum(d1), maximum(d1)) == BOUNDS_δρ₁₂
            @test close_(d1.μ + d1.σ * mode(d1.ρ), MODE_δρ₁₂)
            @test close_(sum(params(d1.ρ)) - 2, κ)                 # κ = α + β - 2
            # the variance formula in the docstring, from the constants: mode m of u,
            # width W of BOUNDS_δρ₁₂ (11/12 and 12 for CRYSOL's defaults)
            W = BOUNDS_δρ₁₂[2] - BOUNDS_δρ₁₂[1]
            m = (MODE_δρ₁₂ - BOUNDS_δρ₁₂[1]) / W
            σ²u = (1 + m * κ) * (1 + (1 - m) * κ) / ((κ + 2)^2 * (κ + 3))
            @test close_(var(d1), W^2 * σ²u)
        end
    end

    @testset "δρ₁/δρ₂: default κ gives SD ≈ 1" begin
        d1, _, _ = δρ_prior(κ_δρ₁₂, κ_δρ₃, ρ̄)
        @test 0.99 < sqrt(var(d1)) < 1.01
    end

    @testset "δρ₃: support is [-ρ̄ₑ/UNIT_OF_δρ, (φ_max - 1)ρ̄ₑ/UNIT_OF_δρ], mode at 0" begin
        for κ in (0.5, 1.25, 10.0)
            _, _, d3 = δρ_prior(1.0, κ, ρ̄)
            @test close_(minimum(d3), -ρ̄ / UNIT_OF_δρ)
            @test close_(maximum(d3), (φ_max - 1) * ρ̄ / UNIT_OF_δρ)
            @test close_(d3.μ + d3.σ * mode(d3.ρ), 0.0; atol = 1e-3 * DEFAULT_ATOL)
            @test close_(φ_max * mode(d3.ρ), 1.0)
            @test close_(sum(params(d3.ρ)) - 2, κ)
            σ²u = (1 + κ / φ_max) * (1 + (1 - 1 / φ_max) * κ) / ((κ + 2)^2 * (κ + 3))
            @test close_(var(d3), (φ_max * ρ̄ / UNIT_OF_δρ)^2 * σ²u)
        end
    end

    @testset "δρ₃: default κ gives Beta(2, 1.25) on the unit interval" begin
        _, _, d3 = δρ_prior(κ_δρ₁₂, κ_δρ₃, ρ̄)
        @test all(close_.(params(d3.ρ), (2.0, 1.25)))
        # partially and nearly empty cavities stay reachable
        @test 0.15 < cdf(d3.ρ, 0.5 / φ_max) < 0.3
        @test 0.01 < cdf(d3.ρ, 0.2 / φ_max) < 0.1
    end

    @testset "δρ_prior: non-positive κ or ρ̄ₑ throws DomainError" begin
        @test_throws DomainError δρ_prior(0.0, 1.0, ρ̄)
        @test_throws DomainError δρ_prior(1.0, -1.0, ρ̄)
        @test_throws DomainError δρ_prior(1.0, 1.0, 0.0)
    end
end
