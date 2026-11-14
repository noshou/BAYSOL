# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/scattering/scatterers.jl, the per-species partial-wave terms:
# `_gaussianDummy` (the Fraser/MacRae/Suzuki dummy amplitude),
# `hydration` and the `SHELL_THICKNESS` constant, plus `computeBLm` fed the vacuum
# (complex form factor) and dummy amplitudes.
# The backbone of the file is a comparison against the Debye double sum
#
#     I(q) = Re Σ_i Σ_j f_i(q) conj(f_j(q)) j_0(q r_ij),   r_ij = |r_i - r_j|
#
# which is the exact orientational average and shares nothing with the
# spherical-harmonic code. The partial-wave sum converges to it as lMax
# grows, so each comparison is run as a convergence ladder (error falling with
# lMax) plus a machine-precision check at the top and a deliberately truncated
# case that must disagree loudly.
#
# Two known gaps:
#   * The Debye sum depends only on pairwise distances, so it is invariant under
#     any rigid motion and cannot see a bug in `_center` or in the cartesian ->
#     spherical conversion. "molecule frame conventions" tests those directly.
#   * `hydration`'s dummy positions come from `Geometry.sasa`, which is
#     pipeline and cannot be meaningfully hardcoded (the cloud depends on the
#     sampling). There the oracle necessarily consumes `sasa`' output as
#     given, so those tests check only the `sasa -> B_lm -> I(q)`
#
# `excluded`'s Debye/convergence comparisons build their per-atom amplitudes
# from arbitrary, test-owned volumes (`scatVol`/`SCAT_EXCLUDED_VOL`) fed
# straight into `_gaussianDummy`/`computeBLm`, not from a real `Molecule`'s
# `vols(mol)`. This is deliberate: those comparisons are testing the Debye-sum
# math `computeBLm`/`selfScatter`/`crossScatter` implement, which does not
# care what a volume means, only that it is consumed correctly -- so they stay
# green regardless of how `MolecularStructure.excludedVolume`
# computes a real molecule's volumes. Only the handful of tests that exist to
# check `excluded`'s own Molecule-wrapping contract (does it call `vols` and
# `computeBLm` correctly) still build a real `Molecule`; `vols`'s own
# numerical correctness is test-molecules.jl's job.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Scattering: _gaussianDummy, _gaussianDummyShared, hydration,
    SHELL_THICKNESS, PROBE_RADIUS,
    computeBLm, partialWaveWeights, selfScatter, crossScatter
using BAYSOL.PhysicalConstants: UNIT_OF_δρ
using BAYSOL.MolecularStructure:
    create, coordsCartesian, coordsSpherical, toSpherical,
    radii, vols, elms, Molecule

using BAYSOL: Geometry
using BAYSOL.Scattering: formFactorTable, formFactors

"""
Per-element van der Waals radii in Å, EXACTLY as the live `AtomicRadii` backend
returns them.

Provenance: dumped at full `Float64` precision from
`lookupRadii([e])` on 2026-09-06, against
`data/atomic_radii.sqlite3` as of commit 071e4fd.
"""
const SCAT_RADII = Dict("c" => 1.77, "o" => 1.5, "h" => 1.2, "fe3+" => 0.49, "o2-" => 1.35)

"""
Arbitrary but fixed per-species volumes (Å³), used ONLY to build this file's
own synthetic dummy amplitudes for the Debye/convergence comparisons below --
not a claim about what `vols(mol)` returns. `vols` computes each atom's
excluded volume geometrically from its actual local packing
(`MolecularStructure.excludedVolume`), which is
packing-dependent and has no fixed per-element value; this file has no
business re-deriving it. The Debye-sum/convergence tests that use these
numbers never call `vols` on a `Molecule` at all, which is the point: they
stay green regardless of how `excludedVolume` is implemented. (These happen
to be the CRYSOL Table 1 values, kept only because they're already a
convenient positive, well-separated set of numbers -- not because anything
here expects them to match a real molecule.)
"""
const SCAT_EXCLUDED_VOL = Dict("c" => 16.44, "o" => 9.13, "h" => 5.15)

"""
Per-dummy synthetic volume for element `e`: `SCAT_EXCLUDED_VOL[e]` if
tabulated, else the sphere volume of `SCAT_RADII[e]` (the ion fixtures
`fe3+`/`o2-` have no table entry). Feeds `_gaussianDummy`/`computeBLm`
directly in the tests below; never compared against `vols(mol)`.
"""
scatVol(e) =
    haskey(SCAT_EXCLUDED_VOL, e) ?
    SCAT_EXCLUDED_VOL[e] : (4.0 / 3.0) * π * SCAT_RADII[e]^3

"""
Dummy amplitude `f = v exp(-q² v^(2/3) / 4π)`, transcribed from the
Fraser/MacRae/Suzuki form in `_gaussianDummy`'s docstring rather than called
from it.
"""
scatGauss(v, q) = v * exp(-q^2 * v^(2 / 3) / (4π))

"Literal momentum-transfer grid in Å⁻¹. q = 0 is present: several closed forms need it."
const SCAT_Q = [0.0, 0.05, 0.15, 0.3, 0.5]

# --- literal fixture geometries -------------------------------------------
# Each is a `(elements, (3, N) cartesian literal)` pair. The molecule under test
# is built from these with `create`, which re-centres them; the oracle reads the
# matrix directly and never asks the molecule for coordinates. That is sound
# because the Debye sum uses only `r_ij`, which no translation can change.

"Two atoms 4 Å apart: the one case whose Debye sum is hand-checkable in closed form."
const SCAT_DIMER_E = ["c", "c"]
const SCAT_DIMER_X = [0.0 4.0; 0.0 0.0; 0.0 0.0]

"""
Cube of 8 identical atoms on ±1.5 Å. Highly symmetric on purpose: whole blocks
of `(l, m)` cancel, so an index/packing bug that a generic molecule would smear
into a small error can show up here as a gross one.
"""
const SCAT_CUBE_E = fill("c", 8)
const SCAT_CUBE_X = reduce(
    hcat,
    [
        Float64[1.5x, 1.5y, 1.5z]
        for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)
    ],
)

"""
20 atoms of three different volumes at irregular positions in a ±4.5 Å box: no
symmetry at all, so the `m != 0` rows carry real weight instead of cancelling.
This is the fixture the convergence ladders lean on. The coordinates were drawn
once from a seeded generator and then frozen as literals, so no test in this
file depends on any RNG state.
"""
const SCAT_BLOB_E = ["o", "h", "c", "o", "h", "c", "o", "h", "c", "o",
    "h", "c", "o", "h", "c", "o", "h", "c", "o", "h"]
# Three axes (x, y, z) of 20 numbers each in one column-major list (axis k is the
# k-th run of 20); `permutedims` makes them the rows of the (3, 20) coordinate matrix.
const SCAT_BLOB_X = permutedims(
    reshape(
        [
            -2.660, -0.142, 1.295, 1.009, 4.166, 1.157, -4.056, 1.445, -1.888, -3.607,
            2.178, -1.018, -0.333, 0.621, 3.352, 0.320, 1.969, 0.482, -0.998, 4.099,
            -0.119, -3.789, 3.422, -0.603, 2.669, 3.933, -3.162, 1.902, -0.207, 2.393,
            -3.760, -4.144, -2.267, 3.580, -2.385, -2.650, 3.236, -3.208, -0.561, 0.987,
            -1.937, 0.693, -0.720, 0.261, 3.099, 0.801, -4.123, 1.298, 1.323, 2.741,
            2.887, -1.076, 4.101, 3.973, -2.176, -0.575, 1.344, -0.462, -3.859, 3.967,
        ], 20, 3),
)

