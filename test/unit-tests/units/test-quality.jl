# SPDX-License-Identifier: LGPL-3.0-or-later

# package hygiene + type-stability guards.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Aqua, JET, ExplicitImports
using BAYSOL.Scattering: sphBess, sphBessRatios!, sphBessStep
using BAYSOL.MolecularStructure: MolecularStructure, create, coordsCartesian,
    coordsSpherical, radii, vols, rMax,
    neighbourTree, elms, name, Molecule
using BAYSOL.MolecularStructure:
    Ion, resolveOne, lookupRadii, tryparseIon, ionKey, nearestIon
using BAYSOL: Geometry, Scattering

@testset "Aqua" begin
    Aqua.test_all(BAYSOL; ambiguities = false)
    Aqua.test_ambiguities(BAYSOL)
end

@testset "ExplicitImports: no stale `using X: a, b, c` imports anywhere" begin
    test_no_stale_explicit_imports(BAYSOL)
end

@testset "type stability (@inferred)" begin
    θ = collect(range(0.1, π - 0.1; length = 8))
    φ = collect(range(0.0, 2pi; length = 8))
    @inferred sphHarm(4, θ, φ)
    @inferred sphBessRatios!(sphBess(3, 4), 2.0, [0.1, 0.5, 1.0], 4)
    @inferred sphBessStep(1.0, 0.5, 3, 5, 0.5, 0.25)
    @inferred Union{Float64,Nothing} resolveOne("fe3+")
    @inferred lookupRadii(["fe3+", "o2-"])
    @inferred Union{Ion,Nothing} tryparseIon("fe3+")
    @inferred ionKey(Ion("fe", 3))
    @inferred Union{String,Nothing} nearestIon("fe", 5)

    m = @inferred create(
        "t", ["o", "h", "h"],
        [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)],
    )
    @test m isa Molecule
    @inferred coordsCartesian(m)
    @inferred coordsSpherical(m)
    @inferred radii(m)
    @inferred vols(m)
    @inferred rMax(m)
    @inferred elms(m)
    @inferred name(m)
end

@testset "type stability of the SASA entry point (@inferred)" begin
    m = create("t", ["o", "h", "h"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)])
    @test (@inferred Geometry.sasa(m; nTarget = 64, probe = 1.4)) isa
          Tuple{Matrix{Float64},Vector{Float64},Vector{Geometry.BeadClass}}
end

@testset "JET (focused type-stability analysis)" begin
    @test_opt target_modules = (Scattering,) sphBessRatios!(
        sphBess(2, 3),
        2.0,
        [0.1, 0.5],
        3,
    )
    @test_opt target_modules = (Scattering,) sphBessStep(1.0, 0.5, 3, 5, 0.5, 0.25)
    @test_opt target_modules = (Scattering,) sphHarm(3, [0.4, 1.2], [0.1, 2.0])
    @test_opt target_modules = (MolecularStructure,) create("t", ["o", "h"],
        [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
    @test_opt target_modules = (MolecularStructure,) resolveOne("fe3+")
    @test_opt target_modules = (MolecularStructure,) lookupRadii(["fe3+", "o2-"])
    @test_opt target_modules = (MolecularStructure,) tryparseIon("fe3+")

    let m = create(
            "t",
            ["o", "h", "h"],
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)],
        )
        @test_opt target_modules = (MolecularStructure,) radii(m)
        @test_opt target_modules = (MolecularStructure,) vols(m)
        @test_opt target_modules = (MolecularStructure,) rMax(m)
    end
end

@testset "JET: SASA's per-atom loop is free of runtime dispatch" begin
    # `neighbourTree(mol)`'s `KDTree` cannot infer to a concrete type at the
    # call site (it's a `Molecule`-cached, non-concretely-typed field).
    #
    # The barrier call is itself one dynamic dispatch, but one per loop rather
    # than one `inrange` dispatch per atom (which is what this used to be, and
    # was worth ~21% of runtime).
    _reports(f, types; mods = (Geometry,)) =
        JET.get_reports(JET.report_opt(f, types; target_modules = mods))

    m    = create("t", ["o", "h", "h"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)])
    crds = MolecularStructure.coordsCartesian(m)
    tt   = typeof(neighbourTree(m))
    Vec3 = BAYSOL.Geometry.Vec3

    # the loop that runs once per atom must be completely clean
    @test isempty(
        _reports(Geometry._sasaLoop,
            (tt, Matrix{Float64}, Vector{Float64}, Float64, Vector{Vec3},
                Float64, Int, Int)),
    )

    # and the helpers it calls once per atom
    @test isempty(
        _reports(Geometry._caps!,
            (Vector{Float64}, Vector{Float64}, Vector{Float64}, Vector{Float64}, Int,
                Vector{Int}, Matrix{Float64}, Vector{Float64}, Float64)),
    )
    @test isempty(
        _reports(Geometry._occlude!,
            (Vector{UInt8}, Vector{Float64}, Vector{Float64}, Vector{Float64},
                Vector{Float64}, Vector{Float64}, Vector{Float64}, Vector{Float64}, Int,
                Int, Int)),
    )
    @test isempty(_reports(Geometry._nOpen, (Vector{UInt8}, Int, Int)))

    @test isempty(
        _reports(Geometry.blocked,
            (NTuple{3,Float64}, Vec3, Vector{Int}, Matrix{Float64},
                Vector{Float64}, Float64); mods = (Geometry,)),
    )

    @test isempty(_reports(Geometry._prefixThin, (Vector{Int}, Int, Int)))

    @test isempty(
        _reports(Geometry._classLoop,
            (tt, Matrix{Float64}, Matrix{Float64}, Matrix{Float64},
                Vector{Float64}, Float64, Vector{Vec3}, Float64)),
    )

    # two barriers here, not one: the sampling loop and the classification loop
    rp = _reports(Geometry.sasa, (Molecule,))
    @test length(rp) ≤ 2
    @test all(
        r -> (t = sprint(show, r);
            occursin("_sasaLoop", t) || occursin("_classLoop", t)), rp)
end
