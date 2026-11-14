# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests for src/inference/profiled-corrs.jl: the grid-pre-scan + Brent()
# profile search for c1 (CRYSOL's excluded-volume correction, no longer
# sampled with a prior) and the exclVolSaturation classifier built on
# top of it.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Inference: WLSData, wlsFit, reducedChi2, profiledCorrs, exclVolSaturation
using BAYSOL.Scattering: forwardCache, ForwardCache
using BAYSOL.MolecularStructure: MolecularStructure
using BAYSOL.Inference: EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS
using StaticArrays: SVector
using ForwardDiff
using Random

include(joinpath(@__DIR__, "..", "floatcompare.jl"))   # close_

const CMIN, CMAX = EXCL_VOL_CORR_BOUNDS
const EPS        = EXCL_VOL_CORR_EPS

# 16 atoms on a helix (mixed n/c/o, non-planar, non-degenerate) -- same
# shape of fixture as test-sampler.jl, self-contained here per this
# directory's one-file-one-concern convention.
function pcMol()
    elms = repeat(["n", "c", "c", "o"], 4)
    n = length(elms)
    crds = [(1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i) for i in 0:(n-1)]
    return MolecularStructure.create("pc", elms, crds)
end

const PC_Q = collect(range(0.02, 0.35; length = 12))
pcFw() = forwardCache(pcMol(), PC_Q, 3, 9000.0; chunk = UInt64(4))

# ξ = (ρₑ, δρ₁, δρ₂, δρ₃). This toy helix has no
# cavity beads, so δρ₃ does not affect the curve.
const ξ_TRUE = SVector(CRYSOL_SOLVENT_DENSITY, 1.5, 0.5, -1.0)

"""
Synthetic WLSData generated from `fw` at `ξ_TRUE`/`c1True`, with the given
relative noise (0 => an exact/noiseless curve, for recovery tests where the
true c1 must be located essentially exactly).
"""
function synthWls(fw::ForwardCache, c1True::Real; relNoise::Real = 0.0)
    y = referenceIntensity(
        fw,
        2.0,
        0.0005,
        ξ_TRUE[1],
        (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]),
        c1True,
    )
    σ = fill(max(relNoise, 1.0e-3) * maximum(abs.(y)), length(y))
    Random.seed!(0xC1_5EED)
    iExp = relNoise == 0 ? y : y .+ σ .* randn(length(y))
    return WLSData(iExp, σ)
end