"""
The 5-atom molecule the vacuum-amplitude tests use, and its form factors at
8000 eV on `SCAT_Q`, hardcoded.

Provenance: `FormFactor.formFactorTable(8000.0, ["fe3+", "o2-", "h"], SCAT_Q)`
followed by `FormFactor.formFactors`, dumped at full `Float64` precision on
2026-09-06 from the xraydb backend. Only three distinct ions are tabulated; the
per-atom matrix is assembled from them by lookup. `fe3+`'s K edge is at ~7.1
keV, so `f''` is large here and `computeBLm` must take its `C = 2` branch --
`f''` is q-independent, which is why each ion's imaginary part is constant
across the row.
"""
const SCAT_FF_E = ["fe3+", "o2-", "h", "o2-", "h"]
const SCAT_FF_X = [0.0 2.1 0.0 -1.4 0.9
    0.0 0.0 1.6 1.9 -2.3
    0.0 0.0 0.6 -0.7 1.1]
const SCAT_FF_ENERGY = 8000.0
const SCAT_FF_TABLE = Dict(
    "fe3+" => [21.739265778665303 + 3.2028526697246287im,
    21.737749881791149 + 3.2028526697246287im,
    21.725629596540660 + 3.2028526697246287im,
    21.684813884461967 + 3.2028526697246287im,
    21.588618751767171 + 3.2028526697246287im],
    "o2-"  => [10.044358726501459 + 0.03235399864710075im,
    10.041666212623870 + 0.03235399864710075im,
    10.020175140088888 + 0.03235399864710075im,
    9.9482814754245616 + 0.03235399864710075im,
    9.7817211659042105 + 0.03235399864710075im],
    "h"    => [0.99944620932546357 + 1.08869064958089e-06im,
    0.99909667497428978 + 1.08869064958089e-06im,
    0.99630692714662494 + 1.08869064958089e-06im,
    0.98697650916313695 + 1.08869064958089e-06im,
    0.96537230148199171 + 1.08869064958089e-06im],
)

# ===========================================================================
# ORACLE
# ===========================================================================

"""
The Debye formula: `I(q) = Re Σ_i Σ_j f_i(q) conj(f_j(q)) j_0(q r_ij)`, the
exact orientational average of `|Σ_i f_i exp(i q·r_i)|²`. Written directly over
cartesian coordinates with `j_0(x) = sin(x)/x`, `j_0(0) = 1`; it borrows nothing
from `SphFuncs`/`PartialWave`. Given two different point sets it is the exact
cross term `Σ_{i∈a} Σ_{j∈b}`, which is what `crossScatter` converges to.
"""
function scatDebye(qvals, crdA, fA, crdB = crdA, fB = fA)
    out = zeros(Float64, length(qvals))
    for k in eachindex(qvals)
        q = qvals[k]
        acc = zero(ComplexF64)
        for i in axes(crdA, 2), j in axes(crdB, 2)
            d = hypot(
                crdA[1, i] - crdB[1, j],
                crdA[2, i] - crdB[2, j],
                crdA[3, i] - crdB[3, j],
            )
            x = q * d
            j0 = iszero(x) ? 1.0 : sin(x) / x   # j_0(0) = 1 by continuity
            acc += fA[i, k] * conj(fB[j, k]) * j0
        end
        out[k] = real(acc)
    end
    return out
end

"`(N, Q)` dummy amplitudes for `es` on `qvals`, built from the hardcoded radii alone."
scatDummyAmp(es, qvals) =
    [scatGauss(scatVol(es[i]), qvals[k]) for i in eachindex(es), k in eachindex(qvals)]

"Largest relative deviation of `got` from `ref`, elementwise."
scatRelerr(got, ref) = maximum(abs.(got .- ref) ./ abs.(ref))

"""
Centred spherical coordinates for a literal `(3, N)` cartesian block, built
without a `Molecule`. Reproduces exactly what `create` -> `coordsSpherical`
does (centre, then `toSpherical`; see "molecule frame conventions" below for
that identity pinned directly), so the synthetic-volume `computeBLm` calls
below feed it the same coordinates a real `Molecule` would, with no `vols`/
`excludedVolume`/radii-backend dependency anywhere in the chain.
"""
scatSph(X) = toSpherical(X .- (sum(X; dims = 2) ./ size(X, 2)))

# ===========================================================================
# PIPELINE-SIDE FIXTURES.
# ===========================================================================

scatMol(name, es, X) = create(name, es, [(X[1, i], X[2, i], X[3, i]) for i in axes(X, 2)])

scatDimer() = scatMol("dimer", SCAT_DIMER_E, SCAT_DIMER_X)
scatCube()  = scatMol("cube", SCAT_CUBE_E, SCAT_CUBE_X)
scatBlob()  = scatMol("blob", SCAT_BLOB_E, SCAT_BLOB_X)

"Water: 3 atoms, entirely convex accessible surface."
scatWater() = create(
    "water",
    ["o", "h", "h"],
    [(0.0, 0.0, 0.0), (0.9572, 0.0, 0.0), (-0.2400, 0.9266, 0.0)],
)

"Two parallel rows of carbons 6 Å apart: the canyon floor between them is concave."
scatCanyon() = create(
    "canyon",
    fill("c", 6),
    [(3.0 * x, 3.0 * s, 0.0) for x in -1:1 for s in (-1.0, 1.0)],
)

"Two atoms stacked at the very same point: neither has any accessible surface."
scatBuried() = create("buried", ["c", "c"], [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)])

scatLmax = 3                         # small: used only by the shape/contract tests
scatK = (scatLmax + 1) * (scatLmax + 2) ÷ 2
scatChunk = UInt64(2)                # `_CHUNK` is UInt64-typed: `2` would not dispatch
scatHchunk = UInt64(16)

# lMax at which every ground-truth comparison below is expected to have
# converged. qMax*rMax is at most ~5 for these fixtures (the hydration cloud,
# not the atoms, sets rMax), and the ladders show the error reaching the
# Float64 floor well before 16.
scatLconv = 16
scatWconv = partialWaveWeights(scatLconv)
scatTol = 1e-11                      # measured errors at scatLconv are ~1e-13

"""
Section 6's expansion restricted to the two dummy species (no vacuum term, hence no
Python): with `A = -dns*A_ex + dro*A_sh`,

    I(q) = dns² S_ex,ex + dro² S_sh,sh - 2 dns dro S_ex,sh

This is the assembly the downstream Gram-matrix code will eventually do; it
lives here so the `B_lm` these functions now return can be driven end to end.
"""
scatToyI(bEx, bSh, w, dns, dro) =
    dns^2 .* selfScatter(bEx, w) .+
    dro^2 .* selfScatter(bSh, w) .-
    (2 * dns * dro) .* crossScatter(bEx, bSh, w)

