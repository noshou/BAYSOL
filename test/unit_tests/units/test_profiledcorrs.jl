# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Inference/ProfiledCorrs.jl: the grid-pre-scan + Brent()
# profile search for c1 (CRYSOL's excluded-volume correction, no longer
# sampled with a prior) and the excl_vol_saturation classifier built on
# top of it.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Inference: WLSData, wls_fit, reduced_chi2, profiled_corrs, excl_vol_saturation
using BAYSOL.Scattering: forward_cache, ForwardCache
using BAYSOL.MolecularStructure: MolecularStructure
using BAYSOL.Inference: EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS
using StaticArrays: SVector
using ForwardDiff
using Random

include(joinpath(@__DIR__, "..", "..", "utils", "floatcompare.jl"))   # close_

const CMIN, CMAX = EXCL_VOL_CORR_BOUNDS
const EPS        = EXCL_VOL_CORR_EPS

# 16 atoms on a helix (mixed n/c/o, non-planar, non-degenerate) -- same
# shape of fixture as test_sampler.jl, self-contained here per this
# directory's one-file-one-concern convention.
function pc_mol()
    elms = repeat(["n", "c", "c", "o"], 4)
    n = length(elms)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:(n-1)]
    return MolecularStructure.create("pc", elms, crds)
end

const pc_q = collect(range(0.02, 0.35; length = 12))
pc_fw() = forward_cache(pc_mol(), pc_q, 3, 9000.0; chunk = UInt64(4))

# ξ = (ρₑ, δρ₁, δρ₂, δρ₃). This toy helix has no
# cavity beads, so δρ₃ does not affect the curve.
const ξ_TRUE = SVector(CRYSOL_SOLVENT_DENSITY, 1.5, 0.5, -1.0)

"""
Synthetic WLSData generated from `fw` at `ξ_TRUE`/`c1_true`, with the given
relative noise (0 => an exact/noiseless curve, for recovery tests where the
true c1 must be located essentially exactly).
"""
function synth_wls(fw::ForwardCache, c1_true::Real; rel_noise::Real = 0.0)
    y = reference_intensity(
        fw,
        2.0,
        0.0005,
        ξ_TRUE[1],
        (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]),
        c1_true,
    )
    σ = fill(max(rel_noise, 1.0e-3) * maximum(abs.(y)), length(y))
    Random.seed!(0xC1_5EED)
    I_exp = rel_noise == 0 ? y : y .+ σ .* randn(length(y))
    return WLSData(I_exp, σ)
end

