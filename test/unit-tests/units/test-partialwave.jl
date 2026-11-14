# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/scattering/partial-wave.jl at the unit level: the packed (l, m)
# ordering shared by `partialWaveWeights` and `computeBLm`, the real/imaginary
# two-channel split, chunking invariance,
# linearity/additivity of B_lm, and the algebraic identities relating
# `selfScatter` and `crossScatter`.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using BAYSOL.Scattering:
    SharedAmplitude, computeBLm, partialWaveWeights, selfScatter, crossScatter
using BAYSOL.Scattering: BESS_CUT
using SpecialFunctions: sphericalbesselj
using BAYSOL.MolecularStructure: create, coordsSpherical, toSpherical

# packed row offsets, duplicated here by hand so the tests pin the convention
# rather than inheriting it from the code under test
pwIdx(l, m) = l * (l + 1) ÷ 2 + m + 1
pwNrows(lMax) = (lMax + 1) * (lMax + 2) ÷ 2

# Straight transcription of the definition in the module docstring:
#   B_lm(q) = Σ_i f_i(q) * j_l(q r_i) * conj(Y_lm(θ_i, φ_i))
function pwNaiveB(coordsSph, qvals, fAtoms, lMax)
    N = size(coordsSph, 2)
    Q = length(qvals)
    B = zeros(ComplexF64, pwNrows(lMax), Q)
    for i in 1:N
        Y = sphHarm(lMax, [coordsSph[2, i]], [coordsSph[3, i]])   # (K, 1)
        for l in 0:lMax, m in 0:l
            k = pwIdx(l, m)
            for qi in 1:Q
                B[k, qi] +=
                    fAtoms[i, qi] * sphericalbesselj(l, qvals[qi] * coordsSph[1, i]) *
                    conj(Y[k, 1])
            end
        end
    end
    return B
end

# A fixed 5-atom geometry plus a fixed q-grid and amplitude matrix.
pwCart = [0.0 1.3 -2.1 0.4 1.7;
    0.0 -0.7 1.1 2.2 -1.9;
    1.5 0.9 0.3 -1.4 0.6]
pwSph = toSpherical(pwCart)
pwQ = [0.0, 0.15, 0.4, 0.9]
# amplitudes decaying with q, distinct per atom, all real
pwF = [(1.0 + 0.5i) * exp(-0.3 * q^2) for i in 1:5, q in pwQ]

