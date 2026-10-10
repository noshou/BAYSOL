# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Pipeline/RunModel.jl: the posterior band of the predicted curve
# (`_curve_bands`) equals the plain quantile-and-filter computation it replaced.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using Statistics: quantile
using BAYSOL.Pipeline: _curve_bands

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