@testset "ProfiledCorrs" begin

    #------------------------------------------------------------------
    #                 excl_vol_saturation -- pure classifier
    #------------------------------------------------------------------

    @testset "excl_vol_saturation: classifies strictly against (cmin, cmax)" begin
        @test excl_vol_saturation(1.0; cmin = CMIN, cmax = CMAX) == 0
        # exactly on the bound: not saturated
        @test excl_vol_saturation(CMIN; cmin = CMIN, cmax = CMAX) == 0
        @test excl_vol_saturation(CMAX; cmin = CMIN, cmax = CMAX) == 0
        @test excl_vol_saturation(CMIN - 1.0e-9; cmin = CMIN, cmax = CMAX) == -1
        @test excl_vol_saturation(CMAX + 1.0e-9; cmin = CMIN, cmax = CMAX) == 1
        @test excl_vol_saturation(0.5 * (CMIN + CMAX); cmin = CMIN, cmax = CMAX) == 0
    end

    #------------------------------------------------------------------
    #                 profiled_corrs -- interior recovery
    #------------------------------------------------------------------

    @testset "profiled_corrs: recovers a known interior c1 on a noiseless curve" begin
        fw = pc_fw()
        c1_true = 1.05
        wls = synth_wls(fw, c1_true)
        ŷ, fit, c1_star = profiled_corrs(wls, ξ_TRUE, fw)

        @test close_(c1_star, c1_true; atol = 1.0e-4)
        @test close_(fit.chi2, 0.0; atol = 1e3 * DEFAULT_ATOL)
        @test excl_vol_saturation(c1_star) == 0
        @test ŷ ≈ reference_intensity(
            fw,
            1.0,
            0.0,
            ξ_TRUE[1],
            (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]),
            c1_star,
        )   # fused A + g·B + g²·C differs from the plain double sum by rounding only
    end

    #------------------------------------------------------------------
    #                 profiled_corrs -- genuine saturation, both directions
    #------------------------------------------------------------------

    # …when the true optimum is far below cmin
    @testset "profiled_corrs: saturates at the padded lower bound" begin
        fw = pc_fw()
        wls = synth_wls(fw, 0.5)   # well outside (cmin, cmax) = (0.8, 1.3)
        _, _, c1_star = profiled_corrs(wls, ξ_TRUE, fw)

        @test close_(c1_star, CMIN - EPS; atol = 1.0e-3)
        @test excl_vol_saturation(c1_star) == -1
    end

    # …when the true optimum is above cmax
    @testset "profiled_corrs: saturates at the padded upper bound" begin
        fw = pc_fw()
        # 1.33 is a deliberately modest excursion past cmax=1.3: χ²(c1) is not
        # globally monotone in c1 for a badly-wrong excluded-volume species
        # (the contrast-match point, where ρₑ·c1³·ΣV cancels the atoms'
        # electrons, sits at c1 ≈ 1.18 for this fixture), but at this c1_true
        # it was checked on a 0.005 grid to decrease monotonically all the way
        # to the padded edge.
        wls = synth_wls(fw, 1.33)
        _, _, c1_star = profiled_corrs(wls, ξ_TRUE, fw)

        @test close_(c1_star, CMAX + EPS; atol = 1.0e-3)
        @test excl_vol_saturation(c1_star) == 1
    end

    #------------------------------------------------------------------
    #                 profiled_corrs -- independent optimality cross-check
    #------------------------------------------------------------------

    @testset "profiled_corrs: c1_star is not beaten by a much finer independent grid" begin
        fw = pc_fw()
        wls = synth_wls(fw, 1.12; rel_noise = 0.02)
        _, fit, c1_star = profiled_corrs(wls, ξ_TRUE, fw)

        χ²_at =
            c1 -> reduced_chi2(
                wls_fit(
                    reference_intensity(
                        fw,
                        1.0,
                        0.0,
                        ξ_TRUE[1],
                        (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]),
                        c1,
                    ), wls,
                ),
            )
        fine_grid = range(CMIN - EPS, CMAX + EPS; length = 4001)
        best_fine = minimum(χ²_at(c1) for c1 in fine_grid)

        # c1_star must be at least as good as anything the fine grid found,
        # modulo Brent's own convergence tolerance.
        @test reduced_chi2(fit) <= best_fine + 1.0e-6
    end

    #------------------------------------------------------------------
    #                 AD-safety: envelope theorem through ForwardDiff
    #------------------------------------------------------------------

    # …(envelope theorem)
    @testset "profiled_corrs: differentiable through ξ via ForwardDiff" begin
        fw = pc_fw()
        wls = synth_wls(fw, 1.12; rel_noise = 0.02)

        χ²_of_ξ = x -> begin
            _, fit, _ = profiled_corrs(wls, SVector{4}(x), fw)
            reduced_chi2(fit)
        end

        x0 = collect(ξ_TRUE)
        g = ForwardDiff.gradient(χ²_of_ξ, x0)
        @test all(isfinite, g)

        # central finite-difference cross-check on one coordinate (ρₑ):
        # the envelope theorem says d(χ²)/dξ at fixed c1_star equals the
        # true total derivative at a profiled optimum, so this should agree
        # with the autodiff result to a loose tolerance.
        h = 1.0e-6
        xp = copy(x0)
        xp[1] += h
        xm = copy(x0)
        xm[1] -= h
        fd = (χ²_of_ξ(xp) - χ²_of_ξ(xm)) / (2h)
        @test close_(g[1], fd; atol = 1.0e-2)
    end

end

