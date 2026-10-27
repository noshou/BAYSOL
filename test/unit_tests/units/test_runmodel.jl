# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Pipeline/RunModel.jl: the posterior band of the predicted curve
# (`_curve_bands`) equals the plain quantile-and-filter computation it replaced.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using Statistics: quantile
using BAYSOL.Pipeline: _curve_bands, _quantile_spec, _sigma_label, DEFAULT_SIGMA, MAX_SIGMA

# the straightforward version: per q, copy the row,
# take the quantiles, filter the draws between them
function curve_bands_reference(qvals, curves, p_lo, p_hi)
    Q = size(curves, 1)
    quant = Matrix{Float64}(undef, Q, 3)
    bnd = Matrix{Float64}(undef, Q, 3)
    for q in 1:Q
        I = curves[q, :]
        lo, hi = quantile(I, [p_lo, p_hi])
        inside = [x for x in I if lo ≤ x ≤ hi]
        quant[q, :] .= (qvals[q], lo, hi)
        bnd[q, :] .= (qvals[q], extrema(inside)...)
    end
    return quant, bnd
end

@testset "run_model: the curve band" begin
    rng = Xoshiro(7)
    qvals = collect(range(0.01, 0.3; length = 70))
    # skewed, with ties-free draws
    curves = randn(rng, 70, 900) .* 0.1 .+ 5 .+ randn(rng, 70, 900) .^ 3 .* 0.01
    for (p_lo, p_hi) in ((0.16, 0.84), (0.025, 0.975), (0.0, 1.0))
        quant, bnd = _curve_bands(qvals, curves, p_lo, p_hi)
        rq, rb = curve_bands_reference(qvals, curves, p_lo, p_hi)
        @test quant == rq && bnd == rb
    end
    @testset "ties and few draws" begin
        c = repeat([1.0 1.0 2.0 2.0 3.0], 4)
        quant, bnd = _curve_bands(1:4, c, 0.25, 0.75)
        rq, rb = curve_bands_reference(1:4, c, 0.25, 0.75)
        @test quant == rq && bnd == rb
    end
    @testset "the input is not modified" begin
        c = randn(rng, 5, 50)
        c0 = copy(c)
        _curve_bands(1:5, c, 0.16, 0.84)
        @test c == c0
    end
end

@testset "run_model: the interval from sigma or quantiles" begin
    # the default is 2σ: the percentiles a Normal has at ±2σ
    @test DEFAULT_SIGMA == 2.0
    lo, hi, label = _quantile_spec(nothing, nothing)
    @test lo ≈ 0.02275 atol = 1e-5
    @test hi ≈ 0.97725 atol = 1e-5
    @test label == "2sigma"
    lo, hi, label = _quantile_spec(nothing, 1)
    @test lo ≈ 0.15866 atol = 1e-5
    @test hi ≈ 0.84134 atol = 1e-5
    @test label == "1sigma"
    lo, hi, label = _quantile_spec(nothing, 0.5)
    @test lo ≈ 0.30854 atol = 1e-5
    @test hi ≈ 0.69146 atol = 1e-5
    @test label == "0.5sigma"
    @test lo + hi ≈ 1                                  # symmetric tails
    @test _sigma_label(3.0) == "3sigma" && _sigma_label(1.5) == "1.5sigma"
    # a "<lo>-<hi>" range, as before, and the extremes
    @test _quantile_spec("5-95", nothing) == (0.05, 0.95, "5-95")
    @test _quantile_spec("0-0", nothing) == (0.0, 1.0, "0-0")
    # both, or nonsense, is an error
    @test_throws ArgumentError _quantile_spec("5-95", 2)
    @test_throws DomainError _quantile_spec(nothing, 0)
    @test_throws DomainError _quantile_spec(nothing, -1)
    @test_throws DomainError _quantile_spec(nothing, MAX_SIGMA + 0.1)
    @test _quantile_spec(nothing, MAX_SIGMA)[3] == "3sigma"
    @test_throws DomainError _quantile_spec("95-5", nothing)
    @test_throws DomainError _quantile_spec("5-101", nothing)
    @test_throws DomainError _quantile_spec("5to95", nothing)
end
