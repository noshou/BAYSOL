# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Hydrogenator/Modified.jl and the nucleotide guard of Content.jl: modified
# nucleotides (HETATM PSU, 5MC, 2MG, ...) are hydrogenated through the standard residue
# of their base. First the text work alone (`_standard_name`, `relabel_modified`,
# `restore_modified!`, `plain_letter_dna`, `_check_nucleotides_kept`) on small files made
# of the lines of 1EHZ and 1BNA, then pdb2pqr runs (they need the CondaPkg tools, like
# test_pdb2pqr.jl; no network): the tRNA 1EHZ with its 14 modified residues, the mixed
# protein-DNA 3HDD at three pH, and crambin on the unchanged protein route. Files that
# are run through pdb2pqr are copied under their own names (`nt-mod-*`) because the
# hydrogenated files are cached by file stem; their cache files are removed at the end.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_modified_nucleotides

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.Hydrogenator: resolve_hydrogens, Pdb2pqrError, Propka, NoTitration,
    relabel_modified, restore_modified!, plain_letter_dna, _standard_name,
    _check_nucleotides_kept, NUCLEIC_FORCE_FIELD, _hydrogens_path, _pka_path, _is_modified,
    has_modified_nucleotides, modified_hydrogen_deficit
using BAYSOL.MolecularStructure: component, residue_names, load_molecule, n_atoms,
    _store_dir, _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _ComponentNotFound,
    STANDARD_NUCLEOTIDES, AMBER_NUCLEIC_NAMES, _COMPONENT_TABLE
using BAYSOL.Runtime: force

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures", "molecules")
_fixture(id) = joinpath(_FIXTURES, "$id-TEST.pdb")

# the non-water ATOM/HETATM lines of chain `chain` of a fixture, residue numbers in `nums`
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
    for l in eachline(_fixture(id))
        (startswith(l, "ATOM") || startswith(l, "HETATM")) || continue
        l[22] == chain && parse(Int, strip(l[23:26])) in nums && push!(out, l)
    end
    return out
end

rename(lines, name) = [l[1:17] * lpad(name, 3) * l[21:end] for l in lines]
inchain(lines, c::Char) = [l[1:21] * c * l[23:end] for l in lines]
renumber(lines, num, icode = ' ') =
    [l[1:22] * lpad(num, 4) * icode * l[28:end] for l in lines]
residue(lines, num) = [l for l in lines if parse(Int, strip(l[23:26])) == num]
name_of(l) = strip(l[18:20])
is_h(l) = strip(l[77:min(end, 78)]) in ("H", "D")

# a residue name that is not in the table and not an Amber name
function _unknown_name()
    for a in "QWXYZ", b in "QWXYZ", c in "QWXYZ"
        n = string(a, b, c)
        haskey(force(_COMPONENT_TABLE), n) || haskey(AMBER_NUCLEIC_NAMES, n) || return n
    end
end

# remove the store files of the stems starting with `prefix` (hydrogenated .pdb,
# .balance, .pka)
function purge_store(prefix)
    for f in readdir(_store_dir())
        startswith(f, prefix) &&
            rm(joinpath(_store_dir(), f); force = true, recursive = true)
    end
end

# write `lines` to a file in `dir` and return its path
function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end

# the lines of a pdb2pqr-like output for `relabeled` lines: the atoms plus hydrogens
# on the given residue numbers (a name H5X, element H)
function with_hydrogens(lines, nums)
    out = String[]
    for l in lines
        push!(out, l)
        n = parse(Int, strip(l[23:26]))
        if n in nums && strip(l[13:16]) == "C1'"
            push!(
                out,
                l[1:11] * " H5X " * l[17:30] *
                "   0.100   0.200   0.300  1.00  0.00           H",
            )
        end
    end
    return out
end

