# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/inference/modes.jl: grouping chains into modes, bridge
# sampling of a mode's mass against targets of known mass, the mode
# weights and the thinning that makes the pooled draws carry them.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using BAYSOL.Inference: chainModes, bridgeLogmass, modeWeights, drawsPerChain,
    evenIndices, weightsUncertain,
    uncertainWeights

@testset "Modes: grouping, bridge-sampled mass, weights and thinning" begin
    rng = Xoshiro(3)

    # …a displaced chain is another
    @testset "chainModes: chains that agree are one mode" begin
        cube = randn(rng, 400, 4, 3)
        @test chainModes(cube) == [1, 1, 1, 1]
        cube[:, 4, :] .+= 6
        @test chainModes(cube) == [1, 1, 1, 2]
        # chains 2 and 4 together, 1 and 3 together
        cube[:, 2, :] .+= 6
        @test chainModes(cube) == [1, 2, 1, 2]
        @test chainModes(randn(rng, 400, 1, 3)) == [1]
    end

    # …in four dimensions
    @testset "bridgeLogmass: a Gaussian of mass 3 (log 3), draws from it" begin
        n = 2000
        W = randn(rng, n, 4)
        logp(w) = log(3) - sum(abs2, w) / 2 - 2 * log(2π)
        r = bridgeLogmass(W, [logp(W[i, :]) for i in 1:n], logp, Xoshiro(1))
        @test r.logZ ≈ log(3) atol = 0.05
        @test r.err < 0.05
    end

    # …(mass Γ(3)⁴ = 16), Gaussian proposal
    @testset "bridgeLogmass: skewed, bounded target x²e⁻ˣ per coordinate" begin
        n = 4000
        W = Matrix{Float64}(undef, n, 4)
        for i in 1:n, j in 1:4
            W[i, j] = -log(rand(rng)) - log(rand(rng)) - log(rand(rng))     # Gamma(3, 1)
        end
        logp(w) = all(>(0), w) ? sum(2 .* log.(w) .- w) : -Inf
        r = bridgeLogmass(W, [logp(W[i, :]) for i in 1:n], logp, Xoshiro(2))
        @test r.logZ ≈ log(16) atol = 0.25
    end

    # …whatever the draws per mode
    @testset "two separated modes of mass 4 and 1: the weights are 0.8 and 0.2" begin
        n = 2000
        m1, m2 = [-6.0, 0, 0, 0], [6.0, 0, 0, 0]
        logp(w) =
            log(4 * exp(-sum(abs2, w .- m1) / 2) + 1 * exp(-sum(abs2, w .- m2) / 2)) -
            2 * log(2π)
        logZ = [
            begin
                W = randn(rng, n, 4) .+ m'
                bridgeLogmass(W, [logp(W[i, :]) for i in 1:n], logp, Xoshiro(5)).logZ
            end for m in (m1, m2)
        ]
        @test logZ ≈ [log(4), log(1)] atol = 0.06
        @test modeWeights(logZ) ≈ [0.8, 0.2] atol = 0.02
    end

    @testset "modeWeights and drawsPerChain" begin
        @test modeWeights([0.0, 0.0]) ≈ [0.5, 0.5]
        @test modeWeights([log(3), NaN, 0.0]) ≈ [0.75, 0.0, 0.25]
        @test sum(modeWeights([1.0, 2.0, 5.0])) ≈ 1
        # 7 chains in a mode of share 0.8, 1 in a mode of share
        # 0.2: the larger mode is thinned, the smaller keeps all
        keep = drawsPerChain([0.8, 0.2], [7, 1], 700)
        @test keep[2] == 700 && keep[1] == round(Int, 700 * (0.8 / 7) / 0.2)
        @test 7 * keep[1] / (7 * keep[1] + keep[2]) ≈ 0.8 atol = 0.005
        # one mode keeps everything; a negligible mode keeps nothing
        @test drawsPerChain([1.0], [8], 700) == [700]
        @test drawsPerChain([0.99995, 5e-5], [7, 1], 700)[2] == 0
    end

    @testset "weightsUncertain: only an error that can change the pool counts" begin
        @test !weightsUncertain([0.0], [0.0])
        # precise: the weights are applied
        @test !weightsUncertain([0.0, -1.0], [0.05, 0.3])
        # a share anywhere between 0.002 and 1: not applied
        @test weightsUncertain([0.0, -1.0], [0.05, 6.3])
        # the dominant mode's own error counts too
        @test weightsUncertain([0.0, -1.0], [6.3, 0.05])
        # large error, but negligible even at its optimistic end
        @test !weightsUncertain([0.0, -40.0], [0.05, 6.0])
        # 4 nats up from -8 is a share of 0.02
        @test weightsUncertain([0.0, -8.0], [0.05, 4.0])
        # a mode without an estimate has no weight to be uncertain about
        @test !weightsUncertain([0.0, NaN], [0.1, NaN])
    end

    # …except the modes that are negligible whatever the error
    @testset "uncertainWeights: chains pooled as they came" begin
        # SASDX52 seed 1: one mode with an error of 6
        # nats, one precise, one 24 nats lower than both
        w = uncertainWeights([0.0, -1.0, -25.0], [0.02, 6.3, 0.0], [5, 1, 1])
        @test w ≈ [5 / 6, 1 / 6, 0.0]
        @test sum(uncertainWeights([0.0, -1.0], [0.05, 6.3], [4, 4])) ≈ 1
        @test uncertainWeights([0.0, -1.0], [0.05, 6.3], [3, 1]) ≈ [0.75, 0.25]
        # nothing known: nothing is dropped
        @test uncertainWeights([NaN, NaN], [NaN, NaN], [2, 2]) ≈ [0.5, 0.5]
    end

    @testset "evenIndices" begin
        @test evenIndices(10, 0) == Int[]
        @test evenIndices(10, 10) == collect(1:10) && evenIndices(10, 20) == collect(1:10)
        idx = evenIndices(700, 175)
        @test length(idx) == 175 && issorted(idx) && allunique(idx) && first(idx) ≥ 1 &&
              last(idx) ≤ 700
        @test diff(idx) ⊆ [3, 4, 5]
    end
    @testset "chainModes: one chain far from nine others is its own mode" begin
        # (the rank-normalized R̂ of all ten chains together is then only about the
        # limit, so "R̂ below the limit" must not stand for "one mode")
        cube = randn(rng, 700, 10, 5)
        cube[:, 7, :] .+= 24
        @test chainModes(cube) == [1, 1, 1, 1, 1, 1, 2, 1, 1, 1]
        @test chainModes(randn(rng, 700, 10, 5)) == ones(Int, 10)
    end

    @testset "workbook: the optima that carry mass" begin
        or = BAYSOL.Inference.OptimumReport
        function optimaSheet(optima, nExtra)
            d = BAYSOL.Inference.ChainDiagnostics(10, zeros(10), fill(true, 10),
                fill("ok", 10), [1.001], [1000.0], [800.0], 0.0, ones(Int, 10), [1.0],
                [850.0], [0.02], false, 300, NaN, false, nExtra, optima)
            return BAYSOL.Pipeline._optimaSheet(d)
        end
        # one optimum and no extra chains: no sheet
        @test optimaSheet([or([0.3, 0, 0, 0], 850.0, 1.0, 9, 0)], 0) === nothing
        sh = optimaSheet(
            [
                or([0.3, 0, 0, 0], 850.0, 0.958, 9, 0),
                or([0.3, 0, -4, -5], 847.0, 0.042, 0, 2),
            ],
            2,
        )
        @test sh.name == "optima"
        @test sh.header == ["optimum", "share", "chains", "started"]
        @test sh.cols == Any[[1, 2], [0.958, 0.042], [9, 0], [0, 2]]
    end

    @testset "workbook: the modes, and the one that keeps no draws" begin
        ChainDiagnostics = BAYSOL.Inference.ChainDiagnostics
        function modesSheet(weights)
            M = length(weights)
            d = ChainDiagnostics(M, zeros(M), fill(true, M), fill("ok", M), [1.001],
                [1000.0], [800.0], 0.0, collect(1:M), weights, fill(850.0, M),
                fill(0.02, M), false, 300, NaN, false, 0,
                BAYSOL.Inference.OptimumReport[])
            return BAYSOL.Pipeline._modesSheet(d)
        end
        # a single mode has no sheet
        @test modesSheet([1.0]) === nothing
        # one mode carries the posterior, the other has a share far below the limit
        sh = modesSheet([1.0, 7.1e-10])
        @test sh.header ==
              ["mode", "share", "logMass", "logMassErr", "chains", "kept"]
        @test sh.cols[2] == [1.0, 7.1e-10] && sh.cols[6] == [1, 0]
        # both carry mass: every mode is kept
        @test modesSheet([0.8, 0.2]).cols[6] == [1, 1]
        # three modes, two carry mass
        @test modesSheet([0.7, 0.3, 1e-9]).cols[6] == [1, 1, 0]
    end
end
