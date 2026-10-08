# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Scattering/ForwardCache.jl (gram, excluded_volume_factor,
# mean_atomic_radius, forward_cache / ForwardCache) and species_multipoles
# (Scatterers.jl).
#
# `gram` is checked against `self_scatter` / `cross_scatter` assembled directly,
# on deterministic pseudo-random `B_lm` inputs: the assembly is linear in them and
# does not depend on where they came from, so there is no pipeline input on the
# reference side.
#
# The reference side re-does the composition by hand from the per-species
# primitives, so a mismatch is a wiring bug here, not a physics bug (the
# physics is checked in test_partialwave.jl / test_scatterers.jl).

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Scattering:  species_multipoles, forward_cache, ForwardCache, mean_atomic_radius,
                    excluded_volume_factor, gram, partial_wave_weights, self_scatter, cross_scatter, hydration,
                    intensity_terms, model_intensity, cavity_shell_fraction,
                    SHELL_THICKNESS, PROBE_RADIUS, SHELL_N_TARGET, B_LM_CHUNK
using BAYSOL.MolecularStructure: create, radii, vols
using BAYSOL.PhysicalConstants: DRO_UNIT
using LinearAlgebra: Symmetric, issymmetric, eigvals
using ForwardDiff

fwd_mol() = create("gly", ["n", "c", "c", "o", "o", "h", "h", "h"],
    [(-1.9, 0.2, 0.1), (-0.5, -0.3, 0.0), (0.6, 0.7, -0.1),
    ( 1.8, 0.2, 0.0), (0.4, 1.9, -0.2), (-2.6, -0.5, 0.0),
    (-0.4, -1.0, 0.8), (0.7, 1.3, 0.8)])
fwd_q      = [0.0, 0.03, 0.07, 0.15, 0.31]
fwd_E      = 9000.0
fwd_lmax   = 4
fwd_chunk  = UInt64(3)

# A packed-(l,m) B_lm array (C, K, Q) filled from a deterministic LCG so every
# run and every reader sees the same numbers.
function iy_B(C::Int, lMax::Int, Q::Int; seed::Int = 0)
    K = (lMax + 1) * (lMax + 2) ÷ 2
    B = Array{ComplexF64,3}(undef, C, K, Q)
    s = UInt64(seed) + 0x9e3779b97f4a7c15
    nextf() = (s = 6364136223846793005 * s + 1442695040888963407; Float64(s >> 11) / 2.0^53 - 0.5)
    @inbounds for i in eachindex(B)
        B[i] = complex(nextf(), nextf())
    end
    return B
end

iy_lMax = 3
iy_Q    = 5
iy_w    = partial_wave_weights(iy_lMax)

