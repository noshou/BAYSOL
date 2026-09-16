# SPDX-License-Identifier: LGPL-2.1-or-later
# Exercises src/Molecule/Hydrophobicity.jl: the ASP table, base-element
# parsing, the cavity-bead aggregation, and its `SASA.shell_points`-driven
# public entry point `cavity_hydrophilicity`.

using ScatterNet: Interfaces
using ScatterNet.Molecule.SASA: SASA
using ScatterNet.Molecule.Molecules: create, coords_cartesian
using ScatterNet.Molecule.Hydrophobicity:
    Hydrophobicity, ASP, cavity_hydrophilicity, _aggregate, _base_element, _sample_std
using ScatterNet.Fitting: dro_prior
using Distributions: mean, std

const _ASP_SCALE = Hydrophobicity._ASP_SCALE

# ---------------------------------------------------------------------------
# Injected radii source, real element letters this time (the ASP table is
# element-keyed), mirroring test_sasa.jl's SasaTestRadii.
# ---------------------------------------------------------------------------
struct HydroTestRadii <: Interfaces.RadiiSource
    table::Dict{String,Float64}
end

function Interfaces.lookup(s::HydroTestRadii, ions::AbstractVector{<:AbstractString})
    out = Vector{Tuple{String,Union{Float64,Nothing}}}(undef, length(ions))
    for i in eachindex(ions)
        k = String(ions[i])
        out[i] = (k, get(s.table, k, nothing))
    end
    return out
end

const HYDRO_SRC = HydroTestRadii(Dict("c" => 1.7, "n" => 1.6, "o" => 1.5, "s" => 1.8))

hydro_mol(elms, crds) = create("hydro-test", elms, crds; radii_source = HYDRO_SRC)

include(joinpath(@__DIR__, "fixtures", "geometry.jl"))   # sph
include(joinpath(@__DIR__, "fixtures", "floatcompare.jl"))   # close_

