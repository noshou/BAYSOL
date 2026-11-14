# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests for src/inference/profiled-corrs.jl: the 2-parameter weighted least squares fit
# of I_calc(q) = scale*yModel(q) + bkgrndCorr, plus the profile
# log-likelihoods and the χ²/dof diagnostic built on top of it.
#
# `refWls` below is an independent re-derivation via explicit normal-equation
# matrix algebra (LinearAlgebra), not a copy of `wlsFit`'s O(n) accumulator
# loop, so agreement between the two is a genuine cross-check of the closed
# forms in profiled-corrs.jl rather than a tautology.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using LinearAlgebra
using Random
using ForwardDiff
using BAYSOL.Inference:
    WLSError, WLSFit, wlsFit, wlsPredict, wlsProfLl,
    reducedChi2

"""
Reference (scale, bkgrndCorr, chi2, det(XᵀWX)) via explicit normal equations
`(XᵀWX) β = XᵀWy`, independent of `wlsFit`'s accumulator formulas.
"""
function refWls(yModel::AbstractVector, iObs::AbstractVector, σ::AbstractVector)
    X = hcat(collect(yModel), ones(length(yModel)))
    W = Diagonal(1.0 ./ σ .^ 2)
    xtWX = X' * W * X
    β = xtWX \ (X' * W * iObs)
    scale, bkgrndCorr = β
    resid = iObs .- X * β
    chi2 = resid' * W * resid
    return scale, bkgrndCorr, chi2, det(xtWX)
end

@testset "WLS" begin

    #------------------------------------------------------------------
    #                 wlsFit -- exact (noise-free) recovery
    #------------------------------------------------------------------

    # …bkgrndCorr) from a noise-free linear curve
    @testset "wlsFit: exact recovery of (scale" begin
        yModel = collect(range(0.1, 5.0; length = 20))
        scaleTrue, bkgrndCorrTrue = 3.7, -1.2
        iObs = scaleTrue .* yModel .+ bkgrndCorrTrue
        σ = fill(0.5, length(yModel))

        f = wlsFit(yModel, iObs, σ)
        @test checkFloat(f.scale, scaleTrue)
        @test checkFloat(f.bkgrndCorr, bkgrndCorrTrue)
        @test checkFloat(f.chi2, 0.0)
        @test f.dof == length(yModel) - 2
    end

    @testset "wlsFit: exact recovery holds under heteroscedastic weights too" begin
        yModel = collect(range(-2.0, 2.0; length = 15))
        scaleTrue, bkgrndCorrTrue = -0.8, 4.4
        iObs = scaleTrue .* yModel .+ bkgrndCorrTrue
        rng = MersenneTwister(1)
        σ = 0.1 .+ rand(rng, length(yModel))   # varying per-point σ

        f = wlsFit(yModel, iObs, σ)
        @test checkFloat(f.scale, scaleTrue; atol = 1e1 * DEFAULT_ATOL)
        @test checkFloat(f.bkgrndCorr, bkgrndCorrTrue; atol = 1e1 * DEFAULT_ATOL)
        @test checkFloat(f.chi2, 0.0; atol = 1e1 * DEFAULT_ATOL)
    end

    #------------------------------------------------------------------
    #                 wlsFit -- agreement with the matrix-algebra oracle
    #------------------------------------------------------------------

    @testset "wlsFit: matches the normal-equations reference on noisy data" begin
        rng = MersenneTwister(42)
        for trial in 1:10
            n = rand(rng, 3:40)
            yModel = randn(rng, n)
            σ = 0.2 .+ rand(rng, n)
            scaleTrue, bkgrndCorrTrue = randn(rng), randn(rng)
            iObs = scaleTrue .* yModel .+ bkgrndCorrTrue .+ σ .* randn(rng, n)

            f = wlsFit(yModel, iObs, σ)
            scaleR, bkgrndCorrR, chi2R, _ = refWls(yModel, iObs, σ)

            @test checkFloat(f.scale, scaleR; atol = 1e3 * DEFAULT_ATOL)
            @test checkFloat(f.bkgrndCorr, bkgrndCorrR; atol = 1e3 * DEFAULT_ATOL)
            @test checkFloat(f.chi2, chi2R; atol = 1e3 * DEFAULT_ATOL)
            @test f.dof == n - 2
        end
    end

    @testset "wlsFit: sumLogVar == Σ log σᵢ²" begin
        yModel = collect(1.0:10.0)
        iObs = 2.0 .* yModel .+ 1.0
        σ = collect(range(0.3, 1.7; length = 10))
        f = wlsFit(yModel, iObs, σ)
        @test checkFloat(f.sumLogVar, sum(2 .* log.(σ)); atol = DEFAULT_ATOL)
    end

    #------------------------------------------------------------------
    #                 wlsFit -- error handling
    #------------------------------------------------------------------

    @testset "wlsFit: length mismatches throw WLSError" begin
        @test_throws WLSError wlsFit([1.0, 2.0, 3.0], [1.0, 2.0], [1.0, 1.0, 1.0])
        @test_throws WLSError wlsFit([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], [1.0, 1.0])
    end

    @testset "wlsFit: n < 3 throws WLSError" begin
        @test_throws WLSError wlsFit(Float64[], Float64[], Float64[])
        @test_throws WLSError wlsFit([1.0], [1.0], [1.0])
        @test_throws WLSError wlsFit([1.0, 2.0], [1.0, 2.0], [1.0, 1.0])
    end

    @testset "wlsFit: n == 3 is the smallest accepted size" begin
        f = wlsFit([1.0, 2.0, 3.0], [2.0, 4.0, 6.0], [1.0, 1.0, 1.0])
        @test f isa WLSFit
        @test f.dof == 1
    end

    @testset "wlsFit: non-positive σ throws WLSError" begin
        @test_throws WLSError wlsFit([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], [1.0, 0.0, 1.0])
        @test_throws WLSError wlsFit([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], [1.0, -1.0, 1.0])
    end

    @testset "wlsFit: a flat (constant) yModel is degenerate and throws WLSError" begin
        @test_throws WLSError wlsFit(fill(2.0, 5), [1.0, 2.0, 3.0, 4.0, 5.0], fill(1.0, 5))
    end

    #------------------------------------------------------------------
    #                 wlsPredict
    #------------------------------------------------------------------

    @testset "wlsPredict: reproduces I_obs exactly on a noise-free fit" begin
        yModel = collect(range(0.0, 10.0; length = 8))
        scaleTrue, bkgrndCorrTrue = 1.5, 0.3
        iObs = scaleTrue .* yModel .+ bkgrndCorrTrue
        f = wlsFit(yModel, iObs, fill(1.0, length(yModel)))
        @test all(checkFloat.(wlsPredict(f, yModel), iObs; atol = DEFAULT_ATOL))
    end

    @testset "wlsPredict: matches the scale*y + bkgrndCorr formula on a fresh curve" begin
        yModel = collect(range(0.0, 10.0; length = 8))
        iObs = 2.0 .* yModel .+ 5.0 .+ [0.1, -0.2, 0.05, 0.0, -0.1, 0.2, -0.05, 0.1]
        f = wlsFit(yModel, iObs, fill(1.0, length(yModel)))
        yFresh = [0.0, 3.3, 7.7]
        @test wlsPredict(f, yFresh) ≈ f.scale .* yFresh .+ f.bkgrndCorr
    end

    #------------------------------------------------------------------
    #                 wlsProfLl
    #------------------------------------------------------------------

    @testset "wlsProfLl: matches its closed form directly from WLSFit fields" begin
        yModel = collect(range(0.1, 5.0; length = 12))
        iObs =
            1.3 .* yModel .+ 0.4 .+
            [0.1, -0.1, 0.2, -0.2, 0.05, -0.05, 0.1, -0.1, 0.0, 0.15, -0.15, 0.05]
        σ = fill(0.3, length(yModel))
        f = wlsFit(yModel, iObs, σ)

        expected = -(f.chi2 + f.sumLogVar) / 2 - (f.dof + 2) * log(2π) / 2
        @test checkFloat(wlsProfLl(f), expected)
    end

    # …constant
    @testset "wlsProfLl: a perfect (chi2 == 0) fit is just the data-normalisation" begin
        yModel = collect(range(0.0, 4.0; length = 6))
        iObs = 2.0 .* yModel .- 1.0
        σ = fill(1.0, length(yModel))
        f = wlsFit(yModel, iObs, σ)
        @test checkFloat(f.chi2, 0.0)
        expected = -f.sumLogVar / 2 - (f.dof + 2) * log(2π) / 2
        @test checkFloat(wlsProfLl(f), expected)
    end

    @testset "wlsProfLl: exact sign flip of the old NLL formula" begin
        # Direct cross-check against the pre-refactor NLL closed form, kept
        # here independent of the source so a sign error in the rename would
        # be caught even if both sides of the wlsProfLl test above shared
        # the same (wrong) sign by copy-paste.
        yModel = collect(range(0.2, 6.0; length = 9))
        iObs =
            -0.7 .* yModel .+ 2.2 .+
            [0.05, -0.02, 0.1, -0.05, 0.0, 0.03, -0.08, 0.02, -0.01]
        σ = fill(0.4, length(yModel))
        f = wlsFit(yModel, iObs, σ)

        nllProf = (f.chi2 + f.sumLogVar) / 2 + (f.dof + 2) * log(2π) / 2
        @test checkFloat(wlsProfLl(f), -nllProf)
    end

    #------------------------------------------------------------------
    #                 reducedChi2
    #------------------------------------------------------------------

    @testset "reducedChi2: equals chi2 / dof exactly" begin
        yModel = collect(range(0.1, 5.0; length = 12))
        iObs =
            1.3 .* yModel .+ 0.4 .+
            [0.1, -0.1, 0.2, -0.2, 0.05, -0.05, 0.1, -0.1, 0.0, 0.15, -0.15, 0.05]
        σ = fill(0.3, length(yModel))
        f = wlsFit(yModel, iObs, σ)
        @test checkFloat(reducedChi2(f), f.chi2 / f.dof; atol = 1e-3 * DEFAULT_ATOL)
    end

    @testset "reducedChi2: a perfect (chi2 == 0) fit gives (numerically) 0" begin
        yModel = collect(range(0.0, 4.0; length = 6))
        iObs = 2.0 .* yModel .- 1.0
        σ = fill(1.0, length(yModel))
        f = wlsFit(yModel, iObs, σ)
        @test checkFloat(reducedChi2(f), 0.0)
    end

    @testset "reducedChi2: matches the true noise level on average over many trials" begin
        # chi2/dof should fluctuate around 1 when sigma and the model are both
        # right -- the classic goodness-of-fit sanity check this function
        # exists to provide, checked here empirically rather than asserted
        # on a single (noisy, so unreliable) trial.
        rng = MersenneTwister(2026)
        yModel = collect(range(0.1, 5.0; length = 30))
        scaleTrue, bkgrndCorrTrue = 1.4, -0.3
        σ = fill(0.25, length(yModel))
        vals = Float64[]
        for _ in 1:500
            iObs =
                scaleTrue .* yModel .+ bkgrndCorrTrue .+
                σ .* randn(rng, length(yModel))
            f = wlsFit(yModel, iObs, σ)
            push!(vals, reducedChi2(f))
        end
        @test isapprox(sum(vals) / length(vals), 1.0; atol = 0.15)
    end

    #------------------------------------------------------------------
    #                 AD-differentiability (stage-1 HMC needs this)
    #------------------------------------------------------------------

    @testset "wlsFit -> wlsProfLl is AD-differentiable through yModel" begin
        # yModel stands in for a forward-model curve parameterised by θ, as
        # it will be when this feeds stage-1 HMC; the gradient must survive
        # with no Float64 cast anywhere in wlsFit/wlsProfLl.
        q = collect(range(0.1, 2.0; length = 10))
        iObs =
            3.0 .* exp.(-q) .+ 0.5 .+
            [0.02, -0.01, 0.03, 0.0, -0.02, 0.01, -0.03, 0.02, 0.0, -0.01]
        σ = fill(0.2, length(q))

        model(θ) = θ[1] .* exp.(-θ[2] .* q)   # θ = (amplitude, decay rate)
        loss(θ) = wlsProfLl(wlsFit(model(θ), iObs, σ))

        θ₀ = [2.5, 1.1]
        g = ForwardDiff.gradient(loss, θ₀)
        @test all(isfinite, g)

        h = 1e-6
        for i in 1:2
            θp = copy(θ₀)
            θp[i] += h
            θm = copy(θ₀)
            θm[i] -= h
            # the amplitude direction is exactly flat under the profile (the scale
            # absorbs it), so its gradient is ~0 and needs an absolute tolerance
            @test g[i] ≈ (loss(θp) - loss(θm)) / (2h) rtol = 1e-4 atol = 1e-6
        end
    end

end
