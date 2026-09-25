# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/MolecularStructure/Mols.jl: construction/centring, the two
# coordinate frames, the lazy radii/vols/r_max accessors, and the error contract.
# Also exercises the geometric per-atom excluded (displaced-solvent) volume
# (src/MolecularStructure/ExcludedVolumes.jl) that `vols` feeds through: a
# radical-plane/power-diagram sampling over each atom's actual local packing.
# The sampled output can't be hand-computed, so the checks here are
# property-based (non-negativity, boundedness by the atom's own vdW sphere
# volume, exactness for a genuinely isolated atom) rather than pinned to
# hardcoded numbers. Also includes one real-fixture check against CRYSOL's own
# reported total excluded volume, which needs real subprocess access for
# PROPKA/PDB2PQR (same assumption as test_pipeline.jl/test_pdb2pqr.jl) but no
# network access.
include(joinpath(@__DIR__, "testsetup.jl"))

using BAYSOL.MolecularStructure:   Molecule, create, coords_cartesian, coords_spherical,
                    radii, vols, r_max, elms, name, sphere_volume,
                    MoleculeError, _to_tuples,
                    LocalPathSource, resolve_structure, propka_pKas, resolve_hydrogens,
                    load_molecule, _store_dir
using BAYSOL.Scattering: mean_atomic_radius
using BAYSOL.Solvation: SASA

# row 1 = r, row 2 = theta, row 3 = phi
r_(m)     = coords_spherical(m)[1, :]
theta_(m) = coords_spherical(m)[2, :]
phi_(m)   = coords_spherical(m)[3, :]

# `done` on the private Lazy fields: the only way to assert that an accessor is
# still unforced without forcing it.
_forced_radii(m) = getfield(getfield(m, :_radii), :done)
_forced_vols(m)  = getfield(getfield(m, :_vols),  :done)
_forced_rmax(m)  = getfield(getfield(m, :_r_max), :done)

# A stand-in RadiiSource, to prove `radii_source` is actually consulted rather
# than the default AtomicRadiiSource being hard-wired in.
struct ConstantRadii <: BAYSOL.AtomicRadii.RadiiSource
    value::Float64
end
BAYSOL.AtomicRadii.lookup(s::ConstantRadii, ions::AbstractVector{<:AbstractString}) =
    Tuple{String,Union{Float64,Nothing}}[(String(i), s.value) for i in ions]

struct NeverResolves <: BAYSOL.AtomicRadii.RadiiSource end
BAYSOL.AtomicRadii.lookup(::NeverResolves, ions::AbstractVector{<:AbstractString}) =
    Tuple{String,Union{Float64,Nothing}}[(String(i), nothing) for i in ions]

