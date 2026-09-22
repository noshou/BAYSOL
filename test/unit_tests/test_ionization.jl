# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/MolecularStructure/Ionization.jl: the Henderson-Hasselbalch
# fraction-charged math, its delta-method σ_pH propagation, and the
# `Ionization` constructor that matches PROPKA-style per-residue-instance
# pKa records onto a `Residues`' atoms (including the "N+"/"C-" terminus
# special case). Also exercises Residues' new resnum/chain fields.

include(joinpath(@__DIR__, "testsetup.jl"))

using BayeSol.MolecularStructure: MolecularStructure, Residues, Ionization

include(joinpath(@__DIR__, "..", "fixtures", "functions", "floatcompare.jl"))   # close_

const _fraction_protonated   = MolecularStructure._fraction_protonated
const _fraction_deprotonated = MolecularStructure._fraction_deprotonated
const _group_charge          = MolecularStructure._group_charge
const _σ_group_charge        = MolecularStructure._σ_group_charge
const _atom_charge           = MolecularStructure._atom_charge
const _σ_atom_charge         = MolecularStructure._σ_atom_charge

# ---------------------------------------------------------------------------
# Independent re-derivation of the HH fraction formulas, not a call into the
# functions under test wearing a different hat.
# ---------------------------------------------------------------------------

ref_frac_base(pH, pKa) = 1.0 / (1.0 + 10.0^(pH - pKa))
ref_frac_acid(pH, pKa) = 1.0 / (1.0 + 10.0^(pKa - pH))

ref_charge(type, pH, pKa) =
    type == "base" ? ref_frac_base(pH, pKa) : -ref_frac_acid(pH, pKa)