"""
The shell dummies `hydration` would build for `mol`: cartesian positions and
`(M, Q)` amplitudes, obtained by applying the same `area * thickness` volume
rule the implementation applies.
"""
function scatShell(mol, qvals; nTarget = 80, probe = PROBE_RADIUS,
    thickness = SHELL_THICKNESS)
    pts, area, _ = Geometry.sasa(mol; probe = probe, nTarget = nTarget)
    amp = [
        scatGauss(area[i] * thickness, qvals[k]) for
        i in eachindex(area), k in eachindex(qvals)
    ]
    return pts, amp
end

"""
`hydration` returns a `(; convex, concave, cavity)` NamedTuple of per-class
`B_lm`. The three bead sets are disjoint and `B_lm` is linear in them, so their
sum is exactly the single merged shell `B_lm` the pre-split code compared
against. Every check below that wants "the whole shell" routes through this.
"""
scatShellBlm(h) = h.convex .+ h.concave .+ h.cavity

# ===========================================================================
# STUB FORM-FACTOR AMPLITUDE. Element labels that are not real elements with a
# hand-picked complex amplitude per ion, so the two-channel (Re f, Im f)
# partial-wave split can be checked against an oracle that shares nothing with
# the FormFactor tables.
# ===========================================================================

const SCAT_STUB_E = ["a", "b", "c", "b"]
# One row per axis: a newline inside a matrix literal starts a new row, so
# these three lines must stay three lines to keep this (3, 4) and not (1, 12).
const SCAT_STUB_X = [0.0 3.2 -1.1 0.4
    0.0 0.0 2.4 -1.8
    0.0 0.0 0.9 2.6]
"Per-ion `(Re, Im)` weights; `b` is repeated in `SCAT_STUB_E` to pin row lookup."
const SCAT_STUB_W = Dict("a" => 20.0 + 4.0im, "b" => 8.0 + 1.5im, "c" => 1.0 + 0.25im)

scatStubF(e, q) = SCAT_STUB_W[e] * exp(-q)

"""
Pipeline-side molecule for the stub. The element strings are not real elements,
which is fine here and only here: `create` resolves radii lazily, and the tests
that use it touch only `coordsSpherical`, so nothing ever queries the radii
table for them. Calling `radii`/`vols` on this molecule would throw.
"""
scatStubmol() = scatMol("stub", SCAT_STUB_E, SCAT_STUB_X)

"Oracle-side copy of the stub amplitude, built from `SCAT_STUB_W` alone."
const SCAT_STUBAMP = ComplexF64[
    scatStubF(SCAT_STUB_E[i], SCAT_Q[k])
    for i in eachindex(SCAT_STUB_E), k in eachindex(SCAT_Q)
]