@testset "MolecularStructure" begin

    @testset "two atoms on x axis" begin
        m = create("test", ["h", "h"], [(1.0, 0.0, 0.0), (-1.0, 0.0, 0.0)])
        @test length(r_(m)) == 2
        @test check_float(r_(m)[1], 1.0) && check_float(r_(m)[2], 1.0)
        @test length(theta_(m)) == 2 && length(phi_(m)) == 2
        @test check_float(theta_(m)[1], π / 2) && check_float(phi_(m)[1], 0.0)
        @test check_float(theta_(m)[2], π / 2) && check_float(phi_(m)[2], π)
    end

    @testset "centring shifts to centroid" begin
        m = create("test", ["h", "h"], [(0.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        @test check_float(r_(m)[1], 1.0) && check_float(r_(m)[2], 1.0)
    end

    @testset "coords_cartesian: shape, centroid, and translation invariance" begin
        pts = [(1.0, 2.0, 3.0), (-4.0, 0.5, 2.0), (7.0, -1.0, 0.0), (0.0, 0.0, 0.0)]
        m = create("test", ["h", "h", "h", "h"], pts)
        c = coords_cartesian(m)
        @test c isa Matrix{Float64}
        @test size(c) == (3, 4)                      # (3, n): rows x/y/z, cols atoms
        for row in 1:3
            @test check_float(sum(c[row, :]) / 4, 0.0)   # centroid is the origin
        end
        # the shape is preserved: only the origin moved
        for i in 1:4, j in 1:4
            d0 = sqrt(sum((pts[i][k] - pts[j][k])^2 for k in 1:3))
            d1 = sqrt(sum((c[k, i] - c[k, j])^2 for k in 1:3))
            @test check_float(d0, d1)
        end
        # translating the input does not change the centred output at all
        shifted = [(p[1] + 10.0, p[2] - 3.0, p[3] + 0.5) for p in pts]
        @test coords_cartesian(create("test", ["h", "h", "h", "h"], shifted)) ≈ c
    end

    @testset "coords_spherical is the polar form of coords_cartesian" begin
        m = create("test", ["h", "h", "h"], [(1.0, 2.0, 3.0), (-2.0, 1.0, -4.0), (0.5, -0.5, 2.0)])
        c, s = coords_cartesian(m), coords_spherical(m)
        @test size(s) == size(c) == (3, 3)
        for j in 1:3
            x, y, z = c[1, j], c[2, j], c[3, j]
            r, θ, φ = s[1, j], s[2, j], s[3, j]
            @test check_float(r, sqrt(x^2 + y^2 + z^2))
            @test 0.0 ≤ θ ≤ π
            @test -π ≤ φ ≤ π
            # round-trip back to cartesian
            @test check_float(r * sin(θ) * cos(φ), x)
            @test check_float(r * sin(θ) * sin(φ), y)
            @test check_float(r * cos(θ), z)
        end
    end

    @testset "single atom r = 0, theta not NaN" begin
        m = create("test", ["h"], [(5.0, 5.0, 5.0)])
        @test check_float(r_(m)[1], 0.0)
        @test !isnan(theta_(m)[1]) && !isnan(phi_(m)[1])
        # the rsafe = 1.0 clamp makes theta = acos(0) and phi = atan(0, 0)
        @test check_float(theta_(m)[1], π / 2)
        @test check_float(phi_(m)[1], 0.0)
        @test coords_cartesian(m) == zeros(3, 1)
    end

    @testset "an atom sitting exactly on the centroid is r = 0, not NaN" begin
        # 0/0 would also bite an interior atom of a larger molecule
        m = create("test", ["h", "h", "h"], [(-1.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        @test check_float(r_(m)[2], 0.0)
        @test !any(isnan, coords_spherical(m))
    end

    @testset "poles: theta = 0 and theta = pi have no NaN phi" begin
        m = create("test", ["h", "h"], [(0.0, 0.0, 1.0), (0.0, 0.0, -1.0)])
        @test check_float(theta_(m)[1], 0.0)
        @test check_float(theta_(m)[2], π)
        @test !any(isnan, phi_(m))
    end

    @testset "name and elms accessors round-trip the inputs" begin
        m = create("water", ["o", "h", "h"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)])
        @test name(m) == "water"
        @test elms(m) == ["o", "h", "h"]
        @test elms(m) isa Vector{String}
        @test name(create(SubString("abc", 1, 2), ["h"], [(0.0, 0.0, 0.0)])) == "ab"
    end

    @testset "vols: shape and bounds against the vdW sphere" begin
        # `vols` is the geometric excluded (displaced-solvent) volume, computed
        # per atom from its actual local packing (ExcludedVolumes.excluded_volume),
        # not looked up by element type. The atoms here are close enough (1 Å
        # apart) to overlap given their vdW radii, so each one's excluded volume
        # is generally smaller than its own full vdW sphere.
        m = create(
            "test", ["fe", "o", "rn"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)]
        )
        @test length(vols(m)) == 3
        @test all(≥(0.0), vols(m))
        @test all(i -> vols(m)[i] ≤ sphere_volume(radii(m)[i]) + 1e-9, eachindex(vols(m)))
    end

    @testset "excluded volume of a genuinely isolated atom is its full vdW sphere" begin
        # A single-atom molecule has no neighbour at all, so the geometric method's
        # `length(candidates) == 1` branch (no overlapping neighbours) applies
        # exactly, and `vols(m)[1]` must equal `sphere_volume(radii(m)[1])`.
        for el in ("fe", "o", "rn")
            m = create("solo", [el], [(0.0, 0.0, 0.0)])
            @test check_float(vols(m)[1], sphere_volume(radii(m)[1]))
        end

        # Same property for one atom in a multi-atom molecule, as long as it sits
        # far enough from every other atom that no vdW spheres can overlap.
        m = create(
            "far", ["fe", "o", "fe"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (1.0e6, 0.0, 0.0)]
        )
        @test check_float(vols(m)[3], sphere_volume(radii(m)[3]))
    end

    @testset "sphere_volume closed form" begin
        @test check_float(sphere_volume(0.0), 0.0)
        @test check_float(sphere_volume(1.0), 4π / 3)
        @test check_float(sphere_volume(2.0), 8 * 4π / 3)   # scales as r³
    end

    @testset "r_max is the largest per-atom radius" begin
        m = create("test", ["fe", "o", "rn"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        @test r_max(m) isa Float64
        @test check_float(r_max(m), maximum(radii(m)))
        @test check_float(r_max(m), 2.44)               # fe is the largest of the three
        @test r_max(m) === r_max(m)
        # a single-atom molecule's r_max is just that atom's radius
        @test check_float(r_max(create("t", ["fe"], [(0.0, 0.0, 0.0)])), 2.44)
        # order of the atoms does not matter
        m2 = create("test", ["rn", "fe", "o"],
                    [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        @test check_float(r_max(m), r_max(m2))
    end

    @testset "radii/vols/r_max are lazy and memoized" begin
        m = create("test", ["fe", "o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        @test !_forced_radii(m) && !_forced_vols(m) && !_forced_rmax(m)
        @test radii(m) === radii(m)          # same object on repeat, not a recompute
        @test _forced_radii(m)
        @test !_forced_vols(m) && !_forced_rmax(m)   # forcing one does not force the others
        @test vols(m) === vols(m)
        @test _forced_vols(m) && !_forced_rmax(m)
        r_max(m)
        @test _forced_rmax(m)
    end

    @testset "vols and r_max force radii as a side effect" begin
        m1 = create("test", ["fe", "o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        @test !_forced_radii(m1)
        vols(m1)
        @test _forced_radii(m1)                       # vols is defined over force(rad)
        m2 = create("test", ["fe", "o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        r_max(m2)
        @test _forced_radii(m2) && !_forced_vols(m2)  # r_max needs radii but not vols
    end

    @testset "coordinate frames are computed eagerly, not lazily" begin
        m = create("test", ["fe"], [(1.0, 1.0, 1.0)])
        @test coords_cartesian(m) === coords_cartesian(m)   # a stored field, not a thunk
        @test coords_spherical(m) === coords_spherical(m)
    end

    @testset "unknown element raises only when a radius accessor is forced" begin
        # construction must stay clean: the radii backend is not consulted here
        m = create("test", ["zzzz"], [(0.0, 0.0, 0.0)])
        @test m isa Molecule
        @test size(coords_cartesian(m)) == (3, 1)     # geometry still usable
        @test_throws MoleculeError vols(m)
        @test_throws MoleculeError radii(create("test", ["zzzz"], [(0.0, 0.0, 0.0)]))
        @test_throws MoleculeError r_max(create("test", ["zzzz"], [(0.0, 0.0, 0.0)]))
        # the message names the offending element
        err = try; radii(m); catch e; e; end
        @test occursin("zzzz", sprint(showerror, err))
    end

    @testset "one unresolvable element out of many still raises" begin
        m = create("test", ["fe", "zzzz", "o"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        @test_throws MoleculeError radii(m)
    end

    @testset "create computes coords_spherical/vols; repeat access stable" begin
        m = create(
            "test", ["o", "h", "h"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
        )
        @test length(r_(m)) == 3
        @test check_float(r_(m)[1], 0.4714045208)
        @test length(theta_(m)) == 3 && length(phi_(m)) == 3 && length(vols(m)) == 3
        @test radii(m) === radii(m)          # lazy accessor: memoized, same object on repeat
    end

    @testset "a custom radii_source is honoured" begin
        # `vols` is computed geometrically from `radii`, so it flows through
        # `radii_source` for any element. These three points are close enough
        # (1 Å apart) that a 2.5 Å radius means the spheres overlap, so `vols`
        # is bounded by but not necessarily equal to the full sphere volume.
        pts = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
        m = create("test", ["rn", "xe", "kr"], pts; radii_source = ConstantRadii(2.5))
        @test radii(m) == [2.5, 2.5, 2.5]
        @test check_float(r_max(m), 2.5)
        @test all(v -> v ≥ 0.0 && v ≤ sphere_volume(2.5) + 1e-9, vols(m))
        # the same elements through the default source give something else entirely
        @test radii(create("test", ["rn", "xe", "kr"], pts)) != radii(m)
        # a source that resolves nothing raises through the same MoleculeError path
        @test_throws MoleculeError radii(create("t", ["o"], [(0.0, 0.0, 0.0)];
                                                radii_source = NeverResolves()))
        # a custom source also lets otherwise-unknown element labels work
        mystery = create("t", ["zzzz"], [(0.0, 0.0, 0.0)]; radii_source = ConstantRadii(1.0))
        @test radii(mystery) == [1.0]
    end

    @testset "_to_tuples accepts any iterable of 3 components" begin
        already = NTuple{3,Float64}[(1.0, 2.0, 3.0)]
        @test _to_tuples(already) === already          # identity fast path, no copy
        @test _to_tuples([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]) ==
                [(1.0, 2.0, 3.0), (4.0, 5.0, 6.0)]
        @test _to_tuples([(1, 2, 3)]) == [(1.0, 2.0, 3.0)]          # Int -> Float64
        @test _to_tuples([(1, 2, 3)]) isa Vector{NTuple{3,Float64}}
        @test _to_tuples([1:3]) == [(1.0, 2.0, 3.0)]                # a range works too
        @test _to_tuples(((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))) ==
                [(1.0, 2.0, 3.0), (4.0, 5.0, 6.0)]                  # tuple of tuples
    end

    @testset "_to_tuples rejects wrong-length entries" begin
        @test_throws MoleculeError _to_tuples([(1.0, 2.0)])
        @test_throws MoleculeError _to_tuples([(1.0, 2.0, 3.0, 4.0)])
        @test_throws MoleculeError _to_tuples([[1.0]])
        @test_throws MoleculeError _to_tuples([(1.0, 2.0, 3.0), (1.0, 2.0)])  # only one bad
    end

    @testset "create accepts non-tuple coordinate containers" begin
        pts_v = [[1.0, 0.0, 0.0], [-1.0, 0.0, 0.0]]
        pts_i = [(1, 0, 0), (-1, 0, 0)]
        ref = coords_cartesian(create("t", ["h", "h"], [(1.0, 0.0, 0.0), (-1.0, 0.0, 0.0)]))
        @test coords_cartesian(create("t", ["h", "h"], pts_v)) == ref
        @test coords_cartesian(create("t", ["h", "h"], pts_i)) == ref
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
        # Shannon's table stores h1+/c4+/n5+ with negative radii. `_compute_radii` 
        # clamps them to 0.0 so volumes stay non-negative and SASA's `r + probe` never inverts.
        for ion in ("h1+", "c4+", "n5+")
            m = create("artifact", [ion], [(0.0, 0.0, 0.0)])
            @test radii(m) == [0.0]
            @test vols(m)  == [0.0]
            @test r_max(m) == 0.0
        end

        # the clamp is floor-only: it must not disturb ordinary positive radii.
        # `vols` only gets `≥(0.0)` here, not `>(0.0)`: these atoms are packed
        # 1 Å apart, tight enough that the geometric method can legitimately
        # claim an interior atom's entire vdW sphere for its neighbours (its
        # positive radius still contributes to those neighbours' own vols).
        m = create("normal", ["fe", "o", "rn"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        @test all(>(0.0), radii(m))
        @test all(≥(0.0), vols(m))

        # a clamped ion alongside normal atoms leaves the others untouched
        m = create("mixed", ["h1+", "fe"], [(0.0, 0.0, 0.0), (3.0, 0.0, 0.0)])
        @test radii(m)[1] == 0.0
        @test check_float(radii(m)[2], 2.44)
        @test r_max(m) == radii(m)[2]     # the clamped atom never wins r_max
    end

    @testset "a zero-radius atom still has a well-defined SASA" begin
        # clamped to r = 0, the atom is a bare probe-radius sphere rather than an inverted one.
        m = create("proton", ["h1+"], [(0.0, 0.0, 0.0)])
        a = SASA.sasa(m; n_occ = 64, n_exp = 256, probe = 1.4)[1]
        @test length(a) == 1
        @test check_float(a[1], 4π * 1.4^2)
    end

    #-------------------------------------------------------------------------
    #  CRYSOL-parity check: total excluded volume on the SASDMJ9 fixture
    #-------------------------------------------------------------------------
    #
    # Needs real subprocess access for PROPKA/PDB2PQR (same assumption as
    # test_pipeline.jl/test_pdb2pqr.jl); no network access, since the PDB is a
    # local fixture. Composes the pipeline primitives exactly as
    # `BAYSOL.run_model` does (`src/BAYSOL.jl`): resolve_structure ->
    # propka_pKas -> resolve_hydrogens -> load_molecule.

    @testset "total excluded volume on SASDMJ9 is close to CRYSOL's own reported Vol" begin
        fixture_dir = joinpath(@__DIR__, "..", "fixtures", "experiments", "SASDMJ9")
        pdb_path    = joinpath(fixture_dir, "SASDMJ9_fit1_model1.pdb")
        fit_path    = joinpath(fixture_dir, "SASDMJ9_fit1.fit")
        @test isfile(pdb_path) && isfile(fit_path)

        # CRYSOL's own reported total excluded volume, read off the .fit
        # header rather than hardcoded (e.g. "... Vol: 23962.  Chi^2: ...").
        header = readline(fit_path)
        m = match(r"Vol:\s*([0-9.]+)", header)
        @test m !== nothing
        crysol_vol = parse(Float64, m.captures[1])

        # Clear any stale cache entries so PROPKA/PDB2PQR genuinely run fresh.
        stem = "SASDMJ9_fit1_model1"
        rm(joinpath(_store_dir(), "$(stem).pka"); force = true)
        rm(joinpath(_store_dir(), "$(stem)_pH7.5.pdb"); force = true)

        pH = 7.5   # matches test/fitting_tests/SASDMJ9/SASDMJ9.jl's PH
        path        = resolve_structure(LocalPathSource(pdb_path))
        pKa_records = propka_pKas(path)
        hpath       = resolve_hydrogens(path, pKa_records, pH)
        mol, _      = load_molecule(hpath)

        @test any(e -> e == "h", elms(mol))   # explicit hydrogens really were added

        total_vol = sum(vols(mol))
        # NEEDS A REAL RUN TO RE-BASELINE: the geometric (radical-plane/
        # power-diagram) method's deviation from CRYSOL's own reported total
        # has never been measured against this fixture, so there is no tight
        # tolerance to assert yet. Only a loose sanity check (positive, finite,
        # same order of magnitude) until that baseline is established.
        @test isfinite(total_vol) && total_vol > 0.0
        @test 0.1 * crysol_vol < total_vol < 10.0 * crysol_vol

        # mean_atomic_radius must be smaller than the plain vdW-sphere radius:
        # bonded/packed atoms displace less than a full isolated vdW sphere.
        mean_r = sum(radii(mol)) / length(radii(mol))
        @test mean_atomic_radius(mol) < mean_r
    end
end
