# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/pipeline/run-model.jl: the posterior band of the predicted curve
# (`_curveBands`) equals the plain quantile-and-filter computation it replaced.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using Statistics: quantile
using BAYSOL.Pipeline: _curveBands, _sigmaSpec, _sigmaLabel, VAL_SIGMA

# the straightforward version: per q, copy the row,
# take the quantiles, filter the draws between them
function curveBandsReference(qvals, curves, pLo, pHi)
    Q = size(curves, 1)
    quant = Matrix{Float64}(undef, Q, 3)
    bnd = Matrix{Float64}(undef, Q, 3)
    for q in 1:Q
        I = curves[q, :]
        lo, hi = quantile(I, [pLo, pHi])
        inside = [x for x in I if lo ≤ x ≤ hi]
        quant[q, :] .= (qvals[q], lo, hi)
        bnd[q, :] .= (qvals[q], extrema(inside)...)
    end
    return quant, bnd
end

@testset "runModel: the curve band" begin
    rng = Xoshiro(7)
    qvals = collect(range(0.01, 0.3; length = 70))
    # skewed, with ties-free draws
    curves = randn(rng, 70, 900) .* 0.1 .+ 5 .+ randn(rng, 70, 900) .^ 3 .* 0.01
    for (pLo, pHi) in ((0.16, 0.84), (0.025, 0.975), (0.0, 1.0))
        quant, bnd = _curveBands(qvals, curves, pLo, pHi)
        rq, rb = curveBandsReference(qvals, curves, pLo, pHi)
        @test quant == rq && bnd == rb
    end
    @testset "ties and few draws" begin
        c = repeat([1.0 1.0 2.0 2.0 3.0], 4)
        quant, bnd = _curveBands(1:4, c, 0.25, 0.75)
        rq, rb = curveBandsReference(1:4, c, 0.25, 0.75)
        @test quant == rq && bnd == rb
    end
    @testset "the input is not modified" begin
        c = randn(rng, 5, 50)
        c0 = copy(c)
        _curveBands(1:5, c, 0.16, 0.84)
        @test c == c0
    end
end

@testset "runModel: the interval from sigma" begin
    # the default is 2σ: the percentiles a Normal has at ±2σ
    @test VAL_SIGMA == 2.0
    lo, hi, label = _sigmaSpec(nothing)
    @test lo ≈ 0.02275 atol = 1e-5
    @test hi ≈ 0.97725 atol = 1e-5
    @test label == "2sigma"
    lo, hi, label = _sigmaSpec(1)
    @test lo ≈ 0.15866 atol = 1e-5
    @test hi ≈ 0.84134 atol = 1e-5
    @test label == "1sigma"
    lo, hi, label = _sigmaSpec(0.5)
    @test lo ≈ 0.30854 atol = 1e-5
    @test hi ≈ 0.69146 atol = 1e-5
    @test label == "0.5sigma"
    @test lo + hi ≈ 1                                  # symmetric tails
    @test _sigmaLabel(3.0) == "3sigma" && _sigmaLabel(1.5) == "1.5sigma"
    # no upper limit, but a finite number above 0
    @test _sigmaSpec(8)[3] == "8sigma"
    @test_throws DomainError _sigmaSpec(0)
    @test_throws DomainError _sigmaSpec(-1)
    @test_throws DomainError _sigmaSpec(Inf)
end
