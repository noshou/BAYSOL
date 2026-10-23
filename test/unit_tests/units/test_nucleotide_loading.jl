# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises what the structure readers keep of a nucleic acid: `nucleotide_selector`,
# `load_molecule`, the canonical .pdb that `resolve_structure` writes for a local .cif
# (src/MolecularStructure/{Components,Mols,StructureSource}.jl). Modified nucleotides
# (HETATM PSU, 5MC, ...) are kept; waters, ions, ligands and (in the canonical file)
# hydrogens are dropped. Fixtures: 1EHZ (.pdb and .cif) and small synthetic files. The
# PDB-ID route is only exercised through a file already in the store and through the
# selector its writer uses; no network, no pdb2pqr. Components not in the bundled table
# are answered by a fake download hook ("no such component").
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_nucleotide_loading

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.MolecularStructure: nucleotide_selector, load_molecule, n_atoms, elms,
    coords_cartesian, MoleculeError, ComponentError, LocalPathSource, PDBIDSource,
    resolve_structure, StructureSourceError, _store_dir, _infer_element,
    _canonical_selector, _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _ComponentNotFound
using BioStructures: BioStructures, PDBFormat, MMCIFFormat, collectatoms, collectmodels,
    writepdb, resname, ishetero, atomname

# a fixed-column ATOM/HETATM record (coordinates and the rest do not matter)
function pdbline(rec, serial, atom, res, chain, num, elem; xyz = (1.0, 2.0, 3.0))
    a = length(elem) == 2 ? rpad(atom, 4) : " " * rpad(atom, 3)
    return @sprintf("%-6s%5d %s %3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s",
        rec, serial, a, res, chain, num, xyz..., 1.0, 10.0, lpad(elem, 2))
end
const ION = pdbline("HETATM", 900, "MG", "MG", 'A', 901, "MG")
const WATER = pdbline("HETATM", 901, "O", "HOH", 'A', 902, "O"; xyz = (4.0, 5.0, 6.0))

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures", "molecules")
_fixture(id, ext = "pdb") = joinpath(_FIXTURES, "$id-TEST.$ext")

name_of(l) = strip(l[18:20])
# a residue name that is not in the table and not an Amber name
function _unknown_name()
    for a in "QWXYZ", b in "QWXYZ", c in "QWXYZ"
        n = string(a, b, c)
        haskey(
                BAYSOL.MolecularStructure.force(BAYSOL.MolecularStructure._COMPONENT_TABLE),
                n,
            ) ||
            haskey(BAYSOL.MolecularStructure.AMBER_NUCLEIC_NAMES, n) || return n
    end
end
function composition(path)
    atoms = Dict{String,Int}()
    hets = Dict{String,Int}()
    for l in eachline(path)
        (startswith(l, "ATOM") || startswith(l, "HETATM")) || continue
        d = startswith(l, "ATOM") ? atoms : hets
        d[name_of(l)] = get(d, name_of(l), 0) + 1
    end
    return atoms, hets
end
function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end
function lines_of(id, chain, nums)
    out = String[]
    for l in eachline(_fixture(id))
        (startswith(l, "ATOM") || startswith(l, "HETATM")) || continue
        l[22] == chain && parse(Int, strip(l[23:26])) in nums && push!(out, l)
    end
    return out
end

