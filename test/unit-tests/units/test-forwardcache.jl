# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/scattering/forward-cache.jl (gram, excludedVolumeFactor,
# meanAtomicRadius, forwardCache / ForwardCache) and speciesMultipoles
# (scatterers.jl).
#
# `gram` is checked against `selfScatter` / `crossScatter` assembled directly,
# on deterministic pseudo-random `B_lm` inputs: the assembly is linear in them and
# does not depend on where they came from, so there is no pipeline input on the
# reference side.
#
# The reference side re-does the composition by hand from the per-species
# primitives, so a mismatch is a wiring bug here, not a physics bug (the
# physics is checked in test-partialwave.jl / test-scatterers.jl).

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Scattering: speciesMultipoles, forwardCache, ForwardCache,
    meanAtomicRadius,
    excludedVolumeFactor, gram, partialWaveWeights, selfScatter, crossScatter,
    hydration,
    intensityTerms, modelIntensity, cavityShellFraction,
    SHELL_THICKNESS, PROBE_RADIUS, B_LM_CHUNK
using BAYSOL.MolecularStructure: create, radii, vols
using BAYSOL.PhysicalConstants: UNIT_OF_δρ
using LinearAlgebra: Symmetric, issymmetric, eigvals
using ForwardDiff

fwdMol() = create("gly", ["n", "c", "c", "o", "o", "h", "h", "h"],
    [(-1.9, 0.2, 0.1), (-0.5, -0.3, 0.0), (0.6, 0.7, -0.1),
        (1.8, 0.2, 0.0), (0.4, 1.9, -0.2), (-2.6, -0.5, 0.0),
        (-0.4, -1.0, 0.8), (0.7, 1.3, 0.8)])
fwdQ = [0.0, 0.03, 0.07, 0.15, 0.31]
fwdE = 9000.0
fwdLmax = 4
fwdChunk = UInt64(3)

# A packed-(l,m) B_lm array (C, K, Q) filled from a deterministic LCG so every
# run and every reader sees the same numbers.
function iyB(C::Int, lMax::Int, Q::Int; seed::Int = 0)
    K = (lMax + 1) * (lMax + 2) ÷ 2
    B = Array{ComplexF64,3}(undef, C, K, Q)
    s = UInt64(seed) + 0x9e3779b97f4a7c15
    nextf() =
        (s = 6364136223846793005 * s + 1442695040888963407; Float64(s >> 11) / 2.0^53 - 0.5)
    @inbounds for i in eachindex(B)
        B[i] = complex(nextf(), nextf())
    end
    return B
end

iyLmax = 3
iyQ    = 5
iyW    = partialWaveWeights(iyLmax)

