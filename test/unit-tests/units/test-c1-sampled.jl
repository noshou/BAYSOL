# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests for c1 as a fifth sampled parameter (the fallback for a kinked c1 profile): the
# `Uniform` prior of c1 and its logit, the Jacobian and moments, ∂ℓ/∂c1, the dual-number
# likelihood, the per-draw fit at a sampled c1, `sampleC1` and the kink check `_c1Kinked`.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Inference: WLSData, ξ_priors, Θ, Ξ, θ_prior_moments, paramKeys, _lp,
    _ll, _llGradC1, _dllDc1, fixedC1Corrs, _C1Tables, _c1Kinked, _twoBranches, _c1Centre,
    _dLogDensT,
    _ξOfθ, _θOfξ, _ξ₀, ρₑ_prior, δρ_prior,
    EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_TOL, C1_KINK_DRAWS
using BAYSOL.Scattering: forwardCache, ForwardCache
using BAYSOL.MolecularStructure: MolecularStructure
using StaticArrays: SVector
using Distributions: Uniform, logpdf, mean
using LinearAlgebra: det
using BAYSOL.BulkElectronDensity: Solute, NonBiological
using BAYSOL.Inference: κ_δρ₁₂, κ_δρ₃
using ForwardDiff, Random
using Statistics: std

const C1_LO, C1_HI = EXCL_VOL_CORR_BOUNDS

function c1Mol()
    elms = repeat(["n", "c", "c", "o"], 4)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:15]
    return MolecularStructure.create("c1s", elms, crds)
end

const C1_Q = collect(range(0.02, 0.35; length = 12))
c1Fw() = forwardCache(c1Mol(), C1_Q, 3, 9000.0; chunk = UInt64(4))