@testset "ForwardCache" begin

    @testset "module-level config constants" begin
        @test SHELL_THICKNESS === 3.0
        @test PROBE_RADIUS    === 1.4
        @test SHELL_N_TARGET  === nothing
        @test B_LM_CHUNK isa Unsigned
        # the primitives really do read these as their defaults
        m = fwd_mol()
        @test   hydration(m, fwd_q, 2, fwd_chunk) ==
                hydration(m, fwd_q, 2, fwd_chunk; thickness = SHELL_THICKNESS,
                        probe = PROBE_RADIUS, n_target = SHELL_N_TARGET)
    end

    @testset "species_multipoles: 5 species in canonical order" begin
        m  = fwd_mol()
        Bs = species_multipoles(m, fwd_q, fwd_lmax, fwd_E; chunk = fwd_chunk)
        @test length(Bs) == 5
        K = (fwd_lmax + 1) * (fwd_lmax + 2) ÷ 2
        @test all(B -> size(B, 2) == K && size(B, 3) == length(fwd_q), Bs)
        @test size(Bs[1], 1) == 2                     # vac: anomalous channels at 9 keV
        @test all(B -> size(B, 1) == 1, Bs[2:5])      # dummies: one real channel

        # the shell species are element-by-element identical to calling hydration directly
        ref_sh  = hydration(m, fwd_q, fwd_lmax, fwd_chunk)
        @test Bs[3] == ref_sh.convex
        @test Bs[4] == ref_sh.concave
        @test Bs[5] == ref_sh.cavity
    end

    @testset "mean_atomic_radius is the mean equivalent-sphere radius of the per-atom excluded volumes" begin
        # CRYSOL's r_m = N⁻¹ Σⱼ r_gj, r_gj = cbrt(3 V_j / 4π) -- the excluded-volume
        # dummy's own radius, not the atom's van der Waals radius.
        mo = fwd_mol()
        v  = vols(mo)
        ref = sum(cbrt(3.0 * vi / (4.0 * π)) for vi in v) / length(v)
        @test mean_atomic_radius(mo) ≈ ref
        # this is generally NOT the mean vdW radius, since the excluded-volume
        # table (h/c/n/o here) gives a smaller dummy than the isolated vdW sphere
        r = radii(mo)
        @test mean_atomic_radius(mo) < sum(r) / length(r)
    end

    @testset "excluded_volume_factor: c_1 == 1 is exactly the identity" begin
        rm = 1.62
        @test excluded_volume_factor(fwd_q, rm, 1.0) == ones(length(fwd_q))
    end

    @testset "excluded_volume_factor: q=0 scales the excluded volume by c_1^3" begin
        rm, c_1 = 1.62, 1.0987654320987654
        g = excluded_volume_factor([0.0], rm, c_1)
        @test g[1] ≈ c_1^3
    end

    @testset "excluded_volume_factor: exact for a dummy at the mean radius" begin
        # The single-envelope approximation is exact for an atom of radius r_m:
        # G(q)*f(V_m, q) must equal the directly-expanded dummy f(c_1^3*V_m, q).
        rm, c_1 = 1.62, 1.0555555555555556
        vm = (4π / 3) * rm^3
        gauss(v, q) = v * exp(-q^2 * v^(2 / 3) / (4π))
        g = excluded_volume_factor(fwd_q, rm, c_1)
        for (k, q) in enumerate(fwd_q)
            @test g[k] * gauss(vm, q) ≈ gauss(c_1^3 * vm, q)
        end
    end

    @testset "excluded_volume_factor: c_1 > 1 damps with q, c_1 < 1 lifts" begin
        rm = 1.62
        up   = excluded_volume_factor(fwd_q, rm, 1.8 / 1.62)
        down = excluded_volume_factor(fwd_q, rm, 1.4 / 1.62)
        # both start at c_1^3 and move monotonically in q away from it
        @test issorted(up ./ up[1];   rev = true)
        @test issorted(down ./ down[1])
    end

    @testset "excluded_volume_factor: domain errors" begin
        @test_throws DomainError excluded_volume_factor(fwd_q, 0.0, 1.6)
        @test_throws DomainError excluded_volume_factor(fwd_q, 1.6, -1.0)
    end

    @testset "forward_cache carries G, the q grid and r_m" begin
        mo = fwd_mol()
        fc = forward_cache(mo, fwd_q, fwd_lmax, fwd_E; chunk = fwd_chunk)
        @test fc isa ForwardCache
        @test size(fc.G) == (5, 5, length(fwd_q))
        for k in axes(fc.G, 3)
            @test issymmetric(fc.G[:, :, k])
            @test minimum(eigvals(fc.G[:, :, k])) > -1e-9
        end
        G_ref = gram(collect(species_multipoles(mo, fwd_q, fwd_lmax, fwd_E; chunk = fwd_chunk)),
                     partial_wave_weights(fwd_lmax))
        @test fc.G == G_ref
        @test fc.qvals == collect(Float64, fwd_q)
        @test fc.r_m == mean_atomic_radius(mo)
        @test fc.n_atoms == 8
        @test fc.lMax == fwd_lmax
    end


    @testset "DRO_UNIT is CRYSOL's --dro contrast unit" begin
        @test DRO_UNIT == 0.03
    end

    @testset "gram: shape, symmetry, and the self / cross diagonal identity" begin
        Bs = [iy_B(2, iy_lMax, iy_Q; seed = 1),
            iy_B(1, iy_lMax, iy_Q; seed = 2),
            iy_B(1, iy_lMax, iy_Q; seed = 3)]
        G = gram(Bs, iy_w)
        @test G isa Array{Float64,3}
        @test size(G) == (3, 3, iy_Q)
        for k in 1:iy_Q
            @test issymmetric(G[:, :, k])
        end
        # the diagonal is exactly self_scatter, and self_scatter == cross_scatter(B, B)
        for a in 1:3
            s = self_scatter(Bs[a], iy_w)
            @test G[a, a, :] == s
            @test cross_scatter(Bs[a], Bs[a], iy_w) == s
        end
        # the off-diagonal is exactly cross_scatter
        @test G[1, 2, :] == cross_scatter(Bs[1], Bs[2], iy_w)
        @test G[1, 3, :] == cross_scatter(Bs[1], Bs[3], iy_w)
        @test G[2, 3, :] == cross_scatter(Bs[2], Bs[3], iy_w)
    end

    @testset "gram: every G(:,:,q) is positive semidefinite" begin
        Bs = [iy_B(2, iy_lMax, iy_Q; seed = 7),
            iy_B(2, iy_lMax, iy_Q; seed = 8),
            iy_B(1, iy_lMax, iy_Q; seed = 9),
            iy_B(1, iy_lMax, iy_Q; seed = 10),
            iy_B(1, iy_lMax, iy_Q; seed = 11)]
        G = gram(Bs, iy_w)
        for k in 1:iy_Q
            λ = eigvals(Symmetric(G[:, :, k]))
            @test minimum(λ) ≥ -1e-9
        end
    end

    @testset "gram: single-species and all-zero edge cases" begin
        B0 = zeros(ComplexF64, 1, length(iy_w), iy_Q)
        @test all(iszero, gram([B0], iy_w))
        B1 = iy_B(1, iy_lMax, iy_Q; seed = 15)
        G1 = gram([B1], iy_w)
        @test size(G1) == (1, 1, iy_Q)
        @test G1[1, 1, :] == self_scatter(B1, iy_w)
        # a zero species contributes a zero row/column, nothing else
        G = gram([B1, B0], iy_w)
        @test all(iszero, G[1, 2, :]) && all(iszero, G[2, 2, :])
        @test G[1, 1, :] == self_scatter(B1, iy_w)
    end

    @testset "gram: shape guards" begin
        good = iy_B(1, iy_lMax, iy_Q; seed = 25)
        @test_throws ArgumentError gram(typeof(good)[], iy_w)                                # no species
        @test_throws ArgumentError gram([good], partial_wave_weights(iy_lMax + 1))           # K mismatch
        @test_throws ArgumentError gram([good, iy_B(1, iy_lMax, iy_Q + 1; seed = 26)], iy_w) # Q mismatch
    end

    # ---------------------------------------------------------------------
    # The contrast contraction (A, B, C), moved from Fitting into Scattering
    # ---------------------------------------------------------------------

    @testset "forward_cache: Gc is G repacked contiguous in q, pairs in _GRAM_PAIRS order" begin
        fc = forward_cache(fwd_mol(), fwd_q, fwd_lmax, fwd_E; chunk = fwd_chunk)
        @test size(fc.Gc) == (length(fwd_q), 15)
        for (j, (a, b)) in enumerate(BAYSOL.Scattering._GRAM_PAIRS)
            @test fc.Gc[:, j] == fc.G[a, b, :]
        end
        @test_throws ArgumentError BAYSOL.Scattering._pack_gram(zeros(3, 3, 4))
    end

    @testset "intensity_terms + model_intensity == the plain double sum vᵀGv, at every c₁" begin
        fc = forward_cache(fwd_mol(), fwd_q, fwd_lmax, fwd_E; chunk = fwd_chunk)
        ρ, δρ = 0.334, (1.2, -0.4, -2.5)
        A, B, C = intensity_terms(fc, ρ, δρ)
        @test length(A) == length(B) == length(C) == length(fwd_q)
        for c1 in (0.8, 1.0, 1.13, 1.3)
            g = excluded_volume_factor(fc.qvals, fc.r_m, c1)
            @test model_intensity(A, B, C, g) ≈ reference_intensity(fc, 1.0, 0.0, ρ, δρ, c1) rtol = 1e-10
        end
    end

    @testset "intensity_terms is ForwardDiff-differentiable in (ρₑ, δρ)" begin
        fc = forward_cache(fwd_mol(), fwd_q, fwd_lmax, fwd_E; chunk = fwd_chunk)
        g = excluded_volume_factor(fc.qvals, fc.r_m, 1.1)
        f(p) = sum(model_intensity(intensity_terms(fc, p[1], (p[2], p[3], p[4]))..., g))
        p0 = [0.334, 1.0, 0.5, -1.0]
        grad = ForwardDiff.gradient(f, p0)
        @test all(isfinite, grad)
        h = 1e-6
        for k in 1:4
            pp = copy(p0); pp[k] += h
            pm = copy(p0); pm[k] -= h
            @test grad[k] ≈ (f(pp) - f(pm)) / (2h) rtol = 1e-5
        end
    end

    @testset "cavity_shell_fraction: the cavity species' share of the shell volume, in [0, 1]" begin
        fc = forward_cache(fwd_mol(), fwd_q, fwd_lmax, fwd_E; chunk = fwd_chunk)
        f = cavity_shell_fraction(fc)
        @test 0.0 ≤ f ≤ 1.0
        # glycine has no sealed void, so no cavity beads
        @test f == 0.0
        v = [sqrt(max(fc.G[k, k, 1], 0.0)) for k in 3:5]
        @test f == v[3] / sum(v)
    end
end
