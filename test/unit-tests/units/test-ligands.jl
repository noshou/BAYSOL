# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the ligands the structure readers keep (owner, 2026-11-11, `KEEP_LIGANDS`):
# heme, nucleotide triphosphates, sugars, glycerol and ions of a known composition scatter
# as heavy atoms without hydrogens; placeholders (`UNK`, `UNL`) and residues without
# component data are kept too (owner, 2026-11-13: nothing is dropped but waters and atoms of
# an unknown element, which are warned about). Covers `hasKnownComposition`, `isLigand`,
# `ligandSelector`, the `ligands` keyword of `loadMolecule`, and the hydrogenation of a
# hemoglobin (pdb2pqr: the CondaPkg tools are needed) whose protein part must be what it
# was. Fixtures: 3ODQ (the hemoglobin
# model of the removed SASDVA2 entry, four heme groups), 4HHB and small synthetic files.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_ligands

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.MolecularStructure: hasKnownComposition, isLigand, ligandSelector,
    polymerSelector, loadMolecule, nAtoms, elms, KEEP_LIGANDS, _storeDir
using BAYSOL.Hydrogenator: resolveHydrogens, NoTitration, hydrogenationBalance
using BioStructures: BioStructures, PDBFormat, collectatoms, collectmodels, resname

const _HB = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "3ODQ-hemoglobin.pdb")
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
countEl(m, e) = count(==(e), elms(m))

