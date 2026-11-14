# SPDX-License-Identifier: LGPL-3.0-or-later

# End-to-end correctness tests for src/inference/{Infer,NUTS,Posterior}.jl: the Bayesian
# fitting pipeline (priors -> initial draw -> θ-space log-posterior -> NUTS
# via AdvancedHMC.jl). These tests check that the wiring is *correct* --
# independent re-derivations of every formula, purity (no hidden mutation)
# of _logπ, AD-differentiability, physical-domain invariants, and internal
# self-consistency between what `infer` returns and what AdvancedHMC.jl
# itself reports. They deliberately do NOT check posterior "goodness"
# (recovery accuracy, convergence diagnostics, effective sample size).

include(joinpath(@__DIR__, "..", "testsetup.jl"))

const FIT = BAYSOL.Inference

using BAYSOL.BulkElectronDensity: Solute, NonBiological
using BAYSOL.Inference: WLSData, wlsFit, wlsProfLl,
    profiledCorrs, Θ, Ξ
using BAYSOL.Inference: BOUNDS_δρ₁₂, κ_δρ₁₂, κ_δρ₃
using BAYSOL.Scattering: forwardCache, ForwardCache
using BAYSOL.MolecularStructure: MolecularStructure
using Distributions: logpdf, mean, std, params, Beta
using StaticArrays: SVector, @SMatrix
using ForwardDiff
using Random

include(joinpath(@__DIR__, "..", "floatcompare.jl"))   # close_

# ---------------------------------------------------------------------------
#                 fixtures: a non-trivial structure + synthetic data
# ---------------------------------------------------------------------------

# 16 atoms on a helix (mixed n/c/o, non-planar, non-degenerate).
function smplMol()
    elms = repeat(["n", "c", "c", "o"], 4)
    n = length(elms)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:(n-1)]
    return MolecularStructure.create("smpl", elms, crds)
end

const SMPL_Q     = collect(range(0.0, 0.35; length = 6))
const SMPL_E     = 9000.0
const SMPL_LMAX  = 3
const SMPL_CHUNK = UInt64(4)

smplFw() = forwardCache(smplMol(), SMPL_Q, SMPL_LMAX, SMPL_E; chunk = SMPL_CHUNK)

# Buffer only: the measured macromolecule is never
# a solute (see BulkElectronDensity.Solute).
smplSolutes()   = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
const SMPL_PH   = 7.4
const smpl_σ_pH = 0.05

smplPriors() = FIT._calc_ξ_priors(SMPL_PH, smpl_σ_pH, smplSolutes())

# Ground truth used to generate synthetic "experimental" data:
# ξ = (ρₑ, δρ₁, δρ₂, δρ₃).
const ξ_TRUE = (CRYSOL_SOLVENT_DENSITY, 1.05, -0.05, -1.0)
const M_TRUE, C_TRUE = 1.7, 0.3

"""
Synthetic `(I_exp, σ_exp)` from `fw` at
`ξ_TRUE`/`M_TRUE`/`C_TRUE`, with small seeded Gaussian noise.
"""
function synthData(fw::ForwardCache)
    y = referenceIntensity(fw, 1.0, 0.0, ξ_TRUE[1], ξ_TRUE[2:4])
    iTrue = M_TRUE .* y .+ C_TRUE
    σ_exp = max.(abs.(iTrue) .* 0.01, 1.0e-6)
    Random.seed!(0x5CA77e12)
    iExp = iTrue .+ randn(length(iTrue)) .* σ_exp
    return iExp, σ_exp
end

# ---------------------------------------------------------------------------
#                 independent references (no calls into the sampler files)
# ---------------------------------------------------------------------------

"Log prior of ξ = (ρₑ, δρ₁, δρ₂, δρ₃), written out by hand."
refLp(ξ, pr) =
    logpdf(pr.ρₑPrior, ξ[1]) + logpdf(pr.δρ₁Prior, ξ[2]) + logpdf(pr.δρ₂Prior, ξ[3]) +
    logpdf(pr.δρ₃Prior, ξ[4])

"""
Log-likelihood at ξ with c1 profiled: the c1 is taken from `profiledCorrs`,
everything else (contrasts, WLS, likelihood) is recomputed directly.
"""
function refLl(ξ, wls, fw)
    _, _, c1 = profiledCorrs(wls, SVector{4,Float64}(ξ), fw)
    ŷ = referenceIntensity(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4]), c1)
    fit = wlsFit(ŷ, wls)
    return wlsProfLl(fit)
end

"""
Independent re-derivation of `_logπ`: decode θ by hand, add the log-Jacobian
a + Σₖ [ln Wₖ + ln uₖ + ln(1 - uₖ)], uₖ = σ(tₖ), W = (12, 12, W₃).
"""
function ref_logπ(θ::NTuple{4,<:Real}, pr, wls, fw)
    lo, hi = BOUNDS_δρ₁₂
    u = map(t -> 1 / (1 + exp(-t)), θ[2:4])
    L₃, W₃ = pr.δρ₃Prior.μ, pr.δρ₃Prior.σ
    W = (hi - lo, hi - lo, W₃)
    ξ = (exp(θ[1]), lo + W[1] * u[1], lo + W[2] * u[2], L₃ + W₃ * u[3])
    corr = θ[1] + sum(log(W[k]) + log(u[k]) + log(1 - u[k]) for k in 1:3)
    return refLp(ξ, pr) + refLl(ξ, wls, fw) + corr
end

