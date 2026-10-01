# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises the Henderson-Hasselbalch protonation helpers in
# src/MolecularStructure/Pdb2pqr.jl (used to choose pdb2pqr's
# --neutraln/--neutralc terminus flags), and Residues' resnum/chain fields.

include(joinpath(@__DIR__, "testsetup.jl"))

using BAYSOL.MolecularStructure: MolecularStructure, Residues

include(joinpath(@__DIR__, "..", "fixtures", "functions", "floatcompare.jl"))   # close_

const _fraction_protonated   = MolecularStructure._fraction_protonated
const _fraction_deprotonated = MolecularStructure._fraction_deprotonated
const _group_protonated      = MolecularStructure._group_protonated

# Independent re-derivation of the HH fraction formulas, not a call into the
# functions under test wearing a different hat.
ref_frac_base(pH, pKa) = 1.0 / (1.0 + 10.0^(pH - pKa))
ref_frac_acid(pH, pKa) = 1.0 / (1.0 + 10.0^(pKa - pH))

@testset "Protonation" begin

    @testset "Residues: resnum/chain round-trip" begin
        r = Residues(["ASP", "LYS"], ["OD1", "NZ"], [12, 45], ["A", "B"])
        @test r.resname == ["ASP", "LYS"]
        @test r.atomname == ["OD1", "NZ"]
        @test r.resnum == [12, 45]
        @test r.chain == ["A", "B"]
    end

    @testset "HH: pH == pKa -> fraction is exactly 0.5, both acid and base" begin
        @test close_(_fraction_protonated(7.0, 7.0), 0.5)
        @test close_(_fraction_deprotonated(7.0, 7.0), 0.5)
    end

    @testset "HH: base group -> protonated fraction -> 1 well below pKa, -> 0 well above" begin
        @test close_(_fraction_protonated(0.0, 10.0), 1.0; atol = 1.0e-6)
        @test close_(_fraction_protonated(20.0, 10.0), 0.0; atol = 1.0e-6)
    end

    @testset "HH: acid group -> deprotonated fraction -> 0 well below pKa, -> 1 well above" begin
        @test close_(_fraction_deprotonated(0.0, 10.0), 0.0; atol = 1.0e-6)
        @test close_(_fraction_deprotonated(20.0, 10.0), 1.0; atol = 1.0e-6)
    end

    @testset "HH: matches an independent reference re-derivation" begin
        for (pH, pKa) in [(7.4, 3.9), (7.4, 10.5), (5.0, 6.0), (9.0, 6.0)]
            @test close_(_fraction_protonated(pH, pKa), ref_frac_base(pH, pKa))
            @test close_(_fraction_deprotonated(pH, pKa), ref_frac_acid(pH, pKa))
        end
    end

    @testset "_group_protonated: base protonated below pKa, acid protonated below pKa" begin
        @test _group_protonated("base", 5.0, 10.0)
        @test !_group_protonated("base", 12.0, 10.0)
        @test _group_protonated("acid", 2.0, 4.0)
        @test !_group_protonated("acid", 7.0, 4.0)
    end

    @testset "_group_protonated: exactly at pKa rounds to the uncharged state" begin
        @test !_group_protonated("base", 7.0, 7.0)   # uncharged base = deprotonated
        @test _group_protonated("acid", 7.0, 7.0)    # uncharged acid = protonated
    end

    @testset "_group_protonated: rejects unknown type" begin
        @test_throws ArgumentError _group_protonated("neither", 7.0, 7.0)
    end
end
