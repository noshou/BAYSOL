# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Solvation/Electrostatics.jl: the Debye length, the
# distance-based phosphate bond-graph classifier, the screened-field
# formula, the cavity-bead aggregation, and its `SASA.shell_points`-driven
# public entry point `nucleic_acid_cavity_electrostatics`.

using BayeSol: Interfaces
using BayeSol.Solvation.SASA: SASA
using BayeSol.MolecularStructure: create, coords_cartesian
using BayeSol.Solvation.Electrostatics:
    Electrostatics, PHOSPHATE_NET_CHARGE, debye_length, nucleic_acid_cavity_electrostatics,
    _phosphate_charge_sites, _screened_field, _aggregate, _sample_std,
    protein_cavity_electrostatics, _protein_charge_sites
using BayeSol.MolecularStructure: Residues
using BayeSol.Fitting: δρ_prior
using Distributions: mean, std

# ---------------------------------------------------------------------------
# Injected radii source, real element letters (p/o/c), mirroring
# test_sasa.jl's SasaTestRadii.
# ---------------------------------------------------------------------------
struct ElecTestRadii <: Interfaces.RadiiSource
    table::Dict{String,Float64}
end

function Interfaces.lookup(s::ElecTestRadii, ions::AbstractVector{<:AbstractString})
    out = Vector{Tuple{String,Union{Float64,Nothing}}}(undef, length(ions))
    for i in eachindex(ions)
        k = String(ions[i])
        out[i] = (k, get(s.table, k, nothing))
    end
    return out
end

const ELEC_SRC = ElecTestRadii(Dict("c" => 1.7, "o" => 1.5, "p" => 1.9, "n" => 1.6))

elec_mol(elms, crds) = create("elec-test", elms, crds; radii_source = ELEC_SRC)

include(joinpath(@__DIR__, "fixtures", "geometry.jl"))       # sph
include(joinpath(@__DIR__, "fixtures", "floatcompare.jl"))   # close_