@testset "ProfiledCorrs" begin

    #------------------------------------------------------------------
    #                 exclVolSaturation -- pure classifier
    #------------------------------------------------------------------

    @testset "exclVolSaturation: classifies strictly against (cmin, cmax)" begin
        @test exclVolSaturation(1.0; cmin = CMIN, cmax = CMAX) == 0
        # exactly on the bound: not saturated
        @test exclVolSaturation(CMIN; cmin = CMIN, cmax = CMAX) == 0
        @test exclVolSaturation(CMAX; cmin = CMIN, cmax = CMAX) == 0
        @test exclVolSaturation(CMIN - 1.0e-9; cmin = CMIN, cmax = CMAX) == -1
        @test exclVolSaturation(CMAX + 1.0e-9; cmin = CMIN, cmax = CMAX) == 1
        @test exclVolSaturation(0.5 * (CMIN + CMAX); cmin = CMIN, cmax = CMAX) == 0
    end

    #------------------------------------------------------------------
    #                 profiledCorrs -- interior recovery
    #------------------------------------------------------------------

    @testset "profiledCorrs: recovers a known interior c1 on a noiseless curve" begin
        fw = pcFw()
        c1True = 1.05
        wls = synthWls(fw, c1True)
        ŷ, fit, c1Star = profiledCorrs(wls, ξ_TRUE, fw)

        @test close_(c1Star, c1True; atol = 1.0e-4)
        @test close_(fit.chi2, 0.0; atol = 1e3 * DEFAULT_ATOL)
        @test exclVolSaturation(c1Star) == 0
        @test ŷ ≈ referenceIntensity(
            fw,
            1.0,
            0.0,
            ξ_TRUE[1],
            (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]),
            c1Star,
        )   # fused A + g·B + g²·C differs from the plain double sum by rounding only
    end

    #------------------------------------------------------------------
    #                 profiledCorrs -- genuine saturation, both directions
    #------------------------------------------------------------------

    # …when the true optimum is far below cmin
    @testset "profiledCorrs: saturates at the padded lower bound" begin
        fw = pcFw()
        wls = synthWls(fw, 0.5)   # well outside (cmin, cmax) = (0.8, 1.3)
        _, _, c1Star = profiledCorrs(wls, ξ_TRUE, fw)

        @test close_(c1Star, CMIN - EPS; atol = 1.0e-3)
        @test exclVolSaturation(c1Star) == -1
    end

    # …when the true optimum is above cmax
    @testset "profiledCorrs: saturates at the padded upper bound" begin
        fw = pcFw()
        # 1.33 is a deliberately modest excursion past cmax=1.3: χ²(c1) is not
        # globally monotone in c1 for a badly-wrong excluded-volume species
        # (the contrast-match point, where ρₑ·c1³·ΣV cancels the atoms'
        # electrons, sits at c1 ≈ 1.18 for this fixture), but at this c1True
        # it was checked on a 0.005 grid to decrease monotonically all the way
        # to the padded edge.
        wls = synthWls(fw, 1.33)
        _, _, c1Star = profiledCorrs(wls, ξ_TRUE, fw)

        @test close_(c1Star, CMAX + EPS; atol = 1.0e-3)
        @test exclVolSaturation(c1Star) == 1
    end

    #------------------------------------------------------------------
    #                 profiledCorrs -- independent optimality cross-check
    #------------------------------------------------------------------

    @testset "profiledCorrs: c1Star is not beaten by a much finer independent grid" begin
        fw = pcFw()
        wls = synthWls(fw, 1.12; relNoise = 0.02)
        _, fit, c1Star = profiledCorrs(wls, ξ_TRUE, fw)

        χ²_at =
            c1 -> reducedChi2(
                wlsFit(
                    referenceIntensity(
                        fw,
                        1.0,
                        0.0,
                        ξ_TRUE[1],
                        (ξ_TRUE[2], ξ_TRUE[3], ξ_TRUE[4]),
                        c1,
                    ), wls,
                ),
            )
        fineGrid = range(CMIN - EPS, CMAX + EPS; length = 4001)
        bestFine = minimum(χ²_at(c1) for c1 in fineGrid)

        # c1Star must be at least as good as anything the fine grid found,
        # modulo Brent's own convergence tolerance.
        @test reducedChi2(fit) <= bestFine + 1.0e-6
    end

    #------------------------------------------------------------------
    #                 AD-safety: envelope theorem through ForwardDiff
    #------------------------------------------------------------------

    # …(envelope theorem)
    @testset "profiledCorrs: differentiable through ξ via ForwardDiff" begin
        fw = pcFw()
        wls = synthWls(fw, 1.12; relNoise = 0.02)

        χ²_of_ξ = x -> begin
            _, fit, _ = profiledCorrs(wls, SVector{4}(x), fw)
            reducedChi2(fit)
        end

        x0 = collect(ξ_TRUE)
        g = ForwardDiff.gradient(χ²_of_ξ, x0)
        @test all(isfinite, g)

        # central finite-difference cross-check on one coordinate (ρₑ):
        # the envelope theorem says d(χ²)/dξ at fixed c1Star equals the
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
    pc = BAYSOL.Inference

    @testset "_pairCol enumerates the envelope-free pairs in _GRAM_PAIRS order" begin
        nonex = (1, 3, 4, 5)   # species that carry a contrast in the five-species model
        for (c, (a, b)) in enumerate(BAYSOL.Scattering._GRAM_PAIRS[1:10])
            i, j = findfirst(==(a), nonex), findfirst(==(b), nonex)
            @test pc._pairCol(i, j, 4) == c
        end
        # the layout for any M is a bijection onto 1:M(M+1)/2
        for M in 1:7
            cols = [pc._pairCol(i, j, M) for i in 1:M for j in i:M]
            @test cols == collect(1:(M*(M+1)÷2))
        end
    end

    # …6 contrast species
    @testset "_intensityTerms! equals the quadratic form vᵀGv for M = 3, 4, 5" begin
        rng = MersenneTwister(7)
        Q = 9
        for M in (3, 4, 5, 6)
            nA = M * (M + 1) ÷ 2
            gc = rand(rng, Q, nA + M + 1)
            ρ = 0.33
            a = (1.0, (0.3 * randn(rng) for _ in 2:M)...)
            # rebuild the symmetric (M+1)×(M+1) Gram matrix
            # per q; the excluded-volume species is last
            A = zeros(Q)
            B = zeros(Q)
            C = zeros(Q)
            pc._intensityTerms!(A, B, C, gc, ρ, a)
            for q in 1:Q
                G = zeros(M + 1, M + 1)
                for i in 1:M, j in i:M
                    G[i, j] = G[j, i] = gc[q, pc._pairCol(i, j, M)]
                end
                for i in 1:M
                    G[i, M+1] = G[M+1, i] = gc[q, nA+i]
                end
                G[M+1, M+1] = gc[q, nA+M+1]
                v = [collect(a); -ρ]
                @test close_(A[q] + B[q] + C[q], v' * G * v; atol = 1e-12)   # g = 1
                vA = [collect(a); 0.0]
                @test close_(A[q], vA' * G * vA; atol = 1e-12)
            end
        end
    end
end

@testset "the anchored envelope of the c1 passes" begin
    pc = BAYSOL.Inference
    fw = pcFw()
    tab = pc._C1Tables(fw)
    ev = BAYSOL.Scattering.EV_EXP_COEFF
    lo, hi = tab.cmin - tab.eps, tab.cmax + tab.eps
    csTest = vcat(
        collect(range(lo, hi; length = 301)),
        [lo, hi, tab.cs[3], tab.cs[3] + tab.eps / 2, 1.0],
    )
    # g(q; c1) = c1³·exp(−q²·(c1² − 1)·EV·r_m²), straight from the definition
    gRef(c) = c^3 .* exp.(-(tab.qvals .^ 2) .* ((c^2 - 1) * ev * tab.rM^2))

    @testset "_envelope! agrees with the definition over the whole window" begin
        g = zeros(length(tab.qvals))
        for c in csTest
            pc._envelope!(g, tab, c)
            @test maximum(abs.(g ./ gRef(c) .- 1)) ≤ 2e-15
        end
    end

    # …the exponential otherwise
    @testset "the Taylor branch is used where its argument is small" begin
        # a table whose q-range is huge forces the
        # fallback; both branches give the same envelope
        big = pc._C1Tables(
            tab.cs,
            tab.g1,
            tab.qvals,
            tab.rM,
            tab.cmin,
            tab.cmax,
            tab.eps,
            1e6,
        )
        g1 = zeros(length(tab.qvals))
        g2 = zeros(length(tab.qvals))
        for c in (0.9, 1.07, 1.2)
            pc._envelope!(g1, tab, c)
            pc._envelope!(g2, big, c)
            @test maximum(abs.(g1 ./ g2 .- 1)) ≤ 2e-15
        end
        @test 1e6 * abs(pc._anchor(tab, 1.07, (1.07^2 - 1) * ev * tab.rM^2)[3]) >
              pc.ENVELOPE_TAYLOR_LIMIT
        # a realistic offset is well inside the Taylor domain
        @test tab.q2max * 0.03 ≤ pc.ENVELOPE_TAYLOR_LIMIT
    end

    @testset "_sumsAt equals the sums of the definition (and of the fallback branch)" begin
        ξ = ξ_TRUE
        A, B, C = BAYSOL.Scattering.intensityTerms(fw, ξ[1], (ξ[2], ξ[3], ξ[4]))
        wls = synthWls(fw, 1.1; relNoise = 0.01)
        big = pc._C1Tables(
            tab.cs,
            tab.g1,
            tab.qvals,
            tab.rM,
            tab.cmin,
            tab.cmax,
            tab.eps,
            1e6,
        )
        for c in csTest
            g = gRef(c)
            ŷ = A .+ g .* (B .+ g .* C)
            ref = (
                sum(wls.weights .* ŷ),
                sum(wls.weights .* ŷ .^ 2),
                sum(wls.weights .* ŷ .* wls.iObs),
            )
            @test all(isapprox.(pc._sumsAt(A, B, C, tab, wls, c), ref; rtol = 1e-13))
            @test all(isapprox.(pc._sumsAt(A, B, C, big, wls, c), ref; rtol = 1e-13))
        end
    end

    @testset "the c1 search result is unchanged by the anchoring" begin
        for c1True in (0.9, 1.05, 1.2), relNoise in (0.0, 0.01)
            wls = synthWls(fw, c1True; relNoise)
            ŷ, fit, c1Star = profiledCorrs(wls, ξ_TRUE, fw)
            big = pc._C1Tables(
                tab.cs,
                tab.g1,
                tab.qvals,
                tab.rM,
                tab.cmin,
                tab.cmax,
                tab.eps,
                1e6,
            )
            _, _, c1Exp = profiledCorrs(wls, ξ_TRUE, fw; tables = big)
            # two evaluations of the same χ² differing by ~1e-15 give Brent paths
            # that end up to about its own accuracy apart (a value-only minimizer
            # locates c1 to about √eps relative to the curvature, here up to ~1e-5)
            @test abs(c1Star - c1Exp) ≤ 1e-5
        end
    end
end
