# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/hydrogenator/modified.jl and the nucleotide guard of content.jl: modified
# nucleotides (HETATM PSU, 5MC, 2MG, ...) are hydrogenated through the standard residue
# of their base. First the text work alone (`_standardName`, `relabelModified`,
# `restoreModified!`, `plainLetterDna`, `_checkNucleotidesKept`) on small files made
# of the lines of 1EHZ and 1BNA, then pdb2pqr runs (they need the CondaPkg tools, like
# test-pdb2pqr.jl; no network): the tRNA 1EHZ with its 14 modified residues, the mixed
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

using BAYSOL.Hydrogenator: resolveHydrogens, Pdb2pqrError, Propka, NoTitration,
    relabelModified, restoreModified!, plainLetterDna, _standardName,
    _checkNucleotidesKept, NUCLEIC_FORCE_FIELD, _hydrogensPath, _pkaPath, _isModified,
    hasModifiedNucleotides, modifiedHydrogenDeficit
using BAYSOL.MolecularStructure: component, residueNames, loadMolecule, nAtoms,
    _storeDir, _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _ComponentNotFound,
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
nameOf(l) = strip(l[18:20])
isH(l) = strip(l[77:min(end, 78)]) in ("H", "D")

# a residue name that is not in the table and not an Amber name
function _unknownName()
    for a in "QWXYZ", b in "QWXYZ", c in "QWXYZ"
        n = string(a, b, c)
        haskey(force(_COMPONENT_TABLE), n) || haskey(AMBER_NUCLEIC_NAMES, n) || return n
    end
end

