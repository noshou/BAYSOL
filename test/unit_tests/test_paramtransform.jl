# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Fitting/ParamTransform.jl: the ξ-space (physical fit
# parameters, mixed domains) <-> θ-space (unconstrained ℝ⁵) bijection that
# stage-1 HMC samples in, plus the log-Jacobian correction `Θ` returns
# alongside the (pure, non-mutating) transform.

include(joinpath(@__DIR__, "testsetup.jl"))

using ForwardDiff
using LinearAlgebra
using Random
using StaticArrays
using BayeSol.Fitting: Θ, Ξ, ρₑ_prior, δρ_prior, c1_prior, Solute, NonBiological

include(joinpath(@__DIR__, "..", "fixtures", "floatcompare.jl"))

"""
Independent re-derivation of `Θ`'s formula from its docstring, so tests
aren't just re-running the implementation against itself. Returns `(θ, corr)`
as plain tuples.
"""
function ref_Θ(x::NTuple{5,<:Real})
    a, b, c = log(x[1]), log(x[2]), log(x[5])
    return ((a, b, x[3], x[4], c), a + b + c)
end

"""
Independent re-derivation of `Ξ`'s formula from its docstring. Returns `ξ`
as a plain tuple.
"""
ref_Ξ(t::NTuple{5,<:Real}) = (exp(t[1]), exp(t[2]), t[3], t[4], exp(t[5]))

"""
Run `Θ` on an `SVector` built from `x`; returns `(θ, corr)` as
`(NTuple{5}, Real)`.
"""
function apply_Θ(x::NTuple{5,<:Real})
    θ, corr = Θ(SVector{5,Float64}(x))
    return (Tuple(θ), corr)
end

"""
Run `Ξ` on an `SVector` built from `t`; returns `ξ` as `NTuple{5}`.
"""
function apply_Ξ(t::NTuple{5,<:Real})
    return Tuple(Ξ(SVector{5,Float64}(t)))
end

"""
Finite-difference Jacobian of `ξ` at `t`, `(5,5)`, for cross-checking `Θ`'s
analytic log-Jacobian correction against something that doesn't share its
derivation.
"""
function numeric_ξ_jacobian(t::NTuple{5,<:Real}; h::Real = 1.0e-6)
    J = zeros(Float64, 5, 5)
    for j in 1:5
        tp = collect(Float64, t); tp[j] += h
        tm = collect(Float64, t); tm[j] -= h
        J[:, j] = (collect(apply_Ξ(Tuple(tp))) .- collect(apply_Ξ(Tuple(tm)))) ./ (2h)
    end
    return J
end