@testset "PartialWave" begin

    @testset "partialWaveWeights: exact values and packed layout" begin
        # (0,0), (1,0), (1,1), (2,0), (2,1), (2,2), m = 0..l
        @test partialWaveWeights(0) == [1.0]
        @test partialWaveWeights(1) == [1.0, 1.0, 2.0]
        @test partialWaveWeights(2) == [1.0, 1.0, 2.0, 1.0, 2.0, 2.0]
        @test partialWaveWeights(3) == [1.0, 1.0, 2.0, 1.0, 2.0, 2.0, 1.0, 2.0, 2.0, 2.0]
        @test partialWaveWeights(2) isa Vector{Float64}
    end

    @testset "partialWaveWeights: the 1.0 entries land exactly on m = 0" begin
        # this is the load-bearing indexing claim; the weight vector is
        # consumed positionally against B_lm's packed second axis
        for lMax in 0:6
            w = partialWaveWeights(lMax)
            @test length(w) == pwNrows(lMax)
            for l in 0:lMax, m in 0:l
                @test w[pwIdx(l, m)] == (m == 0 ? 1.0 : 2.0)
            end
            # equivalently: exactly lMax+1 ones, the rest twos
            @test count(==(1.0), w) == lMax + 1
            @test count(==(2.0), w) == length(w) - (lMax + 1)
        end
        # a larger lMax only appends; the prefix is untouched
        @test partialWaveWeights(6)[1:pwNrows(3)] == partialWaveWeights(3)
    end

    @testset "partialWaveWeights exception contract" begin
        @test_throws ArgumentError partialWaveWeights(-1)
        @test_throws ArgumentError partialWaveWeights(-4)
        # lMax = 0 is the boundary of the valid range, not an error
        @test partialWaveWeights(0) == [1.0]
    end

    @testset "computeBLm matches the naive Σ_i f j_l conj(Y_lm) definition" begin
        # the single most important test in this file: an independent
        # transcription of the defining formula, atom by atom
        for lMax in 0:3
            B = computeBLm(pwSph, pwQ, pwF, lMax, UInt64(2))
            ref = pwNaiveB(pwSph, pwQ, pwF, lMax)
            @test size(B) == (1, pwNrows(lMax), length(pwQ))
            for k in 1:pwNrows(lMax), qi in eachindex(pwQ)
                @test checkComplex(B[1, k, qi], ref[k, qi])
            end
        end
    end

    @testset "computeBLm: negligible-Bessel cut still matches the naive definition" begin
        # small radii (x = q·r ≲ 2.4) at lMax = 12: most high-degree columns fall
        # below x_cut(l) and are skipped, yet B must still match the full sum
        lMax = 12
        B = computeBLm(pwSph, pwQ, pwF, lMax, UInt64(2))
        ref = pwNaiveB(pwSph, pwQ, pwF, lMax)
        # each skipped term is ≤ BESS_CUT·|f|·|Y_lm|, and |Y_lm| ≤ √((2l+1)/4π)
        bound =
            size(pwSph, 2) * BESS_CUT * maximum(abs, pwF) * sqrt((2lMax + 1) / 4π) +
            DEFAULT_ATOL
        for k in 1:pwNrows(lMax), qi in eachindex(pwQ)
            @test abs(B[1, k, qi] - ref[k, qi]) ≤ bound
        end
        # unsorted q takes the uncut path: the same result within that bound
        perm = [3, 1, 4, 2]
        bu = computeBLm(pwSph, pwQ[perm], pwF[:, perm], lMax, UInt64(2))
        @test all(
            abs(bu[1, k, j] - B[1, k, perm[j]]) ≤ bound for k in 1:pwNrows(lMax), j in 1:4
        )
        @test all(
            checkComplex(bu[1, k, j], ref[k, perm[j]]) for k in 1:pwNrows(lMax), j in 1:4
        )
    end

    # …without building it
    @testset "SharedAmplitude: the multipoles of an explicit matrix of equal rows" begin
        n = size(pwSph, 2)
        for fvec in (
            [exp(-0.3 * q^2) for q in pwQ],
            [(1.0 + 0.5im) * exp(-0.3 * q^2) for q in pwQ],
        )
            for lMax in (0, 2, 4)
                bs = computeBLm(pwSph, pwQ, SharedAmplitude(fvec, n), lMax, UInt64(2))
                bm = computeBLm(
                    pwSph,
                    pwQ,
                    repeat(reshape(fvec, 1, :), n, 1),
                    lMax,
                    UInt64(2),
                )
                @test size(bs) == size(bm)
                @test isapprox(bs, bm; rtol = 1e-12, atol = 1e-14)
            end
        end
        @test size(SharedAmplitude([1.0, 2.0, 3.0], 5)) == (5, 3)
        @test SharedAmplitude([1.0, 2.0, 3.0], 5)[4, 2] == 2.0
    end

    # …(they are processed by radius)
    @testset "computeBLm does not depend on the order of the atoms" begin
        rng = MersenneTwister(4)
        cart = 6 .* randn(rng, 3, 60)
        sph = toSpherical(cart)
        q = collect(range(0.0, 0.5; length = 25))
        f = [(1.0 + 0.1 * i) * exp(-0.2 * qq^2) + 0.05im * i for i in 1:60, qq in q]
        for lMax in (3, 12)
            B = computeBLm(sph, q, f, lMax, UInt64(7))
            perm = randperm(rng, 60)
            bp = computeBLm(sph[:, perm], q, f[perm, :], lMax, UInt64(7))
            @test isapprox(bp, B; rtol = 1e-11, atol = 1e-13 * maximum(abs, B))
            # another chunk size regroups the atoms into tiles, hence
            # other negligible-Bessel cuts: equal up to that cut (1e-9)
            @test isapprox(
                computeBLm(sph, q, f, lMax, UInt64(60)),
                B;
                rtol = 0,
                atol = 1e-8 * maximum(abs, B),
            )
        end
    end

    @testset "computeBLm output shape and element type" begin
        for lMax in 0:4
            B = computeBLm(pwSph, pwQ, pwF, lMax, UInt64(3))
            @test size(B) == (1, pwNrows(lMax), length(pwQ))
            @test eltype(B) <: Complex
            @test B isa AbstractArray{<:Complex,3}
        end
    end

    @testset "computeBLm: B_00 = (1/sqrt(4pi)) * Σ_i f_i j_0(q r_i)" begin
        # Y_00 = 1/sqrt(4π) is real and constant, so the l = 0 multipole has a
        # closed form independent of the harmonics machinery
        B = computeBLm(pwSph, pwQ, pwF, 0, UInt64(5))
        j0(x) = x == 0.0 ? 1.0 : sin(x) / x
        for (qi, q) in enumerate(pwQ)
            ref =
                sum(pwF[i, qi] * j0(q * pwSph[1, i]) for i in 1:size(pwSph, 2)) /
                sqrt(4π)
            @test checkComplex(B[1, 1, qi], complex(ref))
        end
    end

    @testset "computeBLm channel count follows the imaginary part" begin
        fReal = real.(pwF)
        fCplx = pwF .+ 0.4im .* pwF          # genuinely complex
        fZeroimag = ComplexF64.(fReal)        # complex type, all-zero imaginary part

        @test size(computeBLm(pwSph, pwQ, fReal, 2, UInt64(2)), 1) == 1
        @test size(computeBLm(pwSph, pwQ, fCplx, 2, UInt64(2)), 1) == 2
        # the `any(x -> imag(x) != 0, ...)` branch: complex *type* is not enough,
        # a numerically zero imaginary part still collapses to one channel
        @test size(computeBLm(pwSph, pwQ, fZeroimag, 2, UInt64(2)), 1) == 1
        # a single nonzero imaginary entry anywhere flips it to two channels
        fOne = ComplexF64.(fReal)
        fOne[3, 2] += 1e-8im
        @test size(computeBLm(pwSph, pwQ, fOne, 2, UInt64(2)), 1) == 2
    end

    @testset "computeBLm channels are B(Re f) and B(Im f) separately" begin
        # load-bearing claim of the whole two-channel design: the channels are
        # not a repacking of one complex B_lm, they are two independent
        # real-amplitude expansions
        fCplx = pwF .+ [(0.2i - 0.05q) * im for i in 1:5, q in eachindex(pwQ)]
        lMax = 3
        B = computeBLm(pwSph, pwQ, fCplx, lMax, UInt64(2))
        bre = computeBLm(pwSph, pwQ, real.(fCplx), lMax, UInt64(2))
        bim = computeBLm(pwSph, pwQ, imag.(fCplx), lMax, UInt64(2))
        @test size(B, 1) == 2
        @test all(
            checkComplex(B[1, k, q], bre[1, k, q]) for
            k in 1:pwNrows(lMax), q in eachindex(pwQ)
        )
        @test all(
            checkComplex(B[2, k, q], bim[1, k, q]) for
            k in 1:pwNrows(lMax), q in eachindex(pwQ)
        )
    end

    @testset "computeBLm is invariant to _CHUNK" begin
        # chunking changes only the order the per-atom terms are accumulated in,
        # so results are equal up to floating-point summation order
        N = size(pwSph, 2)
        lMax = 3
        ref = computeBLm(pwSph, pwQ, pwF, lMax, UInt64(N))
        for c in (1, 2, 3, N - 1, N, N + 10, 1 << 40)
            B = computeBLm(pwSph, pwQ, pwF, lMax, UInt64(c))
            @test size(B) == size(ref)
            @test all(checkComplex(B[i], ref[i]) for i in eachindex(B))
        end
    end

    @testset "computeBLm: _CHUNK = 1 does not underflow the UInt64 range" begin
        # `stop = start + _CHUNK - 1` with an unsigned _CHUNK, and the nested
        # `view(coordsSph, 2:3, idx)` reindexing, both used to wrap around
        # typemax(UInt64); the code converts the index to Int to avoid it
        N = size(pwSph, 2)
        @test N > 1
        b1 = computeBLm(pwSph, pwQ, pwF, 2, UInt64(1))
        ball = computeBLm(pwSph, pwQ, pwF, 2, UInt64(N))
        @test all(checkComplex(b1[i], ball[i]) for i in eachindex(b1))
    end

    @testset "computeBLm is linear in fAtoms" begin
        # both operands are real so both sides have one channel; mixing a real
        # and a complex f would compare a (1, K, Q) against a (2, K, Q)
        f1 = real.(pwF)
        f2 = [cos(0.7i + 1.3q) for i in 1:5, q in eachindex(pwQ)]
        a, b = 2.5, -0.75
        lMax = 2
        lhs = computeBLm(pwSph, pwQ, a .* f1 .+ b .* f2, lMax, UInt64(2))
        rhs =
            a .* computeBLm(pwSph, pwQ, f1, lMax, UInt64(2)) .+
            b .* computeBLm(pwSph, pwQ, f2, lMax, UInt64(2))
        @test size(lhs) == size(rhs)
        @test all(checkComplex(lhs[i], rhs[i]) for i in eachindex(lhs))
    end

    @testset "computeBLm is additive over disjoint atom sets" begin
        # B_lm is a plain sum over atoms, so splitting the molecule in two and
        # adding the parts must reproduce the whole
        lMax = 3
        left = 1:2
        right = 3:5
        bwhole = computeBLm(pwSph, pwQ, pwF, lMax, UInt64(2))
        bleft = computeBLm(pwSph[:, left], pwQ, pwF[left, :], lMax, UInt64(2))
        bright = computeBLm(pwSph[:, right], pwQ, pwF[right, :], lMax, UInt64(2))
        @test all(checkComplex(bwhole[i], bleft[i] + bright[i]) for i in eachindex(bwhole))
    end

    @testset "computeBLm: a larger lMax only appends degree blocks" begin
        # mirrors the sphHarm packing test: degree l's rows depend on l alone,
        # so truncating at a lower lMax must give the shared prefix back
        bbig = computeBLm(pwSph, pwQ, pwF, 5, UInt64(2))
        bsmall = computeBLm(pwSph, pwQ, pwF, 2, UInt64(2))
        @test all(
            checkComplex(bbig[1, k, q], bsmall[1, k, q]) for
            k in 1:pwNrows(2), q in eachindex(pwQ)
        )
    end

    @testset "computeBLm: atoms on the z axis populate only the m = 0 rows" begin
        # θ = 0 kills every m > 0 harmonic, so the nonzero rows of B are exactly
        # the packed offsets partialWaveWeights assigns the weight 1.0 to --
        # an independent, behavioural check that the two agree on the layout
        lMax = 4
        zsph = toSpherical([0.0 0.0 0.0; 0.0 0.0 0.0; 1.0 2.0 3.5])
        f = ones(3, length(pwQ))
        B = computeBLm(zsph, pwQ, f, lMax, UInt64(2))
        w = partialWaveWeights(lMax)
        for l in 0:lMax, m in 0:l
            k = pwIdx(l, m)
            # q = 0 kills every l > 0 too, so use the largest q for the
            # "is nonzero" half of the claim
            v = B[1, k, length(pwQ)]
            if m == 0
                @test w[k] == 1.0
                @test abs(v) > 1e-6
            else
                @test w[k] == 2.0
                @test checkFloat(abs(v), 0.0)
            end
        end
    end

    @testset "computeBLm zero cases" begin
        # a zero amplitude contributes nothing at any (l, m, q)
        bz = computeBLm(pwSph, pwQ, zeros(5, length(pwQ)), 3, UInt64(2))
        @test size(bz) == (1, pwNrows(3), length(pwQ))
        @test all(iszero, bz)
        # no atoms at all: the chunk loop never runs, so the (still correctly
        # shaped) accumulator comes back untouched rather than erroring
        b0 = computeBLm(zeros(3, 0), pwQ, zeros(0, length(pwQ)), 2, UInt64(4))
        @test size(b0) == (1, pwNrows(2), length(pwQ))
        @test all(iszero, b0)
    end

    @testset "computeBLm accepts a Molecule's own spherical coordinates" begin
        # the documented input layout is exactly what MolecularStructure.coordsSpherical
        # returns so it must go straight through
        mol = create(
            "tri",
            ["C", "O", "N"],
            [(0.0, 0.0, 1.0), (1.2, -0.3, 0.5), (-0.8, 0.9, -1.1)],
        )
        sph = coordsSpherical(mol)
        @test size(sph) == (3, 3)
        f = [1.0 + 0.1i for i in 1:3, _ in eachindex(pwQ)]
        B = computeBLm(sph, pwQ, f, 2, UInt64(2))
        ref = pwNaiveB(sph, pwQ, f, 2)
        @test all(
            checkComplex(B[1, k, q], ref[k, q]) for
            k in 1:pwNrows(2), q in eachindex(pwQ)
        )
    end

    @testset "computeBLm exception contract" begin
        # _CHUNK = 0 would make `1:_CHUNK:N` step by zero and loop forever
        @test_throws DomainError computeBLm(pwSph, pwQ, pwF, 2, UInt64(0))
        @test_throws ArgumentError computeBLm(pwSph, pwQ, pwF, -1, UInt64(2))
        @test_throws ArgumentError computeBLm(pwSph, pwQ, pwF, -3, UInt64(2))
        # coords must be the (3, N) spherical layout, not (N, 3) or cartesian-ish
        @test_throws ArgumentError computeBLm(zeros(2, 5), pwQ, pwF, 2, UInt64(2))
        @test_throws ArgumentError computeBLm(zeros(4, 5), pwQ, pwF, 2, UInt64(2))
        @test_throws ArgumentError computeBLm(
            permutedims(pwSph),
            pwQ,
            pwF,
            2,
            UInt64(2),
        )
        # fAtoms is (N, Q): one row per atom, one column per q
        @test_throws ArgumentError computeBLm(pwSph, pwQ, pwF[1:4, :], 2, UInt64(2))
        @test_throws ArgumentError computeBLm(
            pwSph,
            pwQ,
            vcat(pwF, pwF),
            2,
            UInt64(2),
        )
        @test_throws ArgumentError computeBLm(pwSph, pwQ, pwF[:, 1:2], 2, UInt64(2))
        @test_throws ArgumentError computeBLm(
            pwSph,
            pwQ,
            hcat(pwF, pwF),
            2,
            UInt64(2),
        )
        # lMax = 0 and a single q are on the allowed side of every boundary
        @test size(computeBLm(pwSph, [0.3], pwF[:, 1:1], 0, UInt64(1))) == (1, 1, 1)
    end

    @testset "selfScatter equals its defining sum by hand" begin
        lMax = 3
        w = partialWaveWeights(lMax)
        fCplx = pwF .+ [(0.15i + 0.02q) * im for i in 1:5, q in eachindex(pwQ)]
        for B in (
            computeBLm(pwSph, pwQ, real.(pwF), lMax, UInt64(2)),
            computeBLm(pwSph, pwQ, fCplx, lMax, UInt64(2)),
        )
            S = selfScatter(B, w)
            @test length(S) == length(pwQ)
            @test eltype(S) <: Real
            for qi in eachindex(pwQ)
                ref =
                    4π * sum(
                        w[k] * abs2(B[c, k, qi])
                        for c in 1:size(B, 1), k in 1:length(w)
                    )
                @test checkFloat(S[qi], ref)
            end
            # a weighted sum of squared magnitudes is non-negative by construction
            @test all(≥(0.0), S)
        end
    end

    @testset "selfScatter scales quadratically in B" begin
        lMax = 2
        w = partialWaveWeights(lMax)
        B = computeBLm(pwSph, pwQ, real.(pwF), lMax, UInt64(2))
        S = selfScatter(B, w)
        for α in (0.0, 0.5, -2.0, 3.0)
            Sα = selfScatter(α .* B, w)
            @test all(checkFloat(Sα[q], α^2 * S[q]) for q in eachindex(S))
        end
    end

    @testset "selfScatter adds the two channels incoherently" begin
        # the channels are summed, never mixed: a two-channel B's selfScatter
        # must equal the sum of the two single-channel ones
        lMax = 3
        w = partialWaveWeights(lMax)
        fCplx = pwF .+ [(0.3i - 0.06q) * im for i in 1:5, q in eachindex(pwQ)]
        B = computeBLm(pwSph, pwQ, fCplx, lMax, UInt64(2))
        @test size(B, 1) == 2
        s1 = selfScatter(B[1:1, :, :], w)
        s2 = selfScatter(B[2:2, :, :], w)
        S = selfScatter(B, w)
        @test all(checkFloat(S[q], s1[q] + s2[q]) for q in eachindex(S))
    end

    @testset "crossScatter of a B with itself is selfScatter" begin
        lMax = 3
        w = partialWaveWeights(lMax)
        fCplx = pwF .+ [(0.2i + 0.01q) * im for i in 1:5, q in eachindex(pwQ)]
        for B in (
            computeBLm(pwSph, pwQ, real.(pwF), lMax, UInt64(2)),
            computeBLm(pwSph, pwQ, fCplx, lMax, UInt64(2)),
        )
            X = crossScatter(B, B, w)
            S = selfScatter(B, w)
            @test length(X) == length(pwQ)
            @test eltype(X) <: Real   # Re(B conj(B)) is real even for complex B
            @test all(checkFloat(X[q], S[q]) for q in eachindex(S))
        end
    end

    @testset "crossScatter is symmetric and matches its defining sum" begin
        lMax = 2
        w = partialWaveWeights(lMax)
        fa = real.(pwF)
        fb = [sin(0.9i - 0.4q) for i in 1:5, q in eachindex(pwQ)]
        A = computeBLm(pwSph, pwQ, fa, lMax, UInt64(2))
        bb = computeBLm(pwSph, pwQ, fb, lMax, UInt64(2))
        X = crossScatter(A, bb, w)
        # Re(a conj(b)) = Re(b conj(a)), so the order of the operands is free
        @test all(checkFloat(X[q], crossScatter(bb, A, w)[q]) for q in eachindex(X))
        for qi in eachindex(pwQ)
            ref =
                4π * sum(w[k] * real(A[1, k, qi] * conj(bb[1, k, qi])) for k in 1:length(w))
            @test checkFloat(X[qi], ref)
        end
        # unlike selfScatter it is signed: negating one operand negates it
        @test all(
            checkFloat(crossScatter(A, -1.0 .* bb, w)[q], -X[q]) for q in eachindex(X)
        )
    end

    @testset "crossScatter is bilinear" begin
        lMax = 2
        w = partialWaveWeights(lMax)
        A = computeBLm(pwSph, pwQ, real.(pwF), lMax, UInt64(2))
        b1 = computeBLm(
            pwSph, pwQ, [cos(0.5i + q) for i in 1:5, q in eachindex(pwQ)],
            lMax, UInt64(2),
        )
        b2 = computeBLm(
            pwSph, pwQ, [0.3i - 0.2q for i in 1:5, q in eachindex(pwQ)],
            lMax, UInt64(2),
        )
        a, b = 1.75, -0.5
        lhs = crossScatter(A, a .* b1 .+ b .* b2, w)
        rhs = a .* crossScatter(A, b1, w) .+ b .* crossScatter(A, b2, w)
        @test all(checkFloat(lhs[q], rhs[q]) for q in eachindex(lhs))
        # linearity in the first slot follows from the same identity
        lhs2 = crossScatter(a .* b1 .+ b .* b2, A, w)
        @test all(checkFloat(lhs2[q], rhs[q]) for q in eachindex(lhs2))
    end

    @testset "crossScatter with mismatched channel counts uses min(C_a, C_b)" begin
        # documented behaviour: a real amplitude has no imaginary channel, and
        # its absent channel must contribute zero rather than raise
        lMax = 2
        w = partialWaveWeights(lMax)
        fCplx = pwF .+ [(0.25i - 0.03q) * im for i in 1:5, q in eachindex(pwQ)]
        a2 = computeBLm(pwSph, pwQ, fCplx, lMax, UInt64(2))       # 2 channels
        b1 = computeBLm(pwSph, pwQ, real.(pwF), lMax, UInt64(2))  # 1 channel
        @test size(a2, 1) == 2 && size(b1, 1) == 1
        X = crossScatter(a2, b1, w)
        @test length(X) == length(pwQ)
        # equals the cross of the first channels alone
        xfirst = crossScatter(a2[1:1, :, :], b1, w)
        @test all(checkFloat(X[q], xfirst[q]) for q in eachindex(X))
        # and the operand order does not change which channels survive
        @test all(checkFloat(crossScatter(b1, a2, w)[q], X[q]) for q in eachindex(X))
    end
end