# remove the store files of the stems starting with `prefix` (hydrogenated .pdb,
# .balance, .pka)
function purgeStore(prefix)
    for f in readdir(_storeDir())
        startswith(f, prefix) &&
            rm(joinpath(_storeDir(), f); force = true, recursive = true)
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
function withHydrogens(lines, nums)
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
    savedHook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
    empty!(_COMPONENT_MEMO)
    table = force(_COMPONENT_TABLE)

    # A PSU 5MC U: residues 38-41 of the yeast tRNA, the middle two modified (HETATM)
    frag = _residues("1EHZ", 'A', 38:41)
    @test [nameOf(first(residue(frag, n))) for n in 38:41] == ["A", "PSU", "5MC", "U"]
    @test startswith(first(residue(frag, 39)), "HETATM") &&
          startswith(first(residue(frag, 38)), "ATOM")

    try
        @testset "_standardName" begin
            for (b, n) in (("A", "A"), ("C", "C"), ("G", "G"), ("U", "U"), ("T", "U"))
                @test _standardName(:rna, b) == n
            end
            for (b, n) in (("A", "DA"), ("C", "DC"), ("G", "DG"), ("T", "DT"), ("U", "DT"))
                @test _standardName(:dna, b) == n
            end
            for b in ("X", "", "N", "-")
                @test _standardName(:rna, b) === nothing
                @test _standardName(:dna, b) === nothing
            end
            @test _standardName(:other, "A") === nothing
            @test _standardName(:protein, "U") === nothing
        end

        @testset "which nucleotides are modified" begin
            for id in ("PSU", "5MC", "2MG", "1MA", "H2U", "0C", "5HU", "2AT", "1PR")
                @test _isModified(component(id))
            end
            for id in (collect(STANDARD_NUCLEOTIDES)..., "RA", "DA5", "RG3", "HOH", "MG",
                "ALA", "ATP", "ADE")
                @test !_isModified(component(id))
            end
            @test hasModifiedNucleotides([component("A"), component("PSU")])
            @test !hasModifiedNucleotides([component("A"), component("HOH")])
            @test !hasModifiedNucleotides([])
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
            r = relabelModified(src, out)
            @test r.noBase == 0 && r.renumbered == false
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
            restoreModified!(out, plan)
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
                r = relabelModified(src, out)
                @test r.noBase == 0 && length(r.plan) == 1
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
                r = relabelModified(src, out)
                @test r.noBase == 1 && isempty(r.plan)
                @test readlines(out) == readlines(src)
            end
            # two residues without a base are counted once each
            two = [
                rename(residue(frag, 39), "1PR");
                renumber(rename(residue(frag, 40), "1PR"), 77)
            ]
            src = wr(dir, "nobase2.pdb", two)
            @test relabelModified(src, joinpath(dir, "o.pdb")).noBase == 2
            # standard residues, Amber names, ligands and ions are never relabelled
            for name in ("A", "DC", "RA", "DA5", "ATP", "MG", "ALA", "HOH")
                src = wr(dir, "std.pdb", rename(residue(frag, 38), name))
                r = relabelModified(src, joinpath(dir, "o.pdb"))
                @test isempty(r.plan) && r.noBase == 0
                @test readlines(joinpath(dir, "o.pdb")) == readlines(src)
            end
        end

        @testset "relabel and restore: keys, case, hydrogens" begin
            # a name of odd case is found, and given back as it was
            lines = rename(residue(frag, 39), "psu")
            src = wr(dir, "case.pdb", lines)
            r = relabelModified(src, joinpath(dir, "o.pdb"))
            @test r.plan[("A", "39")].name == "psu"
            restoreModified!(joinpath(dir, "o.pdb"), r.plan)
            @test readlines(joinpath(dir, "o.pdb")) == lines

            # insertion codes: 39 and 39A are two residues
            two = [residue(frag, 39); renumber(rename(residue(frag, 40), "PSU"), 39, 'A')]
            src = wr(dir, "ins.pdb", two)
            out = joinpath(dir, "ins.out.pdb")
            r = relabelModified(src, out)
            @test sort(collect(keys(r.plan))) == [("A", "39"), ("A", "39A")]
            restoreModified!(out, r.plan)
            @test readlines(out) == two

            # the same number in two chains
            two = [residue(frag, 39); inchain(rename(residue(frag, 40), "5MC"), 'B')]
            two = [two[1:length(residue(frag, 39))];
                renumber(two[(length(residue(frag, 39))+1):end], 39)]
            src = wr(dir, "chains.pdb", two)
            out = joinpath(dir, "chains.out.pdb")
            r = relabelModified(src, out)
            @test sort(collect(keys(r.plan))) == [("A", "39"), ("B", "39")]
            @test unique(strip(l[18:20]) for l in readlines(out) if l[22] == 'A') == ["U"]
            @test unique(strip(l[18:20]) for l in readlines(out) if l[22] == 'B') == ["C"]
            restoreModified!(out, r.plan)
            @test readlines(out) == two

            # a modified residue as ATOM records keeps its record type
            atomrec = ["ATOM  " * l[7:end] for l in residue(frag, 39)]
            src = wr(dir, "atomrec.pdb", atomrec)
            out = joinpath(dir, "atomrec.out.pdb")
            r = relabelModified(src, out)
            @test r.plan[("A", "39")].record == "ATOM  "
            restoreModified!(out, r.plan)
            @test readlines(out) == atomrec

            # a blank chain id: the plan key has chain "" and pdb2pqr names the chain
            blank = inchain(residue(frag, 39), ' ')
            src = wr(dir, "blank.pdb", blank)
            out = joinpath(dir, "blank.out.pdb")
            r = relabelModified(src, out)
            @test collect(keys(r.plan)) == [("", "39")]
            named = inchain(readlines(out), 'A')       # what pdb2pqr writes
            write(out, join(named, "\n") * "\n")
            restoreModified!(out, r.plan)
            @test readlines(out) == inchain(blank, 'A')
            @test all(
                l -> strip(l[18:20]) == "PSU" && startswith(l, "HETATM"),
                readlines(out),
            )

            # hydrogens that pdb2pqr added to the relabelled residues are restored too
            src = wr(dir, "h.pdb", frag)
            out = joinpath(dir, "h.out.pdb")
            r = relabelModified(src, out)
            hy = withHydrogens(readlines(out), [39, 40])
            write(out, join(hy, "\n") * "\n")
            restoreModified!(out, r.plan)
            res = readlines(out)
            hyd = filter(isH, res)
            @test length(hyd) == 2
            @test [strip(l[18:20]) for l in hyd] == ["PSU", "5MC"]
            @test all(l -> startswith(l, "HETATM"), hyd)
            @test all(l -> startswith(l, "ATOM") || startswith(l, "HETATM"), res)

            # nothing to restore: the file is not rewritten (no newline added)
            path = joinpath(dir, "keep.pdb")
            write(path, "ATOM  no newline at the end")
            restoreModified!(path, Dict{Tuple{String,String},Any}())
            @test read(path, String) == "ATOM  no newline at the end"
            # lines that are not atoms, or too short, pass through
            odd = ["REMARK 1", "ATOM  short", "HETATM", "TER", residue(frag, 39)...]
            write(path, join(odd, "\n") * "\n")
            restoreModified!(path, Dict(("A", "39") => (name = "XXX", record = "ATOM  ")))
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
            r = relabelModified(src, out)
            @test r.renumbered
            res = readlines(out)
            @test !any(startswith("ANISOU"), res)
            @test [parse(Int, strip(l[7:11])) for l in res] == collect(1:length(frag))
            # plain serials: nothing is renumbered
            @test !relabelModified(wr(dir, "plain.pdb", frag), out).renumbered
        end

        @testset "DNA written with RNA letters" begin
            dna = _residues("1BNA", 'A', 1:4)
            names = [nameOf(first(residue(dna, n))) for n in 1:4]
            @test names == ["DC", "DG", "DC", "DG"]
            # plain letters on DNA atoms (no O2'): relabelled as DNA
            letters = [rename(residue(dna, 1), "C"); rename(residue(dna, 2), "G");
                rename(residue(dna, 3), "U"); rename(residue(dna, 4), "T")]
            path = wr(dir, "letters.pdb", letters)
            @test plainLetterDna(path) ==
                  Dict(("A", "1") => "DC", ("A", "2") => "DG", ("A", "3") => "DT",
                ("A", "4") => "DT")
            out = joinpath(dir, "letters.out.pdb")
            r = relabelModified(path, out)
            @test Dict(k => v.name for (k, v) in r.plan) ==
                  Dict(("A", "1") => "  C", ("A", "2") => "  G", ("A", "3") => "  U",
                ("A", "4") => "  T")
            @test [strip(nameOf(first(residue(readlines(out), n)))) for n in 1:4] ==
                  ["DC", "DG", "DT", "DT"]
            restoreModified!(out, r.plan)
            @test readlines(out) == letters
            # RNA letters on atoms that have O2' are RNA; a T is DNA whatever its atoms
            rna = _residues("1SDR", 'A', 1:2)
            path = wr(dir, "rna.pdb", rna)
            @test isempty(plainLetterDna(path))
            @test isempty(relabelModified(path, joinpath(dir, "o.pdb")).plan)
            path = wr(dir, "t.pdb", rename(rna, "T"))
            @test length(plainLetterDna(path)) == 2
            # the DNA names are not plain letters
            path = wr(dir, "dnaonly.pdb", dna)
            @test isempty(plainLetterDna(path))
        end

        @testset "guard: a nucleotide that vanished" begin
            water = WATER
            ion = ION
            src = wr(dir, "in.pdb", [frag; water; ion])
            # the output has every residue (names changed by pdb2pqr do not matter)
            ok = wr(dir, "ok.pdb", rename(frag, "UNK"))
            @test _checkNucleotidesKept(src, ok, :parse) === nothing
            # the waters and ions of the input are not nucleotides: they may vanish
            @test _checkNucleotidesKept(src, wr(dir, "ok2.pdb", frag), :parse) === nothing

            # one modified residue missing
            gone = wr(dir, "gone.pdb", [l for l in frag if l[23:26] != "  39"])
            err = try
                _checkNucleotidesKept(src, gone, :parse)
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
                _checkNucleotidesKept(src, gone, :amber)
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
                _checkNucleotidesKept(both, wr(dir, "prot.pdb", inchain(prot, 'B')),
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
            @test _checkNucleotidesKept(pin, wr(dir, "empty.pdb", String[]), :parse) ===
                  nothing
            # a blank chain id of the input comes back named
            blank = wr(dir, "blankin.pdb", inchain(frag, ' '))
            @test _checkNucleotidesKept(blank, wr(dir, "named.pdb", frag), :parse) ===
                  nothing
            # a nucleotide of unknown name is found by its atoms
            unk = wr(dir, "unk.pdb", rename(residue(frag, 38), _unknownName()))
            @test_throws Pdb2pqrError _checkNucleotidesKept(
                unk, wr(dir, "none.pdb", String[]), :parse)
        end

        # ---- pdb2pqr runs from here: the CondaPkg tools are needed -----------------------
        clean = String[]
        function keepCopy(id, stem)
            p = joinpath(dir, stem * ".pdb")
            cp(_fixture(id), p)
            push!(clean, p)
            return p
        end
        cleanup!(path) = purgeStore("nt-mod-")

        # The heavy atoms of the 14 modified residues of 1EHZ and the hydrogens each got
        @testset "pdb2pqr on 1EHZ: every modified residue hydrogenated" begin
            path = keepCopy("1EHZ", "nt-mod-1ehz")
            hp = resolveHydrogens(
                path,
                7.4;
                ff = NUCLEIC_FORCE_FIELD,
                titration = NoTitration(),
            )
            try
                @test isfile(hp) &&
                      basename(hp) == "nt-mod-1ehz_pH7.4_amber_notitration.pdb"
                @test !isfile(_pkaPath(path))              # no PROPKA for a nucleic acid
                heavyIn = nAtoms(loadMolecule(path))
                mol = loadMolecule(hp)
                # 1652 and 2472 before 2026-11-11: the nine Mg and Mn ions are ligands, kept
                @test heavyIn == 1652 + 9
                @test nAtoms(mol) == 2472 + 9
                lines = [
                    l for l in eachline(hp)
                    if (startswith(l, "ATOM") || startswith(l, "HETATM")) &&
                        nameOf(l) != "HOH"
                ]
                @test count(isH, lines) == 820
                mods = filter(
                    l -> startswith(l, "HETATM") && !(nameOf(l) in ("MG", "MN")),
                    lines,
                )
                perres = Dict{Tuple{String,String},Int}()
                for l in mods
                    k = (l[22] * strip(l[23:27]), String(nameOf(l)))
                    perres[k] = get(perres, k, 0) + isH(l)
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
                key(l) = (nameOf(l), strip(l[22:27]), strip(l[13:16]), l[31:54])
                inmods = Set(
                    key(l) for l in eachline(path)
                    if startswith(l, "HETATM") && !(nameOf(l) in ("MG", "MN", "HOH"))
                )
                outmods = Set(key(l) for l in mods if !isH(l))
                @test length(inmods) == 323
                @test inmods == outmods
                # the record type and the name are the original ones, none is a base name
                @test all(l -> startswith(l, "HETATM"), mods)
                @test Set(nameOf(l) for l in mods) ==
                      Set(["2MG", "H2U", "M2G", "OMC", "OMG", "YYG", "PSU", "5MC", "7MG",
                    "5MU", "1MA"])
                # the diagnostic of the timing log agrees
                infos = component.(residueNames(path))
                d = modifiedHydrogenDeficit(hp, infos)
                @test (d.residues, d.withBase, d.noBase, d.placed) == (14, 14, 0, 149)
                @test d.expected == 232
                # a repeat call is a cache hit
                @test resolveHydrogens(
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
            hp = resolveHydrogens(
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
                one = filter(l -> nameOf(l) == "1PR", res)
                @test length(one) == length(residue(frag, 39))   # kept, same atoms
                @test count(isH, one) == 0
                @test all(l -> startswith(l, "HETATM"), one)
                @test count(isH, filter(l -> nameOf(l) == "5MC", res)) == 11
                infos = component.(residueNames(path))
                d = modifiedHydrogenDeficit(hp, infos)
                @test (d.residues, d.withBase, d.noBase, d.placed) == (2, 1, 1, 11)
            finally
                cleanup!(path)
            end
        end

        @testset "pdb2pqr on the protein-DNA complex 3HDD: the termini do not crash" begin
            path = keepCopy("3HDD", "nt-mod-3hdd")
            try
                heavy = nAtoms(loadMolecule(path))
                @test heavy == 1811
                # the former AMBER route crashed where a terminus is neutral (pH 3 and 9)
                for (pH, total) in ((3.0, 3303), (7.4, 3291), (9.0, 3289))
                    hp = resolveHydrogens(path, pH; titration = Propka())
                    @test isfile(hp)
                    @test nAtoms(loadMolecule(hp)) == total
                    # the DNA is whole at every pH
                    out = [l for l in eachline(hp) if startswith(l, "ATOM")]
                    dna = filter(l -> strip(l[18:20]) in ("DA", "DC", "DG", "DT"), out)
                    @test count(!isH, dna) == 855
                end
                @test isfile(_pkaPath(path))               # protein: PROPKA ran
            finally
                cleanup!(path)
            end
        end

        @testset "pdb2pqr on crambin: the protein route is unchanged" begin
            path = keepCopy("1CRN", "nt-mod-1crn")
            try
                hp = resolveHydrogens(path, 7.4; titration = Propka())
                @test nAtoms(loadMolecule(path)) == 327
                @test nAtoms(loadMolecule(hp)) == 642
                @test count(isH, [l for l in eachline(hp) if startswith(l, "ATOM")]) == 315
                @test endswith(hp, "nt-mod-1crn_pH7.4_parse_propka.pdb")
            finally
                cleanup!(path)
            end
        end
    finally
        _COMPONENT_DOWNLOAD[] = savedHook
        empty!(_COMPONENT_MEMO)
        rm(dir; recursive = true, force = true)
    end
end

end # module