θ_of(ξt, pr) = Tuple(Θ(SVector{4,Float64}(ξt), pr)[1])

@testset "Sampler" begin

    @testset "_calc_ξ_priors: exactly composes ρₑ_prior/δρ_prior" begin
        pr = smplPriors()
        @test pr isa FIT.ξ_priors
        ref_ρ = FIT.ρₑ_prior(SMPL_PH, smpl_σ_pH, smplSolutes())
        ref_δρ₁, ref_δρ₂, ref_δρ₃ = FIT.δρ_prior(κ_δρ₁₂, κ_δρ₃, mean(ref_ρ))
        @test pr.ρₑPrior == ref_ρ
        @test pr.δρ₁Prior == ref_δρ₁
        @test pr.δρ₂Prior == ref_δρ₂
        @test pr.δρ₃Prior == ref_δρ₃
    end

    @testset "_calc_ξ_priors: κ keywords reach δρ_prior" begin
        pr = FIT._calc_ξ_priors(
            SMPL_PH,
            smpl_σ_pH,
            smplSolutes();
            κ_δρ₁₂ = 3.0,
            κ_δρ₃ = 7.0,
        )
        @test sum(params(pr.δρ₁Prior.ρ)) - 2 ≈ 3.0
        @test sum(params(pr.δρ₃Prior.ρ)) - 2 ≈ 7.0
        @test_throws DomainError FIT._calc_ξ_priors(
            SMPL_PH,
            smpl_σ_pH,
            smplSolutes();
            κ_δρ₁₂ = 0.0,
        )
    end

    @testset "_calc_ξ_priors: pure water is allowed; bad σ_pH still throws" begin
        @test FIT._calc_ξ_priors(SMPL_PH, smpl_σ_pH, Solute[]) isa FIT.ξ_priors
        @test_throws DomainError FIT._calc_ξ_priors(SMPL_PH, -0.1, smplSolutes())
    end

    @testset "_ξ₀: draws lie in every prior's support" begin
        pr = smplPriors()
        Random.seed!(20_260_920)
        for _ in 1:200
            ξ0 = FIT._ξ₀(pr)
            @test ξ0 isa SVector{4,Float64}
            @test ξ0[1] > 0
            @test BOUNDS_δρ₁₂[1] < ξ0[2] < BOUNDS_δρ₁₂[2] &&
                  BOUNDS_δρ₁₂[1] < ξ0[3] < BOUNDS_δρ₁₂[2]
            @test pr.δρ₃Prior.μ < ξ0[4] < pr.δρ₃Prior.μ + pr.δρ₃Prior.σ
            @test all(isfinite, ξ0)
        end
    end

    @testset "_ξ₀: empirical means match each prior's analytic mean" begin
        pr = smplPriors()
        Random.seed!(20_260_921)
        n = 60_000
        draws = [FIT._ξ₀(pr) for _ in 1:n]
        for (i, μ, σ) in ((1, mean(pr.ρₑPrior), std(pr.ρₑPrior)),
            (2, mean(pr.δρ₁Prior), std(pr.δρ₁Prior)),
            (3, mean(pr.δρ₂Prior), std(pr.δρ₂Prior)),
            (4, mean(pr.δρ₃Prior), std(pr.δρ₃Prior)))
            xs = getindex.(draws, i)
            @test close_(mean(xs), μ; atol = max(6σ / sqrt(n), 1.0e-9))
        end
    end

    # …of logit(u)
    @testset "θ_prior_moments: δρ₁, δρ₂, δρ₃ entries match the Monte Carlo moments" begin
        pr = smplPriors()
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
        pr = smplPriors()
        μ, σ = FIT.θ_prior_moments(pr)
        θ = SVector(-1.1, 0.2, 0.9, 0.4)
        ẑ = SVector(0.3, -0.2, 0.1, 0.5)
        S = @SMatrix [2.0 0.1 0.0 0.0; 0.0 0.5 0.2 0.0; 0.0 0.0 1.5 0.3; 0.1 0.0 0.0 0.7]
        sp = FIT._SamplingSpace(μ, σ, ẑ, S, 1, 1, 1, true, 0, 0.0, FIT._Optimum{4,16}[])
        w = S \ (FIT._standardize(θ, pr) - ẑ)
        @test all(isapprox.(FIT._θ_of_w(w, sp), θ; rtol = 1e-12))
    end

    @testset "_ll: matches the independent reference" begin
        fw = smplFw()
        wls = WLSData(synthData(fw)...)
        for ξt in (ξ_TRUE, (0.30, 0.95, 0.10, -6.0), (0.40, 1.15, -0.20, 2.5))
            ξ = SVector{4,Float64}(ξt)
            @test close_(FIT._ll(wls, ξ, fw), refLl(ξt, wls, fw))
        end
    end

    @testset "_ll: the forward model takes (δρ₁, δρ₂, δρ₃) straight from ξ[2:4]" begin
        fw = smplFw()
        wls = WLSData(synthData(fw)...)
        ξ = SVector(0.33, 1.0, 1.0, -4.0)
        ŷ, _, c1 = profiledCorrs(wls, ξ, fw)
        ŷ_ref = referenceIntensity(fw, 1.0, 0.0, 0.33, (1.0, 1.0, -4.0), c1)
        @test all(close_.(ŷ, ŷ_ref))
    end

    @testset "_lp: matches the hand-written log prior" begin
        pr = smplPriors()
        for ξt in (ξ_TRUE, (0.30, 0.95, 0.10, -8.0), (1.0e-3, -9.9, 1.9, 1.0))
            @test close_(FIT._lp(SVector{4,Float64}(ξt), pr), refLp(ξt, pr))
        end
    end

    @testset "_logπ: pure, and matches the independent reference" begin
        pr = smplPriors()
        fw = smplFw()
        wls = WLSData(synthData(fw)...)
        for ξt in (ξ_TRUE, (0.30, 0.95, 0.10, -6.0), (0.40, 1.15, -0.20, 2.5))
            θt = θ_of(ξt, pr)
            θ = SVector{4,Float64}(θt)
            θ_before = Tuple(θ)
            val = FIT._logπ(θ, pr, wls, fw)
            @test Tuple(θ) == θ_before
            @test close_(val, ref_logπ(θt, pr, wls, fw); atol = 1e1 * DEFAULT_ATOL)
        end
    end

    # …(c1 re-profiled each time)
    @testset "_logπ: AD gradient matches central differences" begin
        pr = smplPriors()
        fw = smplFw()
        wls = WLSData(synthData(fw)...)
        θ₀ = collect(θ_of(ξ_TRUE, pr))
        f(x) = FIT._logπ(SVector{4,eltype(x)}(x...), pr, wls, fw)
        g = ForwardDiff.gradient(f, θ₀)
        @test all(isfinite, g)
        h = 1.0e-5
        for i in 1:4
            xp = copy(θ₀)
            xp[i] += h
            xm = copy(θ₀)
            xm[i] -= h
            @test g[i] ≈ (f(xp) - f(xm)) / (2h) rtol = 1.0e-3 atol = 1.0e-6
        end
    end

    @testset "priorZScores: zero at the θ-space prior mean" begin
        pr = smplPriors()
        μ, _ = FIT.θ_prior_moments(pr)
        @test all(isapprox.(FIT.priorZScores(Ξ(μ, pr), pr), 0.0; atol = DEFAULT_ATOL))
    end

    @testset "seedSampler: fields are internally consistent" begin
        fw = smplFw()
        iExp, σ_exp = synthData(fw)
        seed = FIT.seedSampler(fw, iExp, σ_exp, SMPL_PH, smpl_σ_pH, smplSolutes())
        @test seed isa FIT.Seed
        @test seed.fw === fw
        @test seed.wls.iObs == iExp
        ξ₀ = Ξ(seed.θ₀, seed.pr)
        @test ξ₀[1] > 0 &&
              seed.pr.δρ₃Prior.μ < ξ₀[4] < seed.pr.δρ₃Prior.μ + seed.pr.δρ₃Prior.σ
        @test_throws DomainError FIT.seedSampler(
            fw,
            iExp,
            σ_exp,
            SMPL_PH,
            -0.1,
            smplSolutes(),
        )
    end

    @testset "pmvFallbackUncert: seedSampler and ρₑ_prior forward it" begin
        fw = smplFw()
        iExp, σ_exp = synthData(fw)
        li = Solute[NonBiological(0.2, 0.002, "lithium chloride")]   # states no uncertainty
        p0 = FIT.ρₑ_prior(SMPL_PH, smpl_σ_pH, li)
        p1 = FIT.ρₑ_prior(SMPL_PH, smpl_σ_pH, li; pmvFallbackUncert = 10.0)
        @test mean(p1) ≈ mean(p0) rtol = 1.0e-12
        @test std(p1) > std(p0)
        seed = FIT.seedSampler(
            fw, iExp, σ_exp, SMPL_PH, smpl_σ_pH, li; pmvFallbackUncert = 10.0,
        )
        @test std(seed.pr.ρₑPrior) ≈ std(p1) rtol = 1.0e-12
        @test std(FIT._calc_ξ_priors(SMPL_PH, smpl_σ_pH, li).ρₑPrior) ≈ std(p0)
        for bad in (0.0, NaN)
            @test_throws DomainError FIT.ρₑ_prior(
                SMPL_PH, smpl_σ_pH, li; pmvFallbackUncert = bad,
            )
            @test_throws DomainError FIT.seedSampler(
                fw, iExp, σ_exp, SMPL_PH, smpl_σ_pH, li; pmvFallbackUncert = bad,
            )
        end
    end

    @testset "MAP search: the f-stop does not stop short of the optimum" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        Random.seed!(11)
        sp = FIT._samplingSpace(seed)
        f(z) = FIT._neglogπ(
            SVector{4}(z...),
            sp.μ,
            sp.σ,
            seed,
            FIT.EXCL_VOL_CORR_TOL,
        )
        g!(G, z) = (G .= ForwardDiff.gradient(f, z); G)
        # polish the reported mode with a gradient-only search 1000× tighter and 10× longer
        res = FIT.optimize(FIT.OnceDifferentiable(f, g!, Vector(sp.ẑ)), Vector(sp.ẑ),
            FIT.LBFGS(),
            FIT.Options(g_abstol = 1e-9, iterations = 5000))
        # nats left on the table by the f-stop
        @test f(sp.ẑ) - FIT.Optim.minimum(res) < 1e-4
        @test FIT.MAP_F_ABSTOL == 1e-6 && FIT.MAP_F_SUCCESSIVE == 3
        # and it costs fewer evaluations than the gradient test alone, for the same optimum
        Random.seed!(11)
        spG =
            FIT._samplingSpace(seed; f_abstol = 0.0, successive_f_tol = 1)
        @test sp.nEvals < spG.nEvals
        @test abs(f(sp.ẑ) - f(spG.ẑ)) < 1e-4
    end

    # …and a different seed gives a different run
    @testset "rngSeed: the MAP search and the whole run are reproducible" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        sp1 = FIT._samplingSpace(seed; base = UInt64(0x1234))
        sp2 = FIT._samplingSpace(seed; base = UInt64(0x1234))
        @test sp1.ẑ == sp2.ẑ && sp1.S == sp2.S && sp1.nEvals == sp2.nEvals
        r1 = FIT.infer(seed, 40, 20; rngSeed = 7, retry = false)
        r2 = FIT.infer(seed, 40, 20; rngSeed = 7, retry = false)
        r3 = FIT.infer(seed, 40, 20; rngSeed = 8, retry = false)
        @test r1.samples == r2.samples
        @test r1.samples != r3.samples
        # `rngSeed = nothing` draws a fresh seed: Random.seed! before the call fixes it
        Random.seed!(3)
        q1 = FIT.infer(seed, 40, 20; rngSeed = nothing, retry = false)
        Random.seed!(3)
        q2 = FIT.infer(seed, 40, 20; rngSeed = nothing, retry = false)
        @test q1.samples == q2.samples
        # and the default is the fixed seed RNG_SEED (0): reproducible without any seeding
        d1 = FIT.infer(seed, 40, 20; retry = false)
        d2 = FIT.infer(seed, 40, 20; rngSeed = FIT.RNG_SEED, retry = false)
        @test FIT.RNG_SEED == 0 && d1.samples == d2.samples
    end

    @testset "run: δ must be a percentage strictly inside (0, 100)" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        for δ in (0, 100, -10, 150)
            @test_throws DomainError FIT.infer(seed, 5, 2; δ = δ, retry = false)
        end
    end

    function checkPhysicalDomain(samples, pr)
        for ξ in samples
            @test length(ξ) == 4
            @test all(isfinite, ξ)
            @test ξ[1] > 0
            @test BOUNDS_δρ₁₂[1] ≤ ξ[2] ≤ BOUNDS_δρ₁₂[2] &&
                  BOUNDS_δρ₁₂[1] ≤ ξ[3] ≤ BOUNDS_δρ₁₂[2]
            @test pr.δρ₃Prior.μ ≤ ξ[4] ≤ pr.δρ₃Prior.μ + pr.δρ₃Prior.σ
        end
    end

    """
    Re-evaluating `_logπ` at Θ(sample) must land on the logDensity
    AdvancedHMC.jl reported for that iteration.
    """
    function checkLogDensitySelfConsistency(samples, stats, seed)
        for i in eachindex(samples)
            θ_check, _ = Θ(samples[i], seed.pr)
            recomputed = FIT._logπ(θ_check, seed.pr, seed.wls, seed.fw)
            # Θ(Ξ(θ)) differs from θ by rounding, and the profiled c1
            # is located by a value-only minimizer, which is only as
            # accurate as √eps relative to the curvature (up to ~1e-6
            # in c1): the log density moves by its second-order effect
            @test close_(recomputed, stats[i].log_density; atol = 1e5 * DEFAULT_ATOL)
        end
    end

    @testset "run: output shapes, physical domain, self-consistency" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        Random.seed!(1)
        nSamples, nAdapt = 60, 30
        fit = FIT.infer(seed, nSamples, nAdapt; nChains = 1, retry = false)
        @test length(fit.samples) == nSamples
        @test length(fit.stats) == nSamples
        @test length(fit.c1) == nSamples
        checkPhysicalDomain(fit.samples, seed.pr)
        checkLogDensitySelfConsistency(fit.samples, fit.stats, seed)
    end

    @testset "run: deterministic under a fixed global RNG seed" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        Random.seed!(42)
        fit1 = FIT.infer(seed, 20, 10; retry = false)
        Random.seed!(42)
        fit2 = FIT.infer(seed, 20, 10; retry = false)
        for i in eachindex(fit1.samples)
            @test all(fit1.samples[i] .== fit2.samples[i])
            @test fit1.stats[i].log_density == fit2.stats[i].log_density
        end
    end

    @testset "chains: mirrored starts, pooling and determinism" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        nSamples, nAdapt = 60, 30
        r = FIT.infer(seed, nSamples, nAdapt; rngSeed = 5, retry = false)
        d = r.diagnostics
        @test d.nChains == FIT.N_CHAINS == 8
        # chains 1 and 2 at the MAP, then mirrored pairs at the CHAIN_START_RADII
        # (never farther than nominal, nearer only if a start had to be pulled back)
        @test d.startScale[1] == 0 && d.startScale[2] == 0
        for p in 1:3
            rad = FIT.CHAIN_START_RADII[p]
            @test d.startScale[2p+1] > 0 && d.startScale[2p+2] < 0 &&
                  d.startScale[2p+1] ≤ rad && -d.startScale[2p+2] ≤ rad
        end
        @test [FIT.chainRadius(k, 8) for k in 1:8] == [0, 0, 4, -4, 10, -10, 20, -20]
        @test FIT.chainRadius(1, 1) == 0 && FIT.chainRadius(2, 2) == 0 &&
              FIT.chainRadius(9, 10) == 20
        # chains 1 and 2 start at the same point but are different chains
        @test r.samples[r.chain .== 1] != r.samples[r.chain .== 2]
        # pooled chains come chain after chain, each with all its warm-up rows; with one
        # posterior mode they are whole, with several the post-warm-up rows are thinned
        # to the modes' shares (a chain never gains rows)
        pk = findall(d.pooled)
        @test !isempty(pk)
        @test length(r.samples) == length(r.stats) == length(r.c1) == size(r.curves, 2) ==
              length(r.chain) == length(r.iteration)
        @test issorted(r.chain) && unique(r.chain) == pk
        for k in pk
            it = r.iteration[r.chain .== k]
            @test it[1:nAdapt] == 1:nAdapt && issorted(it) && allunique(it) &&
                  maximum(it) ≤ nSamples
        end
        if length(d.modeWeight) == 1 && !d.weightsUncertain
            @test r.chain == vcat((fill(k, nSamples) for k in pk)...)
            @test r.iteration == repeat(1:nSamples, length(pk))
        else
            @test length(r.samples) ≤ length(pk) * nSamples
        end
        @test length(d.rhat) == length(d.ess) == length(d.essTail) == 5
        @test d.rewhitened ≥ 0
        # every pooled chain is in a mode; the modes' shares
        # sum to one; one chain is one mode of weight one
        @test length(d.mode) == d.nChains && all(d.mode[pk] .> 0) &&
              all(d.mode[setdiff(1:d.nChains, pk)] .== 0)
        @test sum(d.modeWeight) ≈ 1 &&
              length(d.modeWeight) == length(d.modeLogmass) == length(d.modeErr) ==
              maximum(d.mode)
        @test d.weightsUncertain isa Bool &&
              (length(d.modeWeight) > 1 || !d.weightsUncertain)
        # one chain starts at the MAP
        one = FIT.infer(seed, nSamples, nAdapt; rngSeed = 5, nChains = 1, retry = false)
        @test length(one.samples) == nSamples && one.diagnostics.startScale == [0.0] &&
              one.diagnostics.mode == [1] && one.diagnostics.modeWeight == [1.0]
        # same seeds, same run, at one worker and at several
        # (a chain belongs to its index, not to a thread)
        again = BAYSOL.Runtime.withWorkers(
            () -> FIT.infer(seed, nSamples, nAdapt; rngSeed = 5, retry = false),
            1,
        )
        @test again.samples == r.samples && again.chain == r.chain
        # one seed drives everything, the chain starts included: another seed, other draws
        otherSeed = FIT.infer(seed, nSamples, nAdapt; rngSeed = 6, retry = false)
        @test otherSeed.samples != r.samples
        @test_throws DomainError FIT.infer(
            seed,
            nSamples,
            nAdapt;
            nChains = 0,
            retry = false,
        )
    end

    @testset "retry: a run with R̂ above the limit is rerun once, deterministically" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        # 60 iterations per chain are too few for R̂ ≤ 1.01 on this toy posterior
        plain = FIT.infer(seed, 60, 30; rngSeed = 5, retry = false, nChains = 2)
        @test isnan(plain.diagnostics.firstRhat) && !plain.diagnostics.retryKept &&
              plain.diagnostics.nAdapt == 30
        @test FIT._worstRhat(plain.diagnostics) > FIT.RHAT_OK
        r = FIT.infer(seed, 60, 30; rngSeed = 5, nChains = 2)
        d = r.diagnostics
        @test d.firstRhat == FIT._worstRhat(plain.diagnostics)
        if d.retryKept
            @test d.nAdapt == FIT.RETRY_N_ADAPT
            @test maximum(r.iteration) == FIT.RETRY_N_ADAPT + FIT.RETRY_N_DRAWS
        else
            @test d.nAdapt == 30 && r.samples == plain.samples
        end
        # same seeds, same result, retried or not
        again = FIT.infer(seed, 60, 30; rngSeed = 5, nChains = 2)
        @test again.samples == r.samples && again.diagnostics.retryKept == d.retryKept
        # what counts as converged: R̂ at most RHAT_OK and both ESS at least ESS_MIN, with a
        # NaN (could not be computed) never read as fine
        ok = FIT.ESS_MIN
        @test isempty(FIT._convergenceProblems(1.005, ok, ok))
        @test length(FIT._convergenceProblems(1.02, ok, ok)) == 1
        @test length(FIT._convergenceProblems(1.005, ok - 1, ok)) == 1
        @test length(FIT._convergenceProblems(1.005, ok, ok - 1)) == 1
        @test length(FIT._convergenceProblems(Inf, ok, ok)) == 1
        @test length(FIT._convergenceProblems(NaN, ok, ok)) == 1
        @test length(FIT._convergenceProblems(1.005, NaN, NaN)) == 2
        # the retry follows it, however long the run was, and only when on
        @test FIT._retryNeeded(plain.diagnostics, true)
        @test !FIT._retryNeeded(plain.diagnostics, false)
        # the error says why
        err = FIT.NotConvergedError(FIT._convergenceProblems(1.5, ok, ok))
        @test occursin("did not converge", sprint(showerror, err))
        @test occursin("1.5", sprint(showerror, err))
    end

    @testset "optima: farthest-point cover, shares and chains at an optimum" begin
        rng = Xoshiro(1)
        W = [0.0 0; 1 0; 10 0; 0 10; 10 10]
        c = FIT._farthestCover(W, 3, 1)
        @test c[1] == 1 && allunique(c) && length(c) == 3 && 5 in c
        @test length(FIT._farthestCover(W, 10, 1)) == 5
        # identical rows: nothing is farther than what is taken
        @test FIT._farthestCover(W[[1, 1], :], 2, 1) == [1]

        i4 = @SMatrix [1.0 0 0 0; 0 1 0 0; 0 0 1 0; 0 0 0 1]
        opt(lm; z = zeros(SVector{4}), λ = ones(SVector{4})) =
            FIT._Optimum(z, 0.0, λ, i4, lm)
        @test FIT._optimumShares([opt(0.0), opt(log(0.25)), opt(NaN)]) ≈ [0.8, 0.2, 0.0]
        @test FIT._optimumShares([opt(NaN)]) == [0.0]
        @test sum(FIT._optimumShares([opt(3.0), opt(2.0), opt(-40.0)])) ≈ 1

        # an optimum at z = (10,0,0,0) with unit curvature, whitened coordinates = z
        sp = (ẑ = zeros(SVector{4}), S = i4)
        o = opt(0.0; z = SVector(10.0, 0, 0, 0))
        near = 0.3 .* randn(rng, 200, 4) .+ [10.0 0 0 0]
        far = 0.3 .* randn(rng, 200, 4)
        @test FIT._chainsAt(o, sp, [near, far, near]) == 2
        # 40 % of a chain's draws at the optimum is not at it (the limit is half)
        @test FIT._chainsAt(o, sp, [vcat(near[1:80, :], far[1:120, :])]) == 0
        @test FIT._chainsAt(o, sp, [vcat(near[1:120, :], far[1:80, :])]) == 1
        # without a positive definite Hessian there is nothing to measure against
        @test FIT._chainsAt(opt(NaN; λ = SVector(NaN, 1, 1, 1)), sp, [near]) == 0
    end

    @testset "MAP search: the optima it found, and the harvest from draws" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        sp = FIT._samplingSpace(seed; base = UInt64(5))
        @test 1 ≤ length(sp.optima) ≤ FIT.MAP_OPTIMA_KEPT
        @test issorted([o.f for o in sp.optima])
        # the MAP is one of them, and a Hessian with a finite mass exists for it
        @test any(o -> o.z == sp.ẑ, sp.optima)
        @test all(o -> isnan(o.logmass) || all(>(0), o.λ), sp.optima)
        # a pure function of the seeds
        sp2 = FIT._samplingSpace(seed; base = UInt64(5))
        @test [o.z for o in sp2.optima] == [o.z for o in sp.optima] && sp2.ẑ == sp.ẑ

        # draws around the MAP: the known optima come back, none is lost, and L-BFGS ran
        rng = Xoshiro(2)
        W = randn(rng, 300, 4)
        opts, nEvals = FIT._harvestOptima(
            seed, sp, W, randn(rng, 300), falses(300),
        )
        @test nEvals > 0 && length(opts) ≥ length(sp.optima)
        @test issorted([o.f for o in opts])
        @test all(o -> any(p -> p.z == o.z, opts), sp.optima)
        # nothing to harvest from
        @test FIT._harvestOptima(
            seed, sp, zeros(0, 4), Float64[], Bool[],
        ) == (sp.optima, 0)
    end

    @testset "infer: the optima of the run and the chains started at them" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        r = FIT.infer(seed, 60, 30; rngSeed = 5, retry = false)
        d = r.diagnostics
        @test d.nChains == FIT.N_CHAINS + d.nExtra
        @test 0 ≤ d.nExtra ≤ FIT.OPTIMUM_CHAIN_CAP
        @test length(d.pooled) == length(d.startScale) == length(d.mode) == d.nChains
        @test !isempty(d.optima)
        @test all(o -> o.share ≥ FIT.OPTIMUM_MIN_SHARE, d.optima)
        @test issorted([o.share for o in d.optima]; rev = true)
        @test sum(o.started for o in d.optima) == d.nExtra
        # the chains started at an optimum come last, with their own streams
        @test maximum(r.chain) ≤ d.nChains
        # a single chain is a single chain
        one = FIT.infer(seed, 60, 30; rngSeed = 5, nChains = 1, retry = false)
        @test one.diagnostics.nExtra == 0 && one.diagnostics.nChains == 1
        # same seeds, same run
        again = FIT.infer(seed, 60, 30; rngSeed = 5, retry = false)
        @test again.samples == r.samples && again.diagnostics.nExtra == d.nExtra
    end

    @testset "MAP search: log π at the MAP, more starts, a start added by the caller" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        sp = FIT._samplingSpace(seed; base = UInt64(0x77))
        @test FIT.MAP_N_STARTS == 64 && sp.nOk ≥ 1
        μ, σ = FIT.θ_prior_moments(seed.pr)
        @test sp.logπ ≈
              -FIT._neglogπ(sp.ẑ, μ, σ, seed, FIT.EXCL_VOL_CORR_TOL)
        # a start handed in (here the MAP itself) can only
        # add to the optima, never lower log π at the MAP
        sp2 = FIT._samplingSpace(
            seed;
            base = UInt64(0x77),
            extraStarts = [sp.ẑ],
        )
        @test sp2.logπ ≥ sp.logπ - 1e-6
    end

    @testset "SamplerOptions: the settings of the search, the chains and the rerun" begin
        so = FIT.SamplerOptions
        o = so()
        @test o.retryNAdapt == FIT.RETRY_N_ADAPT && o.retryNDraws == FIT.RETRY_N_DRAWS
        @test o.chainStartRadii == collect(FIT.CHAIN_START_RADII)
        @test o.optimumChainCap == FIT.OPTIMUM_CHAIN_CAP &&
              o.optimumMinChains == FIT.OPTIMUM_MIN_CHAINS
        @test o.optimumChainRadius == FIT.OPTIMUM_CHAIN_RADIUS &&
              o.optimumChainFraction == FIT.OPTIMUM_CHAIN_FRACTION
        @test o.mapMaxIter == FIT.MAP_MAX_ITER && o.mapNStarts == FIT.MAP_N_STARTS &&
              o.mapFSuccessive == FIT.MAP_F_SUCCESSIVE &&
              o.mapOptimaKept == FIT.MAP_OPTIMA_KEPT
        @test o.mapJitterRadii == collect(FIT.MAP_JITTER_RADII) &&
              o.mapJitterDirections == FIT.MAP_JITTER_DIRECTIONS &&
              o.mapJitterMaxOptima == FIT.MAP_JITTER_MAX_OPTIMA &&
              o.mapJitterWithinNats == FIT.MAP_JITTER_WITHIN_NATS
        @test o.basinRestartNats == FIT.BASIN_RESTART_NATS &&
              o.harvestCover == FIT.HARVEST_COVER &&
              o.harvestDivergent == FIT.HARVEST_DIVERGENT
        # every value is converted to the type of its field (so the code stays type-stable)
        c = so(; mapNStarts = 0x05, chainStartRadii = [1, 2], optimumChainRadius = 3)
        @test c.mapNStarts === 5 && c.chainStartRadii == [1.0, 2.0] &&
              c.optimumChainRadius === 3.0

        # the chain radii: a vector replaces the constant, a short one repeats its last
        @test FIT.chainRadius(5, 8, [1.0, 2.0]) == 2.0 &&
              FIT.chainRadius(6, 8, [1.0, 2.0]) == -2.0
        @test FIT.chainRadius(3, 8, (7.0,)) == 7.0 &&
              FIT.chainRadius(8, 8, (7.0,)) == -7.0
        @test FIT.chainRadius(8, 8) == FIT.chainRadius(8, 8, FIT.CHAIN_START_RADII)
        # what counts as a chain at an optimum
        i4 = @SMatrix [1.0 0 0 0; 0 1 0 0; 0 0 1 0; 0 0 0 1]
        sp = (ẑ = zeros(SVector{4}), S = i4)
        o₁ = FIT._Optimum(SVector(10.0, 0, 0, 0), 0.0, ones(SVector{4}), i4, 0.0)
        rng = Xoshiro(3)
        near = 0.3 .* randn(rng, 100, 4) .+ [10.0 0 0 0]
        mixed = vcat(near[1:40, :], 0.3 .* randn(rng, 60, 4))        # 40 % at the optimum
        @test FIT._chainsAt(o₁, sp, [mixed]) == 0
        @test FIT._chainsAt(o₁, sp, [mixed]; fraction = 0.3) == 1
        @test FIT._chainsAt(o₁, sp, [near]; radius = 0.1) == 0
        @test FIT._chainsAt(o₁, sp, [near]) == FIT._chainsAt(
            o₁, sp, [near]; radius = FIT.OPTIMUM_CHAIN_RADIUS,
            fraction = FIT.OPTIMUM_CHAIN_FRACTION,
        )
    end

    @testset "SamplerOptions act: MAP search, harvest, rerun, extra chains" begin
        fw = smplFw()
        seed = FIT.seedSampler(fw, synthData(fw)..., SMPL_PH, smpl_σ_pH, smplSolutes())
        so = FIT.SamplerOptions
        base = UInt64(0x51)
        # the default options are the search as it always ran
        sp0 = FIT._samplingSpace(seed; base = base)
        spd = FIT._samplingSpace(seed; base = base, options = so())
        @test spd.ẑ == sp0.ẑ && spd.nEvals == sp0.nEvals && spd.nStarts == sp0.nStarts
        # fewer starts and no jitter: fewer L-BFGS runs
        few = so(; mapNStarts = 3, mapJitterDirections = 1, mapJitterMaxOptima = 1)
        spf = FIT._samplingSpace(seed; base = base, options = few)
        @test spf.nStarts < sp0.nStarts && spf.nEvals < sp0.nEvals
        # starts + one direction at each radius
        @test spf.nStarts ≤ 3 + 3
        # an iteration cap of 1 gives up early
        capped = FIT._samplingSpace(seed; base = base, options = so(; mapMaxIter = 1))
        @test capped.nEvals < sp0.nEvals
        # the successive-decrease count is a keyword of the options too
        @test FIT._samplingSpace(
            seed; base = base, options = so(; mapFSuccessive = 1),
        ).nEvals ≤ sp0.nEvals
        # harvest: one draw to start from instead of the cover
        rng = Xoshiro(2)
        W = randn(rng, 300, 4)
        ld = randn(rng, 300)
        _, nAll = FIT._harvestOptima(seed, sp0, W, ld, falses(300))
        _, nOne = FIT._harvestOptima(
            seed, sp0, W, ld, falses(300); options = so(; harvestCover = 1),
        )
        @test 0 < nOne < nAll
        # the rerun has the length the options give it
        short = so(; retryNAdapt = 20, retryNDraws = 25)
        r = FIT.infer(seed, 60, 30; rngSeed = 5, nChains = 2, options = short)
        d = r.diagnostics
        @test d.firstRhat == FIT._worstRhat(
            FIT.infer(seed, 60, 30; rngSeed = 5, retry = false, nChains = 2).diagnostics,
        )
        if d.retryKept
            @test d.nAdapt == 20 && maximum(r.iteration) == 45
        else
            @test d.nAdapt == 30
        end
        # the extra chains at optima: none allowed, none started
        none = FIT.infer(
            seed, 60, 30; rngSeed = 5, retry = false,
            options = so(; optimumChainCap = 0),
        )
        @test none.diagnostics.nExtra == 0 && none.diagnostics.nChains == FIT.N_CHAINS
        # the default options are the default run
        a = FIT.infer(seed, 40, 20; rngSeed = 7, retry = false, nChains = 2)
        b = FIT.infer(
            seed,
            40,
            20;
            rngSeed = 7,
            retry = false,
            nChains = 2,
            options = so(),
        )
        @test a.samples == b.samples
        # start radii of the chains: pair 1 starts at ±2, not ±4
        rr = FIT.infer(
            seed, 40, 20; rngSeed = 7, retry = false, nChains = 4,
            options = so(; chainStartRadii = [2.0]),
        )
        @test all(x -> abs(x) ≤ 2, rr.diagnostics.startScale[1:4])
    end

    @testset "seedSampler: bounds, mode, φ_max and the c1 window are keywords" begin
        fw = smplFw()
        data = synthData(fw)
        args = (fw, data..., SMPL_PH, smpl_σ_pH, smplSolutes())
        s0 = FIT.seedSampler(args...)
        # at their constants: the seed of always
        sd = FIT.seedSampler(
            args...; bounds_δρ₁₂ = FIT.BOUNDS_δρ₁₂, mode_δρ₁₂ = FIT.MODE_δρ₁₂,
            φ_max = FIT.φ_max, exclVolCorrBounds = FIT.EXCL_VOL_CORR_BOUNDS,
            exclVolCorrEps = FIT.EXCL_VOL_CORR_EPS,
        )
        @test sd.θ₀ == s0.θ₀ && sd.pr == s0.pr && sd.c1tab.cs == s0.c1tab.cs
        @test (s0.pr.δρ₁Prior.μ, s0.pr.δρ₁Prior.σ) == (-10.0, 12.0)

        # changed: the supports, the mode, φ_max and the c1 window
        s1 = FIT.seedSampler(
            args...; bounds_δρ₁₂ = (-6.0, 3.0), mode_δρ₁₂ = 0.5, φ_max = 1.1,
            exclVolCorrBounds = (0.9, 1.2), exclVolCorrEps = 0.025,
        )
        pr = s1.pr
        @test (pr.δρ₁Prior.μ, pr.δρ₁Prior.σ) == (-6.0, 9.0) &&
              (pr.δρ₂Prior.μ, pr.δρ₂Prior.σ) == (-6.0, 9.0)
        # the mode of the prior sits where it was asked to
        α, β = params(pr.δρ₁Prior.ρ)
        @test pr.δρ₁Prior.μ + pr.δρ₁Prior.σ * (α - 1) / (α + β - 2) ≈ 0.5
        # φ_max is the support of δρ₃: its upper end is (φ_max - 1)·ρ̄ₑ/UNIT_OF_δρ
        ρ̄ = mean(pr.ρₑPrior)
        top3(p) = p.δρ₃Prior.μ + p.δρ₃Prior.σ
        @test top3(pr) ≈ (1.1 - 1) * ρ̄ / FIT.UNIT_OF_δρ
        @test top3(s0.pr) ≈ (FIT.φ_max - 1) * mean(s0.pr.ρₑPrior) / FIT.UNIT_OF_δρ
        c = s1.c1tab
        @test (c.cmin, c.cmax, c.eps) == (0.9, 1.2, 0.025) && c.cs[1] ≈ 0.9 - 0.025
        # the transform follows the support in the prior (and round-trips)
        ξ = SVector(0.33, -2.0, 2.5, top3(pr) / 2)
        θ, corr = Θ(ξ, pr)
        @test Ξ(θ, pr) ≈ ξ
        @test corr ≈ FIT.logjac(θ, pr)
        # a point of (-10, 2) but outside (-6, 3) is not in the support
        @test_throws DomainError Θ(SVector(0.33, -8.0, 0.0, 0.0), pr)
        # type stability of the hot-path functions with a non-default support
        θv = SVector{4,Float64}(θ)
        @inferred Θ(ξ, pr)
        @inferred Ξ(θv, pr)
        @inferred FIT.logjac(θv, pr)
        # the c1 search uses the tables' window; the sampler sees no error
        wls = WLSData(data...)
        _, _, c1 = profiledCorrs(wls, SVector{4,Float64}(ξ), fw; tables = c)
        @test 0.9 - 0.025 ≤ c1 ≤ 1.2 + 0.025
        @test FIT.exclVolSaturation(1.25; cmin = c.cmin, cmax = c.cmax) == 1
        @test FIT.exclVolSaturation(1.25) == 0
        # a table is not used for a window it was not built for (given explicitly)
        @test_throws ArgumentError profiledCorrs(
            wls, SVector{4,Float64}(ξ), fw; tables = c, cmin = 0.8,
        )
        @test isfinite(
            FIT._neglogπ(zeros(SVector{4}), s1.pr |> FIT.θ_prior_moments |> first,
                s1.pr |> FIT.θ_prior_moments |> last, s1, FIT.EXCL_VOL_CORR_TOL),
        )
        # a bad value is a DomainError here (the pipeline checks first, with its own error)
        @test_throws DomainError FIT.seedSampler(args...; mode_δρ₁₂ = 5.0)
        @test_throws DomainError FIT.seedSampler(args...; φ_max = 0.0)
        @test_throws DomainError FIT.seedSampler(args...; bounds_δρ₁₂ = (2.0, -10.0))
    end

end