const C1_ρ = ρₑ_prior(7.4, 0.05, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
const C1_PR = ξ_priors(C1_ρ, δρ_prior(κ_δρ₁₂, κ_δρ₃, mean(C1_ρ))...)
const C1_ξ = SVector(CRYSOL_SOLVENT_DENSITY, 1.5, 0.5, -1.0)

function c1Wls(fw, c1True)
    y = referenceIntensity(fw, 2.0, 0.0005, C1_ξ[1], (C1_ξ[2], C1_ξ[3], C1_ξ[4]), c1True)
    Random.seed!(0xC1_5EED)
    σ = fill(0.01 * maximum(abs.(y)), length(y))
    return WLSData(y .+ σ .* randn(length(y)), σ)
end

@testset "c1 sampled as a fifth parameter" begin
    @testset "the prior is a Uniform on the c1 bounds" begin
        @test C1_PR.c1Prior == Uniform(C1_LO, C1_HI)
        @test paramKeys(C1_PR, 5) == (paramKeys(C1_PR)..., "exclVolCorr")
        @test paramKeys(C1_PR, 4) == paramKeys(C1_PR)
        ξ = SVector(C1_ξ..., 1.1)
        @test _lp(ξ, C1_PR) ≈ _lp(C1_ξ, C1_PR) + logpdf(Uniform(C1_LO, C1_HI), 1.1)
    end

    @testset "logit transform: round trip, Jacobian, moments" begin
        for c1 in (0.81, 1.0, 1.05, 1.29)
            ξ = SVector(C1_ξ..., c1)
            θ, lj = Θ(ξ, C1_PR)
            @test θ[5] ≈ log((c1 - C1_LO) / (C1_HI - c1))
            @test all(isapprox.(Ξ(θ, C1_PR), ξ; rtol = 1.0e-10))
            @test lj ≈ BAYSOL.Inference.logjac(θ, C1_PR)
            J = ForwardDiff.jacobian(t -> Ξ(SVector{5}(t...), C1_PR), collect(θ))
            @test lj ≈ log(abs(det(J))) atol = 1.0e-8
        end
        # the standard logistic: mean 0, standard deviation π/√3
        μ, σ = θ_prior_moments(C1_PR, Val(5))
        @test μ[5] == 0.0
        @test σ[5] ≈ π / sqrt(3)
        @test (μ[1:4], σ[1:4]) == θ_prior_moments(C1_PR)
        rng = Xoshiro(1)
        t = [Θ(SVector(C1_ξ..., rand(rng, C1_PR.c1Prior)), C1_PR)[1][5] for _ in 1:20000]
        @test mean(t) ≈ 0.0 atol = 0.05
        @test std(t) ≈ π / sqrt(3) atol = 0.05
        # a start has its four coordinates unchanged
        @test _ξ₀(C1_PR, Val(5), Xoshiro(3))[1:4] == _ξ₀(C1_PR, Xoshiro(3))
        @test C1_LO ≤ _ξ₀(C1_PR, Val(5), Xoshiro(3))[5] ≤ C1_HI
    end

    @testset "∂ℓ/∂c1 and the five-parameter likelihood" begin
        fw = c1Fw()
        wls = c1Wls(fw, 1.12)
        tab = _C1Tables(fw)
        ξ = SVector(C1_ξ..., 1.07)
        ll, g = _llGradC1(wls, ξ, fw, tab, EXCL_VOL_CORR_TOL)
        @test ll ≈ _ll(wls, ξ, fw; tab)
        fd(f, x; h = 1.0e-5) = (f(x + h) - f(x - h)) / (2h)
        llAt(c) = _llGradC1(wls, SVector(C1_ξ..., c), fw, tab, 1.0e-10)[1]
        @test g[5] ≈ fd(llAt, 1.07) rtol = 1.0e-5
        @test _dllDc1(wls, SVector(C1_ξ...), fw, tab, 1.07) ≈ g[5]
        @test g[2] ≈
              fd(
            x -> _llGradC1(
                wls,
                SVector(C1_ξ[1], x, C1_ξ[3], C1_ξ[4], 1.07),
                fw,
                tab,
                1.0e-10,
            )[1],
            C1_ξ[2]) rtol = 1.0e-3
        # the Dual method chains the gradient: ForwardDiff reproduces it
        @test ForwardDiff.gradient(x -> _ll(wls, SVector{5}(x...), fw; tab), collect(ξ)) ≈ g
        # the draw's fit at the sampled c1
        ŷ, fit = fixedC1Corrs(wls, SVector(C1_ξ...), fw, tab, 1.07)
        @test length(ŷ) == length(C1_Q)
        @test ll ≈ -fit.chi2 / 2 - wls.sumLogVar / 2 - length(C1_Q) / 2 * log(2π) rtol =
            1.0e-8
    end

    @testset "the kink check: clean profile, no draws, one draw" begin
        fw = c1Fw()
        wls = c1Wls(fw, 1.12)
        tab = _C1Tables(fw)
        @test !_c1Kinked(fw, wls, tab, SVector{4,Float64}[])
        @test !_c1Kinked(fw, wls, tab, [C1_ξ])              # a single draw is enough
        draws = [SVector{4}(C1_ξ .* (1 .+ 0.01 .* randn(Xoshiro(i), 4))) for i in 1:5]
        @test !_c1Kinked(fw, wls, tab, draws)
        many = [
            SVector{4}(C1_ξ .* (1 .+ 0.01 .* randn(Xoshiro(i), 4))) for
            i in 1:(2*C1_KINK_DRAWS)
        ]
        @test !_c1Kinked(fw, wls, tab, many)                # subsampled to C1_KINK_DRAWS
    end

    @testset "the kink gate: only a branch the sampler would visit" begin
        bump(x, c, h) = h * exp(-((x - c) / 6)^2)
        xs = 1:100
        two(h2) = [bump(x, 25, 10.0) + bump(x, 75, h2) for x in xs]
        @test _twoBranches(two(10.0))        # equal branches
        @test _twoBranches(two(8.0))         # 2 nats below the top
        @test !_twoBranches(two(5.0))        # 5 nats below: a low-mass mode
        @test !_twoBranches([bump(x, 50, 10.0) for x in xs])   # a single peak
        @test !_twoBranches(two(1.0))        # second bump below the prominence
    end

    @testset "the c1 centre: root of d/dt, gradient, round trip" begin
        fw = c1Fw()
        wls = c1Wls(fw, 1.12)
        tab = _C1Tables(fw)
        W = C1_HI - C1_LO
        t̂ = _c1Centre(wls, C1_ξ, fw, tab, C1_LO, W)
        @test abs(_dLogDensT(wls, C1_ξ, fw, tab, t̂, C1_LO, W)) < 1.0e-6
        # the centre is the maximum of likelihood x logistic density in t
        dens(t) = begin
            σ = 1 / (1 + exp(-t))
            ll = _ll(wls, SVector(C1_ξ..., C1_LO + W * σ), fw; tab)
            ll + log(σ * (1 - σ))
        end
        @test dens(t̂) ≥ dens(t̂ + 0.05) && dens(t̂) ≥ dens(t̂ - 0.05)
        # implicit-function gradient of t̂ against central differences
        g = ForwardDiff.gradient(x -> _c1Centre(wls, SVector{4}(x...), fw, tab, C1_LO, W),
            collect(C1_ξ))
        fd = [
            begin
                h = 1.0e-4 * max(1.0, abs(C1_ξ[j]))
                e = SVector{4}(ntuple(k -> k == j ? h : 0.0, 4))
                (
                    _c1Centre(wls, C1_ξ + e, fw, tab, C1_LO, W) -
                    _c1Centre(wls, C1_ξ - e, fw, tab, C1_LO, W)
                ) / 2h
            end for j in 1:4
        ]
        @test g ≈ fd rtol = 1.0e-3 atol = 1.0e-4
        # θ <-> ξ round trip carries the real c1
        ξ5 = SVector(C1_ξ..., 1.1)
        θ = _θOfξ(ξ5, C1_PR, wls, fw, tab)
        @test θ[5] ≈ log((1.1 - C1_LO) / (C1_HI - 1.1)) - t̂ atol = 1.0e-6
        ξb, t = _ξOfθ(θ, C1_PR, wls, fw, tab)
        @test ξb ≈ ξ5 rtol = 1.0e-8
        @test t ≈ log((1.1 - C1_LO) / (C1_HI - 1.1)) atol = 1.0e-8
    end
end
