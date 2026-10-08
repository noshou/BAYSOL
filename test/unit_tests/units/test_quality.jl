# SPDX-License-Identifier: LGPL-2.1-or-later

# package hygiene + type-stability guards.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Aqua, JET, ExplicitImports
using BAYSOL.Scattering: SphFuncs
using BAYSOL.Scattering.SphFuncs: sphHarm, sphBess, sphBessRatios!, sphBessStep
using BAYSOL.MolecularStructure: MolecularStructure, create, coords_cartesian, coords_spherical, radii, vols, r_max,
                neighbour_tree, elms, name, Molecule
using BAYSOL.MolecularStructure: Ion, resolve_one, lookup_radii, tryparse_ion, ion_key, nearest_ion
using BAYSOL: SASA

@testset "Aqua" begin
    Aqua.test_all(BAYSOL; ambiguities = false)
    Aqua.test_ambiguities(BAYSOL)
end

@testset "ExplicitImports: no stale `using X: a, b, c` imports anywhere" begin
    test_no_stale_explicit_imports(BAYSOL)
end

@testset "type stability (@inferred)" begin
    θ = collect(range(0.1, π - 0.1; length = 8)); φ = collect(range(0.0, 2pi; length = 8))
    @inferred sphHarm(4, θ, φ)
    @inferred sphBessRatios!(sphBess(3, 4), 2.0, [0.1, 0.5, 1.0], 4)
    @inferred sphBessStep(1.0, 0.5, 3, 5, 0.5, 0.25)
    @inferred Union{Float64,Nothing} resolve_one("fe3+")
    @inferred lookup_radii(["fe3+", "o2-"])
    @inferred Union{Ion,Nothing} tryparse_ion("fe3+")
    @inferred ion_key(Ion("fe", 3))
    @inferred Union{String,Nothing} nearest_ion("fe", 5)

    m = @inferred create(
        "t", ["o", "h", "h"],
        [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
    )
    @test m isa Molecule
    @inferred coords_cartesian(m)
    @inferred coords_spherical(m)
    @inferred radii(m)
    @inferred vols(m)
    @inferred r_max(m)
    @inferred elms(m)
    @inferred name(m)
end

@testset "type stability of the SASA entry point (@inferred)" begin
    m = create("t", ["o", "h", "h"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)])
        @test (@inferred SASA.sasa(m; n_target = 64, probe = 1.4)) isa Tuple{Matrix{Float64},Vector{Float64},Vector{SASA.BeadClass}}
end

@testset "JET (focused type-stability analysis)" begin
    @test_opt target_modules = (SphFuncs,) sphBessRatios!(sphBess(2, 3), 2.0, [0.1, 0.5], 3)
    @test_opt target_modules = (SphFuncs,) sphBessStep(1.0, 0.5, 3, 5, 0.5, 0.25)
    @test_opt target_modules = (SphFuncs,) sphHarm(3, [0.4, 1.2], [0.1, 2.0])
    @test_opt target_modules = (MolecularStructure,) create("t", ["o", "h"],
        [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
    @test_opt target_modules = (MolecularStructure,) resolve_one("fe3+")
    @test_opt target_modules = (MolecularStructure,) lookup_radii(["fe3+", "o2-"])
    @test_opt target_modules = (MolecularStructure,) tryparse_ion("fe3+")

    let m = create("t", ["o", "h", "h"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)])
        @test_opt target_modules = (MolecularStructure,) radii(m)
        @test_opt target_modules = (MolecularStructure,) vols(m)
        @test_opt target_modules = (MolecularStructure,) r_max(m)
    end
end

@testset "JET: SASA's per-atom loop is free of runtime dispatch" begin
    # `neighbour_tree(mol)`'s `KDTree` cannot infer to a concrete type at the
    # call site (it's a `Molecule`-cached, non-concretely-typed field).
    #
    # The barrier call is itself one dynamic dispatch, but one per loop rather
    # than one `inrange` dispatch per atom (which is what this used to be, and
    # was worth ~21% of runtime).
    _reports(f, types; mods = (SASA,)) =
        JET.get_reports(JET.report_opt(f, types; target_modules = mods))

    m = create("t", ["o", "h", "h"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)])
    crds = MolecularStructure.coords_cartesian(m)
    TT   = typeof(neighbour_tree(m))
    Vec3 = BAYSOL.PlasticSequence.Vec3

    # the loop that runs once per atom must be completely clean
    @test isempty(_reports(SASA._sasa_loop,
        (   TT, Matrix{Float64}, Vector{Float64}, Float64, Vector{Vec3},
            Float64, Int, Int)))

    # and the helpers it calls once per atom
    @test isempty(_reports(SASA._caps!,
        (   Vector{Float64}, Vector{Float64}, Vector{Float64}, Vector{Float64}, Int,
            Vector{Int}, Matrix{Float64}, Vector{Float64}, Float64)))
    @test isempty(_reports(SASA._occlude!,
        (   Vector{UInt8}, Vector{Float64}, Vector{Float64}, Vector{Float64},
            Vector{Float64}, Vector{Float64}, Vector{Float64}, Vector{Float64}, Int, Int, Int)))
    @test isempty(_reports(SASA._n_open, (Vector{UInt8}, Int, Int)))

    @test isempty(_reports(SASA.blocked,
        (   NTuple{3,Float64}, Vec3, Vector{Int}, Matrix{Float64},
            Vector{Float64}, Float64); mods = (SASA,)))

    @test isempty(_reports(SASA._prefix_thin, (Vector{Int}, Int, Int)))

    @test isempty(_reports(SASA._class_loop,
        (   TT, Matrix{Float64}, Matrix{Float64}, Matrix{Float64},
            Vector{Float64}, Float64, Vector{Vec3})))

    # two barriers here, not one: the sampling loop and the classification loop
    rp = _reports(SASA.sasa, (Molecule,))
    @test length(rp) ≤ 2
    @test all(r -> (t = sprint(show, r);
                    occursin("_sasa_loop", t) || occursin("_class_loop", t)), rp)
end

