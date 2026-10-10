# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Inference/Infer.jl (the chains part): `convergence` (a thin layer
# over MCMCDiagnosticTools.jl, whose own tests cover the statistics; here the shapes,
# the short-chain guard and the behaviour the sampler relies on) and `select_chains`.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using BAYSOL.Inference: convergence, select_chains

# draws × chains × 1 array of an AR(1) process with coefficient φ
function ar1(rng, n, m, φ)
    x = zeros(n, m, 1)
    for j in 1:m, i in 2:n
        x[i, j, 1] = φ * x[i-1, j, 1] + randn(rng)
    end
    return x
end

@testset "Chains: convergence statistics and chain selection" begin
    rng = Xoshiro(1)

    @testset "independent draws: R̂ ≈ 1, ESS of the order of the number of draws" begin
        c = convergence(randn(rng, 1000, 4, 3))
        @test length(c.rhat) == length(c.ess) == length(c.ess_tail) == 3
        @test all(≈(1; atol = 0.02), c.rhat)
        @test all(e -> 2500 < e, c.ess) && all(e -> 1000 < e, c.ess_tail)
    end

    # …R̂ above 1.01
    @testset "chains in different places, of different scale, or drifting" begin
        @test only(
            convergence(
                randn(rng, 500, 4, 1) .+ reshape([0.0, 0.0, 5.0, 5.0], 1, 4, 1),
            ).rhat,
        ) > 1.5
        @test only(
            convergence(
                randn(rng, 1000, 4, 1) .* reshape([1.0, 1.0, 6.0, 6.0], 1, 4, 1),
            ).rhat,
        ) > 1.1
        @test only(convergence(randn(rng, 600, 2, 1) .+ range(0, 6; length = 600)).rhat) >
              1.2
    end

    @testset "autocorrelation lowers the ESS" begin
        φ, n = 0.8, 5000
        c = convergence(ar1(rng, n, 4, φ))
        @test only(c.ess) ≈ 4n * (1 - φ) / (1 + φ) rtol = 0.3
        @test only(c.ess_tail) < 4n / 2
    end

    @testset "chains shorter than 8 draws give NaN, not an error" begin
        c = convergence(randn(rng, 7, 4, 2))
        @test all(isnan, c.rhat) && all(isnan, c.ess) && all(isnan, c.ess_tail)
    end

    # …a chain in a poorer mode is
    @testset "select_chains: errors and mostly divergent chains are not pooled" begin
        pooled, reason =
            select_chains([0.0, 0.0, 0.0, 0.9], [nothing, nothing, nothing, nothing])
        @test pooled == [true, true, true, false]
        @test reason[1:3] == ["ok", "ok", "ok"] && occursin("diverged", reason[4])
        pooled, reason = select_chains([0.0, 0.0], [nothing, "boom"])
        @test pooled == [true, false] && occursin("boom", reason[2])
    end
end
