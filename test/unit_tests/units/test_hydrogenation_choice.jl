# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Hydrogenator/Content.jl: `hydrogenation_choice`, the titration method the
# residue content of a structure calls for, on small synthetic .pdb files built from the
# residues of the fixtures in test/fixtures/molecules/ (protein only, DNA, RNA, mixed,
# Amber-named, legacy-named, unknown names, look-alikes of nucleotide names). Pure text
# and table work: pdb2pqr and PROPKA never run, and the download hook is replaced by
# one that answers "no such component", so no name can reach the network.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_hydrogenation_choice

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.Hydrogenator: hydrogenation_choice, NUCLEIC_NAME_CLASH, _scan_residues,
    _is_nucleic_residue, _backbone_count, _backbone_candidate
using BAYSOL.MolecularStructure: component, residue_names, ComponentError,
    _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _ComponentNotFound, _COMPONENT_TABLE,
    BACKBONE_ATOMS, BACKBONE_MIN, AMBER_NUCLEIC_NAMES
using BAYSOL.Runtime: force

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures", "molecules")

# The ATOM lines of residues `nums` of `chain` in the fixture `id`
# a fixed-column ATOM/HETATM record (coordinates and the rest do not matter)
function pdbline(rec, serial, atom, res, chain, num, elem; xyz = (1.0, 2.0, 3.0))
    a = length(elem) == 2 ? rpad(atom, 4) : " " * rpad(atom, 3)
    return @sprintf("%-6s%5d %s %3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s",
        rec, serial, a, res, chain, num, xyz..., 1.0, 10.0, lpad(elem, 2))
end
const ION = pdbline("HETATM", 900, "MG", "MG", 'A', 901, "MG")
const WATER = pdbline("HETATM", 901, "O", "HOH", 'A', 902, "O"; xyz = (4.0, 5.0, 6.0))

function _residues(id::AbstractString, chain::Char, nums)
    out = String[]
    for l in eachline(joinpath(_FIXTURES, "$id-TEST.pdb"))
        startswith(l, "ATOM") || continue
        l[22] == chain && parse(Int, strip(l[23:26])) in nums && push!(out, l)
    end
    return out
end

# the lines with another residue name / record type / chain / atom selection
rename(lines, name) = [l[1:17] * lpad(name, 3) * l[21:end] for l in lines]
hetero(lines) = ["HETATM" * l[7:end] for l in lines]
inchain(lines, c::Char) = [l[1:21] * c * l[23:end] for l in lines]
B(lines) = inchain(lines, 'B')
atoms_in(lines, names) = [l for l in lines if strip(l[13:16]) in names]
atoms_not_in(lines, names) = [l for l in lines if !(strip(l[13:16]) in names)]
# the lines of one residue only: residue `n` of the list of lines
function one_residue(lines, n)
    key(l) = l[22:27]
    keys_ = unique(key.(lines))
    return [l for l in lines if key(l) == keys_[n]]
end

const _BASE_ADENINE = ["N9", "C8", "N7", "C5", "C6", "N6", "N1", "C2", "N3", "C4"]

# a name that is not in the table and not an Amber name, found deterministically
function _unknown_name()
    table = force(_COMPONENT_TABLE)
    for a in "QWXYZ", b in "QWXYZ", c in "QWXYZ"
        n = string(a, b, c)
        haskey(table, n) || haskey(AMBER_NUCLEIC_NAMES, n) || return n
    end
end
const _UNKNOWN = _unknown_name()

function choice_of(dir, lines; path_arg = true)
    path = joinpath(dir, "case$(rand(UInt32)).pdb")
    write(path, join(lines, "\n") * "\nEND\n")
    infos = component.(residue_names(path))
    return path_arg ? hydrogenation_choice(infos, path) : hydrogenation_choice(infos)
end

