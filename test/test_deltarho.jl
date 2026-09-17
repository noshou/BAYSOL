# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Fitting/Priors/DeltaRho.jl: the fixed dro1/dro2 priors and the
# dro3 = Normal(μ_χ, σ_χ) cavity-water contrast dro_prior builds per call.

using ScatterNet.Fitting: dro_prior
using Distributions: LogNormal, Normal, mean, std, quantile

const FIT = ScatterNet.Fitting

include(joinpath(@__DIR__, "fixtures", "floatcompare.jl"))   # close_

@testset "DeltaRho" begin

    #------------------------------------------------------------------
    #                 dro_prior -- return shape and types
    #------------------------------------------------------------------

    @testset "dro_prior: returns a 3-tuple of the documented distribution types" begin
        out = dro_prior(0.0; σ_χ = 0.3)
        @test out isa Tuple{LogNormal,Normal,Normal}
        dro1, dro2, dro3 = out
        @test dro1 isa LogNormal
        @test dro2 isa Normal
        @test dro3 isa Normal
    end

    #------------------------------------------------------------------
    #                 dro1 -- fixed convex-bead prior
    #------------------------------------------------------------------

    @testset "dro1: median ρ = 1, mean pulled up to 1.15 by right-skew" begin
        dro1, _, _ = dro_prior()
        @test close_(quantile(dro1, 0.5), 1.0)
        @test close_(mean(dro1), 1.15)
        # dro1 is the same object on every call
        dro1_b, _, _ = dro_prior(3.7; σ_χ = 9.0)
        @test dro1 === dro1_b
    end

    #------------------------------------------------------------------
    #                 dro2 -- fixed concave-bead prior
    #------------------------------------------------------------------

    @testset "dro2: Normal(1, 0.15), fixed regardless of arguments" begin
        _, dro2, _ = dro_prior()
        @test close_(mean(dro2), 1.0)
        @test close_(std(dro2), 0.15)
        _, dro2_b, _ = dro_prior(-4.0; σ_χ = 2.0)
        @test dro2 === dro2_b
    end

    #------------------------------------------------------------------
    #                 dro3 -- cavity-water contrast, built from the arguments
    #------------------------------------------------------------------

    @testset "dro3: Normal(μ_χ, σ_χ), tracking whatever is passed in" begin
        for (μ_χ, σ_χ) in ((0.0, 1.0), (1.15, 0.3), (-2.0, 0.05), (5.0, 10.0))
            _, _, dro3 = dro_prior(μ_χ; σ_χ = σ_χ)
            @test close_(mean(dro3), μ_χ)
            @test close_(std(dro3), σ_χ)
        end
    end

    @testset "dro3: defaults are μ_χ = 0, σ_χ = 0 -- a point mass at 0, matching standard CRYSOL's dr3 = 0" begin
        _, _, dro3 = dro_prior()
        @test mean(dro3) == 0.0
        @test std(dro3) == 0.0
        # a point mass always samples its own mean -- dro3 genuinely collapses
        # to exactly 0 by default, it isn't merely centered there
        @test all(==(0.0), rand(dro3, 8))
    end

    @testset "dro3: σ_χ = 0 (default or explicit) collapses to a point mass at whatever μ_χ is" begin
        _, _, dro3 = dro_prior(2.5)   # σ_χ left at its default
        @test std(dro3) == 0.0
        @test mean(dro3) == 2.5
        @test all(==(2.5), rand(dro3, 8))

        _, _, dro3_b = dro_prior(2.5; σ_χ = 0.0)   # same thing, spelled explicitly
        @test mean(dro3_b) == 2.5
        @test std(dro3_b) == 0.0
    end

    @testset "dro3: negative σ_χ is rejected by the underlying Normal" begin
        @test_throws DomainError dro_prior(0.0; σ_χ = -1.0)
        @test_throws DomainError dro_prior(0.0; σ_χ = -0.01)
    end

    @testset "dro3: μ_χ has no positional default collision with σ_χ's keyword default" begin
        # positional μ_χ defaults to 0 independently of the σ_χ keyword
        a = dro_prior()
        b = dro_prior(0.0)
        c = dro_prior(0.0; σ_χ = 0.0)
        @test mean(a[3]) == mean(b[3]) == mean(c[3])
        @test std(a[3]) == std(b[3]) == std(c[3])
    end

end
