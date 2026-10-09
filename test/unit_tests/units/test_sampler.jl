# SPDX-License-Identifier: LGPL-2.1-or-later

# End-to-end correctness tests for src/Inference/Sampler.jl: the Bayesian
# fitting pipeline (priors -> initial draw -> θ-space log-posterior -> NUTS
# via AdvancedHMC.jl). These tests check that the wiring is *correct* --
# independent re-derivations of every formula, purity (no hidden mutation)
# of _logπ, AD-differentiability, physical-domain invariants, and internal
# self-consistency between what `infer` returns and what AdvancedHMC.jl
# itself reports. They deliberately do NOT check posterior "goodness"
# (recovery accuracy, convergence diagnostics, effective sample size).

include(joinpath(@__DIR__, "..", "testsetup.jl"))

const FIT = BAYSOL.Inference

using BAYSOL.Inference: Solute, NonBiological, WLSData, wls_fit, wls_prof_ll, wls_marg_ll,
    profiled_corrs, Θ, Ξ
using BAYSOL.Inference: BOUNDS_δρ₁₂, κ_δρ₁₂, κ_δρ₃
using BAYSOL.Scattering: forward_cache, ForwardCache
using BAYSOL.MolecularStructure: MolecularStructure
using Distributions: logpdf, mean, std, params, Beta
using StaticArrays: SVector, @SMatrix
using ForwardDiff
using Random

include(joinpath(@__DIR__, "..", "..", "utils", "floatcompare.jl"))   # close_

# ---------------------------------------------------------------------------
#                 fixtures: a non-trivial structure + synthetic data
# ---------------------------------------------------------------------------

# 16 atoms on a helix (mixed n/c/o, non-planar, non-degenerate).
function smpl_mol()
    elms = repeat(["n", "c", "c", "o"], 4)
    n = length(elms)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:(n - 1)]
    return MolecularStructure.create("smpl", elms, crds)
end

const smpl_q     = collect(range(0.0, 0.35; length = 6))
const smpl_E     = 9000.0
const smpl_lmax  = 3
const smpl_chunk = UInt64(4)

smpl_fw() = forward_cache(smpl_mol(), smpl_q, smpl_lmax, smpl_E; chunk = smpl_chunk)

# Buffer only: the measured macromolecule is never a solute (see Inference.Solute).
smpl_solutes() = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
const smpl_pH    = 7.4
const smpl_σ_pH  = 0.05

smpl_priors() = FIT._calc_ξ_priors(smpl_pH, smpl_σ_pH, smpl_solutes())

# Ground truth used to generate synthetic "experimental" data:
# ξ = (ρₑ, δρ₁, δρ₂, δρ₃).
const ξ_TRUE = (CRYSOL_SOLVENT_DENSITY, 1.05, -0.05, -1.0)
const M_TRUE, C_TRUE = 1.7, 0.3

"""
Synthetic `(I_exp, σ_exp)` from `fw` at `ξ_TRUE`/`M_TRUE`/`C_TRUE`, with small seeded Gaussian noise.
"""
function synth_data(fw::ForwardCache)
    y = reference_intensity(fw, 1.0, 0.0, ξ_TRUE[1], ξ_TRUE[2:4])
    I_true = M_TRUE .* y .+ C_TRUE
    σ_exp = max.(abs.(I_true) .* 0.01, 1.0e-6)
    Random.seed!(0x5CA77e12)
    I_exp = I_true .+ randn(length(I_true)) .* σ_exp
    return I_exp, σ_exp
end

# ---------------------------------------------------------------------------
#                 independent references (no calls into Sampler.jl)
# ---------------------------------------------------------------------------

"Log prior of ξ = (ρₑ, δρ₁, δρ₂, δρ₃), written out by hand."
ref_lp(ξ, pr) =
    logpdf(pr.ρₑPrior, ξ[1]) + logpdf(pr.δρ₁Prior, ξ[2]) + logpdf(pr.δρ₂Prior, ξ[3]) +
    logpdf(pr.δρ₃Prior, ξ[4])

