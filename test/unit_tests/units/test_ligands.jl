# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the ligands the structure readers keep (owner, 2026-11-11, `KEEP_LIGANDS`):
# heme, nucleotide triphosphates, sugars, glycerol and ions of a known composition scatter
# as heavy atoms without hydrogens; waters and placeholders (`UNK`, `UNL`, `DUM`) stay
# out. Covers `has_known_composition`, `is_ligand`, `ligand_selector`, the `ligands`
# keyword of `load_molecule`, and the hydrogenation of a hemoglobin (pdb2pqr: the CondaPkg
# tools are needed) whose protein part must be what it was. Fixtures: 3ODQ of SASDVA2
# (hemoglobin, four heme groups), 4HHB and small synthetic files.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_ligands

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.MolecularStructure: has_known_composition, is_ligand, ligand_selector,
    polymer_selector, load_molecule, n_atoms, elms, KEEP_LIGANDS, _store_dir
using BAYSOL.Hydrogenator: resolve_hydrogens, NoTitration, hydrogenation_balance
using BioStructures: BioStructures, PDBFormat, collectatoms, collectmodels, resname

const _EXP = joinpath(@__DIR__, "..", "..", "fixtures", "experiments")
const _HB = joinpath(_EXP, "SASDVA2", "SASDVA2_3ODQ.pdb")
const _4HHB = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "4HHB-TEST.pdb")

# a fixed-column ATOM/HETATM record
function pdbline(rec, serial, atom, res, chain, num, elem; xyz = (1.0, 2.0, 3.0))
    a = length(elem) == 2 ? rpad(atom, 4) : " " * rpad(atom, 3)
    return @sprintf("%-6s%5d %s %3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s",
        rec, serial, a, res, chain, num, xyz..., 1.0, 10.0, lpad(elem, 2))
end
function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end
count_el(m, e) = count(==(e), elms(m))

@testset "ligands in the structure" begin
    @test KEEP_LIGANDS === true

    @testset "has_known_composition" begin
        @test has_known_composition("C34 H32 Fe N4 O4")     # heme
        @test has_known_composition("Mg") && has_known_composition("K")
        @test has_known_composition("D2 O")                  # deuterium
        @test !has_known_composition("?")                    # UNL
        @test !has_known_composition("X")                    # DUM
        @test !has_known_composition("")
        @test !has_known_composition("C4 H9 Qq")
    end

    @testset "is_ligand" begin
        for n in ("HEM", "MG", "ZN", "K", "CA", "NA", "GOL", "NAG", "GTP", "GNP", "PO4",
            "TBU", "PXX", "hem")
            @test is_ligand(n)
        end
        # water, placeholders, the polymer
        for n in ("HOH", "DOD", "WAT", "UNK", "UNL", "DUM", "DUMMY", "ALA", "MSE", "A",
            "PSU")
            @test !is_ligand(n)
        end
    end

    @testset "ligand_selector on atoms" begin
        mktempdir() do dir
            path = wr(
                dir,
                "sel.pdb",
                [
                    pdbline("ATOM", 1, "CA", "ALA", 'A', 1, "C"),
                    pdbline("HETATM", 2, "FE", "HEM", 'A', 2, "FE"),
                    pdbline("HETATM", 3, "O", "HOH", 'A', 3, "O"),
                    pdbline("HETATM", 4, "O", "DOD", 'A', 4, "O"),
                    pdbline("HETATM", 5, "CA", "UNK", 'A', 5, "C"),
                    pdbline("HETATM", 6, "MG", "MG", 'A', 6, "MG"),
                ],
            )
            model = first(collectmodels(BioStructures.read(path, PDBFormat)))
            ats = collectatoms(model)
            kept(sel) = sort([resname(a) for a in ats if sel(a)])
            @test kept(polymer_selector) == ["ALA"]
            @test kept(ligand_selector) == ["ALA", "HEM", "MG"]
        end
    end

    @testset "hemoglobin 3ODQ: the four heme groups are scattered" begin
        # 4384 protein heavy atoms and 4 x 43 heme atoms (C34 Fe N4 O4), 4556 in all
        mol = load_molecule(_HB)
        @test n_atoms(mol) == 4384 + 172 == 4556
        poly = load_molecule(_HB; ligands = false)
        @test n_atoms(poly) == 4384
        @test count_el(mol, "fe") == 4
        @test count_el(mol, "c") - count_el(poly, "c") == 4 * 34
        @test count_el(mol, "n") - count_el(poly, "n") == 4 * 4
        @test count_el(mol, "o") - count_el(poly, "o") == 4 * 4
        @test count_el(mol, "s") == count_el(poly, "s")
        # the ligand carries no hydrogen (nor deuterium)
        @test count_el(mol, "h") == 0 && count_el(mol, "d") == 0
        @test all(isfinite, BAYSOL.MolecularStructure.coords_cartesian(mol))
        @test all(>(0), BAYSOL.MolecularStructure.radii(mol))
    end

    @testset "waters and unknown-composition residues stay out" begin
        mktempdir() do dir
            base = [pdbline("ATOM", 1, "CA", "ALA", 'A', 1, "C")]
            extra = [
                pdbline("HETATM", 2, "O", "HOH", 'A', 2, "O"),
                pdbline("HETATM", 3, "O", "DOD", 'A', 3, "O"),
                pdbline("HETATM", 4, "CA", "UNK", 'A', 4, "C"),
                pdbline("HETATM", 5, "C1", "UNL", 'A', 5, "C"),
                pdbline("HETATM", 6, "XX", "DUM", 'A', 6, "C"),
            ]
            @test n_atoms(load_molecule(wr(dir, "w.pdb", [base; extra]))) == 1
            ion = pdbline("HETATM", 7, "ZN", "ZN", 'A', 7, "ZN")
            m = load_molecule(wr(dir, "z.pdb", [base; extra; ion]))
            @test n_atoms(m) == 2 && count_el(m, "zn") == 1
            z2 = wr(dir, "z2.pdb", [base; ion])
            @test n_atoms(load_molecule(z2; ligands = false)) == 1
        end
    end

    @testset "4HHB through pdb2pqr: the protein hydrogens are unchanged" begin
        dir = mktempdir()
        hp = ""
        try
            path = joinpath(dir, "lig-4hhb.pdb")
            cp(_4HHB, path)
            hp = resolve_hydrogens(path, 7.0; ff = :parse, titration = NoTitration())
            b = hydrogenation_balance(hp)
            @test b !== nothing && b.ligands == 0       # pdb2pqr keeps heme
            all_atoms = load_molecule(hp)
            poly = load_molecule(hp; ligands = false)
            heme = n_atoms(all_atoms) - n_atoms(poly)
            # four heme groups of 43 heavy atoms and the two PO4 atoms the fixture keeps
            @test heme == 4 * 43 + 2
            @test count_el(all_atoms, "fe") == 4
            @test count_el(all_atoms, "h") == count_el(poly, "h") > 0
            # no hydrogen sits on a ligand residue of the hydrogenated file
            @test !any(
                l ->
                    startswith(l, "HETATM") && strip(l[77:78]) == "H" &&
                    strip(l[18:20]) in ("HEM", "PO4"),
                eachline(hp),
            )
        finally
            isempty(hp) || foreach(p -> rm(p; force = true), (hp, hp * ".balance"))
            rm(dir; recursive = true, force = true)
        end
    end
end

end # module
