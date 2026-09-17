# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Fitting/Priors/ExcludedVolume.jl: the LogNormal prior over the
# excluded-volume correction factor c1 = r0/r_m, calibrated so that z(n)
# standard deviations around c1 = 1 exactly span CRYSOL's stated fitting bound
# [0.96, 1.04].

using Random
using SpecialFunctions: erfinv
using Distributions: LogNormal, mean, var, cdf
using ScatterNet.Fitting: c1_prior

include(joinpath(@__DIR__, "fixtures", "floatcompare.jl"))   # close_

"""
Independent re-derivation of `c1_prior`'s z/σ/σ_ln/μ_ln pipeline from its
docstring, so tests aren't just re-running the implementation against itself.
"""
function ref_c1_prior(n::Real)
    z = sqrt(2) * erfinv(n / 100)
    σ = 0.04 / z
    σ_ln = sqrt(log(1 + σ^2))
    μ_ln = -σ_ln^2 / 2
    return μ_ln, σ_ln
end

"""
Draws `draws` samples from `c1_prior(n)`, `trials` independent times, and
returns the vector of per-trial fractions landing in CRYSOL's bound
`[0.96, 1.04]`.
"""
function empirical_containment(n::Real; draws::Integer = 1000, trials::Integer = 1000)
    d = c1_prior(n)
    fracs = Vector{Float64}(undef, trials)
    for t in 1:trials
        s = rand(d, draws)
        fracs[t] = count(x -> 0.96 <= x <= 1.04, s) / draws
    end
    return fracs
end

@testset "ExcludedVolume" begin

    #------------------------------------------------------------------
    #                 c1_prior -- matches its own docstring formula
    #------------------------------------------------------------------

    @testset "c1_prior: matches the independent reference derivation across n" begin
        for n in (  0.5, 1.0, 10.0, 50.0, 68.26894921370859, 80.0, 95.0, 99.0,
                    99.73002039367398, 99.999, 100.0)
            d = c1_prior(n)
            @test d isa LogNormal{Float64}
            μ_ln_ref, σ_ln_ref = ref_c1_prior(n)
            @test close_(d.μ, μ_ln_ref)
            @test close_(d.σ, σ_ln_ref)
        end
    end

    #------------------------------------------------------------------
    #                 c1_prior -- moment-matching identities
    #------------------------------------------------------------------

    @testset "c1_prior: mean is exactly 1 regardless of n (moment-matching identity)" begin
        # μ_ln = -σ_ln²/2 forces mean(LogNormal) = exp(μ_ln + σ_ln²/2) = 1
        # for every n, by construction -- not just at the anchor points.
        for n in (1.0e-3, 1.0, 25.0, 50.0, 75.0, 95.0, 99.9, 100.0)
            @test close_(mean(c1_prior(n)), 1.0; atol = 1.0e-9)
        end
    end

    @testset "c1_prior: variance equals (0.04/z)^2 exactly (moment-matching identity)" begin
        for n in (1.0, 50.0, 68.26894921370859, 95.0, 99.73002039367398)
            z = sqrt(2) * erfinv(n / 100)
            σ_target = 0.04 / z
            @test close_(var(c1_prior(n)), σ_target^2; atol = max(1.0e-12, σ_target^2 * 1.0e-9))
        end
    end

    #------------------------------------------------------------------
    #                 c1_prior -- known anchor values (z = 1, 2, 3 std)
    #------------------------------------------------------------------

    @testset "c1_prior: n corresponding to z=1,2,3 std reproduces sigma = 0.04/z" begin
        # n such that erfinv(n/100) = z/sqrt(2), i.e. n = 100*erf(z/sqrt(2)).
        for (z, n) in ( (1.0, 68.26894921370859),
                        (2.0, 95.44997361036416),
                        (3.0, 99.73002039367398))
            d = c1_prior(n)
            @test close_(sqrt(var(d)), 0.04 / z; atol = 1.0e-6)
        end
    end

    #------------------------------------------------------------------
    #                 c1_prior -- monotonicity in n
    #------------------------------------------------------------------

    @testset "c1_prior: higher n gives a strictly smaller sigma (tighter prior)" begin
        ns = (1.0, 10.0, 50.0, 68.0, 80.0, 90.0, 95.0, 99.0, 99.9, 99.99)
        σs = [sqrt(var(c1_prior(n))) for n in ns]
        @test issorted(σs; rev = true)
        @test all(diff(σs) .< 0.0)
    end

    #------------------------------------------------------------------
    #                 c1_prior -- containment sanity (analytic cdf)
    #------------------------------------------------------------------

    @testset "c1_prior: cdf(1.04) - cdf(0.96) tracks n/100 for n >= 50" begin
        # `c1_prior` moment-matches mean/variance, it does not solve for
        # exact quantiles, so this is an approximate check, not an identity.
        # For a narrow LogNormal (large n => small sigma) the two
        # constructions nearly coincide; it degrades for small n (large
        # sigma, more lognormal skew), so only checked here for n >= 50.
        for n in (50.0, 68.26894921370859, 80.0, 95.0, 99.0, 99.73002039367398)
            d = c1_prior(n)
            contain = cdf(d, 1.04) - cdf(d, 0.96)
            @test isapprox(contain, n / 100; atol = 0.01)
        end
    end

    @testset "c1_prior: n = 100 is the boundary -- degenerate point mass at c1 = 1" begin
        d = c1_prior(100.0)
        @test close_(mean(d), 1.0; atol = 1.0e-9)
        @test close_(var(d), 0.0; atol = 1.0e-9)
    end

    @testset "c1_prior: very small n gives a very wide, still-valid distribution" begin
        d = c1_prior(1.0e-6)
        @test d isa LogNormal{Float64}
        @test close_(mean(d), 1.0; atol = 1.0e-6)
        @test var(d) > 1.0   # essentially uninformative at this n
    end

    #------------------------------------------------------------------
    #                 c1_prior -- domain errors
    #------------------------------------------------------------------

    @testset "c1_prior: n outside (0, 100] throws DomainError" begin
        @test_throws DomainError c1_prior(0.0)
        @test_throws DomainError c1_prior(-1.0)
        @test_throws DomainError c1_prior(-100.0)
        @test_throws DomainError c1_prior(100.0 + 1.0e-9)
        @test_throws DomainError c1_prior(200.0)
    end

    @testset "c1_prior: n = 100 (upper boundary) does not throw" begin
        @test c1_prior(100.0) isa LogNormal{Float64}
    end

    #------------------------------------------------------------------
    #                 c1_prior -- Monte Carlo containment (seeded)
    #------------------------------------------------------------------

    @testset "c1_prior: empirical containment matches n/100 (1000 draws x 1000 trials, seeded)" begin
        # Direct empirical check that "n% of samples fall within CRYSOL's
        # bound" actually holds under sampling, not just under the analytic
        # cdf. Seeded for reproducibility; atol is generous (~2-3x the
        # observed trial-to-trial std at these n) so this stays robust to RNG
        # stream/Julia-version differences rather than pinned to today's
        # exact draw.
        Random.seed!(20260917)
        for n in (10.0, 30.0, 50.0, 70.0, 90.0, 100.0)
            fracs = empirical_containment(n)
            empirical_mean = sum(fracs) / length(fracs)
            @test isapprox(empirical_mean, n / 100; atol = 0.03)
        end
    end

end