"""
Log-likelihood at ξ with c1 profiled: the c1 is taken from `profiled_corrs`,
everything else (contrasts, WLS, likelihood) is recomputed directly.
"""
function ref_ll(ξ, wls, fw, l::FIT.LIKELIHOOD)
    _, _, c1 = profiled_corrs(wls, SVector{4,Float64}(ξ), fw)
    ŷ = reference_intensity(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4]), c1)
    fit = wls_fit(ŷ, wls)
    return l isa FIT.PROFILE ? wls_prof_ll(fit) : wls_marg_ll(fit)
end

"""
Independent re-derivation of `_logπ`: decode θ by hand, add the log-Jacobian
a + Σₖ [ln Wₖ + ln uₖ + ln(1 - uₖ)], uₖ = σ(tₖ), W = (12, 12, W₃).
"""
function ref_logπ(θ::NTuple{4,<:Real}, pr, wls, fw, l::FIT.LIKELIHOOD)
    lo, hi = BOUNDS_δρ₁₂
    u = map(t -> 1 / (1 + exp(-t)), θ[2:4])
    L₃, W₃ = pr.δρ₃Prior.μ, pr.δρ₃Prior.σ
    W = (hi - lo, hi - lo, W₃)
    ξ = (exp(θ[1]), lo + W[1] * u[1], lo + W[2] * u[2], L₃ + W₃ * u[3])
    corr = θ[1] + sum(log(W[k]) + log(u[k]) + log(1 - u[k]) for k in 1:3)
    return ref_lp(ξ, pr) + ref_ll(ξ, wls, fw, l) + corr
end

θ_of(ξt, pr) = Tuple(Θ(SVector{4,Float64}(ξt), pr)[1])