@testset "Hydrophobicity" begin

    #------------------------------------------------------------------
    #                 ASP table
    #------------------------------------------------------------------

    @testset "ASP: covers the four organic elements, correct qualitative ordering" begin
        @test Set(keys(ASP)) == Set(["c", "n", "o", "s"])
        # hydrophobic (positive) to hydrophilic (negative), well-established
        # ordering across solvation-parameter scales regardless of exact magnitude
        @test ASP["c"] > ASP["s"] > ASP["n"] > ASP["o"]
        @test ASP["c"] > 0.0
        @test ASP["o"] < 0.0
    end

    @testset "_ASP_SCALE: sample std of ASP's own values" begin
        v = collect(values(ASP))
        μ = sum(v) / length(v)
        ref = sqrt(sum((x - μ)^2 for x in v) / (length(v) - 1))
        @test close_(_ASP_SCALE, ref)
        @test _ASP_SCALE > 0.0
    end

    #------------------------------------------------------------------
    #                 _base_element
    #------------------------------------------------------------------

    @testset "_base_element: strips ionic charge, bare elements pass through" begin
        @test _base_element("fe3+") == "fe"
        @test _base_element("fe+") == "fe"
        @test _base_element("o2-") == "o"
        @test _base_element("c") == "c"
        @test _base_element("n") == "n"
    end

    #------------------------------------------------------------------
    #                 _aggregate -- unit-level, synthetic pts/sel
    #------------------------------------------------------------------

    @testset "_aggregate: empty selection returns dro_prior's own default (0.0, 0.0), a point mass" begin
        m = hydro_mol(["c"], [(0.0, 0.0, 0.0)])
        pts = zeros(3, 0)
        @test _aggregate(m, pts, Int[]) == (0.0, 0.0)
    end

    @testset "_aggregate: single bead, mean is that atom's ASP, std falls back to 0.0 (a point mass)" begin
        m = hydro_mol(["o"], [(0.0, 0.0, 0.0)])
        pts = reshape([0.0, 0.0, 1.5], 3, 1)   # sits right on the atom's surface
        μ, σ = _aggregate(m, pts, [1])
        @test close_(μ, ASP["o"] / _ASP_SCALE)
        @test σ == 0.0
    end

    @testset "_aggregate: two beads -- nearest-atom assignment and mean/std match a manual computation" begin
        m = hydro_mol(["c", "o"], [(0.0, 0.0, 0.0), (10.0, 0.0, 0.0)])
        pts = [0.0 10.0; 0.0 0.0; 1.7 1.5]   # bead 1 near the c atom, bead 2 near the o atom
        μ, σ = _aggregate(m, pts, [1, 2])

        vals = [ASP["c"] / _ASP_SCALE, ASP["o"] / _ASP_SCALE]
        μ_ref = sum(vals) / 2
        σ_ref = _sample_std(vals, μ_ref)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        # sign sanity: mixing one hydrophobic and one strongly hydrophilic
        # atom should land the mean between them, below the pure-carbon value
        @test μ < ASP["c"] / _ASP_SCALE
    end

    @testset "_aggregate: an element with no ASP entry scores neutral (0.0)" begin
        m = hydro_mol(["h"], [(0.0, 0.0, 0.0)])   # hydrogen: not in the table
        pts = reshape([0.0, 0.0, 1.0], 3, 1)
        μ, _ = _aggregate(m, pts, [1])
        @test μ == 0.0
    end

    #------------------------------------------------------------------
    #                 cavity_hydrophilicity -- end to end
    #------------------------------------------------------------------

    @testset "cavity_hydrophilicity: a lone atom has no CAVITY beads -> falls back to (0.0, 0.0)" begin
        m = hydro_mol(["c"], [(0.0, 0.0, 0.0)])
        @test cavity_hydrophilicity(m; probe = 1.4) == (0.0, 0.0)
    end

    @testset "cavity_hydrophilicity: an all-oxygen sealed shell gives a hydrophilic (negative) χ" begin
        m = hydro_mol(fill("o", 300), sph(4.0, 300))
        μ, σ = cavity_hydrophilicity(m; probe = 1.4)
        @test close_(μ, ASP["o"] / _ASP_SCALE)
        @test σ >= 0.0
    end

    @testset "cavity_hydrophilicity: an all-carbon sealed shell gives a hydrophobic (positive) χ" begin
        m = hydro_mol(fill("c", 300), sph(4.0, 300))
        μ, _ = cavity_hydrophilicity(m; probe = 1.4)
        @test close_(μ, ASP["c"] / _ASP_SCALE)
        @test μ > 0.0
    end

    @testset "cavity_hydrophilicity: a mixed carbon/oxygen shell lands strictly between the two pure cases" begin
        elms = [isodd(i) ? "c" : "o" for i in 1:300]
        m = hydro_mol(elms, sph(4.0, 300))
        μ_mixed, σ_mixed = cavity_hydrophilicity(m; probe = 1.4)
        @test ASP["o"] / _ASP_SCALE < μ_mixed < ASP["c"] / _ASP_SCALE
        @test σ_mixed > 0.0   # a genuine mix of two different chemistries has real spread
    end

    #------------------------------------------------------------------
    #                 end to end: feeds DeltaRho.dro_prior directly
    #------------------------------------------------------------------

    @testset "cavity_hydrophilicity -> dro_prior: option-A wiring, no manual (μ_χ, σ_χ) guess" begin
        m_hydrophilic = hydro_mol(fill("o", 300), sph(4.0, 300))
        m_hydrophobic = hydro_mol(fill("c", 300), sph(4.0, 300))

        μχ_phi, σχ_phi = cavity_hydrophilicity(m_hydrophilic)
        μχ_pho, σχ_pho = cavity_hydrophilicity(m_hydrophobic)

        _, _, dro3_phi = dro_prior(μχ_phi; σ_χ = σχ_phi)
        _, _, dro3_pho = dro_prior(μχ_pho; σ_χ = σχ_pho)

        @test close_(mean(dro3_phi), μχ_phi)
        @test close_(std(dro3_phi), σχ_phi)
        @test close_(mean(dro3_pho), μχ_pho)
        @test close_(std(dro3_pho), σχ_pho)

        # the physically meaningful check: the hydrophilic shell's fitted
        # cavity contrast centers below the hydrophobic shell's
        @test mean(dro3_phi) < mean(dro3_pho)
    end

end
