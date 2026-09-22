# SPDX-License-Identifier: LGPL-2.1-or-later

# End-to-end correctness tests for src/Fitting/Sampler.jl: the stage-1
# Bayesian-fitting pipeline (priors -> initial draw -> θ-space log-posterior
# -> NUTS via AdvancedHMC.jl). These tests check that the wiring is
# *correct* -- independent re-derivations of every formula, purity (no
# hidden mutation) of Θ/Ξ/_logπ, AD-differentiability, physical-domain
# invariants, and internal self-consistency between what `run_fitting` returns and
# what AdvancedHMC.jl itself reports. They deliberately do NOT check
# posterior "goodness" (recovery accuracy, convergence diagnostics, effective
# sample size) -- that is a separate concern for once this is run against
# real data.

include(joinpath(@__DIR__, "testsetup.jl"))

const FIT = BayeSol.Fitting

using BayeSol.Fitting: Solute, Protein, NonBiological, WLSFit, wls_fit,
    wls_prof_ll, wls_marg_ll, Θ, Ξ
using BayeSol.Scattering: forward, forward_cache, ForwardCache
using BayeSol.MolecularStructure: MolecularStructure
using Distributions: logpdf, mean, std, LogNormal, Normal
using StaticArrays: SVector
using ForwardDiff
using Random

include(joinpath(@__DIR__, "..", "fixtures", "functions", "floatcompare.jl"))   # close_
include(joinpath(@__DIR__, "..", "fixtures", "functions", "sequences.jl"))      # INSULIN_A

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

# A realistic solutes/pH setup shared by every priors-related test below.
smpl_solutes() = Solute[Protein(2.0e-4, 5.0e-6, INSULIN_A), NonBiological(0.15, 0.001, "sodium chloride")]
const smpl_pH    = 7.4
const smpl_σ_pH  = 0.05
const smpl_μ_χ   = 0.02
const smpl_σ_χ   = 0.01
const smpl_n_c1  = 95.0

smpl_priors() = FIT._calc_ξ_priors(smpl_pH, smpl_σ_pH, smpl_solutes();
    μ_χ = smpl_μ_χ, σ_χ = smpl_σ_χ, n = smpl_n_c1)

# Ground truth used to generate synthetic "experimental" data: physically
# plausible values (dns near bulk water, δρ1/c1 near CRYSOL's defaults).
const ξ_TRUE = (0.334, 1.05, -0.05, 0.02, 1.01)
const M_TRUE, C_TRUE = 1.7, 0.3

"""
Synthetic `(I_exp, σ_exp)` from `fw` at `ξ_TRUE`/`M_TRUE`/`C_TRUE`, with small seeded Gaussian noise.
"""
function synth_data(fw::ForwardCache)
    y = forward(fw, 1.0, 0.0, ξ_TRUE[1], (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]), ξ_TRUE[5])
    I_true = M_TRUE .* y .+ C_TRUE
    σ_exp = max.(abs.(I_true) .* 0.01, 1.0e-6)
    Random.seed!(0x5CA77e12)
    I_exp = I_true .+ randn(length(I_true)) .* σ_exp
    return I_exp, σ_exp
end

# ---------------------------------------------------------------------------
#                 independent references (no calls into Sampler.jl)
# ---------------------------------------------------------------------------

"""
Independent re-derivation of `_logπ`'s formula from first principles --
`Distributions.logpdf`, `forward`, `wls_fit`, `wls_prof_ll`/`wls_marg_ll`.
"""
function ref_logπ(θ::NTuple{5,<:Real}, pr, I_exp, σ_exp, fw, l::FIT.LIKELIHOOD)
    ξ = (exp(θ[1]), exp(θ[2]), θ[3], θ[4], exp(θ[5]))
    lp =    logpdf(pr.dnsPrior, ξ[1]) + logpdf(pr.δρ1Prior, ξ[2]) +
            logpdf(pr.δρ2Prior, ξ[3]) + logpdf(pr.δρ3Prior, ξ[4]) + logpdf(pr.c_1Prior, ξ[5])
    ŷ = forward(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4]), ξ[5])
    fit = wls_fit(ŷ, I_exp, σ_exp)
    ll = l isa FIT.PROFILE ? wls_prof_ll(fit) : wls_marg_ll(fit)
    return lp + ll + (θ[1] + θ[2] + θ[5])
end

"""
Run the pure `_logπ` on an `SVector` built from `θ`.
"""
function apply_logπ(θ::NTuple{5,<:Real}, pr, I_exp, σ_exp, fw, l)
    return FIT._logπ(SVector{5,Float64}(θ), pr, I_exp, σ_exp, fw, l)
