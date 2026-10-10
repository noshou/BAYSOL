# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Inference/Modes.jl: grouping chains into modes, bridge sampling of a mode's mass against targets of known
# mass, the mode weights and the thinning that makes the pooled draws carry them.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using BAYSOL.Inference: chain_modes, bridge_logmass, mode_weights, draws_per_chain, even_indices, weights_uncertain,
    uncertain_weights

@testset "Modes: grouping, bridge-sampled mass, weights and thinning" begin
    rng = Xoshiro(3)

    @testset "chain_modes: chains that agree are one mode, a displaced chain is another" begin
        cube = randn(rng, 400, 4, 3)
        @test chain_modes(cube) == [1, 1, 1, 1]
        cube[:, 4, :] .+= 6
        @test chain_modes(cube) == [1, 1, 1, 2]
        cube[:, 2, :] .+= 6                                   # chains 2 and 4 together, 1 and 3 together
        @test chain_modes(cube) == [1, 2, 1, 2]
        @test chain_modes(randn(rng, 400, 1, 3)) == [1]
    end

    @testset "bridge_logmass: a Gaussian of mass 3 (log 3), draws from it, in four dimensions" begin
        n = 2000
        W = randn(rng, n, 4)
        logp(w) = log(3) - sum(abs2, w) / 2 - 2 * log(2π)
        r = bridge_logmass(W, [logp(W[i, :]) for i in 1:n], logp, Xoshiro(1))
        @test r.logZ ≈ log(3) atol = 0.05
        @test r.err < 0.05
    end

    @testset "bridge_logmass: skewed, bounded target x²e⁻ˣ per coordinate (mass Γ(3)⁴ = 16), Gaussian proposal" begin
        n = 4000
        W = Matrix{Float64}(undef, n, 4)
        for i in 1:n, j in 1:4
            W[i, j] = -log(rand(rng)) - log(rand(rng)) - log(rand(rng))     # Gamma(3, 1)
        end
        logp(w) = all(>(0), w) ? sum(2 .* log.(w) .- w) : -Inf
        r = bridge_logmass(W, [logp(W[i, :]) for i in 1:n], logp, Xoshiro(2))
        @test r.logZ ≈ log(16) atol = 0.25
    end

    @testset "two separated modes of mass 4 and 1: the weights are 0.8 and 0.2, whatever the draws per mode" begin
        n = 2000
        m1, m2 = [-6.0, 0, 0, 0], [6.0, 0, 0, 0]
        logp(w) = log(4 * exp(-sum(abs2, w .- m1) / 2) + 1 * exp(-sum(abs2, w .- m2) / 2)) - 2 * log(2π)
        logZ = [begin
                    W = randn(rng, n, 4) .+ m'
                    bridge_logmass(W, [logp(W[i, :]) for i in 1:n], logp, Xoshiro(5)).logZ
                end for m in (m1, m2)]
        @test logZ ≈ [log(4), log(1)] atol = 0.06
        @test mode_weights(logZ) ≈ [0.8, 0.2] atol = 0.02
    end

    @testset "mode_weights and draws_per_chain" begin
        @test mode_weights([0.0, 0.0]) ≈ [0.5, 0.5]
        @test mode_weights([log(3), NaN, 0.0]) ≈ [0.75, 0.0, 0.25]
        @test sum(mode_weights([1.0, 2.0, 5.0])) ≈ 1
        # 7 chains in a mode of share 0.8, 1 in a mode of share 0.2: the larger mode is thinned, the smaller keeps all
        keep = draws_per_chain([0.8, 0.2], [7, 1], 700)
        @test keep[2] == 700 && keep[1] == round(Int, 700 * (0.8 / 7) / 0.2)
        @test 7 * keep[1] / (7 * keep[1] + keep[2]) ≈ 0.8 atol = 0.005
        # one mode keeps everything; a negligible mode keeps nothing
        @test draws_per_chain([1.0], [8], 700) == [700]
        @test draws_per_chain([0.99995, 5e-5], [7, 1], 700)[2] == 0
    end

    @testset "weights_uncertain: only an error that can change the pool counts" begin
        @test !weights_uncertain([0.0], [0.0])
        @test !weights_uncertain([0.0, -1.0], [0.05, 0.3])                 # precise: the weights are applied
        @test weights_uncertain([0.0, -1.0], [0.05, 6.3])                  # a share anywhere between 0.002 and 1: not applied
        @test weights_uncertain([0.0, -1.0], [6.3, 0.05])                  # the dominant mode's own error counts too
        @test !weights_uncertain([0.0, -40.0], [0.05, 6.0])                # large error, but negligible even at its optimistic end
        @test weights_uncertain([0.0, -8.0], [0.05, 4.0])                  # 4 nats up from -8 is a share of 0.02
        @test !weights_uncertain([0.0, NaN], [0.1, NaN])                   # a mode without an estimate has no weight to be uncertain about
    end

    @testset "uncertain_weights: chains pooled as they came, except the modes that are negligible whatever the error" begin
        # SASDX52 seed 1: one mode with an error of 6 nats, one precise, one 24 nats lower than both
        w = uncertain_weights([0.0, -1.0, -25.0], [0.02, 6.3, 0.0], [5, 1, 1])
        @test w ≈ [5 / 6, 1 / 6, 0.0]
        @test sum(uncertain_weights([0.0, -1.0], [0.05, 6.3], [4, 4])) ≈ 1
        @test uncertain_weights([0.0, -1.0], [0.05, 6.3], [3, 1]) ≈ [0.75, 0.25]
        @test uncertain_weights([NaN, NaN], [NaN, NaN], [2, 2]) ≈ [0.5, 0.5]       # nothing known: nothing is dropped
    end

    @testset "even_indices" begin
        @test even_indices(10, 0) == Int[]
        @test even_indices(10, 10) == collect(1:10) && even_indices(10, 20) == collect(1:10)
        idx = even_indices(700, 175)
        @test length(idx) == 175 && issorted(idx) && allunique(idx) && first(idx) ≥ 1 && last(idx) ≤ 700
        @test diff(idx) ⊆ [3, 4, 5]
    end
end