@testset "ParamTransform" begin

    #------------------------------------------------------------------
    #                 Θ / Ξ -- match their own docstring formulas
    #------------------------------------------------------------------

    @testset "Θ: matches the independent reference derivation" begin
        cases = (
            (0.334, 1.05, -0.2, 0.1, 1.02),
            (1.0, 1.0, 0.0, 0.0, 1.0),
            (0.05, 0.001, -5.0, 5.0, 0.96),
            (10.0, 20.0, 3.3, -3.3, 1.04),
        )
        for ξ0 in cases
            res, corr = apply_Θ(ξ0)
            res_ref, corr_ref = ref_Θ(ξ0)
            @test all(close_.(res, res_ref))
            @test close_(corr, corr_ref)
        end
    end

    @testset "Ξ: matches the independent reference derivation" begin
        cases = (
            (0.0, 0.0, -0.2, 0.1, 0.0),
            (-3.5, 2.1, 5.0, -5.0, 0.02),
            (50.0, -50.0, 0.0, 0.0, -50.0),
            (-1.0e-3, 1.0e-3, 3.3, -3.3, 1.0e-3),
        )
        for θ₀ in cases
            @test all(close_.(apply_Ξ(θ₀), ref_Ξ(θ₀)))
        end
    end

    #------------------------------------------------------------------
    #                 Θ / Ξ -- round trip
    #------------------------------------------------------------------

    @testset "Ξ(Θ(x)) == x for x in the valid ξ domain" begin
        cases = (
            (0.334, 1.05, -0.2, 0.1, 1.02),
            (1.0, 1.0, 0.0, 0.0, 1.0),
            (0.001, 100.0, -50.0, 50.0, 0.96),
        )
        for ξ0 in cases
            res, _ = apply_Θ(ξ0)
            @test all(close_.(apply_Ξ(res), ξ0))
        end
    end

    @testset "Θ(Ξ(x)) == x for x in θ-space (any reals)" begin
        cases = (
            (0.0, 0.0, -0.2, 0.1, 0.0),
            (-3.5, 2.1, 5.0, -5.0, 0.02),
            (10.0, -10.0, 0.0, 0.0, 10.0),
        )
        for θ₀ in cases
            ξ0 = apply_Ξ(θ₀)
            res, _ = apply_Θ(ξ0)
            @test all(close_.(res, θ₀))
        end
    end

    #------------------------------------------------------------------
    #                 θ / ξ -- identity on positions 3, 4 (δρ2, δρ3)
    #------------------------------------------------------------------

    @testset "Θ: positions 3, 4 (δρ2, δρ3) pass through unchanged, exactly" begin
        ξ0 = (0.5, 2.0, -7.25, 3.125, 1.01)
        res, _ = apply_Θ(ξ0)
        @test res[3] == ξ0[3]
        @test res[4] == ξ0[4]
    end

    @testset "Ξ: positions 3, 4 (δρ2, δρ3) pass through unchanged, exactly" begin
        θ₀ = (1.2, -0.5, -7.25, 3.125, 0.02)
        res = apply_Ξ(θ₀)
        @test res[3] == θ₀[3]
        @test res[4] == θ₀[4]
    end

    #------------------------------------------------------------------
    #                 Θ -- log-Jacobian correction
    #------------------------------------------------------------------

    @testset "Θ: corr == a + b + c exactly" begin
        for ξ0 in ((0.334, 1.05, -0.2, 0.1, 1.02), (0.02, 0.02, 0.0, 0.0, 0.02))
            res, corr = apply_Θ(ξ0)
            @test corr == res[1] + res[2] + res[5]
        end
    end

    @testset "Θ: log-Jacobian correction matches a finite-difference Jacobian of ξ" begin
        # Independent numerical cross-check of `corr`, via a totally
        # different route (finite differences on ξ, not θ's own formula).
        for θ₀ in ( (0.1, -0.2, 0.3, -0.4, 0.5), (2.0, -2.0, 0.0, 0.0, 2.0),
                    (-5.0, 5.0, 1.0, -1.0, -5.0))
            ξ0 = apply_Ξ(θ₀)
            _, corr = apply_Θ(ξ0)
            numeric_log_det = log(abs(det(numeric_ξ_jacobian(θ₀))))
            @test isapprox(corr, numeric_log_det; atol = 1.0e-6)
        end
    end

    #------------------------------------------------------------------
    #                 Ξ -- positivity guarantee
    #------------------------------------------------------------------

    @testset "Ξ: positions 1, 2, 5 (dns, δρ1, c_1) are always > 0, any finite θ" begin
        # 700 stays clear of exp's Float64 overflow point (~709.78).
        for θ₀ in ( (0.0, 0.0, 0.0, 0.0, 0.0), (700.0, -700.0, 0.0, 0.0, 700.0),
                    (-700.0, 700.0, 0.0, 0.0, -700.0), (37.0, -21.5, 0.0, 0.0, 8.2))
            res = apply_Ξ(θ₀)
            @test res[1] > 0 && res[2] > 0 && res[5] > 0
            @test all(isfinite, res)
        end
    end

    @testset "Ξ: dns/δρ1/c_1 overflow to Inf far beyond any plausible θ (documented, not a bug)" begin
        res = apply_Ξ((1000.0, 0.0, 0.0, 0.0, 0.0))
        @test res[1] == Inf
    end

    #------------------------------------------------------------------
    #                 θ -- domain errors (matches Julia's own `log`)
    #------------------------------------------------------------------

    @testset "θ: non-positive dns/δρ1/c_1 throws DomainError, matching Base log" begin
        @test_throws DomainError apply_Θ((-1.0, 1.0, 0.0, 0.0, 1.0))
        @test_throws DomainError apply_Θ((1.0, -1.0, 0.0, 0.0, 1.0))
        @test_throws DomainError apply_Θ((1.0, 1.0, 0.0, 0.0, -1.0))
    end

    @testset "θ: dns/δρ1/c_1 == 0 gives -Inf (Base log's own boundary behaviour, no throw)" begin
        res, corr = apply_Θ((0.0, 1.0, 0.0, 0.0, 1.0))
        @test res[1] == -Inf
        @test corr == -Inf
    end

    #------------------------------------------------------------------
    #                 purity -- no mutation of the input
    #------------------------------------------------------------------

    @testset "Θ/Ξ are pure: the input SVector is unchanged, output is correct" begin
        x = SVector{5,Float64}(0.334, 1.05, -0.2, 0.1, 1.02)
        x_before = Tuple(x)
        θ, corr = Θ(x)
        @test Tuple(x) == x_before   # input untouched (trivially true for SVector, worth asserting)
        @test θ[1] == log(0.334) && θ[2] == log(1.05) && θ[5] == log(1.02)
        @test θ[3] == -0.2 && θ[4] == 0.1
        @test corr == θ[1] + θ[2] + θ[5]

        θ_before = Tuple(θ)
        ξ = Ξ(θ)
        @test Tuple(θ) == θ_before   # input untouched
        @test close_(ξ[1], 0.334) && close_(ξ[2], 1.05) && close_(ξ[5], 1.02)
        @test ξ[3] == -0.2 && ξ[4] == 0.1
    end

    #------------------------------------------------------------------
    #                 AD-differentiability (stage-1 HMC needs this)
    #------------------------------------------------------------------

    @testset "Ξ is AD-differentiable" begin
        # Ξ(θ) sits directly on the sampler's hot path: every leapfrog step
        # unpacks the current θ into physical parameters this way, so the
        # gradient must survive with no Float64 cast anywhere in ξ.
        function f(t)
            ξ = Ξ(SVector{5,eltype(t)}(t...))
            return sum(ξ)
        end
        t0 = [0.1, -0.2, 0.3, -0.4, 0.5]
        g = ForwardDiff.gradient(f, t0)
        @test all(isfinite, g)

        h = 1.0e-6
        for i in 1:5
            tp = copy(t0); tp[i] += h
            tm = copy(t0); tm[i] -= h
            @test g[i] ≈ (f(tp) - f(tm)) / (2h) rtol = 1.0e-4
        end
    end

    @testset "Θ is AD-differentiable through its ξ argument" begin
        function f(x)
            θ, corr = Θ(SVector{5,eltype(x)}(x...))
            return sum(θ) + corr
        end
        x0 = [0.334, 1.05, -0.2, 0.1, 1.02]
        g = ForwardDiff.gradient(f, x0)
        @test all(isfinite, g)

        h = 1.0e-6
        for i in 1:5
            xp = copy(x0); xp[i] += h
            xm = copy(x0); xm[i] -= h
            @test g[i] ≈ (f(xp) - f(xm)) / (2h) rtol = 1.0e-4
        end
    end

    #------------------------------------------------------------------
    #                 integration: every prior feeding θ/ξ, at volume
    #------------------------------------------------------------------
    #
    # Each of ρₑ_prior/δρ_prior/c1_prior claims a support (LogNormal or
    # Normal) that θ's domain requirements (dns, δρ1, c_1 > 0; δρ2, δρ3
    # unrestricted) are built around. These draw at volume (250_000 draws
    # each, 1_000_000 total) directly the priors.

    @testset "priors -> θ/ξ: ρₑ_prior draws round-trip and never throw (250_000 draws)" begin
        Random.seed!(20_260_917)
        d_dns = ρₑ_prior(7.0, 0.0, Solute[NonBiological(0.5, 0.01, "urea")])
        fixed = (1.05, -0.2, 0.1, 1.02)   # δρ1, δρ2, δρ3, c_1 held fixed
        n = 250_000
        finite_ok = true
        roundtrip_ok = true
        for _ in 1:n
            ξ0 = (rand(d_dns), fixed...)
            res, corr = apply_Θ(ξ0)
            finite_ok &= isfinite(corr) && all(isfinite, res)
            roundtrip_ok &= all(close_.(apply_Ξ(res), ξ0))
        end
        @test finite_ok
        @test roundtrip_ok
    end

    @testset "priors -> θ/ξ: δρ_prior draws round-trip and never throws" begin
        Random.seed!(20_260_918)
        δρ1_d, δρ2_d, δρ3_d = δρ_prior(μ_χ = 0.0, σ_χ = 1.5)
        fixed_dns, fixed_c1 = 0.334, 1.0
        n = 250_000
        finite_ok = true
        roundtrip_ok = true
        for _ in 1:n
            ξ0 = (fixed_dns, rand(δρ1_d), rand(δρ2_d), rand(δρ3_d), fixed_c1)
            res, corr = apply_Θ(ξ0)
            finite_ok &= isfinite(corr) && all(isfinite, res)
            roundtrip_ok &= all(close_.(apply_Ξ(res), ξ0))
        end
        @test finite_ok
        @test roundtrip_ok
    end

    @testset "priors -> θ/ξ: c1_prior draws round-trip and never throws" begin
        Random.seed!(20_260_919)
        fixed = (0.334, 1.05, -0.2, 0.1)   # dns, δρ1, δρ2, δρ3
        ns = (10.0, 50.0, 95.0, 99.9)
        per_n = 250_000 ÷ length(ns)
        finite_ok = true
        roundtrip_ok = true
        for n in ns
            d_c1 = c1_prior(n)
            for _ in 1:per_n
                ξ0 = (fixed..., rand(d_c1))
                res, corr = apply_Θ(ξ0)
                finite_ok &= isfinite(corr) && all(isfinite, res)
                roundtrip_ok &= all(close_.(apply_Ξ(res), ξ0))
            end
        end
        @test finite_ok
        @test roundtrip_ok
    end

    @testset "priors -> θ/ξ: all three priors combined, full ξ vector" begin
        Random.seed!(20_260_920)
        d_dns = ρₑ_prior(7.4, 0.05, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
        δρ1_d, δρ2_d, δρ3_d = δρ_prior(μ_χ = 2.0, σ_χ = 3.0)
        d_c1 = c1_prior(95.0)
        n = 250_000
        finite_ok = true
        roundtrip_ok = true
        jacobian_ok = true
        for _ in 1:n
            ξ0 = (rand(d_dns), rand(δρ1_d), rand(δρ2_d), rand(δρ3_d), rand(d_c1))
            res, corr = apply_Θ(ξ0)
            finite_ok &= isfinite(corr) && all(isfinite, res)
            roundtrip_ok &= all(close_.(apply_Ξ(res), ξ0))
            jacobian_ok &= corr == res[1] + res[2] + res[5]
        end
        @test finite_ok
        @test roundtrip_ok
        @test jacobian_ok
    end

end