@testset "Scatterers" begin

    # -----------------------------------------------------------------------
    # Localising guards. These exist so that a change in the radii backend
    # reports itself here rather than as a diffuse Debye mismatch further down.
    # -----------------------------------------------------------------------

    @testset "molecule geometry matches the hardcoded oracle constants" begin
        # If this fails the radii backend has changed: SCAT_RADII needs
        # regenerating, and every test below that reads element strings out of
        # these fixtures would be affected by that same single root cause.
        #
        # `vols(mol)` is deliberately NOT checked here against `scatVol`:
        # `vols` is the geometric, packing-dependent excluded volume
        # (`MolecularStructure.excludedVolume`), and `scatVol`/
        # `SCAT_EXCLUDED_VOL` are this file's own synthetic constants, not a
        # prediction of it. `vols`'s numerical correctness belongs to
        # test-molecules.jl (its "vols: shape and bounds against the vdW
        # sphere" and "excluded volume of a genuinely isolated atom..."
        # testsets), not here.
        for (es, X) in (
            (SCAT_DIMER_E, SCAT_DIMER_X),
            (SCAT_CUBE_E, SCAT_CUBE_X),
            (SCAT_BLOB_E, SCAT_BLOB_X),
        )
            mol = scatMol("guard", es, X)
            @test radii(mol) == [SCAT_RADII[e] for e in es]
            @test elms(mol) == es
        end
    end

    @testset "molecule frame conventions: centring and the spherical transform" begin
        # The Debye oracle only ever sees pairwise distances, so it is blind to
        # any rigid motion; it cannot catch a bug in `_center` or in
        # `toSpherical`. Both are therefore pinned here directly, against
        # arithmetic done in the test rather than against MolecularStructure's own helpers.
        X = SCAT_BLOB_X
        n = size(X, 2)
        cx = sum(X[1, :]) / n
        cy = sum(X[2, :]) / n
        cz = sum(X[3, :]) / n
        mol = scatMol("frame", SCAT_BLOB_E, X)
        C = coordsCartesian(mol)
        @test size(C) == (3, n)
        for i in 1:n
            @test checkFloat(C[1, i], X[1, i] - cx)
            @test checkFloat(C[2, i], X[2, i] - cy)
            @test checkFloat(C[3, i], X[3, i] - cz)
        end
        @test checkFloat(sum(C[1, :]), 0.0) && checkFloat(sum(C[2, :]), 0.0) &&
              checkFloat(sum(C[3, :]), 0.0)

        # (r, θ, φ) with θ = acos(z/r) from +z and φ = atan(y, x), on the
        # already-centred literals.
        S = coordsSpherical(mol)
        @test size(S) == (3, n)
        for i in 1:n
            x = X[1, i] - cx
            y = X[2, i] - cy
            z = X[3, i] - cz
            r = sqrt(x^2 + y^2 + z^2)
            @test checkFloat(S[1, i], r)
            @test checkFloat(S[2, i], acos(z / r))
            @test checkFloat(S[3, i], atan(y, x))
        end
    end

    @testset "SHELL_THICKNESS is CRYSOL's 3 Å and is hydration's default" begin
        @test SHELL_THICKNESS === 3.0
        mol = scatWater()
        a = hydration(mol, SCAT_Q, scatLmax, scatHchunk; nTarget = 60)
        b = hydration(
            mol,
            SCAT_Q,
            scatLmax,
            scatHchunk;
            nTarget = 60,
            thickness = SHELL_THICKNESS,
        )
        @test a == b   # the documented default really is the constant
    end

    # -----------------------------------------------------------------------
    # _gaussianDummy
    # -----------------------------------------------------------------------

    @testset "_gaussianDummy shape and element type" begin
        f = _gaussianDummy([1.0, 8.0, 27.0], SCAT_Q)
        @test f isa Matrix{Float64}
        @test size(f) == (3, length(SCAT_Q))   # (N, Q), computeBLm's fAtoms layout
    end

    @testset "_gaussianDummy matches its closed form entry by entry" begin
        v = [0.5, 4.0, 14.137166941154067, 33.51032163829113]
        f = _gaussianDummy(v, SCAT_Q)
        for i in eachindex(v), k in eachindex(SCAT_Q)
            @test checkFloat(f[i, k], scatGauss(v[i], SCAT_Q[k]))
        end
        # and on the same element lists the Debye tests below use, so the
        # synthetic oracle (`scatDummyAmp`, built from `SCAT_EXCLUDED_VOL`/
        # `scatVol` via the independent `scatGauss` formula) is pinned to
        # `_gaussianDummy` itself before any Debye comparison leans on it.
        # No `Molecule`/`vols` involved -- that pairing is exactly what those
        # comparisons are meant not to depend on.
        for es in (SCAT_DIMER_E, SCAT_CUBE_E, SCAT_BLOB_E)
            v = [scatVol(e) for e in es]
            got = _gaussianDummy(v, SCAT_Q)
            ref = scatDummyAmp(es, SCAT_Q)
            @test all(i -> checkFloat(got[i], ref[i]), eachindex(ref))
        end
    end

    # …of _gaussianDummy as one vector
    @testset "_gaussianDummyShared: the equal-volume rows" begin
        q = [0.0, 0.1, 0.35, 0.8]
        for v in (3.7, 25.0)
            sh = _gaussianDummyShared(v, 6, q)
            @test size(sh) == (6, 4)
            @test all(sh[i, :] ≈ _gaussianDummy(fill(v, 6), q)[i, :] for i in 1:6)
        end
    end

    @testset "_gaussianDummy at q = 0 is the volume itself" begin
        # exp(0) == 1 exactly, so this is an equality, not an approximation:
        # a uniform sphere scatters as its own volume in the forward direction.
        v = [0.5, 4.0, 14.137166941154067]
        @test _gaussianDummy(v, [0.0])[:, 1] == v
        # the same column appears wherever q = 0 sits in a longer grid
        @test _gaussianDummy(v, SCAT_Q)[:, 1] == v
    end

    @testset "_gaussianDummy: a zero-volume dummy is an identically zero row" begin
        f = _gaussianDummy([0.0, 5.0], SCAT_Q)
        @test all(iszero, f[1, :])          # 0 * exp(...) == 0 at every q
        @test all(>(0.0), f[2, :])          # its neighbour is unaffected
    end

    @testset "_gaussianDummy is positive and strictly decreasing in q for v > 0" begin
        f = _gaussianDummy([1.0, 20.0], [0.0, 0.1, 0.4, 1.0, 2.0])
        @test all(>(0.0), f)
        for i in axes(f, 1)
            @test all(k -> f[i, k] > f[i, k+1], 1:(size(f, 2)-1))
        end
    end

    @testset "_gaussianDummy: bigger volumes decay faster in q" begin
        # The Gaussian width is set by v^(1/3), so after dividing out the q = 0
        # value (which is just v) the larger dummy must have fallen further.
        vsmall, vbig = 1.0, 64.0
        q = 0.5
        f = _gaussianDummy([vsmall, vbig], [0.0, q])
        @test f[2, 2] / f[2, 1] < f[1, 2] / f[1, 1]
        # concretely: v = 64 has v^(2/3) = 16, so its exponent is 16x the v = 1 one
        @test checkFloat(f[1, 2], exp(-q^2 / (4π)))
        @test checkFloat(f[2, 2], 64.0 * exp(-16 * q^2 / (4π)))
    end

    @testset "_gaussianDummy rejects negative volumes" begin
        @test_throws ArgumentError _gaussianDummy([-1.0], SCAT_Q)
        @test_throws ArgumentError _gaussianDummy([1.0, 2.0, -1e-12], SCAT_Q)
        @test _gaussianDummy([0.0], SCAT_Q) isa Matrix{Float64}   # 0 itself is allowed
    end

    @testset "_gaussianDummy edge cases: empty vols, empty q, single element" begin
        # Broadcasting keeps the (N, Q) contract even when one axis is empty;
        # neither case is an error, so both stay valid `fAtoms` for computeBLm.
        @test size(_gaussianDummy(Float64[], SCAT_Q)) == (0, length(SCAT_Q))
        @test size(_gaussianDummy([1.0, 2.0], Float64[])) == (2, 0)
        @test size(_gaussianDummy(Float64[], Float64[])) == (0, 0)
        @test size(_gaussianDummy([3.0], [0.2])) == (1, 1)
        @test checkFloat(_gaussianDummy([3.0], [0.2])[1, 1], scatGauss(3.0, 0.2))
        # integer volumes are accepted and still come back Float64
        @test _gaussianDummy([1, 8], SCAT_Q) isa Matrix{Float64}
    end

    @testset "the l = 0 closed form at q = 0 is (Σ v_i)/√(4π)" begin
        # At q = 0, j_l(0) = δ_l0 kills every l > 0, and Y_00 = 1/√(4π), so:
        # B_00(0) = (Σ_i v_i) / √(4π). Built from `computeBLm` directly on
        # synthetic volumes and literal coordinates -- no `Molecule`, no
        # `vols` -- since this pins `computeBLm`'s l = 0 behaviour.
        for (es, X) in ((SCAT_DIMER_E, SCAT_DIMER_X), (SCAT_CUBE_E, SCAT_CUBE_X),
            (SCAT_BLOB_E, SCAT_BLOB_X))
            v = [scatVol(e) for e in es]
            B = computeBLm(
                scatSph(X),
                [0.0],
                _gaussianDummy(v, [0.0]),
                scatLmax,
                scatChunk,
            )
            tot = sum(v)
            @test isapprox(real(B[1, 1, 1]), tot / sqrt(4π); rtol = 1e-12)
            @test checkFloat(imag(B[1, 1, 1]), 0.0)
            @test all(k -> checkComplex(B[1, k, 1], 0.0), 2:scatK)
        end
    end

    @testset "computeBLm on a single dummy at the origin" begin
        # One dummy sits at the origin, so r = 0 and j_l(0) = δ_l0 makes every
        # degree above l = 0 vanish at *every* q, not just at q = 0, and
        # B_00(q) is just that dummy's amplitude over √(4π). A synthetic
        # volume and a literal r = 0 coordinate -- no `Molecule` involved, so
        # this is `computeBLm`'s property.
        v = scatVol("c")
        crd = zeros(3, 1)   # r = 0 exactly; θ, φ are irrelevant since j_l(0) = δ_l0
        B = computeBLm(crd, SCAT_Q, _gaussianDummy([v], SCAT_Q), scatLmax, scatChunk)
        for k in eachindex(SCAT_Q)
            @test isapprox(
                real(B[1, 1, k]),
                scatGauss(v, SCAT_Q[k]) / sqrt(4π);
                rtol = 1e-12,
            )
            @test all(j -> checkComplex(B[1, j, k], 0.0), 2:scatK)
        end
    end

    # -----------------------------------------------------------------------
    # computeBLm against Debye
    # -----------------------------------------------------------------------

    @testset "computeBLm reproduces the exact Debye intensity for the dimer" begin
        # Two identical synthetic dummies of volume v, 4 Å apart, so the
        # double sum has four terms and collapses by hand to
        #   I(q) = 2 f(q)² (1 + j_0(4q)).
        # Written out here without calling `scatDebye` at all, so the oracle
        # itself is checked against pen and paper before it is trusted below.
        # Built directly from `computeBLm`/`selfScatter` on a synthetic
        # volume and literal (centred) coordinates -- no `excluded`, no
        # `Molecule`, no `vols` -- since this is pinning the Debye-sum math,
        # not `excluded`'s wiring.
        v = scatVol("c")
        B = computeBLm(scatSph(SCAT_DIMER_X), SCAT_Q,
            _gaussianDummy([v, v], SCAT_Q), scatLconv, scatChunk)
        S = selfScatter(B, scatWconv)
        for k in eachindex(SCAT_Q)
            q = SCAT_Q[k]
            x = 4.0 * q
            j0 = iszero(x) ? 1.0 : sin(x) / x
            @test isapprox(S[k], 2 * scatGauss(v, q)^2 * (1 + j0); rtol = scatTol)
        end
        # and the generic oracle agrees with that hand computation
        @test isapprox(
            scatDebye(
                SCAT_Q,
                SCAT_DIMER_X,
                scatDummyAmp(SCAT_DIMER_E, SCAT_Q)),
            S;
            rtol = scatTol,
        )
    end

    @testset "computeBLm converges to Debye as lMax grows" begin
        # The multipole series truncates at lMax with an error set by q*rMax,
        # so this is asserted as a ladder rather than at one lMax: the relative
        # deviation from the exact Debye value has to fall at every rung. Run on
        # the asymmetric blob, the only fixture wide enough that lMax = 2 is
        # genuinely far from converged (the cube's symmetry puts it at the
        # Float64 floor by lMax = 8, which would make a strict ladder meaningless).
        # Synthetic volumes + literal coordinates, no `excluded`/`Molecule`/`vols`.
        v = [scatVol(e) for e in SCAT_BLOB_E]
        ref = scatDebye(SCAT_Q, SCAT_BLOB_X, scatDummyAmp(SCAT_BLOB_E, SCAT_Q))
        errs = [
            scatRelerr(
                selfScatter(
                    computeBLm(
                        scatSph(SCAT_BLOB_X),
                        SCAT_Q,
                        _gaussianDummy(v, SCAT_Q),
                        L,
                        UInt64(4),
                    ),
                    partialWaveWeights(L)),
                ref,
            ) for L in (2, 4, 8)
        ]
        @test all(k -> errs[k] > errs[k+1], 1:(length(errs)-1))
        @test errs[1] > 1e-3   # the ladder really does start unconverged
    end

    @testset "computeBLm matches Debye to machine precision at lMax = 16" begin
        for (es, X) in ((SCAT_DIMER_E, SCAT_DIMER_X), (SCAT_CUBE_E, SCAT_CUBE_X),
            (SCAT_BLOB_E, SCAT_BLOB_X))
            v = [scatVol(e) for e in es]
            ref = scatDebye(SCAT_Q, X, scatDummyAmp(es, SCAT_Q))
            got = selfScatter(
                computeBLm(scatSph(X), SCAT_Q, _gaussianDummy(v, SCAT_Q),
                    scatLconv, UInt64(4)), scatWconv)
            @test scatRelerr(got, ref) < scatTol
        end
    end

    @testset "a deliberately truncated computeBLm disagrees with Debye loudly" begin
        # Teeth for the tolerance above: at lMax = 1 the series is nowhere near
        # converged for a molecule this wide, so the same comparison must fail
        # by percent-level amounts. If it did not, `scatTol` would be passing
        # everything rather than pinning anything.
        v = [scatVol(e) for e in SCAT_BLOB_E]
        ref = scatDebye(SCAT_Q, SCAT_BLOB_X, scatDummyAmp(SCAT_BLOB_E, SCAT_Q))
        bad = selfScatter(
            computeBLm(
                scatSph(SCAT_BLOB_X),
                SCAT_Q,
                _gaussianDummy(v, SCAT_Q),
                1,
                UInt64(4),
            ),
            partialWaveWeights(1),
        )
        @test scatRelerr(bad, ref) > 1e-2
        # ... and the disagreement is truncation, not a constant offset: it
        # vanishes at q = 0, where only l = 0 contributes at any lMax.
        @test isapprox(bad[1], ref[1]; rtol = scatTol)
    end

    # -----------------------------------------------------------------------
    # hydration
    # -----------------------------------------------------------------------

    @testset "hydration returns a per-class B_lm NamedTuple" begin
        h = hydration(scatWater(), SCAT_Q, scatLmax, scatHchunk; nTarget = 60)
        @test h isa NamedTuple{(:convex, :concave, :cavity)}
        for B in (h.convex, h.concave, h.cavity)
            @test B isa AbstractArray{<:Complex,3}
            @test size(B) == (1, scatK, length(SCAT_Q))   # C = 1, real dummy amplitude
            @test all(isfinite, B)
        end
        # water's accessible surface is entirely CONVEX
        @test !all(iszero, h.convex)
        @test all(iszero, h.concave) && all(iszero, h.cavity)
        # the three disjoint populations sum to the single merged shell B_lm
        B = scatShellBlm(h)
        @test B isa AbstractArray{<:Complex,3}
        @test size(B) == (1, scatK, length(SCAT_Q))
    end

    @testset "the three shell classes partition the accessible surface" begin
        for mk in (scatWater, scatBlob, scatCube, scatCanyon)
            mol = mk()
            cls = Geometry.sasa(mol; nTarget = 100)[3]
            @test count(==(Geometry.CONVEX), cls) + count(==(Geometry.CONCAVE), cls) +
                  count(==(Geometry.CAVITY), cls) == length(cls)
            # B_lm is linear in the disjoint bead sets: the three B_00(0) add up
            # to the whole surface's total area * thickness / √(4π).
            h = hydration(mol, [0.0], scatLmax, scatHchunk; nTarget = 100)
            total = sum(Geometry.sasa(mol; nTarget = 100)[2])
            @test isapprox(
                real(h.convex[1, 1, 1]) + real(h.concave[1, 1, 1]) +
                real(h.cavity[1, 1, 1]),
                total * SHELL_THICKNESS / sqrt(4π); rtol = 1e-12)
        end
        for mk in (scatWater, scatBlob)          # no enclosed interior voids
            @test all(
                iszero,
                hydration(mk(), SCAT_Q, scatLmax, scatHchunk;
                    nTarget = 100).cavity,
            )
        end
    end

    @testset "hydration argument guards" begin
        mol = scatWater()
        @test_throws ArgumentError hydration(
            mol,
            SCAT_Q,
            scatLmax,
            scatHchunk;
            thickness = 0.0,
            nTarget = 60,
        )
        @test_throws ArgumentError hydration(
            mol,
            SCAT_Q,
            scatLmax,
            scatHchunk;
            thickness = -1.0,
            nTarget = 60,
        )
    end

    @testset "Geometry.sasa is deterministic" begin
        # The plastic sequence carries no RNG, so repeated calls must agree bit-for-bit.
        mol = scatWater()
        a = Geometry.sasa(mol; nTarget = 60)
        b = Geometry.sasa(mol; nTarget = 60)
        @test a[1] == b[1] && a[2] == b[2] && a[3] == b[3]
        @test hydration(mol, SCAT_Q, scatLmax, scatHchunk; nTarget = 60) ==
              hydration(mol, SCAT_Q, scatLmax, scatHchunk; nTarget = 60)
    end

    @testset "hydration's q = 0 closed form is (total area * thickness)/√(4π)" begin
        # Same l = 0 collapse as `excluded`, with each dummy's volume now
        # `area_i * thickness`; `sasa` gives every point an equal area,
        # so B_00(0) = (Σ_i area_i * thickness)/√(4π) = total_area*Δ/√(4π).
        mol = scatWater()
        for n in (40, 60, 90)
            area = sum(Geometry.sasa(mol; nTarget = n)[2])
            B = scatShellBlm(hydration(mol, [0.0], scatLmax, scatHchunk; nTarget = n))
            @test isapprox(
                real(B[1, 1, 1]),
                area * SHELL_THICKNESS / sqrt(4π);
                rtol = 1e-12,
            )
            @test checkFloat(imag(B[1, 1, 1]), 0.0)
            @test all(k -> checkComplex(B[1, k, 1], 0.0), 2:scatK)
        end
    end

    @testset "hydration's B_00(0) is invariant to nTarget" begin
        # Thinning refills `areas = total/length(idx)`, so the total accessible
        # area  is conserved exactly.
        mol = scatWater()
        ref = scatShellBlm(hydration(mol, [0.0], scatLmax, scatHchunk; nTarget = 40))[
            1,
            1,
            1,
        ]
        for n in (60, 90, 120)
            @test isapprox(
                scatShellBlm(hydration(mol, [0.0], scatLmax, scatHchunk; nTarget = n))[
                    1,
                    1,
                    1,
                ],
                ref;
                rtol = 1e-10,
            )
        end
        # nTarget really does change the dummy count, so this is not vacuous
        @test length(Geometry.sasa(mol; nTarget = 40)[2]) == 40
        @test length(Geometry.sasa(mol; nTarget = 90)[2]) == 90
    end

    @testset "hydration scales linearly in thickness at q = 0 only" begin
        # the amplitude scales with `thickness`
        # only where the exponential is exactly 1, i.e. at q = 0. Assert the
        # clean factor there, and only a strictly smaller factor away from it.
        mol = scatWater()
        b1 = scatShellBlm(
            hydration(mol, SCAT_Q, scatLmax, scatHchunk; nTarget = 60, thickness = 1.5),
        )
        b2 = scatShellBlm(
            hydration(mol, SCAT_Q, scatLmax, scatHchunk; nTarget = 60, thickness = 3.0),
        )
        @test isapprox(real(b2[1, 1, 1]), 2 * real(b1[1, 1, 1]); rtol = 1e-10)
        for k in 2:length(SCAT_Q)
            r = real(b2[1, 1, k]) / real(b1[1, 1, k])
            @test 1.0 < r < 2.0    # thicker dummies are also wider, so they decay sooner
        end
    end

    # …and the classes partition the surface
    @testset "the canyon has recessed CONCAVE beads" begin
        # Water's accessible surface is entirely CONVEX; the canyon really does
        # have recessed CONCAVE beads.
        @test all(==(Geometry.CONVEX), Geometry.sasa(scatWater(); nTarget = 60)[3])
        can = scatCanyon()
        cls = Geometry.sasa(can; nTarget = 120)[3]
        @test count(==(Geometry.CONCAVE), cls) > 0            # the fixture is doing its job
        all3 = hydration(can, [0.0], scatLmax, scatHchunk; nTarget = 120)
        @test !all(iszero, all3.concave)
        # the classes partition the surface, so the per-class B_00(0) add back up
        @test real(all3.concave[1, 1, 1]) > 0.0
        @test isapprox(
            real(all3.convex[1, 1, 1]) + real(all3.concave[1, 1, 1]) +
            real(all3.cavity[1, 1, 1]),
            real(scatShellBlm(all3)[1, 1, 1]); rtol = 1e-12)
    end

    @testset "hydration on a molecule with no accessible surface is all zeros" begin
        # Two atoms stacked at one point occlude each other completely; the
        # docstring promises an all-zero B_lm rather than an error.
        mol = scatBuried()
        @test size(Geometry.sasa(mol)[1], 2) == 0
        h = hydration(mol, SCAT_Q, scatLmax, scatHchunk)
        @test all(iszero, h.convex) && all(iszero, h.concave) && all(iszero, h.cavity)
        B = scatShellBlm(h)
        @test size(B) == (1, scatK, length(SCAT_Q))
        @test all(iszero, B)
    end

    @testset "hydration forwards probe to sasa" begin
        mol = scatWater()
        # The default probe is water's (PROBE_RADIUS, 1.4 Å) ...
        @test hydration(mol, [0.0], scatLmax, scatHchunk; nTarget = 60) ==
              hydration(
            mol,
            [0.0],
            scatLmax,
            scatHchunk;
            nTarget = 60,
            probe = PROBE_RADIUS,
        )
        # ... and a bigger probe inflates the accessible surface, which the
        # forward multipole sees exactly via total area * thickness.
        big = scatShellBlm(
            hydration(mol, [0.0], scatLmax, scatHchunk; nTarget = 60, probe = 2.5),
        )
        small = scatShellBlm(
            hydration(
                mol,
                [0.0],
                scatLmax,
                scatHchunk;
                nTarget = 60,
                probe = PROBE_RADIUS,
            ),
        )
        @test real(big[1, 1, 1]) > real(small[1, 1, 1])
        area = sum(Geometry.sasa(mol; probe = 2.5, nTarget = 60)[2])
        @test isapprox(real(big[1, 1, 1]), area * SHELL_THICKNESS / sqrt(4π); rtol = 1e-12)
    end

    @testset "hydration is invariant to _CHUNK" begin
        # As for `excluded`: chunking only reorders the summation.
        mol = scatWater()
        ref = scatShellBlm(hydration(mol, SCAT_Q, scatLmax, UInt64(1); nTarget = 40))
        for c in (UInt64(7), UInt64(40), UInt64(10_000))
            got = scatShellBlm(hydration(mol, SCAT_Q, scatLmax, c; nTarget = 40))
            @test all(i -> checkComplex(got[i], ref[i]), eachindex(ref))
        end
    end

    # -----------------------------------------------------------------------
    # hydration
    # -----------------------------------------------------------------------

    @testset "hydration converges to the Debye intensity of its shell cloud" begin
        # The shell cloud sits a probe radius plus an atomic radius outside the
        # atoms, so its rMax is roughly 3-4 Å larger than the molecule's and it
        # needs a correspondingly higher lMax for the same q, which is why the
        # ladder here starts at 4 rather than 2, and why `scatLconv = 16` is
        # sized off the shell rather than off the atoms.
        mol = scatBlob()
        P, fh = scatShell(mol, SCAT_Q; nTarget = 80)
        ref = scatDebye(SCAT_Q, P, fh)
        errs = [
            scatRelerr(
                selfScatter(
                    scatShellBlm(hydration(mol, SCAT_Q, L, UInt64(64); nTarget = 80)),
                    partialWaveWeights(L),
                ),
                ref,
            ) for L in (4, 8)
        ]
        @test errs[1] > errs[2]
        @test errs[1] > 1e-3
        @test scatRelerr(
            selfScatter(
                scatShellBlm(
                    hydration(mol, SCAT_Q, scatLconv, UInt64(64); nTarget = 80),
                ),
                scatWconv), ref) < scatTol
    end

    @testset "hydration matches Debye on the cube's shell cloud" begin
        mol = scatCube()
        P, fh = scatShell(mol, SCAT_Q; nTarget = 80)
        got = selfScatter(
            scatShellBlm(hydration(mol, SCAT_Q, scatLconv, UInt64(64); nTarget = 80)),
            scatWconv,
        )
        @test scatRelerr(got, scatDebye(SCAT_Q, P, fh)) < scatTol
    end

    @testset "hydration matches Debye under a non-default probe and thickness" begin
        # The keywords have to reach `sasa`/`_gaussianDummy` intact for
        # the reference (built from the same keywords by hand) to match.
        mol = scatBlob()
        P, fh = scatShell(mol, SCAT_Q; nTarget = 70, probe = 2.0, thickness = 5.0)
        got = selfScatter(
            scatShellBlm(
                hydration(mol, SCAT_Q, scatLconv, UInt64(64);
                    nTarget = 70, probe = 2.0, thickness = 5.0),
            ), scatWconv)
        @test scatRelerr(got, scatDebye(SCAT_Q, P, fh)) < scatTol
    end

    # -----------------------------------------------------------------------
    # The cross term
    # -----------------------------------------------------------------------

    @testset "crossScatter converges to the exact Debye cross sum" begin
        # Σ_{i in ex} Σ_{j in sh} f_i conj(f_j) j_0(q r_ij) between two DIFFERENT
        # point sets. This is the comparison that catches a sign or conjugation
        # slip in the cross path.
        #
        # NOTE the coordinate frames: the atom side uses the raw literals while
        # the shell side is in the molecule's centred frame. Both point sets have
        # to share one origin for a cross term, so the atoms are re-centred here
        # by hand (again from the literals, not from `coordsCartesian`).
        #
        # The "ex" side is built from `computeBLm` + a synthetic per-atom
        # volume, not the molecule's own `vols`, so it carries no dependency on
        # `excludedVolume`. The "sh" side genuinely needs `mol`: its
        # dummies come from `hydration`'s real SASA-driven cloud, which has
        # nothing to do with excluded volume in the first place.
        mol = scatBlob()
        n = size(SCAT_BLOB_X, 2)
        xc = SCAT_BLOB_X .- (sum(SCAT_BLOB_X; dims = 2) ./ n)
        v = [scatVol(e) for e in SCAT_BLOB_E]
        fe = scatDummyAmp(SCAT_BLOB_E, SCAT_Q)
        P, fh = scatShell(mol, SCAT_Q; nTarget = 80)
        ref = scatDebye(SCAT_Q, xc, fe, P, fh)
        errs = [
            scatRelerr(
                crossScatter(
                    computeBLm(
                        scatSph(SCAT_BLOB_X),
                        SCAT_Q,
                        _gaussianDummy(v, SCAT_Q),
                        L,
                        UInt64(4),
                    ),
                    scatShellBlm(hydration(mol, SCAT_Q, L, UInt64(64);
                        nTarget = 80)),
                    partialWaveWeights(L)), ref)
            for L in (4, 8)
        ]
        @test errs[1] > errs[2]
        @test errs[1] > 1e-3
        bEx = computeBLm(
            scatSph(SCAT_BLOB_X),
            SCAT_Q,
            _gaussianDummy(v, SCAT_Q),
            scatLconv,
            UInt64(4),
        )
        bSh = scatShellBlm(hydration(mol, SCAT_Q, scatLconv, UInt64(64); nTarget = 80))
        @test scatRelerr(crossScatter(bEx, bSh, scatWconv), ref) < scatTol
        # the cross sum is symmetric under swapping the two species
        @test crossScatter(bEx, bSh, scatWconv) == crossScatter(bSh, bEx, scatWconv)
    end

    # -----------------------------------------------------------------------
    # The assembled I(q)
    # -----------------------------------------------------------------------

    @testset "assembled I(q) matches the Debye-assembled intensity" begin
        # Section 6 restricted to the two dummy species. Both sides use the same
        # (dns, dro); the left side goes through B_lm and the weighted inner
        # product, the right side through three independent O(N²) real-space
        # sums. Agreement closes the loop from geometry to intensity.
        #
        # `B_ex` comes from `computeBLm` + a synthetic volume, not
        # the molecule's own `vols`: `mol` is still built (and still needed) for the
        # `hydration`/SASA side, which is unrelated to excluded volume.
        for (es, X, mkmol) in ((SCAT_CUBE_E, SCAT_CUBE_X, scatCube),
            (SCAT_BLOB_E, SCAT_BLOB_X, scatBlob))
            mol = mkmol()
            xc = X .- (sum(X; dims = 2) ./ size(X, 2))   # shared origin, see above
            v = [scatVol(e) for e in es]
            fe = scatDummyAmp(es, SCAT_Q)
            P, fh = scatShell(mol, SCAT_Q; nTarget = 80)
            dEx = scatDebye(SCAT_Q, xc, fe)
            dSh = scatDebye(SCAT_Q, P, fh)
            dX = scatDebye(SCAT_Q, xc, fe, P, fh)
            bEx = computeBLm(
                scatSph(X),
                SCAT_Q,
                _gaussianDummy(v, SCAT_Q),
                scatLconv,
                UInt64(4),
            )
            bSh = scatShellBlm(
                hydration(mol, SCAT_Q, scatLconv, UInt64(64); nTarget = 80),
            )
            for (dns, dro) in ((CRYSOL_SOLVENT_DENSITY, UNIT_OF_δρ), (1.0, 1.0), (0.2, 0.9))
                ref = dns^2 .* dEx .+ dro^2 .* dSh .- (2 * dns * dro) .* dX
                @test scatRelerr(scatToyI(bEx, bSh, scatWconv, dns, dro), ref) < 1e-9
            end
        end
    end

    @testset "assembled I(0) is (dns*ΣV_ex - dro*ΣV_sh)², straight from geometry" begin
        # At q = 0 every j_0 is 1 and the Debye sums collapse to products of
        # totals, so the whole model becomes a perfect square:
        #   I(0) = (dns Σ_i v_i - dro * total_area * thickness)².
        # A pen-and-paper endpoint that needs neither the oracle nor B_lm.
        # `B_ex`/`V_ex` are synthetic (as above); `mol` is only needed for the
        # `hydration`/SASA side.
        for (es, X, mkmol) in ((SCAT_CUBE_E, SCAT_CUBE_X, scatCube),
            (SCAT_BLOB_E, SCAT_BLOB_X, scatBlob))
            mol = mkmol()
            n = 80
            v = [scatVol(e) for e in es]
            bEx = computeBLm(
                scatSph(X),
                [0.0],
                _gaussianDummy(v, [0.0]),
                scatLconv,
                UInt64(4),
            )
            bSh =
                scatShellBlm(hydration(mol, [0.0], scatLconv, UInt64(64); nTarget = n))
            vEx = sum(v)
            vSh = sum(Geometry.sasa(mol; nTarget = n)[2]) * SHELL_THICKNESS
            @test isapprox(selfScatter(bEx, scatWconv)[1], vEx^2; rtol = 1e-12)
            @test isapprox(selfScatter(bSh, scatWconv)[1], vSh^2; rtol = 1e-12)
            @test isapprox(
                crossScatter(bEx, bSh, scatWconv)[1],
                vEx * vSh;
                rtol = 1e-12,
            )
            for (dns, dro) in ((CRYSOL_SOLVENT_DENSITY, UNIT_OF_δρ), (1.0, 0.0), (0.2, 0.9))
                @test isapprox(scatToyI(bEx, bSh, scatWconv, dns, dro)[1],
                    (dns * vEx - dro * vSh)^2; rtol = 1e-10)
            end
        end
    end

    # …exact limits
    @testset "assembled I(q) sanity guards: non-negative, Cauchy-Schwarz" begin
        # Cheap structural guards, kept only to catch gross damage; the
        # ground-truth comparisons above are what actually pin the values.
        # I is, mode by mode, |dns*B_ex - dro*B_sh|², so non-negativity follows
        # from the weighted inner product being positive semi-definite.
        # `B_ex` synthetic as above; `mol` only needed for `hydration`.
        mol = scatBlob()
        v = [scatVol(e) for e in SCAT_BLOB_E]
        bEx = computeBLm(
            scatSph(SCAT_BLOB_X),
            SCAT_Q,
            _gaussianDummy(v, SCAT_Q),
            scatLconv,
            UInt64(4),
        )
        bSh = scatShellBlm(hydration(mol, SCAT_Q, scatLconv, UInt64(64); nTarget = 80))
        sEx = selfScatter(bEx, scatWconv)
        sSh = selfScatter(bSh, scatWconv)
        X = crossScatter(bEx, bSh, scatWconv)
        for k in eachindex(SCAT_Q)
            @test abs(X[k]) ≤ sqrt(sEx[k] * sSh[k]) * (1 + 1e-10)
        end
        for (dns, dro) in ((CRYSOL_SOLVENT_DENSITY, UNIT_OF_δρ), (0.5, -0.2), (-1.7, 2.3))
            I = scatToyI(bEx, bSh, scatWconv, dns, dro)
            @test I isa AbstractVector{<:Real}
            @test length(I) == length(SCAT_Q)
            @test all(isfinite, I) && all(≥(0.0), I)
        end
        # switching a contrast off drops two terms exactly (0.0 * x == 0.0)
        @test scatToyI(bEx, bSh, scatWconv, 0.7, 0.0) == 0.7^2 .* sEx
        @test scatToyI(bEx, bSh, scatWconv, 0.0, 0.4) == 0.4^2 .* sSh
        @test all(iszero, scatToyI(bEx, bSh, scatWconv, 0.0, 0.0))
        # and with the two species identical the three terms cancel identically
        @test crossScatter(bEx, bEx, scatWconv) == sEx
        @test all(iszero, scatToyI(bEx, bEx, scatWconv, 0.75, 0.75))
    end

    # -----------------------------------------------------------------------
    # The vacuum amplitude (two-channel complex form factors) through computeBLm
    # -----------------------------------------------------------------------

    let
        scatFfmol = scatMol("ffmol", SCAT_FF_E, SCAT_FF_X)
        # oracle-side per-atom amplitude, assembled from the hardcoded table only
        scatFfamp = reduce(vcat, [permutedims(SCAT_FF_TABLE[e]) for e in SCAT_FF_E])
        # pipeline-side amplitude: the live FormFactor
        # tables, as speciesMultipoles builds it
        scatFfampLive(q, energy) =
            formFactors(formFactorTable(energy, SCAT_FF_E, q), SCAT_FF_E, q)

        @testset "the live form factors match the hardcoded oracle table" begin
            # Same role as the radii guard: if the xraydb tables or the backend
            # change, that reports itself here rather than as a Debye mismatch,
            # and SCAT_FF_TABLE is what needs regenerating.
            amp = scatFfampLive(SCAT_Q, SCAT_FF_ENERGY)
            @test size(amp) == size(scatFfamp)
            @test all(i -> checkComplex(amp[i], scatFfamp[i]), eachindex(scatFfamp))
            @test any(x -> imag(x) != 0, scatFfamp)   # the fixture really is anomalous
        end

        @testset "computeBLm on complex form factors has two channels near an edge" begin
            B = computeBLm(coordsSpherical(scatFfmol), SCAT_Q,
                scatFfampLive(SCAT_Q, SCAT_FF_ENERGY), scatLmax, scatChunk)
            @test size(B) == (2, scatK, length(SCAT_Q))   # f'' != 0 at 8 keV
            @test all(isfinite, B)
            # ... and a real amplitude collapses back to one channel: at 1 eV
            # the tabulated f'' is zero (test-formfactor.jl pins that too).
            b1 = computeBLm(coordsSpherical(scatFfmol), SCAT_Q,
                scatFfampLive(SCAT_Q, 1.0), scatLmax, scatChunk)
            @test size(b1, 1) == 1
        end

        @testset "the q = 0 limit is Σ_i f_i(0)/√(4π), channel by channel" begin
            # Same l = 0 collapse as the dummy species, but Re(f) and Im(f) land
            # in separate channels rather than being folded together. Both sums
            # come from the hardcoded table.
            B = computeBLm(coordsSpherical(scatFfmol), [0.0],
                scatFfampLive([0.0], SCAT_FF_ENERGY), scatLmax, scatChunk)
            @test isapprox(real(B[1, 1, 1]),
                sum(real, scatFfamp[:, 1]) / sqrt(4π); rtol = 1e-10)
            @test isapprox(real(B[2, 1, 1]),
                sum(imag, scatFfamp[:, 1]) / sqrt(4π); rtol = 1e-10)
            for c in axes(B, 1)
                @test all(k -> checkComplex(B[c, k, 1], 0.0), 2:scatK)
            end
        end

        @testset "the complex-f partial-wave sum reproduces the exact Debye intensity" begin
            # The general complex Debye form, Re Σ_ij f_i conj(f_j) j_0(q r_ij),
            # against the two-channel partial-wave sum. `partialWaveWeights`'
            # docstring records a MEASURED 3% error from folding a complex f directly
            # instead of splitting it, so a mismatch here that does not shrink with lMax
            # would mean the channel split is wrong, not that lMax is too small.
            ref = scatDebye(SCAT_Q, SCAT_FF_X, scatFfamp)
            vac(L) = computeBLm(coordsSpherical(scatFfmol), SCAT_Q,
                scatFfampLive(SCAT_Q, SCAT_FF_ENERGY), L, UInt64(4))
            errs = [
                scatRelerr(selfScatter(vac(L), partialWaveWeights(L)), ref) for
                L in (1, 2, 4)
            ]
            @test all(k -> errs[k] > errs[k+1], 1:(length(errs)-1))
            @test errs[1] > 1e-3
            @test scatRelerr(selfScatter(vac(scatLconv), scatWconv), ref) < scatTol
        end
    end

    @testset "the channel split survives an f'' as large as f'" begin
        # `partialWaveWeights`' docstring records a MEASURED 3% error from
        # folding a complex f directly instead of splitting it. Real 8 keV
        # f''/f' is ~0.15; here it is 1.0, which magnifies that failure mode
        # by ~an order of magnitude. Converging to the Float64 floor anyway
        # is strong evidence the two channels are combined correctly.
        heavy = ComplexF64[
            (1.0 + 1.0im) * SCAT_STUBAMP[i, k]
            for i in axes(SCAT_STUBAMP, 1), k in axes(SCAT_STUBAMP, 2)
        ]
        B = computeBLm(coordsSpherical(scatStubmol()), SCAT_Q, heavy,
            scatLconv, scatChunk)
        @test size(B, 1) == 2
        @test scatRelerr(selfScatter(B, scatWconv),
            scatDebye(SCAT_Q, SCAT_STUB_X, heavy)) < scatTol
    end

    @testset "a real-amplitude stub collapses to one channel" begin
        # Im(f) identically zero must take the C = 1 branch, and still match Debye.
        re = ComplexF64.(real.(SCAT_STUBAMP))
        B = computeBLm(coordsSpherical(scatStubmol()), SCAT_Q, re,
            scatLconv, scatChunk)
        @test size(B, 1) == 1
        @test scatRelerr(selfScatter(B, scatWconv),
            scatDebye(SCAT_Q, SCAT_STUB_X, re)) < scatTol
    end
end