@testset "Sampler" begin

    @testset "_calc_ξ_priors: exactly composes ρₑ_prior/δρ_prior" begin
        pr = smpl_priors()
        @test pr isa FIT.ξ_priors
        ref_ρ = FIT.ρₑ_prior(smpl_pH, smpl_σ_pH, smpl_solutes())
        ref_δρ₁, ref_δρ₂, ref_δρ₃ = FIT.δρ_prior(κ_δρ₁₂, κ_δρ₃, mean(ref_ρ))
        @test pr.ρₑPrior  == ref_ρ
        @test pr.δρ₁Prior == ref_δρ₁
        @test pr.δρ₂Prior == ref_δρ₂
        @test pr.δρ₃Prior == ref_δρ₃
    end

    @testset "_calc_ξ_priors: κ keywords reach δρ_prior" begin
        pr = FIT._calc_ξ_priors(smpl_pH, smpl_σ_pH, smpl_solutes(); κ_δρ₁₂ = 3.0, κ_δρ₃ = 7.0)
        @test sum(params(pr.δρ₁Prior.ρ)) - 2 ≈ 3.0
        @test sum(params(pr.δρ₃Prior.ρ)) - 2 ≈ 7.0
        @test_throws DomainError FIT._calc_ξ_priors(smpl_pH, smpl_σ_pH, smpl_solutes(); κ_δρ₁₂ = 0.0)
    end

    @testset "_calc_ξ_priors: pure water is allowed; bad σ_pH still throws" begin
        @test FIT._calc_ξ_priors(smpl_pH, smpl_σ_pH, Solute[]) isa FIT.ξ_priors
        @test_throws DomainError FIT._calc_ξ_priors(smpl_pH, -0.1, smpl_solutes())
    end

    @testset "_ξ₀: draws lie in every prior's support" begin
        pr = smpl_priors()
        Random.seed!(20_260_920)
        for _ in 1:200
            ξ0 = FIT._ξ₀(pr)
            @test ξ0 isa SVector{4,Float64}
            @test ξ0[1] > 0
            @test BOUNDS_δρ₁₂[1] < ξ0[2] < BOUNDS_δρ₁₂[2] && BOUNDS_δρ₁₂[1] < ξ0[3] < BOUNDS_δρ₁₂[2]
            @test pr.δρ₃Prior.μ < ξ0[4] < pr.δρ₃Prior.μ + pr.δρ₃Prior.σ
            @test all(isfinite, ξ0)
        end
    end

    @testset "_ξ₀: empirical means match each prior's analytic mean" begin
        pr = smpl_priors()
        Random.seed!(20_260_921)
        n = 60_000
        draws = [FIT._ξ₀(pr) for _ in 1:n]
        for (i, μ, σ) in ((1, mean(pr.ρₑPrior),  std(pr.ρₑPrior)),
                          (2, mean(pr.δρ₁Prior), std(pr.δρ₁Prior)),
                          (3, mean(pr.δρ₂Prior), std(pr.δρ₂Prior)),
                          (4, mean(pr.δρ₃Prior), std(pr.δρ₃Prior)))
            xs = getindex.(draws, i)
            @test close_(mean(xs), μ; atol = max(6σ / sqrt(n), 1.0e-9))
        end
    end

    @testset "θ_prior_moments: δρ₁, δρ₂, δρ₃ entries match the Monte Carlo moments of logit(u)" begin
        pr = smpl_priors()
        μ, σ = FIT.θ_prior_moments(pr)
        Random.seed!(20_260_922)
        for (i, b) in ((2, pr.δρ₁Prior.ρ), (3, pr.δρ₂Prior.ρ), (4, pr.δρ₃Prior.ρ))
            u = rand(b, 400_000)
            t = log.(u) .- log1p.(-u)
            @test isapprox(μ[i], mean(t); atol = 0.01)
            @test isapprox(σ[i], std(t); rtol = 0.01)
        end
        @test μ[1] == pr.ρₑPrior.μ && σ[1] == pr.ρₑPrior.σ
    end

    @testset "_θ_of_w inverts _standardize and the whitening" begin
        pr = smpl_priors()
        μ, σ = FIT.θ_prior_moments(pr)
        θ = SVector(-1.1, 0.2, 0.9, 0.4)
        ẑ = SVector(0.3, -0.2, 0.1, 0.5)
        S = @SMatrix [2.0 0.1 0.0 0.0; 0.0 0.5 0.2 0.0; 0.0 0.0 1.5 0.3; 0.1 0.0 0.0 0.7]
        sp = FIT._SamplingSpace(μ, σ, ẑ, S, 1, 1, true, 0)
        w = S \ (FIT._standardize(θ, pr) - ẑ)
        @test all(isapprox.(FIT._θ_of_w(w, sp), θ; rtol = 1e-12))
    end

    @testset "_ll: PROFILE/MARGINAL match the independent reference" begin
        fw = smpl_fw()
        wls = WLSData(synth_data(fw)...)
        for ξt in (ξ_TRUE, (0.30, 0.95, 0.10, -6.0), (0.40, 1.15, -0.20, 2.5))
            ξ = SVector{4,Float64}(ξt)
            for l in (FIT.PROFILE(), FIT.MARGINAL())
                @test close_(FIT._ll(wls, ξ, fw, l), ref_ll(ξt, wls, fw, l))
            end
            @test !close_(FIT._ll(wls, ξ, fw, FIT.PROFILE()),
                          FIT._ll(wls, ξ, fw, FIT.MARGINAL()); atol = 1e3 * DEFAULT_ATOL)
        end
    end

    @testset "_ll: the forward model takes (δρ₁, δρ₂, δρ₃) straight from ξ[2:4]" begin
        fw = smpl_fw()
        wls = WLSData(synth_data(fw)...)
        ξ = SVector(0.33, 1.0, 1.0, -4.0)
        ŷ, _, c1 = profiled_corrs(wls, ξ, fw)
        ŷ_ref = reference_intensity(fw, 1.0, 0.0, 0.33, (1.0, 1.0, -4.0), c1)
        @test all(close_.(ŷ, ŷ_ref))
    end

    @testset "_lp: matches the hand-written log prior" begin
        pr = smpl_priors()
        for ξt in (ξ_TRUE, (0.30, 0.95, 0.10, -8.0), (1.0e-3, -9.9, 1.9, 1.0))
            @test close_(FIT._lp(SVector{4,Float64}(ξt), pr), ref_lp(ξt, pr))
        end
    end

    @testset "_logπ: pure, and matches the independent reference for both LIKELIHOODs" begin
        pr = smpl_priors()
        fw = smpl_fw()
        wls = WLSData(synth_data(fw)...)
        for ξt in (ξ_TRUE, (0.30, 0.95, 0.10, -6.0), (0.40, 1.15, -0.20, 2.5))
            θt = θ_of(ξt, pr)
            θ = SVector{4,Float64}(θt)
            θ_before = Tuple(θ)
            for l in (FIT.PROFILE(), FIT.MARGINAL())
                val = FIT._logπ(θ, pr, wls, fw, l)
                @test Tuple(θ) == θ_before
                @test close_(val, ref_logπ(θt, pr, wls, fw, l); atol = 1e1 * DEFAULT_ATOL)
            end
        end
    end

    @testset "_logπ: AD gradient matches central differences (c1 re-profiled each time)" begin
        pr = smpl_priors()
        fw = smpl_fw()
        wls = WLSData(synth_data(fw)...)
        θ₀ = collect(θ_of(ξ_TRUE, pr))
        f(x) = FIT._logπ(SVector{4,eltype(x)}(x...), pr, wls, fw, FIT.PROFILE())
        g = ForwardDiff.gradient(f, θ₀)
        @test all(isfinite, g)
        h = 1.0e-5
        for i in 1:4
            xp = copy(θ₀); xp[i] += h
            xm = copy(θ₀); xm[i] -= h
            @test g[i] ≈ (f(xp) - f(xm)) / (2h) rtol = 1.0e-3 atol = 1.0e-6
        end
    end

    @testset "prior_z_scores: zero at the θ-space prior mean" begin
        pr = smpl_priors()
        μ, _ = FIT.θ_prior_moments(pr)
        @test all(isapprox.(FIT.prior_z_scores(Ξ(μ, pr), pr), 0.0; atol = DEFAULT_ATOL))
    end

    @testset "seed_sampler: fields are internally consistent" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        seed = FIT.seed_sampler(fw, I_exp, σ_exp, smpl_pH, smpl_σ_pH, smpl_solutes())
        @test seed isa FIT.Seed
        @test seed.fw === fw
        @test seed.wls.I_obs == I_exp
        ξ₀ = Ξ(seed.θ₀, seed.pr)
        @test ξ₀[1] > 0 && seed.pr.δρ₃Prior.μ < ξ₀[4] < seed.pr.δρ₃Prior.μ + seed.pr.δρ₃Prior.σ
        @test_throws DomainError FIT.seed_sampler(fw, I_exp, σ_exp, smpl_pH, -0.1, smpl_solutes())
    end

    @testset "MAP search: the f-stop does not stop short of the optimum" begin
        fw = smpl_fw()
        seed = FIT.seed_sampler(fw, synth_data(fw)..., smpl_pH, smpl_σ_pH, smpl_solutes())
        Random.seed!(11)
        sp = FIT._sampling_space(seed, FIT.PROFILE())
        f(z) = FIT._neglogπ(SVector{4}(z...), sp.μ, sp.σ, seed, FIT.PROFILE(), FIT.EXCL_VOL_CORR_TOL)
        g!(G, z) = (G .= ForwardDiff.gradient(f, z); G)
        # polish the reported mode with a gradient-only search 1000× tighter and 10× longer
        res = FIT.optimize(FIT.OnceDifferentiable(f, g!, Vector(sp.ẑ)), Vector(sp.ẑ), FIT.LBFGS(),
                           FIT.Options(g_abstol = 1e-9, iterations = 5000))
        @test f(sp.ẑ) - FIT.Optim.minimum(res) < 1e-4          # nats left on the table by the f-stop
        @test FIT.MAP_F_ABSTOL == 1e-6 && FIT.MAP_F_SUCCESSIVE == 3
        # and it costs fewer evaluations than the gradient test alone, for the same optimum
        Random.seed!(11)
        sp_g = FIT._sampling_space(seed, FIT.PROFILE(); f_abstol = 0.0, successive_f_tol = 1)
        @test sp.n_evals < sp_g.n_evals
        @test abs(f(sp.ẑ) - f(sp_g.ẑ)) < 1e-4
    end

    @testset "run: δ must be a percentage strictly inside (0, 100)" begin
        fw = smpl_fw()
        seed = FIT.seed_sampler(fw, synth_data(fw)..., smpl_pH, smpl_σ_pH, smpl_solutes())
        for δ in (0, 100, -10, 150)
            @test_throws DomainError FIT.infer(seed, 5, 2; δ = δ)
        end
    end

    function check_physical_domain(samples, pr)
        for ξ in samples
            @test length(ξ) == 4
            @test all(isfinite, ξ)
            @test ξ[1] > 0
            @test BOUNDS_δρ₁₂[1] ≤ ξ[2] ≤ BOUNDS_δρ₁₂[2] && BOUNDS_δρ₁₂[1] ≤ ξ[3] ≤ BOUNDS_δρ₁₂[2]
            @test pr.δρ₃Prior.μ ≤ ξ[4] ≤ pr.δρ₃Prior.μ + pr.δρ₃Prior.σ
        end
    end

    """
    Re-evaluating `_logπ` at Θ(sample) must land on the log_density
    AdvancedHMC.jl reported for that iteration.
    """
    function check_log_density_self_consistency(samples, stats, seed, l)
        for i in eachindex(samples)
            θ_check, _ = Θ(samples[i], seed.pr)
            recomputed = FIT._logπ(θ_check, seed.pr, seed.wls, seed.fw, l)
            # Θ(Ξ(θ)) differs from θ by rounding, and the profiled c1 is located by a value-only minimizer, which is only as
            # accurate as √eps relative to the curvature (up to ~1e-6 in c1): the log density moves by its second-order effect
            @test close_(recomputed, stats[i].log_density; atol = 1e5 * DEFAULT_ATOL)
        end
    end

    for (name, l, rng) in (("PROFILE", FIT.PROFILE(), 1), ("MARGINAL", FIT.MARGINAL(), 2))
        @testset "run: $name -- output shapes, physical domain, self-consistency" begin
            fw = smpl_fw()
            seed = FIT.seed_sampler(fw, synth_data(fw)..., smpl_pH, smpl_σ_pH, smpl_solutes())
            Random.seed!(rng)
            n_samples, n_adapt = 60, 30
            fit = FIT.infer(seed, n_samples, n_adapt; l = l)
            @test length(fit.samples) == n_samples
            @test length(fit.stats) == n_samples
            @test length(fit.c1) == n_samples
            check_physical_domain(fit.samples, seed.pr)
            check_log_density_self_consistency(fit.samples, fit.stats, seed, l)
        end
    end

    @testset "run: deterministic under a fixed global RNG seed" begin
        fw = smpl_fw()
        seed = FIT.seed_sampler(fw, synth_data(fw)..., smpl_pH, smpl_σ_pH, smpl_solutes())
        Random.seed!(42)
        fit1 = FIT.infer(seed, 20, 10; l = FIT.PROFILE())
        Random.seed!(42)
        fit2 = FIT.infer(seed, 20, 10; l = FIT.PROFILE())
        for i in eachindex(fit1.samples)
            @test all(fit1.samples[i] .== fit2.samples[i])
            @test fit1.stats[i].log_density == fit2.stats[i].log_density
        end
    end
end