# a tiny mmCIF: an RNA residue A with a hydrogen, a modified residue PSU with a hydrogen,
# and an Mg ion, a water and a ligand (ATP) that must not survive
const _MIXED_CIF = """
data_NTLOAD
loop_
_atom_site.group_PDB
_atom_site.id
_atom_site.type_symbol
_atom_site.label_atom_id
_atom_site.label_comp_id
_atom_site.label_asym_id
_atom_site.label_seq_id
_atom_site.Cartn_x
_atom_site.Cartn_y
_atom_site.Cartn_z
_atom_site.occupancy
_atom_site.B_iso_or_equiv
_atom_site.auth_seq_id
_atom_site.auth_asym_id
_atom_site.pdbx_PDB_model_num
ATOM 1 P P A A 1 1.000 2.000 3.000 1.00 10.00 1 A 1
ATOM 2 O "O5'" A A 1 2.000 2.000 3.000 1.00 10.00 1 A 1
ATOM 3 C "C5'" A A 1 3.000 2.000 3.000 1.00 10.00 1 A 1
ATOM 4 H "H5'" A A 1 3.500 2.500 3.000 1.00 10.00 1 A 1
HETATM 5 P P PSU A 2 4.000 2.000 3.000 1.00 10.00 2 A 1
HETATM 6 C "C1'" PSU A 2 5.000 2.000 3.000 1.00 10.00 2 A 1
HETATM 7 N N1 PSU A 2 6.000 2.000 3.000 1.00 10.00 2 A 1
HETATM 8 H H1 PSU A 2 6.500 2.500 3.000 1.00 10.00 2 A 1
HETATM 9 MG MG MG B . 7.000 2.000 3.000 1.00 10.00 101 B 1
HETATM 10 O O HOH C . 8.000 2.000 3.000 1.00 10.00 102 C 1
HETATM 11 P PG ATP D . 9.000 2.000 3.000 1.00 10.00 103 D 1
"""

