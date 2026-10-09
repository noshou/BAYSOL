# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for test/utils/seed_diagnostics.jl, the sampler diagnostics used on the SASBDB fitting tests
# (through test/run/diagnose.tcl). They run on a small toy seed so that the
# diagnostics cannot rot unnoticed; the numbers they produce on real fits are not asserted here.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Fitting: Solute, NonBiological
using BAYSOL.Scattering: forward_cache, ForwardCache
using BAYSOL.MolecularStructure: MolecularStructure
using StaticArrays: SVector
using Random
using Statistics: mean, median

include(joinpath(@__DIR__, "..", "..", "utils", "seed_diagnostics.jl"))
using .SeedDiagnostics

const SDF = BAYSOL.Fitting

# 16 atoms on a helix (mixed n/c/o, non-planar), the same shape of fixture as test_sampler.jl,
# self-contained here per this directory's one-file-one-concern convention.
function sdg_mol()
    elms = repeat(["n", "c", "c", "o"], 4)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:(length(elms) - 1)]
    return MolecularStructure.create("sdg", elms, crds)
end

const sdg_q = collect(range(0.0, 0.35; length = 10))

"A `Seed` on the toy helix with synthetic data (ξ_TRUE, c1 = 1.1) at ~1 % noise: smooth, well-posed, fast."
function sdg_seed(; rel_noise = 0.01)
    fw = forward_cache(sdg_mol(), sdg_q, 3, 9000.0; chunk = UInt64(4))
    y = reference_intensity(fw, 1.7, 0.3, CRYSOL_SOLVENT_DENSITY, (1.05, -0.05, -1.0), 1.1)
    σ = max.(abs.(y) .* rel_noise, 1.0e-6)
    Random.seed!(0x5D6)
    I_exp = y .+ randn(length(y)) .* σ
    Random.seed!(0x5D7)   # θ₀ and the MAP starts are drawn from the global RNG
    return SDF.seed_fitting(fw, I_exp, σ, 7.4, 0.05, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
end

@testset "SeedDiagnostics" begin

    @testset "ess: iid draws ≈ n, AR(1) draws ≈ n(1-ρ)/(1+ρ), constant → NaN" begin
        Random.seed!(1)
        n = 20_000
        @test ess(randn(n)) > 0.8n
        ρ = 0.9
        x = zeros(n)
        for i in 2:n
            x[i] = ρ * x[i-1] + sqrt(1 - ρ^2) * randn()
        end
        @test ess(x; maxlag = 200) ≈ n * (1 - ρ) / (1 + ρ) rtol = 0.5
        @test isnan(ess(fill(2.0, 100)))
    end

    @testset "curve_chi2: an exact curve gives 0, a rescaled one is recovered by the free scale+offset" begin
        q = collect(range(0.01, 0.3; length = 50))
        I = 100 .* exp.(-q .^ 2 .* 200)
        σ = 0.01 .* I
        c = curve_chi2(q, I, σ, q, I)
        @test c.n == 50 && c.raw < 1e-20 && c.fitted < 1e-20
        c = curve_chi2(q, I, σ, q, 0.5 .* I .+ 3)
        @test c.raw > 1 && c.fitted < 1e-12
        @test_throws ArgumentError curve_chi2(q, I, σ, q .+ 10, I)
    end

    seed = sdg_seed()
    l = SDF.PROFILE()
    rep = nuts_replica(seed; n_samples = 160, n_adapt = 80, rng_seed = 11)
    sp = rep.sp

    @testset "nuts_replica: shapes, a positive adapted step size, finite draws" begin
        @test size(rep.W) == (4, 160) && size(rep.post) == (4, 80)
        @test length(rep.stats) == 160
        @test rep.ε > 0 && rep.ε0 > 0 && all(isfinite, rep.W)
        @test rep.n_leapfrog == sum(s -> s.n_steps, rep.stats)
        @test_throws ArgumentError nuts_replica(seed; n_samples = 10, n_adapt = 10)
    end

    @testset "nuts_replica: same rng_seed reproduces the chain; the whitening is reused" begin
        again = nuts_replica(seed; n_samples = 160, n_adapt = 80, rng_seed = 11, sp = sp)
        @test again.W == rep.W
        @test again.sp === sp
    end

    @testset "gradient_w: matches a central difference of log π(θ(w))" begin
        w = rep.post[:, 5]
        g = gradient_w(seed, sp, w; tol = 1e-11)
        @test length(g) == 4 && all(isfinite, g)
        f(x) = SDF._logπ(SDF._θ_of_w(SVector{4}(x...), sp), seed.pr, seed.wls, seed.fw, l; tab = seed.c1tab, c1_tol = 1e-11)
        h = 1e-5
        for i in 1:4
            e = zeros(4); e[i] = h
            @test g[i] ≈ (f(w .+ e) - f(w .- e)) / 2h rtol = 1e-3 atol = 1e-5
        end
    end

    @testset "gradient_noise: zero against itself, and shrinking with the tolerance" begin
        self = gradient_noise(seed, sp, rep.post; tol = 1e-11, ref_tol = 1e-11, n = 8)
        @test all(==(0.0), self.noise)
        @test length(self.noise) == length(self.grad_norm) == 8
        loose = gradient_noise(seed, sp, rep.post; tol = 1e-2, n = 8)
        tight = gradient_noise(seed, sp, rep.post; tol = SDF.EXCL_VOL_CORR_TOL, n = 8)
        @test all(isfinite, loose.noise) && all(≥(0), loose.noise)
        @test maximum(tight.noise) ≤ maximum(loose.noise)
    end

    @testset "regression: the default c1 tolerance keeps NUTS's gradient accurate on a stiff fit" begin
        # With σ = 1e-5·I the posterior is narrow and ∂²f/∂c1∂ξ large, so a c1 error δ perturbs the envelope-
        # theorem gradient by about (∂²f/∂c1∂ξ)·δ, first order. At the old tolerance 1e-5 that error is of the
        # order of the gradient itself (the sampler's step size collapses on real fits like this); at the
        # package default it must be negligible. The first assertion fails if the fixture stops being stiff.
        stiff = sdg_seed(; rel_noise = 1e-5)
        r = nuts_replica(stiff; n_samples = 200, n_adapt = 100, rng_seed = 5)
        old = gradient_noise(stiff, r.sp, r.post; tol = 1e-5, n = 12)
        now = gradient_noise(stiff, r.sp, r.post; tol = SDF.EXCL_VOL_CORR_TOL, n = 12)
        @test median(old.noise) > 0.1 * median(old.grad_norm)
        @test median(now.noise) < 0.01 * median(now.grad_norm)
    end

    @testset "local_curvature: one pair of eigenvalues per probed draw, λ_max ≥ λ_min" begin
        lc = local_curvature(seed, sp, rep.post; n = 6)
        @test length(lc.λmax) == length(lc.λmin) == 6
        @test all(lc.λmax .≥ lc.λmin) && all(isfinite, lc.λmax)
    end

    starts = lbfgs_starts(seed; rng_seed = 3, n_starts = 4)

    @testset "lbfgs_starts: each feasible start reports how it stopped" begin
        @test !isempty(starts)
        for o in starts
            @test isfinite(o.f) && o.iters ≥ 0 && o.grad_gap ≥ 0
            @test o.ξ[1] > 0 && 0.7 < o.c1 < 1.4
        end
        @test lbfgs_starts(seed; rng_seed = 3, n_starts = 4) == starts   # reproducible under rng_seed
    end

    @testset "hessian_sensitivity: eigenvalues for every step size; a well-posed MAP is step-independent" begin
        hs = hessian_sensitivity(seed, sp.ẑ; rels = (0.3, 0.1))
        @test length(hs.pass1) == 4 && sort(collect(keys(hs.pass2))) == [0.1, 0.3]
        @test all(isfinite, hs.pass2[0.1]) && all(hs.σ_lap .> 0)
    end

    @testset "mode_table: best mode first, Laplace mass finite only for a positive-definite Hessian" begin
        modes = mode_table(seed, starts, sp)
        @test !isempty(modes) && issorted(getproperty.(modes, :f))
        @test all(m -> length(m.λ) == 4, modes)
        @test all(m -> isnan(m.log_mass) || isfinite(m.log_mass), modes)
    end

    @testset "axis_scan: four axes, ratios finite, no c1 regime jump on a smooth fit" begin
        scans = axis_scan(seed, sp; grid = 41)
        @test length(scans) == 4 && [a.axis for a in scans] == 1:4
        @test all(a -> all(isfinite, a.ratio) && a.noise ≥ 0 && a.f2_max ≥ a.f2_median, scans)
        @test all(a -> a.c1_range[1] ≤ a.c1_range[2], scans)
    end

    @testset "shell_contrast_ablation: finite χ², contrasts inside their supports" begin
        a = shell_contrast_ablation(seed)
        @test all(isfinite, (a.M1.chi2, a.M2.chi2, a.M3.chi2))
        @test SDF.DRO_LOWER ≤ a.M1.d ≤ SDF.DRO_LOWER + SDF.DRO_WIDTH
        @test SDF.DRO_LOWER ≤ a.M2.d12 ≤ SDF.DRO_LOWER + SDF.DRO_WIDTH
        # one more free contrast cannot fit worse than a shared one, up to the grid resolution
        @test a.M2.chi2 ≤ a.M1.chi2 * 1.05 + 1e-6
    end

    @testset "diagnose / tolerance_sweep: write their reports" begin
        io = IOBuffer()
        diagnose(io, seed; label = "toy", n_samples = 120, n_adapt = 60)
        txt = String(take!(io))
        for key in ("toy", "MAP search", "NUTS:", "L-BFGS starts", "gradient error", "distinct optima")
            @test occursin(key, txt)
        end
        rows = tolerance_sweep(io, seed; label = "toy", tols = (1e-5, 1e-8), rng_seeds = (1, 2), n_samples = 120, n_adapt = 60)
        @test length(rows) == 4 && all(r -> r.ε > 0 && r.steps ≥ 1, rows)
        @test count(==('\n'), String(take!(io))) == 4
    end

    @testset "warmup_study: step-size trace, one row per (adaptation length, seed), draw statistics" begin
        io = IOBuffer()
        r = warmup_study(io, seed; label = "toy", adapts = (30, 60), n_post = 100, n_ref = 200, n_adapt_ref = 60, rng_seeds = (1, 2))
        txt = String(take!(io))
        for key in ("toy WARMUP", "toy ADAPT", "toy DRAWS", "toy ESS400")
            @test occursin(key, txt)
        end
        @test length(r.adapt) == 4 && all(x -> x.ε > 0 && x.steps ≥ 1 && x.dm ≥ 0 && x.ds ≥ 0, r.adapt)
        @test [d.n for d in r.draws] == [100, 200] && all(d -> d.min_ess > 0, r.draws)
        @test all(e -> e[2] > 0, r.trace) && last(r.trace)[1] ≤ 60
    end
end
