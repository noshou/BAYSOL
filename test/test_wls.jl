# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Fitting/WLS.jl: the 2-parameter weighted least squares fit
# of I_calc(q) = m*y_model(q) + c, plus the profile/marginal negative
# log-likelihoods built on top of it.
#
# `ref_wls` below is an independent re-derivation via explicit normal-equation
# matrix algebra (LinearAlgebra), not a copy of `wls_fit`'s O(n) accumulator
# loop, so agreement between the two is a genuine cross-check of the closed
# forms in WLS.jl rather than a tautology.

using LinearAlgebra
using Random
using ScatterNet.Fitting: WLSError, WLSFit, wls_fit, wls_predict, wls_prof_nll, wls_marg_nll

"""
Reference (m, c, var_m, var_c, cov_mc, chi2, det_XtWX) via explicit normal
equations `(XᵀWX) β = XᵀWy`, independent of `wls_fit`'s accumulator formulas.
"""
function ref_wls(y_model::AbstractVector, I_obs::AbstractVector, σ::AbstractVector)
    X = hcat(collect(y_model), ones(length(y_model)))
    W = Diagonal(1.0 ./ σ .^ 2)
    XtWX = X' * W * X
    β = XtWX \ (X' * W * I_obs)
    m, c = β
    cov = inv(XtWX)
    resid = I_obs .- X * β
    chi2 = resid' * W * resid
    return m, c, cov[1, 1], cov[2, 2], cov[1, 2], chi2, det(XtWX)
end

@testset "WLS" begin

    #------------------------------------------------------------------
    #                 wls_fit -- exact (noise-free) recovery
    #------------------------------------------------------------------

    @testset "wls_fit: exact recovery of (m, c) from a noise-free linear curve" begin
        y_model = collect(range(0.1, 5.0; length = 20))
        m_true, c_true = 3.7, -1.2
        I_obs = m_true .* y_model .+ c_true
        σ = fill(0.5, length(y_model))

        f = wls_fit(y_model, I_obs, σ)
        @test check_float(f.m, m_true; atol = 1e-9)
        @test check_float(f.c, c_true; atol = 1e-9)
        @test check_float(f.chi2, 0.0; atol = 1e-9)
        @test f.dof == length(y_model) - 2
    end

    @testset "wls_fit: exact recovery holds under heteroscedastic weights too" begin
        y_model = collect(range(-2.0, 2.0; length = 15))
        m_true, c_true = -0.8, 4.4
        I_obs = m_true .* y_model .+ c_true
        rng = MersenneTwister(1)
        σ = 0.1 .+ rand(rng, length(y_model))   # varying per-point σ

        f = wls_fit(y_model, I_obs, σ)
        @test check_float(f.m, m_true; atol = 1e-8)
        @test check_float(f.c, c_true; atol = 1e-8)
        @test check_float(f.chi2, 0.0; atol = 1e-8)
    end

    #------------------------------------------------------------------
    #                 wls_fit -- agreement with the matrix-algebra oracle
    #------------------------------------------------------------------

    @testset "wls_fit: matches the normal-equations reference on noisy data" begin
        rng = MersenneTwister(42)
        for trial in 1:10
            n = rand(rng, 3:40)
            y_model = randn(rng, n)
            σ = 0.2 .+ rand(rng, n)
            m_true, c_true = randn(rng), randn(rng)
            I_obs = m_true .* y_model .+ c_true .+ σ .* randn(rng, n)

            f = wls_fit(y_model, I_obs, σ)
            m_r, c_r, vm_r, vc_r, cov_r, chi2_r, det_r = ref_wls(y_model, I_obs, σ)

            @test check_float(f.m, m_r; atol = 1e-6)
            @test check_float(f.c, c_r; atol = 1e-6)
            @test check_float(f.var_m, vm_r; atol = 1e-6)
            @test check_float(f.var_c, vc_r; atol = 1e-6)
            @test check_float(f.cov_mc, cov_r; atol = 1e-6)
            @test check_float(f.chi2, chi2_r; atol = 1e-6)
            @test check_float(f.det_XtWX, det_r; atol = 1e-3)
            @test f.dof == n - 2
        end
    end

    @testset "wls_fit: sum_log_var == Σ log σᵢ²" begin
        y_model = collect(1.0:10.0)
        I_obs = 2.0 .* y_model .+ 1.0
        σ = collect(range(0.3, 1.7; length = 10))
        f = wls_fit(y_model, I_obs, σ)
        @test check_float(f.sum_log_var, sum(2 .* log.(σ)); atol = 1e-9)
    end

    #------------------------------------------------------------------
    #                 wls_fit -- error handling
    #------------------------------------------------------------------

    @testset "wls_fit: length mismatches throw WLSError" begin
        @test_throws WLSError wls_fit([1.0, 2.0, 3.0], [1.0, 2.0], [1.0, 1.0, 1.0])
        @test_throws WLSError wls_fit([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], [1.0, 1.0])
    end

    @testset "wls_fit: n < 3 throws WLSError" begin
        @test_throws WLSError wls_fit(Float64[], Float64[], Float64[])
        @test_throws WLSError wls_fit([1.0], [1.0], [1.0])
        @test_throws WLSError wls_fit([1.0, 2.0], [1.0, 2.0], [1.0, 1.0])
    end

    @testset "wls_fit: n == 3 is the smallest accepted size" begin
        f = wls_fit([1.0, 2.0, 3.0], [2.0, 4.0, 6.0], [1.0, 1.0, 1.0])
        @test f isa WLSFit
        @test f.dof == 1
    end

    @testset "wls_fit: non-positive σ throws WLSError" begin
        @test_throws WLSError wls_fit([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], [1.0, 0.0, 1.0])
        @test_throws WLSError wls_fit([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], [1.0, -1.0, 1.0])
    end

    @testset "wls_fit: a flat (constant) y_model is degenerate and throws WLSError" begin
        @test_throws WLSError wls_fit(fill(2.0, 5), [1.0, 2.0, 3.0, 4.0, 5.0], fill(1.0, 5))
    end

    #------------------------------------------------------------------
    #                 wls_predict
    #------------------------------------------------------------------

    @testset "wls_predict: reproduces I_obs exactly on a noise-free fit" begin
        y_model = collect(range(0.0, 10.0; length = 8))
        m_true, c_true = 1.5, 0.3
        I_obs = m_true .* y_model .+ c_true
        f = wls_fit(y_model, I_obs, fill(1.0, length(y_model)))
        @test all(check_float.(wls_predict(f, y_model), I_obs; atol = 1e-9))
    end

    @testset "wls_predict: matches the m*y + c formula on a fresh curve" begin
        y_model = collect(range(0.0, 10.0; length = 8))
        I_obs = 2.0 .* y_model .+ 5.0 .+ [0.1, -0.2, 0.05, 0.0, -0.1, 0.2, -0.05, 0.1]
        f = wls_fit(y_model, I_obs, fill(1.0, length(y_model)))
        y_fresh = [0.0, 3.3, 7.7]
        @test wls_predict(f, y_fresh) ≈ f.m .* y_fresh .+ f.c
    end

    #------------------------------------------------------------------
    #                 wls_prof_nll / wls_marg_nll
    #------------------------------------------------------------------

    @testset "wls_prof_nll: matches its closed form directly from WLSFit fields" begin
        y_model = collect(range(0.1, 5.0; length = 12))
        I_obs = 1.3 .* y_model .+ 0.4 .+ [0.1, -0.1, 0.2, -0.2, 0.05, -0.05, 0.1, -0.1, 0.0, 0.15, -0.15, 0.05]
        σ = fill(0.3, length(y_model))
        f = wls_fit(y_model, I_obs, σ)

        expected = (f.chi2 + f.sum_log_var) / 2 + (f.dof + 2) * log(2π) / 2
        @test check_float(wls_prof_nll(f), expected; atol = 1e-9)
    end

    @testset "wls_marg_nll: matches its closed form directly from WLSFit fields" begin
        y_model = collect(range(0.1, 5.0; length = 12))
        I_obs = 1.3 .* y_model .+ 0.4 .+ [0.1, -0.1, 0.2, -0.2, 0.05, -0.05, 0.1, -0.1, 0.0, 0.15, -0.15, 0.05]
        σ = fill(0.3, length(y_model))
        f = wls_fit(y_model, I_obs, σ)

        expected = wls_prof_nll(f) + log(f.det_XtWX) / 2 - log(2π)
        @test check_float(wls_marg_nll(f), expected; atol = 1e-9)
    end

    @testset "wls_prof_nll: a perfect (chi2 == 0) fit is just the data-normalisation constant" begin
        y_model = collect(range(0.0, 4.0; length = 6))
        I_obs = 2.0 .* y_model .- 1.0
        σ = fill(1.0, length(y_model))
        f = wls_fit(y_model, I_obs, σ)
        @test check_float(f.chi2, 0.0; atol = 1e-9)
        expected = f.sum_log_var / 2 + (f.dof + 2) * log(2π) / 2
        @test check_float(wls_prof_nll(f), expected; atol = 1e-9)
    end

    #------------------------------------------------------------------
    #                 AD-differentiability (stage-1 HMC needs this)
    #------------------------------------------------------------------

    @testset "wls_fit -> wls_marg_nll is AD-differentiable through y_model" begin
        # y_model stands in for a forward-model curve parameterised by θ, as
        # it will be when this feeds stage-1 HMC; the gradient must survive
        # with no Float64 cast anywhere in wls_fit/wls_prof_nll/wls_marg_nll.
        q = collect(range(0.1, 2.0; length = 10))
        I_obs = 3.0 .* exp.(-q) .+ 0.5 .+ [0.02, -0.01, 0.03, 0.0, -0.02, 0.01, -0.03, 0.02, 0.0, -0.01]
        σ = fill(0.2, length(q))

        model(θ) = θ[1] .* exp.(-θ[2] .* q)   # θ = (amplitude, decay rate)
        loss(θ) = wls_marg_nll(wls_fit(model(θ), I_obs, σ))

        θ0 = [2.5, 1.1]
        g = ForwardDiff.gradient(loss, θ0)
        @test all(isfinite, g)

        h = 1e-6
        for i in 1:2
            θp = copy(θ0); θp[i] += h
            θm = copy(θ0); θm[i] -= h
            @test g[i] ≈ (loss(θp) - loss(θm)) / (2h) rtol = 1e-4
        end
    end

end