@testset "hydrogenation_choice" begin
    dir = mktempdir()
    saved_hook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
    empty!(_COMPONENT_MEMO)

    prot = _residues("1CRN", 'A', 1:3)
    dna = _residues("1BNA", 'A', 1:3)
    rna = _residues("1SDR", 'A', 1:3)     # U A A, 5' end without P
    @test length(prot) > 0 && length(dna) > 0 && length(rna) > 0

    try
        @testset "protein, nucleic acid, mixed, neither" begin
            @test choice_of(dir, prot) ==
                  (content = :protein, ff = :parse, titration = :propka, reason = "")
            @test choice_of(dir, dna) ==
                  (content = :nucleic, ff = :amber, titration = :none, reason = "")
            @test choice_of(dir, rna) ==
                  (content = :nucleic, ff = :amber, titration = :none, reason = "")
            @test choice_of(dir, [prot; B(dna)]) ==
                  (content = :mixed, ff = :parse, titration = :propka, reason = "")
            # the order is irrelevant
            @test choice_of(dir, [B(dna); prot]).content === :mixed
            @test choice_of(dir, [prot; B(dna); inchain(rna, 'C')]).content === :mixed
            # neither: no residue at all, a water, an ion, a ligand
            @test choice_of(dir, String[]).content === :protein
            @test choice_of(dir, ["REMARK nothing here"]).content === :protein
            ion = ION
            wat = WATER
            @test choice_of(dir, [ion, wat]) ==
                  (content = :protein, ff = :parse, titration = :propka, reason = "")
            # a nucleic acid with its waters and ions is still a nucleic acid
            @test choice_of(dir, [dna; ion; wat]).content === :nucleic
            # ATP is a ligand, not a nucleotide of a chain
            atp = hetero(rename(atoms_not_in(one_residue(rna, 2), ["OP1", "OP2"]), "ATP"))
            @test choice_of(dir, atp).content === :protein
            @test choice_of(dir, [prot; B(atp)]).content === :protein
            # PROPKA is chosen for everything with protein, never for DNA/RNA alone
            for lines in (prot, [prot; B(dna)], [prot; B(rna)])
                @test choice_of(dir, lines).titration === :propka
            end
            for lines in (dna, rna, [dna; ion; wat])
                @test choice_of(dir, lines).titration === :none
            end
        end

        @testset "without a path only the component classes count" begin
            @test choice_of(dir, dna; path_arg = false).content === :nucleic
            @test choice_of(dir, [prot; B(dna)]; path_arg = false).content === :mixed
            @test choice_of(dir, prot; path_arg = false).content === :protein
            # legacy names and unknown names need the atoms, and so the path
            legacy = rename(rna, "ADE")
            @test choice_of(dir, legacy; path_arg = false).content === :protein
            @test choice_of(dir, legacy).content === :nucleic
            unk = rename(rna, _UNKNOWN)
            @test choice_of(dir, unk; path_arg = false).content === :protein
            @test choice_of(dir, unk).content === :nucleic
            # the records themselves, no file: by type and class
            nuc = (; id = "XD", class = :dna, type = "dna linking")
            pep = (; id = "XP", class = :other, type = "l-peptide linking")
            dpep = (; id = "XQ", class = :other, type = "d-peptide linking")
            like = (; id = "XL", class = :other, type = "peptide-like")
            sug = (; id = "XS", class = :other, type = "d-saccharide")
            @test hydrogenation_choice([nuc]) ==
                  (content = :nucleic, ff = :amber, titration = :none, reason = "")
            @test hydrogenation_choice([pep]).content === :protein
            @test hydrogenation_choice([nuc, pep]).content === :mixed
            @test hydrogenation_choice([nuc, dpep]).content === :mixed
            # peptide-like is not a peptide
            @test hydrogenation_choice([nuc, like]).content === :nucleic
            @test hydrogenation_choice([nuc, sug]).content === :nucleic
            @test hydrogenation_choice([like]).content === :protein
            @test hydrogenation_choice([]).content === :protein
            @test hydrogenation_choice(NamedTuple[]) ==
                  (content = :protein, ff = :parse, titration = :propka, reason = "")
        end

        @testset "Amber names" begin
            amber = [
                rename(one_residue(dna, 1), "DC5"); rename(one_residue(dna, 2), "DG");
                rename(one_residue(dna, 3), "DC3")
            ]
            @test choice_of(dir, amber) ==
                  (content = :nucleic, ff = :amber, titration = :none, reason = "")
            ra = [
                rename(one_residue(rna, 1), "RU"); rename(one_residue(rna, 2), "RA");
                rename(one_residue(rna, 3), "RA3")
            ]
            # RU is ruthenium in the dictionary, but RA and RA3 are RNA: no reason needed
            @test choice_of(dir, ra) ==
                  (content = :nucleic, ff = :amber, titration = :none, reason = "")
            @test choice_of(dir, [prot; B(amber)]).content === :mixed
            # lower case names are the same names
            @test choice_of(dir, rename(dna, " dc")).content === :nucleic
            @test choice_of(dir, rename(dna, " Dc")).content === :nucleic
        end

        @testset "legacy names" begin
            # three residues, the first without P: every one counts, with the atoms
            for (name, rows) in (
                ("ADE", rename(rna, "ADE")), ("URI", rename(rna, "URI")),
                ("GUA", rename(rna, "GUA")), ("CYT", rename(rna, "CYT")),
                ("THY", rename(dna, "THY")),
            )
                c = choice_of(dir, rows)
                @test c.content === :nucleic && c.titration === :none
                @test c.reason == "3 legacy-named nucleotide residues ($name)"
                # as HETATM records they are the same
                @test choice_of(dir, hetero(rows)).content === :nucleic
            end
            two = [rename(one_residue(rna, 1), "URI"); rename(one_residue(rna, 2), "ADE");
                rename(one_residue(rna, 3), "GUA")]
            @test choice_of(dir, two).reason ==
                  "3 legacy-named nucleotide residues (ADE, GUA, URI)"
            # with protein it is a mixed file
            c = choice_of(dir, [prot; B(rename(rna, "ADE"))])
            @test c.content === :mixed && c.titration === :propka
            @test occursin("legacy-named", c.reason)

            # without the backbone they are free bases, ligands: no nucleic acid
            bases = hetero(rename(atoms_in(one_residue(rna, 2), _BASE_ADENINE), "ADE"))
            @test choice_of(dir, bases) ==
                  (content = :protein, ff = :parse, titration = :propka, reason = "")
            @test choice_of(dir, [prot; B(bases)]).content === :protein
            @test choice_of(dir, [dna; B(bases)]).content === :nucleic    # DNA decides

            # a single ADE residue: 7 backbone atoms and no P is not a nucleotide ...
            seven = hetero(
                rename(atoms_not_in(one_residue(rna, 2), ["P", "OP1", "OP2"]), "ADE"),
            )
            @test _backbone_count(Set(strip(l[13:16]) for l in seven)) == 7
            @test choice_of(dir, seven).content === :protein
            # ... with a P it is
            withp = hetero(rename(one_residue(rna, 2), "ADE"))
            c = choice_of(dir, withp)
            @test c.content === :nucleic &&
                  c.reason == "1 legacy-named nucleotide residues (ADE)"
            # 3 backbone atoms and no P are too few, even in a chain of many
            few = atoms_in(one_residue(rna, 2), ["O5'", "C5'", "C4'", "N9", "C8"])
            @test choice_of(dir, rename(few, "ADE")).content === :protein
            # four backbone atoms and no P count, but only with a second such residue in
            # the chain
            four = ["O5'", "C5'", "C4'", "O4'"]
            r2 = rename(atoms_in(one_residue(rna, 2), four), "ADE")
            r3 = rename(atoms_in(one_residue(rna, 3), four), "ADE")
            @test choice_of(dir, [r2; r3]).content === :nucleic
            @test choice_of(dir, r2).content === :protein
            @test choice_of(dir, [r2; inchain(r3, 'B')]).content === :protein
            @test choice_of(dir, [r2; r3[1:3]]).content === :protein   # the 2nd has 3
            # a residue with a P rescues nothing for the others of its chain's count: each
            # residue is judged by its own atoms, the chain only has to have two
            rp = rename(one_residue(rna, 2), "ADE")
            @test choice_of(dir, [rp; r3]).content === :nucleic
            # blank chain ids work as any other
            blank = inchain([r2; r3], ' ')
            @test choice_of(dir, blank).content === :nucleic
            # old star primes read as primes
            star = [
                l[1:12] * replace(l[13:16], "'" => "*") * l[17:end]
                for l in rename(rna, "ADE")
            ]
            @test choice_of(dir, star).content === :nucleic
        end

        @testset "look-alikes of nucleotide names" begin
            # the D-amino acid, D-sugar and ligand ids DAD DCY DGU DTH are not nucleotides,
            # whatever atoms they carry
            for n in ("DAD", "DGU", "DTH", "DCY")
                @test !(component(n).class in (:dna, :rna))
                @test !_backbone_candidate(component(n))
            end
            rows = hetero(
                [rename(one_residue(rna, 1), "DAD"); rename(one_residue(rna, 2), "DCY");
                    rename(one_residue(rna, 3), "DGU")],
            )
            @test choice_of(dir, rows) ==
                  (content = :protein, ff = :parse, titration = :propka, reason = "")
            @test choice_of(dir, hetero(rename(rna, "DTH"))).content === :protein
            # DCY is a D-peptide: a protein as far as titration goes
            @test hydrogenation_choice([component("DCY")]).content === :protein
            @test hydrogenation_choice([component("DCY"), component("DA")]).content ===
                  :mixed
            # DCP (dCTP) and the plain DNA components are not confused
            @test choice_of(dir, hetero(rename(one_residue(dna, 2), "DCP"))).content ===
                  :protein
        end

        @testset "backbone atoms in unknown names (safety net)" begin
            @test _backbone_candidate(component(_UNKNOWN))
            c = choice_of(dir, rename(rna, _UNKNOWN))
            @test c == (content = :nucleic, ff = :amber, titration = :none,
                reason = "backbone atoms in unknown residue(s) $_UNKNOWN")
            # with protein: mixed
            c = choice_of(dir, [prot; B(hetero(rename(rna, _UNKNOWN)))])
            @test c.content === :mixed && c.titration === :propka
            @test c.reason == "backbone atoms in unknown residue(s) $_UNKNOWN"
            # fewer than BACKBONE_MIN backbone atoms: an unknown ligand
            @test BACKBONE_MIN == 4
            few = atoms_in(one_residue(rna, 2), BACKBONE_ATOMS[1:(BACKBONE_MIN-1)])
            @test choice_of(dir, rename(few, _UNKNOWN)).content === :protein
            ok = atoms_in(one_residue(rna, 2), BACKBONE_ATOMS[1:BACKBONE_MIN])
            @test choice_of(dir, rename(ok, _UNKNOWN)).content === :nucleic
            # one unknown residue is enough (no chain rule here)
            @test choice_of(dir, hetero(rename(one_residue(rna, 2), _UNKNOWN))).content ===
                  :nucleic
            # the net only runs when no component is nucleic, and then it is silent
            @test choice_of(dir, [dna; B(rename(rna, _UNKNOWN))]).reason == ""
            # no path: no net
            @test choice_of(dir, rename(rna, _UNKNOWN); path_arg = false).content ===
                  :protein
            # an unknown name with protein-like atoms only stays a protein file
            @test choice_of(dir, rename(prot, _UNKNOWN)).content === :protein
        end

        @testset "RU: ruthenium or RNA uracil" begin
            @test "RU" in NUCLEIC_NAME_CLASH
            @test component("RU").class === :other
            @test _backbone_candidate(component("RU"))
            u = rename(one_residue(rna, 1), "RU")
            c = choice_of(dir, [u; rename(one_residue(rna, 2), "RU")])
            @test c.content === :nucleic &&
                  c.reason == "backbone atoms in unknown residue(s) RU"
            # a ruthenium ion has no backbone
            ru = pdbline("HETATM", 1, "RU", "RU", 'A', 101, "RU")
            @test choice_of(dir, [prot; ru]) ==
                  (content = :protein, ff = :parse, titration = :propka, reason = "")
            @test choice_of(dir, [ru]).content === :protein
            # RU beside real nucleotides: the components decide and there is no reason
            @test choice_of(dir, [B(dna); u]) ==
                  (content = :nucleic, ff = :amber, titration = :none, reason = "")
            # a ruthenium ion beside a protein with a nucleic acid under RU
            @test choice_of(dir, [prot; ru; B(u)]).content === :mixed
        end

        @testset "chain ids and files with several chains" begin
            blankdna = inchain(dna, ' ')
            @test choice_of(dir, blankdna).content === :nucleic
            @test choice_of(dir, [inchain(prot, ' '); blankdna]).content === :mixed
            multi = [inchain(prot, 'A'); inchain(dna, 'B'); inchain(rna, 'C')]
            @test choice_of(dir, multi).content === :mixed
            # chains of the same kind
            @test choice_of(dir, [inchain(dna, 'A'); inchain(rna, 'B')]).content ===
                  :nucleic
            @test choice_of(dir, [inchain(prot, 'A'); inchain(prot, 'B')]).content ===
                  :protein
        end

        @testset "DNA written with RNA letters" begin
            # plain letters on atoms without O2' are DNA relabelled for pdb2pqr: the reason
            # says so (the content is nucleic either way)
            letters = [rename(one_residue(dna, 1), "C"); rename(one_residue(dna, 2), "G");
                rename(one_residue(dna, 3), "T")]
            c = choice_of(dir, letters)
            @test c.content === :nucleic && c.titration === :none
            @test c.reason == "3 plain-letter DNA residues relabelled"
            # RNA letters on RNA atoms (with O2') are RNA: nothing to say
            @test choice_of(dir, rna).reason == ""
            # beside legacy names the two reasons are joined
            both = [letters; B(rename(rna, "ADE"))]
            @test choice_of(dir, both).reason ==
                  "3 legacy-named nucleotide residues (ADE); " *
                  "3 plain-letter DNA residues relabelled"
        end

        @testset "odd records" begin
            # atoms already carrying hydrogens, X elements, alternate locations, a
            # residue name of mixed case, lines cut short
            h = pdbline("ATOM", 99, "H5T", "DC", 'A', 1, "H")
            @test choice_of(dir, [dna; h]).content === :nucleic
            x = pdbline("HETATM", 100, "X1", "XXX", 'A', 200, "X")
            @test choice_of(dir, [dna; x]).content === :nucleic
            @test choice_of(dir, [prot; x]).content === :protein
            altloc = [
                l[1:16] * (i % 2 == 0 ? 'A' : 'B') * l[18:end] for (i, l) in enumerate(dna)
            ]
            @test choice_of(dir, altloc).content === :nucleic
            # a name of odd case and one with a blank in front are the same name
            # blanks are not part of a name
            @test choice_of(dir, rename(dna, "DC ")).content === :nucleic
            cut = [l[1:15] for l in dna]    # shorter than a residue name
            @test choice_of(dir, cut).content === :protein
            cut2 = [l[1:22] for l in dna]   # a residue name, no number
            @test choice_of(dir, cut2).content === :nucleic
            @test choice_of(dir, [dna; "ATOM"; "HETATM"; ""; "TER"]).content === :nucleic
            # an insertion code makes a different residue; legacy residues
            # 2 and 2A are two, each with a P
            ins = [rename(one_residue(rna, 2), "ADE");
                [l[1:22] * "   2A" * l[28:end] for l in rename(one_residue(rna, 3), "ADE")]]
            @test choice_of(dir, ins).reason == "2 legacy-named nucleotide residues (ADE)"
        end

        @testset "_scan_residues and _is_nucleic_residue" begin
            path = joinpath(dir, "scan.pdb")
            lines = [prot[1:2]; hetero(rename(one_residue(rna, 2), "PSU"));
                WATER
            ]
            write(path, join(lines, "\n") * "\n")
            rs = _scan_residues(path)
            @test [r.name for r in rs] == ["THR", "PSU"]          # waters are left out
            @test rs[1].key == ("A", "1")
            @test "P" in rs[2].atoms && "C1'" in rs[2].atoms
            @test _is_nucleic_residue("PSU", rs[2].atoms)
            @test !_is_nucleic_residue("THR", rs[1].atoms)
            @test !_is_nucleic_residue("HOH", Set(["O"]))
            # an unknown name is a nucleotide by its atoms only
            @test _is_nucleic_residue(_UNKNOWN, Set(BACKBONE_ATOMS))
            @test !_is_nucleic_residue(_UNKNOWN, Set(["N", "CA", "C", "O"]))
            @test _is_nucleic_residue("DA", Set{String}())
            # old star primes are read as primes
            path2 = joinpath(dir, "star.pdb")
            write(path2, join(replace.(rna[1:3], "O5'" => "O5*"), "\n") * "\n")
            @test "O5'" in only(_scan_residues(path2)).atoms
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
        empty!(_COMPONENT_MEMO)
        rm(dir; recursive = true, force = true)
    end
end

end # module