@testset "Electrostatics" begin

    #------------------------------------------------------------------
    #                 debye_length
    #------------------------------------------------------------------

    @testset "debye_length: physiological default is ~8 A" begin
        κinv = debye_length()
        @test close_(κinv, 7.95; atol = 0.05)
    end

    @testset "debye_length: higher ionic strength screens more -> shorter length" begin
        @test debye_length(; ionic_strength_M = 0.5) < debye_length(; ionic_strength_M = 0.15)
    end

    @testset "debye_length: rejects non-positive inputs" begin
        @test_throws DomainError debye_length(; ionic_strength_M = 0.0)
        @test_throws DomainError debye_length(; eps_r = -1.0)
        @test_throws DomainError debye_length(; T = 0.0)
    end

    #------------------------------------------------------------------
    #                 _phosphate_charge_sites
    #------------------------------------------------------------------

    @testset "_phosphate_charge_sites: no phosphorus -> empty" begin
        m = elec_mol(["c", "o"], [(0.0, 0.0, 0.0), (1.4, 0.0, 0.0)])
        @test isempty(_phosphate_charge_sites(m))
    end

    @testset "_phosphate_charge_sites: 2 non-bridging + 2 bridging O" begin
        elms = ["p", "o", "o", "o", "o", "c", "c"]
        crds = [
            (0.0, 0.0, 0.0),    # 1: p
            (1.5, 0.0, 0.0),    # 2: o, non-bridging
            (-1.5, 0.0, 0.0),   # 3: o, non-bridging
            (0.0, 1.5, 0.0),    # 4: o, bridging (-> c at 6)
            (0.0, -1.5, 0.0),   # 5: o, bridging (-> c at 7)
            (0.0, 2.9, 0.0),    # 6: c, bonded to 4 only
            (0.0, -2.9, 0.0),   # 7: c, bonded to 5 only
        ]
        m = elec_mol(elms, crds)
        sites = _phosphate_charge_sites(m)

        @test length(sites) == 2
        idxs = Set(first.(sites))
        @test idxs == Set([2, 3])
        for (_, q) in sites
            @test close_(q, PHOSPHATE_NET_CHARGE / 2)
        end
        @test close_(sum(last.(sites)), PHOSPHATE_NET_CHARGE)
    end

    @testset "_phosphate_charge_sites: all 4 O's bridging -> fallback splits charge across all of them" begin
        elms = ["p", "o", "o", "o", "o", "c", "c", "c", "c"]
        crds = [
            (0.0, 0.0, 0.0),     # 1: p
            (1.5, 0.0, 0.0),     # 2: o
            (-1.5, 0.0, 0.0),    # 3: o
            (0.0, 1.5, 0.0),     # 4: o
            (0.0, -1.5, 0.0),    # 5: o
            (2.9, 0.0, 0.0),     # 6: c, bonded to 2
            (-2.9, 0.0, 0.0),    # 7: c, bonded to 3
            (0.0, 2.9, 0.0),     # 8: c, bonded to 4
            (0.0, -2.9, 0.0),    # 9: c, bonded to 5
        ]
        m = elec_mol(elms, crds)
        sites = _phosphate_charge_sites(m)

        @test length(sites) == 4
        @test Set(first.(sites)) == Set([2, 3, 4, 5])
        for (_, q) in sites
            @test close_(q, PHOSPHATE_NET_CHARGE / 4)
        end
        @test close_(sum(last.(sites)), PHOSPHATE_NET_CHARGE)
    end

    #------------------------------------------------------------------
    #                 _screened_field
    #------------------------------------------------------------------

    @testset "_screened_field: decays with distance" begin
        κinv = debye_length()
        near = _screened_field(-0.24, 3.0, κinv, 80.0)
        far  = _screened_field(-0.24, 10.0, κinv, 80.0)
        @test near > far > 0.0
    end

    @testset "_screened_field: sign of the charge is discarded" begin
        κinv = debye_length()
        @test close_(_screened_field(0.24, 5.0, κinv, 80.0), _screened_field(-0.24, 5.0, κinv, 80.0))
    end

    #------------------------------------------------------------------
    #                 _aggregate -- unit-level, synthetic pts/sel
    #------------------------------------------------------------------

    @testset "_aggregate: empty selection returns (0.0, 0.0)" begin
        m = elec_mol(["c"], [(0.0, 0.0, 0.0)])
        pts = zeros(3, 0)
        @test _aggregate(m, pts, Int[], _phosphate_charge_sites(m)) == (0.0, 0.0)
    end

    @testset "_aggregate: no charge sites at all returns (0.0, 0.0)" begin
        m = elec_mol(["c", "c"], [(0.0, 0.0, 0.0), (5.0, 0.0, 0.0)])
        pts = reshape([2.5, 0.0, 0.0], 3, 1)
        @test _aggregate(m, pts, [1], _phosphate_charge_sites(m)) == (0.0, 0.0)
    end

    @testset "_aggregate: bead closer to a phosphate charge scores higher" begin
        elms = ["p", "o", "o"]
        crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-1.5, 0.0, 0.0)]
        m = elec_mol(elms, crds)
        sites = _phosphate_charge_sites(m)

        pts = [3.0 10.0; 0.0 0.0; 0.0 0.0]   # bead 1 near, bead 2 far
        μ_near, _ = _aggregate(m, pts, [1], sites)
        μ_far, _  = _aggregate(m, pts, [2], sites)
        @test μ_near > μ_far > 0.0
    end

    #------------------------------------------------------------------
    #                 nucleic_acid_cavity_electrostatics
    #------------------------------------------------------------------

    @testset "nucleic_acid_cavity_electrostatics: a lone atom has no CAVITY beads -> falls back to (0.0, 0.0)" begin
        m = elec_mol(["c"], [(0.0, 0.0, 0.0)])
        @test nucleic_acid_cavity_electrostatics(m; probe = 1.4) == (0.0, 0.0)
    end

    @testset "nucleic_acid_cavity_electrostatics: an all-carbon sealed shell with no phosphorus scores neutral" begin
        m = elec_mol(fill("c", 300), sph(4.0, 300))
        @test nucleic_acid_cavity_electrostatics(m; probe = 1.4) == (0.0, 0.0)
    end

    # Radius/point-count chosen empirically. A bead is CAVITY only when every
    # one of its sampled outward rays hits another atom (of the enclosing
    # shell) within SASA._BEAD_RAY_RANGE (12 A) instead of escaping to bulk
    # solvent.
    @testset "nucleic_acid_cavity_electrostatics: adding a phosphate group inside the cavity gives a positive χ" begin
        shell_elms = fill("c", 800)
        shell_crds = sph(8.0, 800)

        phos_elms = ["p", "o", "o"]
        phos_crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-1.5, 0.0, 0.0)]

        m = elec_mol(vcat(shell_elms, phos_elms), vcat(shell_crds, phos_crds))
        μ, σ = nucleic_acid_cavity_electrostatics(m; probe = 1.4)
        @test μ > 0.0
        @test σ >= 0.0
    end

    #------------------------------------------------------------------
    #                 end to end: feeds DeltaRho.δρ_prior directly
    #------------------------------------------------------------------

    @testset "nucleic_acid_cavity_electrostatics -> δρ_prior: no manual (μ_χ, σ_χ) guess" begin
        shell_elms = fill("c", 800)
        shell_crds = sph(8.0, 800)
        phos_elms = ["p", "o", "o"]
        phos_crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-1.5, 0.0, 0.0)]
        m = elec_mol(vcat(shell_elms, phos_elms), vcat(shell_crds, phos_crds))

        μχ, σχ = nucleic_acid_cavity_electrostatics(m)
        _, _, dro3 = δρ_prior(μ_χ = μχ, σ_χ = σχ)

        @test close_(mean(dro3), μχ)
        @test close_(std(dro3), σχ)
    end

    #------------------------------------------------------------------
    #                 _protein_charge_sites
    #------------------------------------------------------------------

    @testset "_protein_charge_sites: mismatched residues length throws ArgumentError" begin
        m = elec_mol(["c", "c"], [(0.0, 0.0, 0.0), (5.0, 0.0, 0.0)])
        bad = Residues(["GLY"], ["CA"])   # length 1, mol has 2 atoms
        @test_throws ArgumentError _protein_charge_sites(m, bad)
    end

    @testset "_protein_charge_sites: an all-backbone molecule has no charge sites" begin
        m = elec_mol(["c", "c", "o"], [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (3.0, 0.0, 0.0)])
        residues = Residues(["GLY", "GLY", "GLY"], ["CA", "C", "O"])
        @test isempty(_protein_charge_sites(m, residues))
    end

    @testset "_protein_charge_sites: Asp side-chain oxygens resolve via Interfaces.ResidueNetCharge" begin
        elms = ["c", "o", "o"]   # a bare CA plus the two carboxylate O's
        crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-1.5, 0.0, 0.0)]
        m = elec_mol(elms, crds)
        residues = Residues(["ASP", "ASP", "ASP"], ["CA", "OD1", "OD2"])

        sites = _protein_charge_sites(m, residues)
        @test length(sites) == 2
        @test Set(first.(sites)) == Set([2, 3])
        q_od1 = Interfaces.residue_charge("ASP", "OD1")
        q_od2 = Interfaces.residue_charge("ASP", "OD2")
        @test Set(last.(sites)) == Set([q_od1, q_od2])
    end

    @testset "_protein_charge_sites: Lys/Arg resolve to Interfaces.ResidueNetCharge's own values" begin
        elms = ["n", "n", "n", "n"]
        crds = [(0.0, 0.0, 0.0), (2.0, 0.0, 0.0), (4.0, 0.0, 0.0), (6.0, 0.0, 0.0)]
        m = elec_mol(elms, crds)
        residues = Residues(["LYS", "ARG", "ARG", "ARG"], ["NZ", "NH1", "NH2", "NE"])

        sites = Dict(_protein_charge_sites(m, residues))
        @test close_(sites[1], Interfaces.residue_charge("LYS", "NZ"))
        @test close_(sites[2], Interfaces.residue_charge("ARG", "NH1"))
        @test close_(sites[3], Interfaces.residue_charge("ARG", "NH2"))
        @test close_(sites[4], Interfaces.residue_charge("ARG", "NE"))
        # all three Arg atoms share the same per-atom charge, by construction
        @test close_(sites[2], sites[3]) && close_(sites[3], sites[4])
    end

    #------------------------------------------------------------------
    #                 protein_cavity_electrostatics
    #------------------------------------------------------------------

    @testset "protein_cavity_electrostatics: a lone atom has no CAVITY beads -> falls back to (0.0, 0.0)" begin
        m = elec_mol(["c"], [(0.0, 0.0, 0.0)])
        residues = Residues(["GLY"], ["CA"])
        @test protein_cavity_electrostatics(m, residues; probe = 1.4) == (0.0, 0.0)
    end

    @testset "protein_cavity_electrostatics: an all-backbone sealed shell scores neutral" begin
        m = elec_mol(fill("c", 300), sph(4.0, 300))
        residues = Residues(fill("GLY", 300), fill("CA", 300))
        @test protein_cavity_electrostatics(m, residues; probe = 1.4) == (0.0, 0.0)
    end

    @testset "protein_cavity_electrostatics: an Asp/Lys pair inside the cavity gives a positive χ" begin
        shell_elms = fill("c", 800)
        shell_crds = sph(8.0, 800)

        # a carboxylate (Asp) and an amine (Lys) sitting well inside the cavity;
        # |q| is what feeds the field (see _screened_field), so both should
        # contribute positively regardless of sign.
        ion_elms = ["o", "o", "n"]
        ion_crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-2.0, 0.0, 0.0)]

        m = elec_mol(vcat(shell_elms, ion_elms), vcat(shell_crds, ion_crds))
        residues = Residues(
            vcat(fill("GLY", 800), ["ASP", "ASP", "LYS"]),
            vcat(fill("CA", 800), ["OD1", "OD2", "NZ"]),
        )

        μ, σ = protein_cavity_electrostatics(m, residues; probe = 1.4)
        @test μ > 0.0
        @test σ >= 0.0
    end

    #------------------------------------------------------------------
    #                 end to end: feeds DeltaRho.δρ_prior directly
    #------------------------------------------------------------------

    @testset "protein_cavity_electrostatics -> δρ_prior: no manual (μ_χ, σ_χ) guess" begin
        shell_elms = fill("c", 800)
        shell_crds = sph(8.0, 800)
        ion_elms = ["o", "o", "n"]
        ion_crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-2.0, 0.0, 0.0)]
        m = elec_mol(vcat(shell_elms, ion_elms), vcat(shell_crds, ion_crds))
        residues = Residues(
            vcat(fill("GLY", 800), ["ASP", "ASP", "LYS"]),
            vcat(fill("CA", 800), ["OD1", "OD2", "NZ"]),
        )

        μχ, σχ = protein_cavity_electrostatics(m, residues)
        _, _, dro3 = δρ_prior(μ_χ = μχ, σ_χ = σχ)

        @test close_(mean(dro3), μχ)
        @test close_(std(dro3), σχ)
    end

end