@testset "ligands in the structure" begin
    @test KEEP_LIGANDS === true

    @testset "hasKnownComposition" begin
        @test hasKnownComposition("C34 H32 Fe N4 O4")     # heme
        @test hasKnownComposition("Mg") && hasKnownComposition("K")
        @test hasKnownComposition("D2 O")                  # deuterium
        @test !hasKnownComposition("?")                    # UNL
        @test !hasKnownComposition("X")                    # DUM
        @test !hasKnownComposition("")
        @test !hasKnownComposition("C4 H9 Qq")
    end

    @testset "isLigand" begin
        for n in ("HEM", "MG", "ZN", "K", "CA", "NA", "GOL", "NAG", "GTP", "GNP", "PO4",
            "TBU", "PXX", "hem")
            @test isLigand(n)
        end
        # water, placeholders, the polymer
        for n in ("HOH", "DOD", "WAT", "UNK", "UNL", "DUM", "DUMMY", "ALA", "MSE", "A",
            "PSU")
            @test !isLigand(n)
        end
    end

    @testset "ligandSelector on atoms" begin
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
            @test kept(polymerSelector) == ["ALA"]
            @test kept(ligandSelector) == ["ALA", "HEM", "MG", "UNK"]
        end
    end

    @testset "hemoglobin 3ODQ: the four heme groups are scattered" begin
        # 4384 protein heavy atoms and 4 x 43 heme atoms (C34 Fe N4 O4), 4556 in all
        mol = loadMolecule(_HB)
        @test nAtoms(mol) == 4384 + 172 == 4556
        poly = loadMolecule(_HB; ligands = false)
        @test nAtoms(poly) == 4384
        @test countEl(mol, "fe") == 4
        @test countEl(mol, "c") - countEl(poly, "c") == 4 * 34
        @test countEl(mol, "n") - countEl(poly, "n") == 4 * 4
        @test countEl(mol, "o") - countEl(poly, "o") == 4 * 4
        @test countEl(mol, "s") == countEl(poly, "s")
        # the ligand carries no hydrogen (nor deuterium)
        @test countEl(mol, "h") == 0 && countEl(mol, "d") == 0
        @test all(isfinite, BAYSOL.MolecularStructure.coordsCartesian(mol))
        @test all(>(0), BAYSOL.MolecularStructure.radii(mol))
    end

    @testset "waters stay out, unknown-composition residues are kept" begin
        mktempdir() do dir
            base = [pdbline("ATOM", 1, "CA", "ALA", 'A', 1, "C")]
            waters = [
                pdbline("HETATM", 2, "O", "HOH", 'A', 2, "O"),
                pdbline("HETATM", 3, "O", "DOD", 'A', 3, "O"),
            ]
            @test nAtoms(loadMolecule(wr(dir, "w.pdb", [base; waters]))) == 1
            # placeholders and a name without component data: kept with their elements
            extra = [
                pdbline("HETATM", 4, "CA", "UNK", 'A', 4, "C"),
                pdbline("HETATM", 5, "C1", "UNL", 'A', 5, "C"),
                pdbline("HETATM", 6, "N1", "X+Y", 'A', 6, "N"),
            ]
            path = wr(dir, "u.pdb", [base; waters; extra])
            m = @test_logs (:info, r"kept ligands") (
                :warn, r"without component data.*X\+Y",
            ) begin
                loadMolecule(path)
            end
            @test nAtoms(m) == 4 && countEl(m, "c") == 3 && countEl(m, "n") == 1
            @test nAtoms(loadMolecule(path; ligands = false)) == 1
            # a Zn site: the ion is kept next to the protein
            ion = pdbline("HETATM", 7, "ZN", "ZN", 'A', 7, "ZN")
            m = loadMolecule(wr(dir, "z.pdb", [base; waters; ion]))
            @test nAtoms(m) == 2 && countEl(m, "zn") == 1
            z2 = wr(dir, "z2.pdb", [base; ion])
            @test nAtoms(loadMolecule(z2; ligands = false)) == 1
        end
    end

    @testset "an atom of an unknown element is dropped with a warning" begin
        mktempdir() do dir
            lines = [
                pdbline("ATOM", 1, "CA", "ALA", 'A', 1, "C"),
                pdbline("HETATM", 2, "C1", "UNL", 'A', 2, "C"),
                pdbline("HETATM", 3, "XX", "DUM", 'A', 3, "X"),
                pdbline("HETATM", 4, "XX", "DUM", 'A', 4, "X"),
            ]
            path = wr(dir, "x.pdb", lines)
            m = @test_logs (:info, r"kept ligands") (:warn, r"UNL: 1") (
                :warn, r"unknown element.*DUM: 2",
            ) begin
                loadMolecule(path)
            end
            @test nAtoms(m) == 2
        end
    end

    @testset "a glycan (NAG) and the hydrogens the file gives are kept" begin
        mktempdir() do dir
            nag = [
                pdbline("HETATM", 2, "C1", "NAG", 'A', 2, "C"),
                pdbline("HETATM", 3, "O5", "NAG", 'A', 2, "O"),
                pdbline("HETATM", 4, "N2", "NAG", 'A', 2, "N"),
                pdbline("HETATM", 5, "H1", "NAG", 'A', 2, "H"),
            ]
            path = wr(dir, "n.pdb", [pdbline("ATOM", 1, "CA", "ALA", 'A', 1, "C"); nag])
            m = loadMolecule(path)
            @test nAtoms(m) == 5 && countEl(m, "h") == 1 && countEl(m, "n") == 1
            @test isLigand("NAG") && isLigand("BMA") && isLigand("FUC")
        end
    end

    @testset "4HHB through pdb2pqr: the protein hydrogens are unchanged" begin
        dir = mktempdir()
        hp = ""
        try
            path = joinpath(dir, "lig-4hhb.pdb")
            cp(_4HHB, path)
            hp = resolveHydrogens(path, 7.0; ff = :parse, titration = NoTitration())
            b = hydrogenationBalance(hp)
            @test b !== nothing && b.ligands == 0       # pdb2pqr keeps heme
            allAtoms = loadMolecule(hp)
            poly = loadMolecule(hp; ligands = false)
            heme = nAtoms(allAtoms) - nAtoms(poly)
            # four heme groups of 43 heavy atoms and the two PO4 atoms the fixture keeps
            @test heme == 4 * 43 + 2
            @test countEl(allAtoms, "fe") == 4
            @test countEl(allAtoms, "h") == countEl(poly, "h") > 0
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
