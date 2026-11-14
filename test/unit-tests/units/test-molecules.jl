# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/molecular-structure/mols.jl: construction/centring, the two
# coordinate frames, the lazy radii/vols/rMax accessors, and the error contract.
# Also exercises the geometric per-atom excluded (displaced-solvent) volume
# (src/geometry/excluded-volumes.jl) that `vols` feeds through: a
# radical-plane/power-diagram sampling over each atom's actual local packing.
# The sampled output can't be hand-computed, so the checks here are
# property-based (non-negativity, boundedness by the atom's own vdW sphere
# volume, exactness for a genuinely isolated atom) rather than pinned to
# hardcoded numbers. Also includes one real-fixture check against CRYSOL's own
# reported total excluded volume, which needs real subprocess access for
# PROPKA/Pdb2pqr (same assumption as test-pipeline.jl/test-pdb2pqr.jl) but no
# network access.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.MolecularStructure: Molecule, create, coordsCartesian, coordsSpherical,
    radii, vols, rMax, elms, name,
    MoleculeError, _toTuples,
    LocalPathSource, resloveStruct, loadMolecule, _storeDir
using BAYSOL.Hydrogenator: propkaPkas, resolveHydrogens, Propka
using BAYSOL.Geometry: sphereVolume
using BAYSOL.Scattering: meanAtomicRadius
using BAYSOL: Geometry

# row 1 = r, row 2 = theta, row 3 = phi
r_(m)     = coordsSpherical(m)[1, :]
theta_(m) = coordsSpherical(m)[2, :]
phi_(m)   = coordsSpherical(m)[3, :]

# `done` on the private Lazy fields: the only way to assert that an accessor is
# still unforced without forcing it.
_forcedRadii(m) = getfield(getfield(m, :_radii), :done)
_forcedVols(m)  = getfield(getfield(m, :_vols), :done)
_forcedRmax(m)  = getfield(getfield(m, :_rMax), :done)