@testset "Ionization" begin

    #------------------------------------------------------------------
    #                 Residues: new fields round-trip
    #------------------------------------------------------------------

    @testset "Residues: resnum/chain round-trip" begin
        r = Residues(["ASP", "LYS"], ["OD1", "NZ"], [12, 45], ["A", "B"])
        @test r.resname == ["ASP", "LYS"]
        @test r.atomname == ["OD1", "NZ"]
        @test r.resnum == [12, 45]
        @test r.chain == ["A", "B"]
    end

    #------------------------------------------------------------------
    #                 Henderson-Hasselbalch fraction math
    #------------------------------------------------------------------

    @testset "HH: pH == pKa -> fraction is exactly 0.5, both acid and base" begin
        @test close_(_fraction_protonated(7.0, 7.0), 0.5)
        @test close_(_fraction_deprotonated(7.0, 7.0), 0.5)
    end

    @testset "HH: base group -> protonated (charged) fraction -> 1 well below pKa, -> 0 well above" begin
        @test close_(_fraction_protonated(0.0, 10.0), 1.0; atol = 1.0e-6)
        @test close_(_fraction_protonated(20.0, 10.0), 0.0; atol = 1.0e-6)
    end

    @testset "HH: acid group -> deprotonated (charged) fraction -> 0 well below pKa, -> 1 well above" begin
        @test close_(_fraction_deprotonated(0.0, 10.0), 0.0; atol = 1.0e-6)
        @test close_(_fraction_deprotonated(20.0, 10.0), 1.0; atol = 1.0e-6)
    end

    @testset "HH: matches an independent reference re-derivation" begin
        for (pH, pKa) in [(7.4, 3.9), (7.4, 10.5), (5.0, 6.0), (9.0, 6.0)]
            @test close_(_fraction_protonated(pH, pKa), ref_frac_base(pH, pKa))
            @test close_(_fraction_deprotonated(pH, pKa), ref_frac_acid(pH, pKa))
        end
    end

    @testset "_group_charge: sign convention -- base positive, acid negative" begin
        @test _group_charge("base", 5.0, 10.0) > 0.0   # pH well below pKa -> protonated -> charged base
        @test _group_charge("acid", 10.0, 5.0) < 0.0   # pH well above pKa -> deprotonated -> charged acid
    end

    @testset "_group_charge: matches independent reference" begin
        for (type, pH, pKa) in [("acid", 7.4, 3.9), ("base", 7.4, 10.5), ("acid", 5.0, 6.0), ("base", 9.0, 6.0)]
            @test close_(_group_charge(type, pH, pKa), ref_charge(type, pH, pKa))
        end
    end

    @testset "_group_charge: rejects unknown type" begin
        @test_throws ArgumentError _group_charge("neither", 7.0, 7.0)
    end

    #------------------------------------------------------------------
    #                 delta-method uncertainty: finite-difference check
    #------------------------------------------------------------------

    @testset "_σ_group_charge: matches a central-difference d(charge)/dpH * σ_pH" begin
        σ_pH = 0.2
        h = 1.0e-6
        for (type, pKa) in [("acid", 4.0), ("base", 10.5)]
            pH = 6.5
            fd = (_group_charge(type, pH + h, pKa) - _group_charge(type, pH - h, pKa)) / (2h)
            @test _σ_group_charge(type, pH, pKa, σ_pH) ≈ abs(fd) * σ_pH rtol = 1.0e-4
        end
    end

    @testset "_σ_atom_charge: split scales linearly, matches central-difference check" begin
        σ_pH = 0.15
        h = 1.0e-6
        split = 0.5
        type, pKa, pH = "acid", 3.9, 7.4
        fd = (split * _group_charge(type, pH + h, pKa) - split * _group_charge(type, pH - h, pKa)) / (2h)
        @test _σ_atom_charge(split, type, pH, pKa, σ_pH) ≈ abs(fd) * σ_pH rtol = 1.0e-4
        @test close_(_σ_atom_charge(split, type, pH, pKa, σ_pH), split * _σ_group_charge(type, pH, pKa, σ_pH))
    end

    #------------------------------------------------------------------
    #                 Ionization construction
    #------------------------------------------------------------------

    pKa_rec(resname, resnum, chain, pKa) = (resname = resname, resnum = resnum, chain = chain, pKa = pKa)

    @testset "Ionization: Asp/Lys/Arg/terminus all land on the correct atoms with correct splits" begin
        # residue instances, chain A:
        #   1: ASP  (CA, OD1, OD2)
        #   2: LYS  (CA, NZ)          -- also the chain's first residue -> carries N+
        #   3: ARG  (CA, NE, NH1, NH2)
        resname  = ["ASP", "ASP", "ASP", "LYS", "LYS", "ARG", "ARG", "ARG", "ARG"]
        atomname = ["CA", "OD1", "OD2", "CA", "NZ", "CA", "NE", "NH1", "NH2"]
        resnum   = [1, 1, 1, 2, 2, 3, 3, 3, 3]
        chain    = fill("A", 9)
        residues = Residues(resname, atomname, resnum, chain)

        pH, σ_pH = 7.4, 0.2
        records = [
            pKa_rec("ASP", 1, "A", 3.9),
            pKa_rec("LYS", 2, "A", 10.5),
            pKa_rec("N+", 2, "A", 8.0),     # terminus record on the Lys residue instance
            pKa_rec("ARG", 3, "A", 12.5),
        ]

        ion = Ionization(residues, records, pH, σ_pH)
        @test length(ion.charge) == length(ion.σ_charge) == 9

        # CA atoms (index 1, 4, 6) are never ionizable -> exactly zero
        for i in (1, 4, 6)
            @test ion.charge[i] == 0.0
            @test ion.σ_charge[i] == 0.0
        end

        # Asp: acid, split 0.5/0.5 on OD1(2)/OD2(3)
        q_asp = ref_charge("acid", pH, 3.9)
        @test close_(ion.charge[2], 0.5 * q_asp)
        @test close_(ion.charge[3], 0.5 * q_asp)
        @test close_(ion.charge[2], ion.charge[3])

        # Lys: base, split 1.0 on NZ(5)
        q_lys = ref_charge("base", pH, 10.5)
        @test close_(ion.charge[5], q_lys)

        # N+ terminus: base, split 1.0 on atom named "N" at (resnum=2, chain="A") --
        # none of Lys's atoms here are named "N" (only "CA"/"NZ"), so the N+
        # record matches nothing and contributes no charge anywhere.
        @test close_(sum(ion.charge[4:5]), q_lys)  # only NZ's charge, N+ found no atom

        # Arg: base, split 1/3 each on NE(7)/NH1(8)/NH2(9)
        q_arg = ref_charge("base", pH, 12.5)
        for i in (7, 8, 9)
            @test close_(ion.charge[i], (1.0/3.0) * q_arg)
        end
        @test close_(ion.charge[7], ion.charge[8])
        @test close_(ion.charge[8], ion.charge[9])
    end

    @testset "Ionization: N+ terminus resolves onto the real backbone N atom by (resnum, chain), not resname" begin
        # A Gly is the chain's first residue and carries the physical N-terminal
        # amine; PROPKA reports it under the literal resname "N+".
        resname  = ["GLY", "GLY", "GLY"]
        atomname = ["N", "CA", "C"]
        resnum   = [1, 1, 1]
        chain    = ["A", "A", "A"]
        residues = Residues(resname, atomname, resnum, chain)

        pH, σ_pH = 7.4, 0.2
        records = [pKa_rec("N+", 1, "A", 8.0)]
        ion = Ionization(residues, records, pH, σ_pH)

        q_nterm = ref_charge("base", pH, 8.0)
        @test close_(ion.charge[1], q_nterm)   # atom "N"
        @test ion.charge[2] == 0.0             # CA untouched
        @test ion.charge[3] == 0.0             # C untouched
        @test ion.σ_charge[1] > 0.0
    end

    @testset "Ionization: C- terminus resolves onto O/OXT by (resnum, chain), not resname" begin
        resname  = ["ALA", "ALA", "ALA"]
        atomname = ["C", "O", "OXT"]
        resnum   = [9, 9, 9]
        chain    = ["A", "A", "A"]
        residues = Residues(resname, atomname, resnum, chain)

        pH, σ_pH = 7.4, 0.2
        records = [pKa_rec("C-", 9, "A", 3.3)]
        ion = Ionization(residues, records, pH, σ_pH)

        q_cterm = ref_charge("acid", pH, 3.3)
        @test ion.charge[1] == 0.0   # backbone C untouched
        @test close_(ion.charge[2], 0.5 * q_cterm)   # O
        @test close_(ion.charge[3], 0.5 * q_cterm)   # OXT
    end

    @testset "Ionization: two instances of the same resname get independently correct charges" begin
        # two separate Asp residues, different resnum, different pKa records
        resname  = ["ASP", "ASP", "ASP", "ASP"]
        atomname = ["OD1", "OD2", "OD1", "OD2"]
        resnum   = [10, 10, 55, 55]
        chain    = fill("A", 4)
        residues = Residues(resname, atomname, resnum, chain)

        pH, σ_pH = 7.4, 0.2
        records = [
            pKa_rec("ASP", 10, "A", 3.9),
            pKa_rec("ASP", 55, "A", 7.0),   # near solution pH -> substantially different charge
        ]
        ion = Ionization(residues, records, pH, σ_pH)

        q1 = ref_charge("acid", pH, 3.9)
        q2 = ref_charge("acid", pH, 7.0)
        @test close_(ion.charge[1], 0.5 * q1)
        @test close_(ion.charge[2], 0.5 * q1)
        @test close_(ion.charge[3], 0.5 * q2)
        @test close_(ion.charge[4], 0.5 * q2)
        @test !close_(ion.charge[1], ion.charge[3]; atol = 1.0e-3)   # genuinely different, not collapsed
    end

    @testset "Ionization: different chains with the same resnum are not conflated" begin
        resname  = ["ASP", "ASP", "ASP", "ASP"]
        atomname = ["OD1", "OD2", "OD1", "OD2"]
        resnum   = [10, 10, 10, 10]
        chain    = ["A", "A", "B", "B"]
        residues = Residues(resname, atomname, resnum, chain)

        pH, σ_pH = 7.4, 0.2
        records = [pKa_rec("ASP", 10, "A", 3.9)]   # only chain A reported
        ion = Ionization(residues, records, pH, σ_pH)

        q1 = ref_charge("acid", pH, 3.9)
        @test close_(ion.charge[1], 0.5 * q1)
        @test close_(ion.charge[2], 0.5 * q1)
        @test ion.charge[3] == 0.0   # chain B's Asp has no matching record
        @test ion.charge[4] == 0.0
    end

    @testset "Ionization: unmatched pKa record and unmatched residue atom don't crash" begin
        residues = Residues(["ASP", "ASP", "GLY"], ["OD1", "OD2", "CA"], [1, 1, 2], ["A", "A", "A"])
        pH, σ_pH = 7.4, 0.2

        # record for a residue instance that doesn't exist in `residues`
        records = [pKa_rec("GLU", 99, "A", 4.2)]
        ion = @test_nowarn Ionization(residues, records, pH, σ_pH)
        @test all(==(0.0), ion.charge)
        @test all(==(0.0), ion.σ_charge)

        # residue atom (GLY/CA) with no corresponding record at all: also fine
        records2 = [pKa_rec("ASP", 1, "A", 3.9)]
        ion2 = @test_nowarn Ionization(residues, records2, pH, σ_pH)
        @test ion2.charge[3] == 0.0
        @test ion2.σ_charge[3] == 0.0
    end

end