@testset "Gram column layout and A, B, C are generic in the number of contrasts" begin
    PC = BAYSOL.Inference

    @testset "_pair_col enumerates the envelope-free pairs in _GRAM_PAIRS order" begin
        nonex = (1, 3, 4, 5)   # species that carry a contrast in the five-species model
        for (c, (a, b)) in enumerate(BAYSOL.Scattering._GRAM_PAIRS[1:10])
            i, j = findfirst(==(a), nonex), findfirst(==(b), nonex)
            @test PC._pair_col(i, j, 4) == c
        end
        # the layout for any M is a bijection onto 1:M(M+1)/2
        for M in 1:7
            cols = [PC._pair_col(i, j, M) for i in 1:M for j in i:M]
            @test cols == collect(1:(M*(M+1)÷2))
        end
    end

    # …6 contrast species
    @testset "_intensity_terms! equals the quadratic form vᵀGv for M = 3, 4, 5" begin
        rng = MersenneTwister(7)
        Q = 9
        for M in (3, 4, 5, 6)
            nA = M * (M + 1) ÷ 2
            Gc = rand(rng, Q, nA + M + 1)
            ρ = 0.33
            a = (1.0, (0.3 * randn(rng) for _ in 2:M)...)
            # rebuild the symmetric (M+1)×(M+1) Gram matrix
            # per q; the excluded-volume species is last
            A = zeros(Q)
            B = zeros(Q)
            C = zeros(Q)
            PC._intensity_terms!(A, B, C, Gc, ρ, a)
            for q in 1:Q
                G = zeros(M + 1, M + 1)
                for i in 1:M, j in i:M
                    G[i, j] = G[j, i] = Gc[q, PC._pair_col(i, j, M)]
                end
                for i in 1:M
                    G[i, M+1] = G[M+1, i] = Gc[q, nA+i]
                end
                G[M+1, M+1] = Gc[q, nA+M+1]
                v = [collect(a); -ρ]
                @test close_(A[q] + B[q] + C[q], v' * G * v; atol = 1e-12)   # g = 1
                vA = [collect(a); 0.0]
                @test close_(A[q], vA' * G * vA; atol = 1e-12)
            end
        end
    end
end

@testset "the anchored envelope of the c1 passes" begin
    PC = BAYSOL.Inference
    fw = pc_fw()
    tab = PC._C1Tables(fw)
    ev = BAYSOL.Scattering.EV_EXP_COEFF
    lo, hi = tab.cmin - tab.eps, tab.cmax + tab.eps
    cs_test = vcat(
        collect(range(lo, hi; length = 301)),
        [lo, hi, tab.cs[3], tab.cs[3] + tab.eps / 2, 1.0],
    )
    # g(q; c1) = c1³·exp(−q²·(c1² − 1)·EV·r_m²), straight from the definition
    g_ref(c) = c^3 .* exp.(-(tab.qvals .^ 2) .* ((c^2 - 1) * ev * tab.r_m^2))

    @testset "_envelope! agrees with the definition over the whole window" begin
        g = zeros(length(tab.qvals))
        for c in cs_test
            PC._envelope!(g, tab, c)
            @test maximum(abs.(g ./ g_ref(c) .- 1)) ≤ 2e-15
        end
    end

    # …the exponential otherwise
    @testset "the Taylor branch is used where its argument is small" begin
        # a table whose q-range is huge forces the
        # fallback; both branches give the same envelope
        big = PC._C1Tables(
            tab.cs,
            tab.g1,
            tab.qvals,
            tab.r_m,
            tab.cmin,
            tab.cmax,
            tab.eps,
            1e6,
        )
        g1 = zeros(length(tab.qvals))
        g2 = zeros(length(tab.qvals))
        for c in (0.9, 1.07, 1.2)
            PC._envelope!(g1, tab, c)
            PC._envelope!(g2, big, c)
            @test maximum(abs.(g1 ./ g2 .- 1)) ≤ 2e-15
        end
        @test 1e6 * abs(PC._anchor(tab, 1.07, (1.07^2 - 1) * ev * tab.r_m^2)[3]) >
              PC.ENVELOPE_TAYLOR_LIMIT
        # a realistic offset is well inside the Taylor domain
        @test tab.q2max * 0.03 ≤ PC.ENVELOPE_TAYLOR_LIMIT
    end

    @testset "_sums_at equals the sums of the definition (and of the fallback branch)" begin
        ξ = ξ_TRUE
        A, B, C = BAYSOL.Scattering.intensity_terms(fw, ξ[1], (ξ[2], ξ[3], ξ[4]))
        wls = synth_wls(fw, 1.1; rel_noise = 0.01)
        big = PC._C1Tables(
            tab.cs,
            tab.g1,
            tab.qvals,
            tab.r_m,
            tab.cmin,
            tab.cmax,
            tab.eps,
            1e6,
        )
        for c in cs_test
            g = g_ref(c)
            ŷ = A .+ g .* (B .+ g .* C)
            ref = (
                sum(wls.weights .* ŷ),
                sum(wls.weights .* ŷ .^ 2),
                sum(wls.weights .* ŷ .* wls.I_obs),
            )
            @test all(isapprox.(PC._sums_at(A, B, C, tab, wls, c), ref; rtol = 1e-13))
            @test all(isapprox.(PC._sums_at(A, B, C, big, wls, c), ref; rtol = 1e-13))
        end
    end

    @testset "the c1 search result is unchanged by the anchoring" begin
        for c1_true in (0.9, 1.05, 1.2), rel_noise in (0.0, 0.01)
            wls = synth_wls(fw, c1_true; rel_noise)
            ŷ, fit, c1_star = profiled_corrs(wls, ξ_TRUE, fw)
            big = PC._C1Tables(
                tab.cs,
                tab.g1,
                tab.qvals,
                tab.r_m,
                tab.cmin,
                tab.cmax,
                tab.eps,
                1e6,
            )
            _, _, c1_exp = profiled_corrs(wls, ξ_TRUE, fw; tables = big)
            # two evaluations of the same χ² differing by ~1e-15 give Brent paths
            # that end up to about its own accuracy apart (a value-only minimizer
            # locates c1 to about √eps relative to the curvature, here up to ~1e-5)
            @test abs(c1_star - c1_exp) ≤ 1e-5
        end
    end
end