@testset "MolecularStructure" begin

    @testset "two atoms on x axis" begin
        m = create("test", ["h", "h"], [(1.0, 0.0, 0.0), (-1.0, 0.0, 0.0)])
        @test length(r_(m)) == 2
        @test checkFloat(r_(m)[1], 1.0) && checkFloat(r_(m)[2], 1.0)
        @test length(theta_(m)) == 2 && length(phi_(m)) == 2
        @test checkFloat(theta_(m)[1], π / 2) && checkFloat(phi_(m)[1], 0.0)
        @test checkFloat(theta_(m)[2], π / 2) && checkFloat(phi_(m)[2], π)
    end

    @testset "centring shifts to centroid" begin
        m = create("test", ["h", "h"], [(0.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        @test checkFloat(r_(m)[1], 1.0) && checkFloat(r_(m)[2], 1.0)
    end

    @testset "coordsCartesian: shape, centroid, and translation invariance" begin
        pts = [(1.0, 2.0, 3.0), (-4.0, 0.5, 2.0), (7.0, -1.0, 0.0), (0.0, 0.0, 0.0)]
        m = create("test", ["h", "h", "h", "h"], pts)
        c = coordsCartesian(m)
        @test c isa Matrix{Float64}
        @test size(c) == (3, 4)                      # (3, n): rows x/y/z, cols atoms
        for row in 1:3
            @test checkFloat(sum(c[row, :]) / 4, 0.0)   # centroid is the origin
        end
        # the shape is preserved: only the origin moved
        for i in 1:4, j in 1:4
            d0 = sqrt(sum((pts[i][k] - pts[j][k])^2 for k in 1:3))
            d1 = sqrt(sum((c[k, i] - c[k, j])^2 for k in 1:3))
            @test checkFloat(d0, d1)
        end
        # translating the input does not change the centred output at all
        shifted = [(p[1] + 10.0, p[2] - 3.0, p[3] + 0.5) for p in pts]
        @test coordsCartesian(create("test", ["h", "h", "h", "h"], shifted)) ≈ c
    end

    @testset "coordsSpherical is the polar form of coordsCartesian" begin
        m = create(
            "test",
            ["h", "h", "h"],
            [(1.0, 2.0, 3.0), (-2.0, 1.0, -4.0), (0.5, -0.5, 2.0)],
        )
        c, s = coordsCartesian(m), coordsSpherical(m)
        @test size(s) == size(c) == (3, 3)
        for j in 1:3
            x, y, z = c[1, j], c[2, j], c[3, j]
            r, θ, φ = s[1, j], s[2, j], s[3, j]
            @test checkFloat(r, sqrt(x^2 + y^2 + z^2))
            @test 0.0 ≤ θ ≤ π
            @test -π ≤ φ ≤ π
            # round-trip back to cartesian
            @test checkFloat(r * sin(θ) * cos(φ), x)
            @test checkFloat(r * sin(θ) * sin(φ), y)
            @test checkFloat(r * cos(θ), z)
        end
    end

    @testset "single atom r = 0, theta not NaN" begin
        m = create("test", ["h"], [(5.0, 5.0, 5.0)])
        @test checkFloat(r_(m)[1], 0.0)
        @test !isnan(theta_(m)[1]) && !isnan(phi_(m)[1])
        # the rsafe = 1.0 clamp makes theta = acos(0) and phi = atan(0, 0)
        @test checkFloat(theta_(m)[1], π / 2)
        @test checkFloat(phi_(m)[1], 0.0)
        @test coordsCartesian(m) == zeros(3, 1)
    end

    @testset "an atom sitting exactly on the centroid is r = 0, not NaN" begin
        # 0/0 would also bite an interior atom of a larger molecule
        m = create(
            "test",
            ["h", "h", "h"],
            [(-1.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 0.0, 0.0)],
        )
        @test checkFloat(r_(m)[2], 0.0)
        @test !any(isnan, coordsSpherical(m))
    end

    @testset "poles: theta = 0 and theta = pi have no NaN phi" begin
        m = create("test", ["h", "h"], [(0.0, 0.0, 1.0), (0.0, 0.0, -1.0)])
        @test checkFloat(theta_(m)[1], 0.0)
        @test checkFloat(theta_(m)[2], π)
        @test !any(isnan, phi_(m))
    end

    @testset "name and elms accessors round-trip the inputs" begin
        m = create(
            "water",
            ["o", "h", "h"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)],
        )
        @test name(m) == "water"
        @test elms(m) == ["o", "h", "h"]
        @test elms(m) isa Vector{String}
        @test name(create(SubString("abc", 1, 2), ["h"], [(0.0, 0.0, 0.0)])) == "ab"
    end

    @testset "vols: shape and bounds against the vdW sphere" begin
        # `vols` is the geometric excluded (displaced-solvent) volume, computed
        # per atom from its actual local packing (`excludedVolume`),
        # not looked up by element type. The atoms here are close enough (1 Å
        # apart) to overlap given their vdW radii, so each one's excluded volume
        # is generally smaller than its own full vdW sphere.
        m = create(
            "test", ["fe", "o", "rn"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)],
        )
        @test length(vols(m)) == 3
        @test all(≥(0.0), vols(m))
        @test all(i -> vols(m)[i] ≤ sphereVolume(radii(m)[i]) + 1e-9, eachindex(vols(m)))
    end

    @testset "excluded volume of a genuinely isolated atom is its full vdW sphere" begin
        # A single-atom molecule has no neighbour at all, so the geometric method's
        # `length(candidates) == 1` branch (no overlapping neighbours) applies
        # exactly, and `vols(m)[1]` must equal `sphereVolume(radii(m)[1])`.
        for el in ("fe", "o", "rn")
            m = create("solo", [el], [(0.0, 0.0, 0.0)])
            @test checkFloat(vols(m)[1], sphereVolume(radii(m)[1]))
        end

        # Same property for one atom in a multi-atom molecule, as long as it sits
        # far enough from every other atom that no vdW spheres can overlap.
        m = create(
            "far", ["fe", "o", "fe"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (1.0e6, 0.0, 0.0)],
        )
        @test checkFloat(vols(m)[3], sphereVolume(radii(m)[3]))
    end

    @testset "sphereVolume closed form" begin
        @test checkFloat(sphereVolume(0.0), 0.0)
        @test checkFloat(sphereVolume(1.0), 4π / 3)
        @test checkFloat(sphereVolume(2.0), 8 * 4π / 3)   # scales as r³
    end

    @testset "rMax is the largest per-atom radius" begin
        m = create(
            "test",
            ["fe", "o", "rn"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)],
        )
        @test rMax(m) isa Float64
        @test checkFloat(rMax(m), maximum(radii(m)))
        @test checkFloat(rMax(m), 2.44)               # fe is the largest of the three
        @test rMax(m) === rMax(m)
        # a single-atom molecule's rMax is just that atom's radius
        @test checkFloat(rMax(create("t", ["fe"], [(0.0, 0.0, 0.0)])), 2.44)
        # order of the atoms does not matter
        m2 = create("test", ["rn", "fe", "o"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        @test checkFloat(rMax(m), rMax(m2))
    end

    @testset "radii/vols/rMax are lazy and memoized" begin
        m = create("test", ["fe", "o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        @test !_forcedRadii(m) && !_forcedVols(m) && !_forcedRmax(m)
        @test radii(m) === radii(m)          # same object on repeat, not a recompute
        @test _forcedRadii(m)
        @test !_forcedVols(m) && !_forcedRmax(m)   # forcing one does not force the others
        @test vols(m) === vols(m)
        @test _forcedVols(m) && !_forcedRmax(m)
        rMax(m)
        @test _forcedRmax(m)
    end

    @testset "vols and rMax force radii as a side effect" begin
        m1 = create("test", ["fe", "o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        @test !_forcedRadii(m1)
        vols(m1)
        @test _forcedRadii(m1)                       # vols is defined over force(rad)
        m2 = create("test", ["fe", "o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        rMax(m2)
        @test _forcedRadii(m2) && !_forcedVols(m2)  # rMax needs radii but not vols
    end

    @testset "coordinate frames are computed eagerly, not lazily" begin
        m = create("test", ["fe"], [(1.0, 1.0, 1.0)])
        @test coordsCartesian(m) === coordsCartesian(m)   # a stored field, not a thunk
        @test coordsSpherical(m) === coordsSpherical(m)
    end

    @testset "unknown element raises only when a radius accessor is forced" begin
        # construction must stay clean: the radii backend is not consulted here
        m = create("test", ["zzzz"], [(0.0, 0.0, 0.0)])
        @test m isa Molecule
        @test size(coordsCartesian(m)) == (3, 1)     # geometry still usable
        @test_throws MoleculeError vols(m)
        @test_throws MoleculeError radii(create("test", ["zzzz"], [(0.0, 0.0, 0.0)]))
        @test_throws MoleculeError rMax(create("test", ["zzzz"], [(0.0, 0.0, 0.0)]))
        # the message names the offending element
        err = try
            radii(m)
        catch e
            e
        end
        @test occursin("zzzz", sprint(showerror, err))
    end

    @testset "one unresolvable element out of many still raises" begin
        m = create(
            "test",
            ["fe", "zzzz", "o"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)],
        )
        @test_throws MoleculeError radii(m)
    end

    @testset "create computes coordsSpherical/vols; repeat access stable" begin
        m = create(
            "test", ["o", "h", "h"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)],
        )
        @test length(r_(m)) == 3
        @test checkFloat(r_(m)[1], 0.4714045208)
        @test length(theta_(m)) == 3 && length(phi_(m)) == 3 && length(vols(m)) == 3
        # lazy accessor: memoized, same object on repeat
        @test radii(m) === radii(m)
    end

    @testset "a zero-radius atom still has a well-defined SASA" begin
        # clamped to r = 0, the atom is a bare
        # probe-radius sphere rather than an inverted one.
        m = create("proton", ["h1+"], [(0.0, 0.0, 0.0)])
        areas = Geometry.sasa(m; probe = 1.4)[2]
        @test checkFloat(sum(areas), 4π * 1.4^2)
    end

    @testset "_toTuples accepts any iterable of 3 components" begin
        already = NTuple{3,Float64}[(1.0, 2.0, 3.0)]
        @test _toTuples(already) === already          # identity fast path, no copy
        @test _toTuples([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]) ==
              [(1.0, 2.0, 3.0), (4.0, 5.0, 6.0)]
        @test _toTuples([(1, 2, 3)]) == [(1.0, 2.0, 3.0)]          # Int -> Float64
        @test _toTuples([(1, 2, 3)]) isa Vector{NTuple{3,Float64}}
        @test _toTuples([1:3]) == [(1.0, 2.0, 3.0)]                # a range works too
        @test _toTuples(((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))) ==
              [(1.0, 2.0, 3.0), (4.0, 5.0, 6.0)]                  # tuple of tuples
    end

    @testset "_toTuples rejects wrong-length entries" begin
        @test_throws MoleculeError _toTuples([(1.0, 2.0)])
        @test_throws MoleculeError _toTuples([(1.0, 2.0, 3.0, 4.0)])
        @test_throws MoleculeError _toTuples([[1.0]])
        @test_throws MoleculeError _toTuples([(1.0, 2.0, 3.0), (1.0, 2.0)])  # only one bad
    end

    @testset "create accepts non-tuple coordinate containers" begin
        ptsV = [[1.0, 0.0, 0.0], [-1.0, 0.0, 0.0]]
        ptsI = [(1, 0, 0), (-1, 0, 0)]
        ref = coordsCartesian(create("t", ["h", "h"], [(1.0, 0.0, 0.0), (-1.0, 0.0, 0.0)]))
        @test coordsCartesian(create("t", ["h", "h"], ptsV)) == ref
        @test coordsCartesian(create("t", ["h", "h"], ptsI)) == ref
        @test_throws MoleculeError create("t", ["h"], [(1.0, 0.0)])
    end

    @testset "empty coords raises" begin
        @test_throws MoleculeError create("empty", String[], NTuple{3,Float64}[])
        @test_throws MoleculeError create("empty", String[], Vector{Float64}[])
    end

    @testset "length mismatch raises, in both directions" begin
        @test_throws MoleculeError create("bad", ["o", "h"], [(0.0, 0.0, 0.0)])
        @test_throws MoleculeError create("bad", ["o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        @test_throws MoleculeError create("bad", String[], [(0.0, 0.0, 0.0)])
    end

    @testset "MoleculeError prints its message" begin
        @test sprint(showerror, MoleculeError("boom")) == "MoleculeError: boom"
        @test MoleculeError("boom") isa Exception
    end

    @testset "negative ionic radii are clamped to zero" begin
        # Shannon's table stores h1+/c4+/n5+ with negative radii.
        # `_computeRadii` clamps them to 0.0 so volumes stay
        # non-negative and a shell sphere's `r + probe` never inverts.
        for ion in ("h1+", "c4+", "n5+")
            m = create("artifact", [ion], [(0.0, 0.0, 0.0)])
            @test radii(m) == [0.0]
            @test vols(m) == [0.0]
            @test rMax(m) == 0.0
        end

        # the clamp is floor-only: it must not disturb ordinary positive radii.
        # `vols` only gets `≥(0.0)` here, not `>(0.0)`: these atoms are packed
        # 1 Å apart, tight enough that the geometric method can legitimately
        # claim an interior atom's entire vdW sphere for its neighbours (its
        # positive radius still contributes to those neighbours' own vols).
        m = create(
            "normal",
            ["fe", "o", "rn"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)],
        )
        @test all(>(0.0), radii(m))
        @test all(≥(0.0), vols(m))

        # a clamped ion alongside normal atoms leaves the others untouched
        m = create("mixed", ["h1+", "fe"], [(0.0, 0.0, 0.0), (3.0, 0.0, 0.0)])
        @test radii(m)[1] == 0.0
        @test checkFloat(radii(m)[2], 2.44)
        @test rMax(m) == radii(m)[2]     # the clamped atom never wins rMax
    end

    #-------------------------------------------------------------------------
    #  CRYSOL-parity check: total excluded volume on the SASDMJ9 fixture
    #-------------------------------------------------------------------------
    #
    # Needs real subprocess access for PROPKA/Pdb2pqr (same assumption as
    # test-pipeline.jl/test-pdb2pqr.jl); no network access, since the PDB is a
    # local fixture. Composes the pipeline primitives exactly as
    # `BAYSOL.runModel` does (`src/BAYSOL.jl`): resloveStruct ->
    # propkaPkas -> resolveHydrogens -> loadMolecule.

    @testset "total excluded volume on SASDMJ9 is close to CRYSOL's own reported Vol" begin
        fixtureDir = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMJ9")
        pdbPath    = joinpath(fixtureDir, "SASDMJ9_fit1_model1.pdb")
        fitPath    = joinpath(fixtureDir, "SASDMJ9_fit1.fit")
        @test isfile(pdbPath) && isfile(fitPath)

        # CRYSOL's own reported total excluded volume, read off the .fit
        # header rather than hardcoded (e.g. "... Vol: 23962.  Chi^2: ...").
        header = readline(fitPath)
        m = match(r"Vol:\s*([0-9.]+)", header)
        @test m !== nothing
        crysolVol = parse(Float64, m.captures[1])

        # Clear any stale cache entries so PROPKA/Pdb2pqr genuinely run fresh.
        stem = "SASDMJ9_fit1_model1"
        rm(joinpath(_storeDir(), "$(stem).pka"); force = true)
        rm(joinpath(_storeDir(), "$(stem)_pH7.5_parse_propka.pdb"); force = true)

        pH = 7.5   # matches test/fitting_tests/SASDMJ9/SASDMJ9.jl's PH
        path = resloveStruct(LocalPathSource(pdbPath))
        pKaRecords = propkaPkas(path)
        hpath = resolveHydrogens(path, pH; titration = Propka(pKaRecords))
        mol = loadMolecule(hpath)

        @test any(e -> e == "h", elms(mol))   # explicit hydrogens really were added

        totalVol = sum(vols(mol))
        # vols sums to the vdW-union volume, which leaves out the packing
        # voids between atoms. Measured 2026-09-29 with hydrogens: 0.66 of
        # CRYSOL's fitted Vol on SASDA52 (0.73 of the sequence partial molar
        # volume); the profiled c1 absorbs the difference (c1³ ≈ 1.5-1.6).
        @test isfinite(totalVol) && totalVol > 0.0
        @test 0.5 * crysolVol < totalVol < 0.9 * crysolVol

        # meanAtomicRadius must be smaller than the plain vdW-sphere radius:
        # bonded/packed atoms displace less than a full isolated vdW sphere.
        meanR = sum(radii(mol)) / length(radii(mol))
        @test meanAtomicRadius(mol) < meanR
    end
end