@testset "nucleotides in the structure readers" begin
    dir = mktempdir()
    saved_hook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
    empty!(_COMPONENT_MEMO)
    stored = String[]

    try
        @testset "the selector on atoms" begin
            path = wr(
                dir,
                "sel.pdb",
                [
                    lines_of("1EHZ", 'A', 38:41)...,
                    ION,
                    WATER,
                    pdbline("HETATM", 902, "O", "DOD", 'A', 903, "O"),
                    pdbline("HETATM", 903, "PG", "ATP", 'A', 904, "P"),
                    pdbline("HETATM", 904, "C1", _unknown_name(), 'A', 905, "C"),
                    lines_of("1CRN", 'A', 1:2)...,
                ],
            )
            model = first(collectmodels(BioStructures.read(path, PDBFormat)))
            ats = collectatoms(model)
            kept(r) = count(a -> resname(a) == r && nucleotide_selector(a), ats)
            total(r) = count(a -> resname(a) == r, ats)
            for r in ("A", "U", "THR")                      # standard (ATOM) residues
                @test kept(r) == total(r) > 0
            end
            for r in ("PSU", "5MC")                         # modified, HETATM
                @test kept(r) == total(r) > 0
            end
            # ions, waters, ligands, unknown
            for r in ("MG", "HOH", "DOD", "ATP", _unknown_name())
                @test kept(r) == 0 && total(r) > 0
            end
            # the canonical selector adds the removal of hydrogens
            hyd = lines_of("1BNA", 'A', 1:1)[1]
            hat = pdbline("ATOM", 999, "H5T", "DC", 'A', 1, "H")
            m2 = first(
                collectmodels(BioStructures.read(wr(dir, "h.pdb", [hyd, hat]), PDBFormat)),
            )
            @test length(collectatoms(m2, nucleotide_selector)) == 2
            @test length(collectatoms(m2, _canonical_selector(m2))) == 1

            # a residue that cannot be looked up is an error of the selector, typed
            _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(ErrorException("no route to host"))
            empty!(_COMPONENT_MEMO)
            @test kept("PSU") == total("PSU")              # the table needs no network
            @test_throws ComponentError count(nucleotide_selector, ats)
            err = try
                count(nucleotide_selector, ats)
                nothing
            catch e
                e
            end
            @test occursin("are you offline?", err.msg)
            _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
            empty!(_COMPONENT_MEMO)
        end

        @testset "load_molecule: 1EHZ keeps its modified bases" begin
            atoms, hets = composition(_fixture("1EHZ"))
            modified = [
                "1MA",
                "2MG",
                "5MC",
                "5MU",
                "7MG",
                "H2U",
                "M2G",
                "OMC",
                "OMG",
                "PSU",
                "YYG",
            ]
            nmod = sum(hets[r] for r in modified)
            @test nmod == 323
            nstd = sum(values(atoms))
            @test nstd == 1329
            mol = load_molecule(_fixture("1EHZ"))
            @test n_atoms(mol) == 1652 == nstd + nmod
            # waters and ions are not in it
            @test hets["HOH"] == 160 && hets["MG"] == 6 && hets["MN"] == 3
            @test !any(e -> lowercase(e) in ("mg", "mn"), elms(mol))
            @test all(isfinite, coords_cartesian(mol))
            # the same file with its modified residues stripped has 323 atoms fewer
            lean = wr(
                dir,
                "lean.pdb",
                [
                    l for l in eachline(_fixture("1EHZ"))
                    if !(startswith(l, "HETATM") && name_of(l) in modified)
                ],
            )
            @test n_atoms(load_molecule(lean)) == 1329
            # the other nucleic acid fixtures are as before
            @test n_atoms(load_molecule(_fixture("1BNA"))) == 486
            @test n_atoms(load_molecule(_fixture("1RNA"))) == 582
            @test n_atoms(load_molecule(_fixture("1SDR"))) == 1006
            # 246D has a DC in an RNA and two Na+: the ions are dropped
            atoms246, hets246 = composition(_fixture("246D"))
            @test n_atoms(load_molecule(_fixture("246D"))) == sum(values(atoms246))
            @test n_atoms(load_molecule(_fixture("3HDD"))) == 1811
        end

        @testset "resolve_structure: the .cif of 1EHZ gives the same atoms" begin
            cif = joinpath(dir, "nt-load-1ehz.cif")
            cp(_fixture("1EHZ", "cif"), cif)
            canon = joinpath(_store_dir(), "nt-load-1ehz.pdb")
            push!(stored, canon)
            rm(canon; force = true)
            resolved = resolve_structure(LocalPathSource(cif))
            @test resolved == canon && isfile(canon)
            @test n_atoms(load_molecule(resolved)) == 1652
            atoms, hets = composition(resolved)
            # modified bases are written as HETATM, with their own names; nothing else is
            @test sum(values(atoms)) == 1329
            @test sum(values(hets)) == 323
            @test Set(keys(hets)) ==
                  Set([
                "1MA",
                "2MG",
                "5MC",
                "5MU",
                "7MG",
                "H2U",
                "M2G",
                "OMC",
                "OMG",
                "PSU",
                "YYG",
            ])
            @test !any(l -> startswith(l, "HETATM") && name_of(l) in ("HOH", "MG", "MN"),
                eachline(resolved))
            # a second call finds the same content
            @test resolve_structure(LocalPathSource(cif)) == canon
            # the .pdb route used in place: the same count
            @test n_atoms(
                load_molecule(resolve_structure(LocalPathSource(_fixture("1EHZ")))),
            ) ==
                  1652
            @test resolve_structure(LocalPathSource(_fixture("1EHZ"))) ==
                  abspath(_fixture("1EHZ"))
            # the writer's selector gives the same atoms straight from the parsed model
            struc = BioStructures.read(_fixture("1EHZ", "cif"), MMCIFFormat)
            model = first(collectmodels(struc))
            out = joinpath(dir, "writer.pdb")
            writepdb(out, model, _canonical_selector(model))
            @test n_atoms(load_molecule(out)) == 1652
            @test read(out, String) == read(canon, String)
        end

        @testset "resolve_structure: waters, ions, ligands and hydrogens dropped" begin
            cif = joinpath(dir, "nt-load-mixed.cif")
            write(cif, _MIXED_CIF)
            canon = joinpath(_store_dir(), "nt-load-mixed.pdb")
            push!(stored, canon)
            rm(canon; force = true)
            resolved = resolve_structure(LocalPathSource(cif))
            recs = [
                l for l in eachline(resolved) if
                startswith(l, "ATOM") || startswith(l, "HETATM")
            ]
            @test [(l[1:6], name_of(l), strip(l[13:16])) for l in recs] == [
                ("ATOM  ", "A", "P"), ("ATOM  ", "A", "O5'"), ("ATOM  ", "A", "C5'"),
                ("HETATM", "PSU", "P"), ("HETATM", "PSU", "C1'"), ("HETATM", "PSU", "N1"),
            ]
            @test n_atoms(load_molecule(resolved)) == 6
        end

        @testset "the PDB-ID route, offline" begin
            # a file already in the store is trusted outright: no fetch
            canon = joinpath(_store_dir(), "QQ9X.pdb")
            push!(stored, canon)
            cp(_fixture("1EHZ"), canon; force = true)
            @test resolve_structure(PDBIDSource("qq9x")) == canon
            @test resolve_structure(PDBIDSource("QQ9X")) == canon
            rm(canon; force = true)
        end

        @testset "edge cases of the files" begin
            ehz = lines_of("1EHZ", 'A', 38:41)
            @test length(ehz) == 83
            # empty file or no atom: not a structure
            for content in (String[], ["REMARK 1", "END"])
                path = wr(dir, "none.pdb", content)
                @test_throws MoleculeError load_molecule(path)
            end
            @test_throws MoleculeError load_molecule(joinpath(dir, "absent.pdb"))
            # a file with waters, ions and ligands only: nothing is left
            only_het = wr(
                dir,
                "het.pdb",
                [
                    ION,
                    WATER,
                ],
            )
            @test_throws MoleculeError load_molecule(only_het)
            # a file without nucleotides is a protein as before
            @test n_atoms(load_molecule(_fixture("1CRN"))) == 327
            # truncated lines: a parse error that names the file, typed
            cut = wr(dir, "cut.pdb", [l[1:40] for l in ehz[1:5]])
            err = try
                load_molecule(cut)
                nothing
            catch e
                e
            end
            @test err isa MoleculeError && occursin("failed parsing", err.msg)
            # lines without the element column are read, atoms of modified bases too
            noelem = wr(dir, "noelem.pdb", [l[1:76] for l in ehz])
            m = load_molecule(noelem)
            @test n_atoms(m) == 83
            ref = load_molecule(wr(dir, "withelem.pdb", ehz))
            @test lowercase.(elms(m)) == lowercase.(elms(ref))
            # hydrogens already in a .pdb are loaded (a .pdb is used as given)
            hat = pdbline("HETATM", 999, "H5X", "PSU", 'A', 39, "H")
            @test n_atoms(load_molecule(wr(dir, "hyd.pdb", [ehz; hat]))) == 84
            # alternate locations: BioStructures keeps the default location, one atom each
            alt = [
                l[1:16] * (i % 2 == 0 ? "A" : "B") * l[18:end] for (i, l) in enumerate(ehz)
            ]
            @test n_atoms(load_molecule(wr(dir, "alt.pdb", alt))) <= 83
            # a residue name of odd case
            @test n_atoms(
                load_molecule(
                    wr(dir, "case.pdb",
                        [l[1:17] * lowercase(l[18:20]) * l[21:end] for l in ehz]),
                ),
            ) == 83
            # insertion codes: residues 39 and 39A
            icode = [
                l[1:26] * (parse(Int, strip(l[23:26])) == 40 ? "A" : " ") * l[28:end]
                for l in ehz
            ]
            @test n_atoms(load_molecule(wr(dir, "icode.pdb", icode))) == 83
            # a blank chain id
            blank = [l[1:21] * " " * l[23:end] for l in ehz]
            @test n_atoms(load_molecule(wr(dir, "blank.pdb", blank))) == 83
            # two models: the first only
            two = ["MODEL        1"; ehz; "ENDMDL"; "MODEL        2"; ehz; "ENDMDL"]
            @test n_atoms(load_molecule(wr(dir, "models.pdb", two))) == 83
        end

        @testset "element guesses for atoms without an element column" begin
            # the element of every atom of the modified bases of 1EHZ is guessed right
            wrong = String[]
            for l in eachline(_fixture("1EHZ"))
                startswith(l, "HETATM") || continue
                name_of(l) in ("HOH", "MG", "MN") && continue
                g = _infer_element(strip(l[13:16]), true)
                uppercase(g) == uppercase(strip(l[77:78])) || push!(wrong, strip(l[13:16]))
            end
            @test isempty(wrong)
            # the ions named for their element in full
            for (n, e) in
                (("MG", "MG"), ("MN", "MN"), ("NA", "NA"), ("ZN", "ZN"), ("FE", "FE"))
                @test _infer_element(n, true) == e
            end
            # an ATOM record trusts only the first letter: CA is carbon
            @test _infer_element("CA", false) == "C"
            @test _infer_element("", true) == "" && _infer_element("123", true) == ""
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
        empty!(_COMPONENT_MEMO)
        foreach(p -> rm(p; force = true), stored)
        rm(dir; recursive = true, force = true)
    end
end

end # module