@testset "ForwardCache" begin

    @testset "module-level config constants" begin
        @test SHELL_THICKNESS === 3.0
        @test PROBE_RADIUS === 1.4
        @test B_LM_CHUNK isa Unsigned
        # the primitives really do read these as their defaults
        m = fwdMol()
        @test hydration(m, fwdQ, 2, fwdChunk) ==
              hydration(m, fwdQ, 2, fwdChunk; thickness = SHELL_THICKNESS,
            probe = PROBE_RADIUS, nTarget = nothing)
    end

    @testset "speciesMultipoles: 5 species in canonical order" begin
        m  = fwdMol()
        bs = speciesMultipoles(m, fwdQ, fwdLmax, fwdE; chunk = fwdChunk)
        @test length(bs) == 5
        K = (fwdLmax + 1) * (fwdLmax + 2) ÷ 2
        @test all(B -> size(B, 2) == K && size(B, 3) == length(fwdQ), bs)
        @test size(bs[1], 1) == 2                     # vac: anomalous channels at 9 keV
        @test all(B -> size(B, 1) == 1, bs[2:5])      # dummies: one real channel

        # the shell species are element-by-element identical to calling hydration directly
        refSh = hydration(m, fwdQ, fwdLmax, fwdChunk)
        @test bs[3] == refSh.convex
        @test bs[4] == refSh.concave
        @test bs[5] == refSh.cavity
    end

    # …of the per-atom excluded volumes
    @testset "meanAtomicRadius is the mean equivalent-sphere radius" begin
        # CRYSOL's rM = N⁻¹ Σⱼ r_gj, r_gj = cbrt(3 V_j / 4π) -- the excluded-volume
        # dummy's own radius, not the atom's van der Waals radius.
        mo = fwdMol()
        v = vols(mo)
        ref = sum(cbrt(3.0 * vi / (4.0 * π)) for vi in v) / length(v)
        @test meanAtomicRadius(mo) ≈ ref
        # this is generally NOT the mean vdW radius, since the excluded-volume
        # table (h/c/n/o here) gives a smaller dummy than the isolated vdW sphere
        r = radii(mo)
        @test meanAtomicRadius(mo) < sum(r) / length(r)
    end

    @testset "excludedVolumeFactor: c1Factor == 1 is exactly the identity" begin
        rm = 1.62
        @test excludedVolumeFactor(fwdQ, rm, 1.0) == ones(length(fwdQ))
    end

    @testset "excludedVolumeFactor: q=0 scales the excluded volume by c1Factor^3" begin
        rm, c1Factor = 1.62, 1.0987654320987654
        g = excludedVolumeFactor([0.0], rm, c1Factor)
        @test g[1] ≈ c1Factor^3
    end

    @testset "excludedVolumeFactor: exact for a dummy at the mean radius" begin
        # The single-envelope approximation is exact for an atom of radius rM:
        # G(q)*f(V_m, q) must equal the directly-expanded dummy f(c1Factor^3*V_m, q).
        rm, c1Factor = 1.62, 1.0555555555555556
        vm = (4π / 3) * rm^3
        gauss(v, q) = v * exp(-q^2 * v^(2 / 3) / (4π))
        g = excludedVolumeFactor(fwdQ, rm, c1Factor)
        for (k, q) in enumerate(fwdQ)
            @test g[k] * gauss(vm, q) ≈ gauss(c1Factor^3 * vm, q)
        end
    end

    @testset "excludedVolumeFactor: c1Factor > 1 damps with q, c1Factor < 1 lifts" begin
        rm   = 1.62
        up   = excludedVolumeFactor(fwdQ, rm, 1.8 / 1.62)
        down = excludedVolumeFactor(fwdQ, rm, 1.4 / 1.62)
        # both start at c1Factor^3 and move monotonically in q away from it
        @test issorted(up ./ up[1]; rev = true)
        @test issorted(down ./ down[1])
    end

    @testset "excludedVolumeFactor: domain errors" begin
        @test_throws DomainError excludedVolumeFactor(fwdQ, 0.0, 1.6)
        @test_throws DomainError excludedVolumeFactor(fwdQ, 1.6, -1.0)
    end

    @testset "forwardCache carries G, the q grid and rM" begin
        mo = fwdMol()
        fc = forwardCache(mo, fwdQ, fwdLmax, fwdE; chunk = fwdChunk)
        @test fc isa ForwardCache
        @test size(fc.G) == (5, 5, length(fwdQ))
        for k in axes(fc.G, 3)
            @test issymmetric(fc.G[:, :, k])
            @test minimum(eigvals(fc.G[:, :, k])) > -1e-9
        end
        gRef =
            gram(collect(speciesMultipoles(mo, fwdQ, fwdLmax, fwdE; chunk = fwdChunk)),
                partialWaveWeights(fwdLmax))
        @test fc.G == gRef
        @test fc.qvals == collect(Float64, fwdQ)
        @test fc.rM == meanAtomicRadius(mo)
        @test fc.nAtoms == 8
        @test fc.lMax == fwdLmax
    end


    @testset "UNIT_OF_δρ is CRYSOL's --dro contrast unit" begin
        @test UNIT_OF_δρ == 0.03
    end

    @testset "gram: shape, symmetry, and the self / cross diagonal identity" begin
        bs = [iyB(2, iyLmax, iyQ; seed = 1),
            iyB(1, iyLmax, iyQ; seed = 2),
            iyB(1, iyLmax, iyQ; seed = 3)]
        G = gram(bs, iyW)
        @test G isa Array{Float64,3}
        @test size(G) == (3, 3, iyQ)
        for k in 1:iyQ
            @test issymmetric(G[:, :, k])
        end
        # the diagonal is exactly selfScatter, and selfScatter == crossScatter(B, B)
        for a in 1:3
            s = selfScatter(bs[a], iyW)
            @test G[a, a, :] == s
            @test crossScatter(bs[a], bs[a], iyW) == s
        end
        # the off-diagonal is exactly crossScatter
        @test G[1, 2, :] == crossScatter(bs[1], bs[2], iyW)
        @test G[1, 3, :] == crossScatter(bs[1], bs[3], iyW)
        @test G[2, 3, :] == crossScatter(bs[2], bs[3], iyW)
    end

    @testset "gram: every G(:,:,q) is positive semidefinite" begin
        bs = [iyB(2, iyLmax, iyQ; seed = 7),
            iyB(2, iyLmax, iyQ; seed = 8),
            iyB(1, iyLmax, iyQ; seed = 9),
            iyB(1, iyLmax, iyQ; seed = 10),
            iyB(1, iyLmax, iyQ; seed = 11)]
        G = gram(bs, iyW)
        for k in 1:iyQ
            λ = eigvals(Symmetric(G[:, :, k]))
            @test minimum(λ) ≥ -1e-9
        end
    end

    @testset "gram: single-species and all-zero edge cases" begin
        b0 = zeros(ComplexF64, 1, length(iyW), iyQ)
        @test all(iszero, gram([b0], iyW))
        b1 = iyB(1, iyLmax, iyQ; seed = 15)
        g1 = gram([b1], iyW)
        @test size(g1) == (1, 1, iyQ)
        @test g1[1, 1, :] == selfScatter(b1, iyW)
        # a zero species contributes a zero row/column, nothing else
        G = gram([b1, b0], iyW)
        @test all(iszero, G[1, 2, :]) && all(iszero, G[2, 2, :])
        @test G[1, 1, :] == selfScatter(b1, iyW)
    end

    @testset "gram: shape guards" begin
        good = iyB(1, iyLmax, iyQ; seed = 25)
        # no species
        @test_throws ArgumentError gram(typeof(good)[], iyW)
        # K mismatch
        @test_throws ArgumentError gram([good], partialWaveWeights(iyLmax + 1))
        # Q mismatch
        @test_throws ArgumentError gram([good, iyB(1, iyLmax, iyQ + 1; seed = 26)], iyW)
    end

    # ---------------------------------------------------------------------
    # The contrast contraction (A, B, C), moved from Inference into Scattering
    # ---------------------------------------------------------------------

    # …in _GRAM_PAIRS order
    @testset "forwardCache: Gc is G repacked contiguous in q, pairs" begin
        fc = forwardCache(fwdMol(), fwdQ, fwdLmax, fwdE; chunk = fwdChunk)
        @test size(fc.gc) == (length(fwdQ), 15)
        for (j, (a, b)) in enumerate(BAYSOL.Scattering._GRAM_PAIRS)
            @test fc.gc[:, j] == fc.G[a, b, :]
        end
        @test_throws ArgumentError BAYSOL.Scattering._packGram(zeros(3, 3, 4))
    end

    # …at every c₁
    @testset "intensityTerms + modelIntensity == the plain double sum vᵀGv" begin
        fc = forwardCache(fwdMol(), fwdQ, fwdLmax, fwdE; chunk = fwdChunk)
        ρ, δρ = 0.334, (1.2, -0.4, -2.5)
        A, B, C = intensityTerms(fc, ρ, δρ)
        @test length(A) == length(B) == length(C) == length(fwdQ)
        for c1 in (0.8, 1.0, 1.13, 1.3)
            g = excludedVolumeFactor(fc.qvals, fc.rM, c1)
            want = referenceIntensity(fc, 1.0, 0.0, ρ, δρ, c1)
            @test modelIntensity(A, B, C, g) ≈ want rtol = 1e-10
        end
    end

    @testset "intensityTerms is ForwardDiff-differentiable in (ρₑ, δρ)" begin
        fc = forwardCache(fwdMol(), fwdQ, fwdLmax, fwdE; chunk = fwdChunk)
        g = excludedVolumeFactor(fc.qvals, fc.rM, 1.1)
        f(p) = sum(modelIntensity(intensityTerms(fc, p[1], (p[2], p[3], p[4]))..., g))
        p0 = [0.334, 1.0, 0.5, -1.0]
        grad = ForwardDiff.gradient(f, p0)
        @test all(isfinite, grad)
        h = 1e-6
        for k in 1:4
            pp = copy(p0)
            pp[k] += h
            pm = copy(p0)
            pm[k] -= h
            @test grad[k] ≈ (f(pp) - f(pm)) / (2h) rtol = 1e-5
        end
    end

    # …in [0, 1]
    @testset "cavityShellFraction: the cavity species' share of the shell volume" begin
        fc = forwardCache(fwdMol(), fwdQ, fwdLmax, fwdE; chunk = fwdChunk)
        f = cavityShellFraction(fc)
        @test 0.0 ≤ f ≤ 1.0
        # glycine has no sealed void, so no cavity beads
        @test f == 0.0
        v = [sqrt(max(fc.G[k, k, 1], 0.0)) for k in 3:5]
        @test f == v[3] / sum(v)
    end
end