end

@testset "Sampler" begin

    #------------------------------------------------------------------
    #                 _calc_ξ_priors -- composition of the 3 priors
    #------------------------------------------------------------------

    @testset "_calc_ξ_priors: exactly composes ρₑ_prior/δρ_prior/c1_prior" begin
        pr = smpl_priors()
        @test pr isa FIT._ξ_priors

        ref_dns = BayeSol.Fitting.ρₑ_prior(smpl_pH, smpl_σ_pH, smpl_solutes())
        ref_δρ1, ref_δρ2, ref_δρ3 = BayeSol.Fitting.δρ_prior(; μ_χ = smpl_μ_χ, σ_χ = smpl_σ_χ)
        ref_c1 = BayeSol.Fitting.c1_prior(smpl_n_c1)

        @test pr.dnsPrior  == ref_dns
        @test pr.δρ1Prior  == ref_δρ1
        @test pr.δρ2Prior  == ref_δρ2
        @test pr.δρ3Prior  == ref_δρ3
        @test pr.c_1Prior  == ref_c1
    end

    @testset "_calc_ξ_priors: propagates validation from the underlying priors" begin
        @test_throws ArgumentError FIT._calc_ξ_priors(smpl_pH, smpl_σ_pH, Solute[])
        @test_throws DomainError FIT._calc_ξ_priors(smpl_pH, -0.1, smpl_solutes())
    end

    #------------------------------------------------------------------
    #                 _ξ₀ -- initial draw respects each prior
    #------------------------------------------------------------------

    @testset "_ξ₀: returns an SVector{5,<:Real} inside every prior's support" begin
        pr = smpl_priors()
        Random.seed!(20_260_920)
        for _ in 1:200
            ξ0 = FIT._ξ₀(pr)
            @test ξ0 isa SVector{5,Float64}
            @test ξ0[1] > 0   # dns:  LogNormal support
            @test ξ0[2] > 0   # δρ1:  LogNormal support
            @test ξ0[5] > 0   # c1:   LogNormal support
            @test all(isfinite, ξ0)
        end
    end

    @testset "_ξ₀: empirical moments match each prior's analytic moments" begin
        pr = smpl_priors()
        Random.seed!(20_260_921)
        n = 60_000
        draws = [FIT._ξ₀(pr) for _ in 1:n]
        for (i, dist) in enumerate((pr.dnsPrior, pr.δρ1Prior, pr.δρ2Prior, pr.δρ3Prior, pr.c_1Prior))
            xs = getindex.(draws, i)
            μ_emp, σ_emp = mean(xs), std(xs)
            # generous (6 SEM) bound: deterministic seed keeps this from being flaky
            tol = 6 * std(dist) / sqrt(n)
            @test close_(μ_emp, mean(dist); atol = max(tol, 1.0e-3))
        end
    end

    #------------------------------------------------------------------
    #                 _ll -- PROFILE/MARGINAL dispatch
    #------------------------------------------------------------------

    @testset "_ll: PROFILE/MARGINAL match direct forward+wls_fit+wls_*_ll calls" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        cases = (
            ξ_TRUE,
            (0.30, 0.95, 0.10, -0.03, 0.98),
            (0.40, 1.15, -0.20, 0.05, 1.04),
        )
        for ξt in cases
            ξ = SVector{5,Float64}(ξt)
            ŷ = forward(fw, 1.0, 0.0, ξt[1], (ξt[2], ξt[3], ξt[4]), ξt[5])
            fit = wls_fit(ŷ, I_exp, σ_exp)

            @test close_(FIT._ll(I_exp, σ_exp, ξ, fw, FIT.PROFILE()), wls_prof_ll(fit))
            @test close_(FIT._ll(I_exp, σ_exp, ξ, fw, FIT.MARGINAL()), wls_marg_ll(fit))
            # the two variants genuinely differ (marginal isn't secretly aliased to profile)
            @test !close_(  FIT._ll(I_exp, σ_exp, ξ, fw, FIT.PROFILE()),
                            FIT._ll(I_exp, σ_exp, ξ, fw, FIT.MARGINAL()); atol = 1.0e-6)
        end
    end

    #------------------------------------------------------------------
    #                 _lp -- matches a manual logpdf sum
    #------------------------------------------------------------------

    @testset "_lp: matches an independently-summed logpdf over all 5 priors" begin
        pr = smpl_priors()
        cases = (
            ξ_TRUE,
            (0.30, 0.95, 0.10, -0.03, 0.98),
            (1.0e-3, 1.0e-3, 5.0, -5.0, 1.0e-3),  # tail values: still valid support
        )
        for ξt in cases
            ξ = SVector{5,Float64}(ξt)
            ref =   logpdf(pr.dnsPrior, ξt[1]) + logpdf(pr.δρ1Prior, ξt[2]) +
                    logpdf(pr.δρ2Prior, ξt[3]) + logpdf(pr.δρ3Prior, ξt[4]) + logpdf(pr.c_1Prior, ξt[5])
            @test close_(FIT._lp(ξ, pr), ref)
        end
    end

    #------------------------------------------------------------------
    #                 _logπ -- purity + composition + Jacobian correctness
    #------------------------------------------------------------------

    @testset "_logπ: pure -- composes _lp/_ll/Ξ exactly, no mutation of θ" begin
        pr = smpl_priors()
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        θt = (log(ξ_TRUE[1]), log(ξ_TRUE[2]), ξ_TRUE[3], ξ_TRUE[4], log(ξ_TRUE[5]))
        θ = SVector{5,Float64}(θt)
        θ_before = Tuple(θ)

        val = FIT._logπ(θ, pr, I_exp, σ_exp, fw, FIT.PROFILE())
        @test Tuple(θ) == θ_before   # input untouched

        ξ = Ξ(θ)
        @test all(close_.(Tuple(ξ), ξ_TRUE))
        expected = FIT._lp(ξ, pr) + FIT._ll(I_exp, σ_exp, ξ, fw, FIT.PROFILE()) + (θ[1] + θ[2] + θ[5])
        @test close_(val, expected)
    end

    @testset "_logπ: matches the independent reference, both LIKELIHOOD variants" begin
        pr = smpl_priors()
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        cases = (
            (log(ξ_TRUE[1]), log(ξ_TRUE[2]), ξ_TRUE[3], ξ_TRUE[4], log(ξ_TRUE[5])),
            (log(0.30), log(0.95), 0.10, -0.03, log(0.98)),
            (log(0.40), log(1.15), -0.20, 0.05, log(1.04)),
        )
        for θt in cases
            for l in (FIT.PROFILE(), FIT.MARGINAL())
                val = apply_logπ(θt, pr, I_exp, σ_exp, fw, l)
                @test close_(val, ref_logπ(θt, pr, I_exp, σ_exp, fw, l); atol = 1.0e-8)
            end
        end
    end

    @testset "_logπ: is AD-differentiable, gradient matches central differences" begin
        pr = smpl_priors()
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        θ₀ = [log(ξ_TRUE[1]), log(ξ_TRUE[2]), ξ_TRUE[3], ξ_TRUE[4], log(ξ_TRUE[5])]

        f(x) = FIT._logπ(SVector{5,eltype(x)}(x...), pr, I_exp, σ_exp, fw, FIT.PROFILE())
        g = ForwardDiff.gradient(f, θ₀)
        @test all(isfinite, g)

        h = 1.0e-6
        for i in 1:5
            xp = copy(θ₀); xp[i] += h
            xm = copy(θ₀); xm[i] -= h
            fd = (f(xp) - f(xm)) / (2h)
            @test g[i] ≈ fd rtol = 1.0e-4
        end
    end

    #------------------------------------------------------------------
    #                 Seed / seed_fitting
    #------------------------------------------------------------------

    @testset "seed_fitting: fields are internally consistent" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        seed = FIT.seed_fitting(fw, I_exp, σ_exp, smpl_pH, smpl_σ_pH, smpl_solutes();
            μ_χ = smpl_μ_χ, σ_χ = smpl_σ_χ, n = smpl_n_c1)

        @test seed isa FIT.Seed
        @test seed.fw === fw
        @test seed.ex == (I_exp, σ_exp)

        # θ₀ round-trips back to ξ₀ exactly through Ξ (independent of Θ/Ξ's
        # own dedicated test suite -- this is checking seed_fitting's *wiring*).
        @test all(close_.(Tuple(Ξ(seed.θ₀)), Tuple(seed.ξ₀)))

        # ξ₀ itself is a genuine draw from the composed priors
        @test seed.ξ₀[1] > 0 && seed.ξ₀[2] > 0 && seed.ξ₀[5] > 0
    end

    @testset "seed_fitting: propagates validation from _calc_ξ_priors" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        @test_throws ArgumentError FIT.seed_fitting(fw, I_exp, σ_exp, smpl_pH, smpl_σ_pH, Solute[])
        @test_throws DomainError FIT.seed_fitting(fw, I_exp, σ_exp, smpl_pH, -0.1, smpl_solutes())
    end

    #------------------------------------------------------------------
    #                 run -- argument validation
    #------------------------------------------------------------------

    @testset "run: δ must be a percentage strictly inside (0, 100)" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        seed = FIT.seed_fitting(fw, I_exp, σ_exp, smpl_pH, smpl_σ_pH, smpl_solutes();
            μ_χ = smpl_μ_χ, σ_χ = smpl_σ_χ, n = smpl_n_c1)
        @test_throws DomainError FIT.run_fitting(seed, 5, 2; δ = 0)
        @test_throws DomainError FIT.run_fitting(seed, 5, 2; δ = 100)
        @test_throws DomainError FIT.run_fitting(seed, 5, 2; δ = -10)
        @test_throws DomainError FIT.run_fitting(seed, 5, 2; δ = 150)
    end

    #------------------------------------------------------------------
    #                 run -- end to end
    #------------------------------------------------------------------

    """
    Every sample must obey ξ's structural domain (`dns, δρ1, c1 > 0`) --
    guaranteed by construction (Ξ always exponentiates those 3 coordinates)
    regardless of whether the sampler converged well, so this checks the
    decode step, not sampler quality.
    """
    function check_physical_domain(samples)
        for ξ in samples
            @test length(ξ) == 5
            @test all(isfinite, ξ)
            @test ξ[1] > 0
            @test ξ[2] > 0
            @test ξ[5] > 0
        end
    end

    """
    For a handful of returned samples, reconstruct θ from the (already
    decoded) ξ via Θ, and check that re-evaluating `_logπ` on it lands on
    the same `log_density` AdvancedHMC.jl itself reported for that
    iteration -- a wiring/self-consistency check of the whole
    ℓπ/∂ℓπ∂θ/Hamiltonian/NUTS chain, not a re-test of `_logπ`'s math (that's
    covered above against `ref_logπ`).
    """
    function check_log_density_self_consistency(samples, stats, seed, l)
        for i in eachindex(samples)
            θ_check, _ = Θ(samples[i])
            recomputed = FIT._logπ(θ_check, seed.pr, seed.ex[1], seed.ex[2], seed.fw, l)
            @test close_(recomputed, stats[i].log_density; atol = 1.0e-6)
        end
    end

    @testset "run: PROFILE -- output shapes, physical domain, self-consistency" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        seed = FIT.seed_fitting(fw, I_exp, σ_exp, smpl_pH, smpl_σ_pH, smpl_solutes();
            μ_χ = smpl_μ_χ, σ_χ = smpl_σ_χ, n = smpl_n_c1)

        Random.seed!(1)
        n_samples, n_adapt = 60, 30
        fit = FIT.run_fitting(seed, n_samples, n_adapt; l = FIT.PROFILE())
        samples, stats = fit.samples, fit.stats

        @test length(samples) == n_samples
        @test length(stats) == n_samples
        check_physical_domain(samples)
        check_log_density_self_consistency(samples, stats, seed, FIT.PROFILE())
    end

    @testset "run: MARGINAL -- output shapes, physical domain, self-consistency" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        seed = FIT.seed_fitting(fw, I_exp, σ_exp, smpl_pH, smpl_σ_pH, smpl_solutes();
            μ_χ = smpl_μ_χ, σ_χ = smpl_σ_χ, n = smpl_n_c1)

        Random.seed!(2)
        n_samples, n_adapt = 60, 30
        fit = FIT.run_fitting(seed, n_samples, n_adapt; l = FIT.MARGINAL())
        samples, stats = fit.samples, fit.stats

        @test length(samples) == n_samples
        @test length(stats) == n_samples
        check_physical_domain(samples)
        check_log_density_self_consistency(samples, stats, seed, FIT.MARGINAL())
    end

    @testset "run: deterministic under a fixed global RNG seed" begin
        fw = smpl_fw()
        I_exp, σ_exp = synth_data(fw)
        seed = FIT.seed_fitting(fw, I_exp, σ_exp, smpl_pH, smpl_σ_pH, smpl_solutes();
            μ_χ = smpl_μ_χ, σ_χ = smpl_σ_χ, n = smpl_n_c1)

        Random.seed!(42)
        fit1 = FIT.run_fitting(seed, 20, 10; l = FIT.PROFILE())
        samples1, stats1 = fit1.samples, fit1.stats
        Random.seed!(42)
        fit2 = FIT.run_fitting(seed, 20, 10; l = FIT.PROFILE())
        samples2, stats2 = fit2.samples, fit2.stats

        @test length(samples1) == length(samples2)
        for i in eachindex(samples1)
            @test all(samples1[i] .== samples2[i])
            @test stats1[i].log_density == stats2[i].log_density
        end
    end

end
