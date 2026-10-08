# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Fitting/ParamTransform.jl: the ξ-space (physical fit
# parameters, bounded/half-bounded domains) <-> θ-space (unconstrained ℝ⁴) bijection that
# the HMC sampler runs in, plus the log-Jacobian correction `Θ` returns
# alongside the (pure, non-mutating) transform.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using ForwardDiff
using LinearAlgebra
using Random
using StaticArrays
using Distributions: mean
using BAYSOL.Fitting: Θ, Ξ, ρₑ_prior, δρ_prior, ξ_priors, Solute, NonBiological
using BAYSOL.Fitting: DRO_BOUNDS, DRO12_CONCENTRATION, DRO3_CONCENTRATION

const logjac = BAYSOL.Fitting.logjac

include(joinpath(@__DIR__, "..", "..", "utils", "floatcompare.jl"))

const LO, HI = DRO_BOUNDS

# One fixed prior set (NaCl buffer); its δρ₃ prior supplies the interval (L₃, L₃ + W₃).
const PR_ρ = ρₑ_prior(7.4, 0.05, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
const PR = ξ_priors(PR_ρ, δρ_prior(DRO12_CONCENTRATION, DRO3_CONCENTRATION, mean(PR_ρ))...)
const L3, W3 = PR.δρ₃Prior.μ, PR.δρ₃Prior.σ

"""
Independent re-derivation of `Θ`'s formula from its docstring, so tests
aren't just re-running the implementation against itself. Returns `(θ, corr)`
as plain tuples.
"""
function ref_Θ(x::NTuple{4,<:Real})
    a = log(x[1])
    us = ((x[2] - LO) / (HI - LO), (x[3] - LO) / (HI - LO), (x[4] - L3) / W3)
    Ws = (HI - LO, HI - LO, W3)
    ts = map(u -> log(u / (1 - u)), us)
    corr = a + sum(log(W) + log(u) + log(1 - u) for (u, W) in zip(us, Ws))
    return ((a, ts...), corr)
end

"""
Independent re-derivation of `Ξ`'s formula from its docstring. Returns `ξ`
as a plain tuple.
"""
ref_Ξ(t::NTuple{4,<:Real}) = (
    exp(t[1]),
    LO + (HI - LO) / (1 + exp(-t[2])),
    LO + (HI - LO) / (1 + exp(-t[3])),
    L3 + W3 / (1 + exp(-t[4])),
)

apply_Θ(x::NTuple{4,<:Real}) = (θ = Θ(SVector{4,Float64}(x), PR); (Tuple(θ[1]), θ[2]))
apply_Ξ(t::NTuple{4,<:Real}) = Tuple(Ξ(SVector{4,Float64}(t), PR))

"""
Finite-difference Jacobian of `ξ` at `t`, `(4,4)`, for cross-checking the
analytic log-Jacobian against something that doesn't share its derivation.
"""
function numeric_ξ_jacobian(t::NTuple{4,<:Real}; h::Real = 1.0e-6)
    J = zeros(Float64, 4, 4)
    for j in 1:4
        tp = collect(Float64, t); tp[j] += h
        tm = collect(Float64, t); tm[j] -= h
        J[:, j] = (collect(apply_Ξ(Tuple(tp))) .- collect(apply_Ξ(Tuple(tm)))) ./ (2h)
    end
    return J
end

const ξ_CASES = (
    (CRYSOL_SOLVENT_DENSITY, 1.05, -0.2, 0.0),
    (1.0, 1.0, 0.0, -3.0),
    (0.05, 0.001, -5.0, -11.0),
    (10.0, 1.99, -9.99, 2.7),
)
const θ_CASES = (
    (0.0, 0.0, -0.2, 0.1),
    (-3.5, 2.1, 5.0, -5.0),
    (10.0, -10.0, 0.0, 8.0),
    (-1.0e-3, 1.0e-3, 3.3, -3.3),
)

@testset "ParamTransform" begin

    @testset "Θ: matches the independent reference derivation" begin
        for ξ0 in ξ_CASES
            res, corr = apply_Θ(ξ0)
            res_ref, corr_ref = ref_Θ(ξ0)
            @test all(close_.(res, res_ref))
            @test close_(corr, corr_ref)
        end
    end

    @testset "Ξ: matches the independent reference derivation" begin
        for θ₀ in θ_CASES
            @test all(close_.(apply_Ξ(θ₀), ref_Ξ(θ₀)))
        end
    end

    @testset "Ξ(Θ(x)) == x for x in the valid ξ domain" begin
        for ξ0 in ξ_CASES
            res, _ = apply_Θ(ξ0)
            @test all(isapprox.(apply_Ξ(res), ξ0; rtol = 1e-12, atol = 1e-3 * DEFAULT_ATOL))
        end
    end

    @testset "Θ(Ξ(x)) == x for x in θ-space" begin
        for θ₀ in θ_CASES
            res, _ = apply_Θ(apply_Ξ(θ₀))
            @test all(isapprox.(res, θ₀; rtol = 1e-9, atol = DEFAULT_ATOL))
        end
    end

    @testset "δρ₁/δρ₂: the midpoint of [-10, 2] maps to t = 0 and back" begin
        mid = (LO + HI) / 2
        @test apply_Θ((0.5, mid, mid, 0.7))[1][2:3] == (0.0, 0.0)
        @test apply_Ξ((1.2, 0.0, 0.0, 0.3))[2:3] == (mid, mid)
    end

    @testset "log-Jacobian: Θ's corr == logjac(Θ(ξ)), and matches a finite-difference det" begin
        for θ₀ in ((0.1, -0.2, 0.3, -0.4), (2.0, -2.0, 0.0, 0.0), (-5.0, 5.0, 1.0, 3.0))
            ξ0 = apply_Ξ(θ₀)
            θ, corr = apply_Θ(ξ0)
            @test isapprox(corr, logjac(SVector{4}(θ...), PR); atol = DEFAULT_ATOL)
            @test isapprox(corr, log(abs(det(numeric_ξ_jacobian(θ₀)))); atol = 1.0e-6)
        end
    end

    @testset "logjac stays finite far out in the logit tail" begin
        for t in (-500.0, 500.0)
            @test isfinite(logjac(SVector(0.0, 0.0, 0.0, t), PR))
        end
    end

    @testset "Ξ: ρₑ > 0, δρ₁, δρ₂ ∈ [-10, 2] and δρ₃ ∈ [L₃, L₃ + W₃] for any finite θ" begin
        for θ₀ in ((0.0, 0.0, 0.0, 0.0), (700.0, -700.0, 700.0, 40.0),
                   (-700.0, 700.0, -700.0, -40.0), (37.0, -21.5, 3.0, 3.0))
            res = apply_Ξ(θ₀)
            @test res[1] > 0
            @test LO ≤ res[2] ≤ HI && LO ≤ res[3] ≤ HI
            @test L3 ≤ res[4] ≤ L3 + W3
            @test all(isfinite, res)
        end
    end

    @testset "Θ: out-of-domain inputs throw DomainError" begin
        @test_throws DomainError apply_Θ((-1.0, 1.0, 0.0, 0.0))
        @test_throws DomainError apply_Θ((1.0, LO - 0.5, 0.0, 0.0))      # δρ₁ < -10
        @test_throws DomainError apply_Θ((1.0, HI + 0.5, 0.0, 0.0))      # δρ₁ > 2
        @test_throws DomainError apply_Θ((1.0, 1.0, LO - 0.5, 0.0))      # δρ₂ < -10
        @test_throws DomainError apply_Θ((1.0, 1.0, HI + 0.5, 0.0))      # δρ₂ > 2
        @test_throws DomainError apply_Θ((1.0, 1.0, 0.0, L3 - 0.1))        # δρ₃ < L₃
        @test_throws DomainError apply_Θ((1.0, 1.0, 0.0, L3 + W3 + 0.1))  # δρ₃ > L₃ + W₃
    end

    @testset "Θ/Ξ are pure: inputs unchanged" begin
        x = SVector{4,Float64}(CRYSOL_SOLVENT_DENSITY, 1.05, -0.2, -1.0)
        x_before = Tuple(x)
        θ, _ = Θ(x, PR)
        @test Tuple(x) == x_before
        θ_before = Tuple(θ)
        ξ = Ξ(θ, PR)
        @test Tuple(θ) == θ_before
        @test all(isapprox.(Tuple(ξ), x_before; rtol = 1e-12))
    end

    @testset "Ξ and logjac are AD-differentiable" begin
        f(t) = sum(Ξ(SVector{4,eltype(t)}(t...), PR)) + logjac(SVector{4,eltype(t)}(t...), PR)
        t0 = [0.1, -0.2, 0.3, -0.4]
        g = ForwardDiff.gradient(f, t0)
        @test all(isfinite, g)
        h = 1.0e-6
        for i in 1:4
            tp = copy(t0); tp[i] += h
            tm = copy(t0); tm[i] -= h
            @test g[i] ≈ (f(tp) - f(tm)) / (2h) rtol = 1.0e-4
        end
    end

    @testset "Θ is AD-differentiable through its ξ argument" begin
        function f(x)
            θ, corr = Θ(SVector{4,eltype(x)}(x...), PR)
            return sum(θ) + corr
        end
        x0 = [CRYSOL_SOLVENT_DENSITY, 1.05, -0.2, -1.0]
        g = ForwardDiff.gradient(f, x0)
        @test all(isfinite, g)
        h = 1.0e-6
        for i in 1:4
            xp = copy(x0); xp[i] += h
            xm = copy(x0); xm[i] -= h
            @test g[i] ≈ (f(xp) - f(xm)) / (2h) rtol = 1.0e-4
        end
    end

    @testset "5-parameter (nucleotide) variant: round trip and log-Jacobian" begin
        ξ5 = SVector(CRYSOL_SOLVENT_DENSITY, 1.05, -0.2, -2.0, 0.4)
        θ5, corr5 = Θ(ξ5, PR)
        @test all(isapprox.(Ξ(θ5, PR), ξ5; rtol = 1e-12))
        @test isapprox(corr5, logjac(SVector(θ5[1], θ5[2], θ5[3], θ5[4]), PR) + θ5[5]; atol = 1e-3 * DEFAULT_ATOL)
    end

    @testset "priors -> θ/ξ: full-prior draws round-trip and never throw (250_000 draws)" begin
        Random.seed!(20_260_920)
        d_ρ, δρ₁_d, δρ₂_d, δρ₃_d = PR.ρₑPrior, PR.δρ₁Prior, PR.δρ₂Prior, PR.δρ₃Prior
        finite_ok = true
        roundtrip_ok = true
        jacobian_ok = true
        for _ in 1:250_000
            ξ0 = (rand(d_ρ), rand(δρ₁_d), rand(δρ₂_d), rand(δρ₃_d))
            res, corr = apply_Θ(ξ0)
            finite_ok &= isfinite(corr) && all(isfinite, res)
            roundtrip_ok &= all(isapprox.(apply_Ξ(res), ξ0; rtol = 1e-9, atol = 1e-3 * DEFAULT_ATOL))
            jacobian_ok &= isapprox(corr, logjac(SVector{4}(res...), PR); atol = DEFAULT_ATOL)
        end
        @test finite_ok
        @test roundtrip_ok
        @test jacobian_ok
    end
end
