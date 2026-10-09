# SPDX-License-Identifier: LGPL-2.1-or-later

# Allocation guards for the fitting hot path.
#
#  * Kernels that are allocation-free are certified statically with AllocCheck (a failure means a
#    change introduced a possible heap allocation on a path that runs once per leapfrog step).
#  * Functions that still allocate have a byte budget per q point, measured on a toy structure.
#    The budgets are ceilings with ~15 % slack and only ever go down: lower them when an
#    allocation is removed, never raise one without saying why in the commit message.
#
# Context: GC was ~23 % of the 53-fit wall clock and 37-53 % of the MAP/NUTS/re-profile stages.
# One gradient call allocated ~260 bytes per q point (62 % ForwardDiff Dual vectors, 25 % the eight temporaries of
# `_scan_chi2`, now `_scan_chi2!`) until the analytic profile-likelihood gradient and Bumper temporaries (2026-10-08): now ~6.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using AllocCheck
using BAYSOL.Inference: WLSData, WLSFit, profiled_corrs, Solute, NonBiological
using BAYSOL.Scattering: forward_cache
using BAYSOL.MolecularStructure: MolecularStructure
using StaticArrays: SVector
using ForwardDiff
using Random

const ALC = BAYSOL.Inference

# 16 atoms on a helix (mixed n/c/o, non-planar), self-contained per this directory's convention.
function alc_mol()
    elms = repeat(["n", "c", "c", "o"], 4)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:(length(elms) - 1)]
    return MolecularStructure.create("alc", elms, crds)
end

const ALC_Q = 400   # large enough that the per-q term dominates the fixed overhead

function alc_seed()
    q = collect(range(0.0, 0.35; length = ALC_Q))
    fw = forward_cache(alc_mol(), q, 3, 9000.0; chunk = UInt64(4))
    y = reference_intensity(fw, 1.7, 0.3, CRYSOL_SOLVENT_DENSITY, (1.05, -0.05, -1.0), 1.1)
    σ = max.(abs.(y) .* 0.01, 1.0e-6)
    Random.seed!(0xA110C)
    I_exp = y .+ randn(length(y)) .* σ
    return ALC.seed_sampler(fw, I_exp, σ, 7.4, 0.05, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
end

@testset "Allocations" begin

    seed = alc_seed()
    fw, wls, tab, pr = seed.fw, seed.wls, seed.c1tab, seed.pr
    ξ = SVector(0.335, 1.0, 0.0, -1.0)
    A, B, C = ALC.intensity_terms(fw, ξ[1], (ξ[2], ξ[3], ξ[4]))

    @testset "kernels certified allocation-free (static, AllocCheck)" begin
        # the Brent inner pass: one fused loop per trial c1, runs ~13-20 times per gradient call
        @test isempty(AllocCheck.check_allocs(ALC._sums_at,
            (Vector{Float64}, Vector{Float64}, Vector{Float64}, typeof(tab), typeof(wls), Float64)))
        # the closed-form scale/background solve and its reduced χ²
        @test isempty(AllocCheck.check_allocs(ALC._wls_from_sums, (Float64, Float64, Float64, Int, typeof(wls))))
        @test isempty(AllocCheck.check_allocs(ALC.reduced_chi2, (WLSFit{Float64},)))
    end

    @testset "allocation budgets, bytes per q point (ratchet down, never up)" begin
        g(x) = ForwardDiff.gradient(z -> ALC._logπ(SVector{4}(z...), pr, wls, fw, ALC.PROFILE(); tab = tab), x)
        x0 = collect(ALC.Θ(ξ, pr)[1])
        # warm up, then measure
        chis = Vector{Float64}(undef, length(tab.cs))
        g(x0); profiled_corrs(wls, ξ, fw; tables = tab); ALC._scan_chi2!(chis, A, B, C, tab, wls)
        ALC.intensity_terms(fw, ξ[1], (ξ[2], ξ[3], ξ[4]))

        # measured at Q = 400, bytes per q point: intensity_terms 25 (unchanged), profiled_corrs 133 -> 8.5 (Bumper temporaries, one output vector); 2026-10-08: the
        # scan 65 -> 0.7 (Bumper work vectors), a whole gradient call 267 -> 6.1 (analytic gradient through
        # `_profile_ll_grad`, no dual-number vectors, Bumper temporaries)
        @test (@allocated ALC.intensity_terms(fw, ξ[1], (ξ[2], ξ[3], ξ[4]))) ≤ 30 * ALC_Q
        @test (@allocated ALC._scan_chi2!(chis, A, B, C, tab, wls)) ≤ 1 * ALC_Q
        @test (@allocated profiled_corrs(wls, ξ, fw; tables = tab)) ≤ 10 * ALC_Q
        @test (@allocated g(x0)) ≤ 7 * ALC_Q
        @test (@allocated ALC._profile_ll_grad(wls, ξ, fw, tab, 1e-8)) ≤ 1 * ALC_Q
    end
end