@testset "modified nucleotides through their base" begin
    dir = mktempdir()
    saved_hook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
    empty!(_COMPONENT_MEMO)
    table = force(_COMPONENT_TABLE)

    # A PSU 5MC U: residues 38-41 of the yeast tRNA, the middle two modified (HETATM)
    frag = _residues("1EHZ", 'A', 38:41)
    @test [name_of(first(residue(frag, n))) for n in 38:41] == ["A", "PSU", "5MC", "U"]
    @test startswith(first(residue(frag, 39)), "HETATM") &&
          startswith(first(residue(frag, 38)), "ATOM")

    try
        @testset "_standard_name" begin
            for (b, n) in (("A", "A"), ("C", "C"), ("G", "G"), ("U", "U"), ("T", "U"))
                @test _standard_name(:rna, b) == n
            end
            for (b, n) in (("A", "DA"), ("C", "DC"), ("G", "DG"), ("T", "DT"), ("U", "DT"))
                @test _standard_name(:dna, b) == n
            end
            for b in ("X", "", "N", "-")
                @test _standard_name(:rna, b) === nothing
                @test _standard_name(:dna, b) === nothing
            end
            @test _standard_name(:other, "A") === nothing
            @test _standard_name(:protein, "U") === nothing
        end

        @testset "which nucleotides are modified" begin
            for id in ("PSU", "5MC", "2MG", "1MA", "H2U", "0C", "5HU", "2AT", "1PR")
                @test _is_modified(component(id))
            end
            for id in (collect(STANDARD_NUCLEOTIDES)..., "RA", "DA5", "RG3", "HOH", "MG",
                "ALA", "ATP", "ADE")
                @test !_is_modified(component(id))
            end
            @test has_modified_nucleotides([component("A"), component("PSU")])
            @test !has_modified_nucleotides([component("A"), component("HOH")])
            @test !has_modified_nucleotides([])
        end

        @testset "relabel: names, record types, the rest untouched" begin
            src = wr(
                dir,
                "frag.pdb",
                [
                    "HEADER    TEST", frag...,
                    ION,
                    WATER,
                    "TER", "END",
                ],
            )
            out = joinpath(dir, "frag.relabeled.pdb")
            r = relabel_modified(src, out)
            @test r.no_base == 0 && r.renumbered == false
            @test sort(collect(keys(r.plan))) == [("A", "39"), ("A", "40")]
            @test r.plan[("A", "39")] == (name = "PSU", record = "HETATM")
            @test r.plan[("A", "40")] == (name = "5MC", record = "HETATM")
            a, b = readlines(src), readlines(out)
            @test length(a) == length(b)
            for (x, y) in zip(a, b)
                if startswith(x, "HETATM") && strip(x[18:20]) in ("PSU", "5MC")
                    # ATOM record, base residue name, everything else the same
                    @test startswith(y, "ATOM  ")
                    @test y[7:17] == x[7:17] && y[21:end] == x[21:end]
                    @test strip(y[18:20]) == (strip(x[18:20]) == "PSU" ? "U" : "C")
                    @test y[18:20] == lpad(strip(y[18:20]), 3)
                else
                    @test x == y      # standard residues, ion, water, other records
                end
            end
            # all atoms of every modified residue were relabelled, none was missed
            @test count(
                l -> strip(l[18:20]) in ("PSU", "5MC"),
                filter(startswith("ATOM"), b),
            ) == 0
            # restoring on the relabelled file gives the original back, line by line
            plan = r.plan
            restore_modified!(out, plan)
            @test readlines(out) == a
            @test endswith(read(out, String), "\n")
        end

        @testset "relabel by base: the awkward classes, unknown bases" begin
            t = "5HU"
            r_ = "2AT"
            @test table[t].class === :dna && table[t].base == "U"
            @test table[r_].class === :rna && table[r_].base == "T"
            dnaA = first(
                i for i in sort(collect(values(table)); by = i -> i.id)
                if
                i.class === :dna && i.base == "A" && !(i.id in STANDARD_NUCLEOTIDES) &&
                    !haskey(AMBER_NUCLEIC_NAMES, i.id) &&
                    occursin(r"^[A-Z0-9]{3}$", i.id)
            ).id
            for (name, expect) in ((t, "DT"), (r_, "U"), (dnaA, "DA"), ("2MG", "G"),
                ("1MA", "A"), ("5MC", "C"), ("PSU", "U"), ("5MU", "U"), ("H2U", "U"))
                lines = rename(residue(frag, 39), name)
                src = wr(dir, "one.pdb", lines)
                out = joinpath(dir, "one.relabeled.pdb")
                r = relabel_modified(src, out)
                @test r.no_base == 0 && length(r.plan) == 1
                got = unique(strip(l[18:20]) for l in readlines(out))
                @test got == [expect]
                @test all(l -> startswith(l, "ATOM  "), readlines(out))
            end
            # no base: nucleotides the table gives no base (1PR RNA, 0KZ DNA) stay as
            # they are
            for name in ("1PR", "0KZ")
                @test table[name].class in (:rna, :dna) && table[name].base === nothing
                src = wr(dir, "nobase.pdb", rename(residue(frag, 39), name))
                out = joinpath(dir, "nobase.relabeled.pdb")
                r = relabel_modified(src, out)
                @test r.no_base == 1 && isempty(r.plan)
                @test readlines(out) == readlines(src)
            end
            # two residues without a base are counted once each
            two = [
                rename(residue(frag, 39), "1PR");
                renumber(rename(residue(frag, 40), "1PR"), 77)
            ]
            src = wr(dir, "nobase2.pdb", two)
            @test relabel_modified(src, joinpath(dir, "o.pdb")).no_base == 2
            # standard residues, Amber names, ligands and ions are never relabelled
            for name in ("A", "DC", "RA", "DA5", "ATP", "MG", "ALA", "HOH")
                src = wr(dir, "std.pdb", rename(residue(frag, 38), name))
                r = relabel_modified(src, joinpath(dir, "o.pdb"))
                @test isempty(r.plan) && r.no_base == 0
                @test readlines(joinpath(dir, "o.pdb")) == readlines(src)
            end
        end

        @testset "relabel and restore: keys, case, hydrogens" begin
            # a name of odd case is found, and given back as it was
            lines = rename(residue(frag, 39), "psu")
            src = wr(dir, "case.pdb", lines)
            r = relabel_modified(src, joinpath(dir, "o.pdb"))
            @test r.plan[("A", "39")].name == "psu"
            restore_modified!(joinpath(dir, "o.pdb"), r.plan)
            @test readlines(joinpath(dir, "o.pdb")) == lines

            # insertion codes: 39 and 39A are two residues
            two = [residue(frag, 39); renumber(rename(residue(frag, 40), "PSU"), 39, 'A')]
            src = wr(dir, "ins.pdb", two)
            out = joinpath(dir, "ins.out.pdb")
            r = relabel_modified(src, out)
            @test sort(collect(keys(r.plan))) == [("A", "39"), ("A", "39A")]
            restore_modified!(out, r.plan)
            @test readlines(out) == two

            # the same number in two chains
            two = [residue(frag, 39); inchain(rename(residue(frag, 40), "5MC"), 'B')]
            two = [two[1:length(residue(frag, 39))];
                renumber(two[(length(residue(frag, 39))+1):end], 39)]
            src = wr(dir, "chains.pdb", two)
            out = joinpath(dir, "chains.out.pdb")
            r = relabel_modified(src, out)
            @test sort(collect(keys(r.plan))) == [("A", "39"), ("B", "39")]
            @test unique(strip(l[18:20]) for l in readlines(out) if l[22] == 'A') == ["U"]
            @test unique(strip(l[18:20]) for l in readlines(out) if l[22] == 'B') == ["C"]
            restore_modified!(out, r.plan)
            @test readlines(out) == two

            # a modified residue as ATOM records keeps its record type
            atomrec = ["ATOM  " * l[7:end] for l in residue(frag, 39)]
            src = wr(dir, "atomrec.pdb", atomrec)
            out = joinpath(dir, "atomrec.out.pdb")
            r = relabel_modified(src, out)
            @test r.plan[("A", "39")].record == "ATOM  "
            restore_modified!(out, r.plan)
            @test readlines(out) == atomrec

            # a blank chain id: the plan key has chain "" and pdb2pqr names the chain
            blank = inchain(residue(frag, 39), ' ')
            src = wr(dir, "blank.pdb", blank)
            out = joinpath(dir, "blank.out.pdb")
            r = relabel_modified(src, out)
            @test collect(keys(r.plan)) == [("", "39")]
            named = inchain(readlines(out), 'A')       # what pdb2pqr writes
            write(out, join(named, "\n") * "\n")
            restore_modified!(out, r.plan)
            @test readlines(out) == inchain(blank, 'A')
            @test all(
                l -> strip(l[18:20]) == "PSU" && startswith(l, "HETATM"),
                readlines(out),
            )

            # hydrogens that pdb2pqr added to the relabelled residues are restored too
            src = wr(dir, "h.pdb", frag)
            out = joinpath(dir, "h.out.pdb")
            r = relabel_modified(src, out)
            hy = with_hydrogens(readlines(out), [39, 40])
            write(out, join(hy, "\n") * "\n")
            restore_modified!(out, r.plan)
            res = readlines(out)
            hyd = filter(is_h, res)
            @test length(hyd) == 2
            @test [strip(l[18:20]) for l in hyd] == ["PSU", "5MC"]
            @test all(l -> startswith(l, "HETATM"), hyd)
            @test all(l -> startswith(l, "ATOM") || startswith(l, "HETATM"), res)

            # nothing to restore: the file is not rewritten (no newline added)
            path = joinpath(dir, "keep.pdb")
            write(path, "ATOM  no newline at the end")
            restore_modified!(path, Dict{Tuple{String,String},Any}())
            @test read(path, String) == "ATOM  no newline at the end"
            # lines that are not atoms, or too short, pass through
            odd = ["REMARK 1", "ATOM  short", "HETATM", "TER", residue(frag, 39)...]
            write(path, join(odd, "\n") * "\n")
            restore_modified!(path, Dict(("A", "39") => (name = "XXX", record = "ATOM  ")))
            res = readlines(path)
            @test res[1:4] == odd[1:4]
            @test all(l -> strip(l[18:20]) == "XXX", res[5:end])
        end

        @testset "hybrid-36 serials renumber the copy" begin
            lines =
                [l[1:6] * "A" * lpad(i, 4, '0') * l[12:end] for (i, l) in enumerate(frag)]
            lines = [lines; "ANISOU    1  N   ALA A   1"]
            src = wr(dir, "h36.pdb", lines)
            out = joinpath(dir, "h36.out.pdb")
            r = relabel_modified(src, out)
            @test r.renumbered
            res = readlines(out)
            @test !any(startswith("ANISOU"), res)
            @test [parse(Int, strip(l[7:11])) for l in res] == collect(1:length(frag))
            # plain serials: nothing is renumbered
            @test !relabel_modified(wr(dir, "plain.pdb", frag), out).renumbered
        end

        @testset "DNA written with RNA letters" begin
            dna = _residues("1BNA", 'A', 1:4)
            names = [name_of(first(residue(dna, n))) for n in 1:4]
            @test names == ["DC", "DG", "DC", "DG"]
            # plain letters on DNA atoms (no O2'): relabelled as DNA
            letters = [rename(residue(dna, 1), "C"); rename(residue(dna, 2), "G");
                rename(residue(dna, 3), "U"); rename(residue(dna, 4), "T")]
            path = wr(dir, "letters.pdb", letters)
            @test plain_letter_dna(path) ==
                  Dict(("A", "1") => "DC", ("A", "2") => "DG", ("A", "3") => "DT",
                ("A", "4") => "DT")
            out = joinpath(dir, "letters.out.pdb")
            r = relabel_modified(path, out)
            @test Dict(k => v.name for (k, v) in r.plan) ==
                  Dict(("A", "1") => "  C", ("A", "2") => "  G", ("A", "3") => "  U",
                ("A", "4") => "  T")
            @test [strip(name_of(first(residue(readlines(out), n)))) for n in 1:4] ==
                  ["DC", "DG", "DT", "DT"]
            restore_modified!(out, r.plan)
            @test readlines(out) == letters
            # RNA letters on atoms that have O2' are RNA; a T is DNA whatever its atoms
            rna = _residues("1SDR", 'A', 1:2)
            path = wr(dir, "rna.pdb", rna)
            @test isempty(plain_letter_dna(path))
            @test isempty(relabel_modified(path, joinpath(dir, "o.pdb")).plan)
            path = wr(dir, "t.pdb", rename(rna, "T"))
            @test length(plain_letter_dna(path)) == 2
            # the DNA names are not plain letters
            path = wr(dir, "dnaonly.pdb", dna)
            @test isempty(plain_letter_dna(path))
        end

        @testset "guard: a nucleotide that vanished" begin
            water = WATER
            ion = ION
            src = wr(dir, "in.pdb", [frag; water; ion])
            # the output has every residue (names changed by pdb2pqr do not matter)
            ok = wr(dir, "ok.pdb", rename(frag, "UNK"))
            @test _check_nucleotides_kept(src, ok, :parse) === nothing
            # the waters and ions of the input are not nucleotides: they may vanish
            @test _check_nucleotides_kept(src, wr(dir, "ok2.pdb", frag), :parse) === nothing

            # one modified residue missing
            gone = wr(dir, "gone.pdb", [l for l in frag if l[23:26] != "  39"])
            err = try
                _check_nucleotides_kept(src, gone, :parse)
                nothing
            catch e
                e
            end
            @test err isa Pdb2pqrError
            @test occursin("--ff PARSE", err.msg) &&
                  occursin("1 nucleotide residue(s)", err.msg)
            @test occursin("PSU A39", err.msg) && !occursin("5MC", err.msg)
            @test occursin(src, err.msg) && occursin("would be lost", err.msg)
            @test startswith(sprint(showerror, err), "Pdb2pqrError: ")
            err = try
                _check_nucleotides_kept(src, gone, :amber)
                nothing
            catch e
                e
            end
            @test occursin("--ff AMBER", err.msg)

            # all nucleic acid missing: protein only left
            prot = _residues("1CRN", 'A', 1:3)
            nuc = _residues("1EHZ", 'A', 1:12)
            both = wr(dir, "both.pdb", [inchain(prot, 'B'); nuc])
            err = try
                _check_nucleotides_kept(both, wr(dir, "prot.pdb", inchain(prot, 'B')),
                    :parse)
                nothing
            catch e
                e
            end
            @test err isa Pdb2pqrError
            @test occursin("12 nucleotide residue(s)", err.msg)
            @test occursin("and 4 more", err.msg)             # eight are named
            @test occursin("G A1", err.msg) && occursin("2MG A10", err.msg) == false
            @test !occursin("THR", err.msg)

            # protein only: nothing to lose, even with an empty output
            pin = wr(dir, "pin.pdb", prot)
            @test _check_nucleotides_kept(pin, wr(dir, "empty.pdb", String[]), :parse) ===
                  nothing
            # a blank chain id of the input comes back named
            blank = wr(dir, "blankin.pdb", inchain(frag, ' '))
            @test _check_nucleotides_kept(blank, wr(dir, "named.pdb", frag), :parse) ===
                  nothing
            # a nucleotide of unknown name is found by its atoms
            unk = wr(dir, "unk.pdb", rename(residue(frag, 38), _unknown_name()))
            @test_throws Pdb2pqrError _check_nucleotides_kept(
                unk, wr(dir, "none.pdb", String[]), :parse)
        end

        # ---- pdb2pqr runs from here: the CondaPkg tools are needed -----------------------
        clean = String[]
        function keep_copy(id, stem)
            p = joinpath(dir, stem * ".pdb")
            cp(_fixture(id), p)
            push!(clean, p)
            return p
        end
        cleanup!(path) = purge_store("nt-mod-")

        # The heavy atoms of the 14 modified residues of 1EHZ and the hydrogens each got
        @testset "pdb2pqr on 1EHZ: every modified residue hydrogenated" begin
            path = keep_copy("1EHZ", "nt-mod-1ehz")
            hp = resolve_hydrogens(
                path,
                7.4;
                ff = NUCLEIC_FORCE_FIELD,
                titration = NoTitration(),
            )
            try
                @test isfile(hp) &&
                      basename(hp) == "nt-mod-1ehz_pH7.4_amber_notitration.pdb"
                @test !isfile(_pka_path(path))              # no PROPKA for a nucleic acid
                heavy_in = n_atoms(load_molecule(path))
                mol = load_molecule(hp)
                @test heavy_in == 1652
                @test n_atoms(mol) == 2472
                lines = [
                    l for l in eachline(hp)
                    if (startswith(l, "ATOM") || startswith(l, "HETATM")) &&
                        name_of(l) != "HOH"
                ]
                @test count(is_h, lines) == 820
                mods = filter(
                    l -> startswith(l, "HETATM") && !(name_of(l) in ("MG", "MN")),
                    lines,
                )
                perres = Dict{Tuple{String,String},Int}()
                for l in mods
                    k = (l[22] * strip(l[23:27]), String(name_of(l)))
                    perres[k] = get(perres, k, 0) + is_h(l)
                end
                @test perres == Dict(
                    ("A10", "2MG") => 11, ("A16", "H2U") => 10, ("A17", "H2U") => 10,
                    ("A26", "M2G") => 11, ("A32", "OMC") => 11, ("A34", "OMG") => 11,
                    ("A37", "YYG") => 11, ("A39", "PSU") => 10, ("A40", "5MC") => 11,
                    ("A46", "7MG") => 11, ("A49", "5MC") => 11, ("A54", "5MU") => 10,
                    ("A55", "PSU") => 10, ("A58", "1MA") => 11,
                )
                @test sum(values(perres)) == 149
                # every heavy atom of the modified residues is still there, unmoved
                key(l) = (name_of(l), strip(l[22:27]), strip(l[13:16]), l[31:54])
                inmods = Set(
                    key(l) for l in eachline(path)
                    if startswith(l, "HETATM") && !(name_of(l) in ("MG", "MN", "HOH"))
                )
                outmods = Set(key(l) for l in mods if !is_h(l))
                @test length(inmods) == 323
                @test inmods == outmods
                # the record type and the name are the original ones, none is a base name
                @test all(l -> startswith(l, "HETATM"), mods)
                @test Set(name_of(l) for l in mods) ==
                      Set(["2MG", "H2U", "M2G", "OMC", "OMG", "YYG", "PSU", "5MC", "7MG",
                    "5MU", "1MA"])
                # the diagnostic of the timing log agrees
                infos = component.(residue_names(path))
                d = modified_hydrogen_deficit(hp, infos)
                @test (d.residues, d.with_base, d.no_base, d.placed) == (14, 14, 0, 149)
                @test d.expected == 232
                # a repeat call is a cache hit
                @test resolve_hydrogens(
                    path,
                    7.4;
                    ff = NUCLEIC_FORCE_FIELD,
                    titration = NoTitration(),
                ) ==
                      hp
            finally
                cleanup!(path)
            end
        end

        @testset "pdb2pqr: a modified residue without a base stays whole, no hydrogen" begin
            lines = [residue(frag, 38); rename(residue(frag, 39), "1PR");
                residue(frag, 40); residue(frag, 41)]
            path = wr(dir, "nt-mod-nobase.pdb", lines)
            hp = resolve_hydrogens(
                path,
                7.4;
                ff = NUCLEIC_FORCE_FIELD,
                titration = NoTitration(),
            )
            try
                res = [
                    l for l in eachline(hp) if
                    startswith(l, "ATOM") || startswith(l, "HETATM")
                ]
                one = filter(l -> name_of(l) == "1PR", res)
                @test length(one) == length(residue(frag, 39))   # kept, same atoms
                @test count(is_h, one) == 0
                @test all(l -> startswith(l, "HETATM"), one)
                @test count(is_h, filter(l -> name_of(l) == "5MC", res)) == 11
                infos = component.(residue_names(path))
                d = modified_hydrogen_deficit(hp, infos)
                @test (d.residues, d.with_base, d.no_base, d.placed) == (2, 1, 1, 11)
            finally
                cleanup!(path)
            end
        end

        @testset "pdb2pqr on the protein-DNA complex 3HDD: the termini do not crash" begin
            path = keep_copy("3HDD", "nt-mod-3hdd")
            try
                heavy = n_atoms(load_molecule(path))
                @test heavy == 1811
                # the former AMBER route crashed where a terminus is neutral (pH 3 and 9)
                for (pH, total) in ((3.0, 3303), (7.4, 3291), (9.0, 3289))
                    hp = resolve_hydrogens(path, pH; titration = Propka())
                    @test isfile(hp)
                    @test n_atoms(load_molecule(hp)) == total
                    # the DNA is whole at every pH
                    out = [l for l in eachline(hp) if startswith(l, "ATOM")]
                    dna = filter(l -> strip(l[18:20]) in ("DA", "DC", "DG", "DT"), out)
                    @test count(!is_h, dna) == 855
                end
                @test isfile(_pka_path(path))               # protein: PROPKA ran
            finally
                cleanup!(path)
            end
        end

        @testset "pdb2pqr on crambin: the protein route is unchanged" begin
            path = keep_copy("1CRN", "nt-mod-1crn")
            try
                hp = resolve_hydrogens(path, 7.4; titration = Propka())
                @test n_atoms(load_molecule(path)) == 327
                @test n_atoms(load_molecule(hp)) == 642
                @test count(is_h, [l for l in eachline(hp) if startswith(l, "ATOM")]) == 315
                @test endswith(hp, "nt-mod-1crn_pH7.4_parse_propka.pdb")
            finally
                cleanup!(path)
            end
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
        empty!(_COMPONENT_MEMO)
        rm(dir; recursive = true, force = true)
    end
end

end # module
