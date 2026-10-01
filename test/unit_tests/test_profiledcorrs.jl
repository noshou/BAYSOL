# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Fitting/ProfiledCorrs.jl: the grid-pre-scan + Brent()
# profile search for c1 (CRYSOL's excluded-volume correction, no longer
# sampled with a prior) and the excl_vol_saturation classifier built on
# top of it.

include(joinpath(@__DIR__, "testsetup.jl"))

using BAYSOL.Fitting: WLSData, wls_fit, reduced_chi2, profiled_corrs, excl_vol_saturation
using BAYSOL.Scattering: forward, forward_cache, ForwardCache
using BAYSOL.MolecularStructure: MolecularStructure
using BAYSOL.Constants: EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS
using StaticArrays: SVector
using ForwardDiff
using Random

include(joinpath(@__DIR__, "..", "fixtures", "functions", "floatcompare.jl"))   # close_

const CMIN, CMAX = EXCL_VOL_CORR_BOUNDS
const EPS        = EXCL_VOL_CORR_EPS

# 16 atoms on a helix (mixed n/c/o, non-planar, non-degenerate) -- same
# shape of fixture as test_sampler.jl, self-contained here per this
# directory's one-file-one-concern convention.
function pc_mol()
    elms = repeat(["n", "c", "c", "o"], 4)
    n = length(elms)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:(n - 1)]
    return MolecularStructure.create("pc", elms, crds)
end

const pc_q = collect(range(0.02, 0.35; length = 12))
pc_fw() = forward_cache(pc_mol(), pc_q, 3, 9000.0; chunk = UInt64(4))

# ξ = (ρₑ, δρ₁, δρ₂, δρ₃). This toy helix has no cavity beads, so δρ₃ does not affect the curve.
const ξ_TRUE = SVector(0.334, 1.5, 0.5, -1.0)

"""
Synthetic WLSData generated from `fw` at `ξ_TRUE`/`c1_true`, with the given
relative noise (0 => an exact/noiseless curve, for recovery tests where the
true c1 must be located essentially exactly).
"""
function synth_wls(fw::ForwardCache, c1_true::Real; rel_noise::Real = 0.0)
    y = forward(fw, 2.0, 0.0005, ξ_TRUE[1], (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]), c1_true)
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
        @test excl_vol_saturation(1.0; cmin=CMIN, cmax=CMAX) == 0
        @test excl_vol_saturation(CMIN; cmin=CMIN, cmax=CMAX) == 0       # exactly on the bound: not saturated
        @test excl_vol_saturation(CMAX; cmin=CMIN, cmax=CMAX) == 0
        @test excl_vol_saturation(CMIN - 1.0e-9; cmin=CMIN, cmax=CMAX) == -1
        @test excl_vol_saturation(CMAX + 1.0e-9; cmin=CMIN, cmax=CMAX) == 1
        @test excl_vol_saturation(0.5 * (CMIN + CMAX); cmin=CMIN, cmax=CMAX) == 0
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
        @test close_(fit.chi2, 0.0; atol = 1.0e-6)
        @test excl_vol_saturation(c1_star) == 0
        @test ŷ == forward(fw, 1.0, 0.0, ξ_TRUE[1], (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]), c1_star)
    end

    #------------------------------------------------------------------
    #                 profiled_corrs -- genuine saturation, both directions
    #------------------------------------------------------------------

    @testset "profiled_corrs: saturates at the padded lower bound when the true optimum is far below cmin" begin
        fw = pc_fw()
        wls = synth_wls(fw, 0.5)   # well outside (cmin, cmax) = (0.8, 1.3)
        _, _, c1_star = profiled_corrs(wls, ξ_TRUE, fw)

        @test close_(c1_star, CMIN - EPS; atol = 1.0e-3)
        @test excl_vol_saturation(c1_star) == -1
    end

    @testset "profiled_corrs: saturates at the padded upper bound when the true optimum is above cmax" begin
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

        χ²_at = c1 -> reduced_chi2(wls_fit(
            forward(fw, 1.0, 0.0, ξ_TRUE[1], (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]), c1), wls
        ))
        fine_grid = range(CMIN - EPS, CMAX + EPS; length = 4001)
        best_fine = minimum(χ²_at(c1) for c1 in fine_grid)

        # c1_star must be at least as good as anything the fine grid found,
        # modulo Brent's own convergence tolerance.
        @test reduced_chi2(fit) <= best_fine + 1.0e-6
    end

    #------------------------------------------------------------------
    #                 AD-safety: envelope theorem through ForwardDiff
    #------------------------------------------------------------------

    @testset "profiled_corrs: differentiable through ξ via ForwardDiff (envelope theorem)" begin
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
        xp = copy(x0); xp[1] += h
        xm = copy(x0); xm[1] -= h
        fd = (χ²_of_ξ(xp) - χ²_of_ξ(xm)) / (2h)
        @test close_(g[1], fd; atol = 1.0e-2)
    end

end
