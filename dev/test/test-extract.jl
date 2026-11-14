# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of Extract on tiny synthetic dictionaries: quoted values, `?` parents, DNA / RNA /
# L-RNA and terminus types, tab sanitising, sorting, multi-line names, atom and bond loops
# with quoted atom names, the base read from the ring by position (every natural base,
# 5-aminothymidine, an abasic sugar, inosine- and isoguanine-like bases), the signal order
# and the parent chain, the validation report, the header, and the --check / --update
# modes through the command line.
using Test

# --- Components

module TComponents

using Test
using CodecZlib
using Dev
using Dev.Common
using .Main.Helpers

const C = Dev.Extract.Components

# --- building a dictionary

# A CIF token: quoted when it holds a quote or a space.
q(s) = occursin(r"['\s]", s) ? "\"" * s * "\"" : s

# The CIF text of one component.
function block_text(; id, name_mode = nothing, formula = "C1", parent = "?", letter = "?",
    atoms = [], bonds = [], type = "RNA LINKING", name = nothing)
    id = string(id)
    name_lines =
        name_mode === :block ? ["_chem_comp.name", ";" * name, "continued line", ";"] :
        name_mode === :next ? ["_chem_comp.name ", "\"" * name * "\""] :
        ["_chem_comp.name  " * (name === nothing ? "?" : "\"" * name * "\"")]
    lines = vcat(["data_$id", "# ", "_chem_comp.id $id "], name_lines,
        ["_chem_comp.type \"$type\"", "_chem_comp.formula \"$formula\"",
            "_chem_comp.mon_nstd_parent_comp_id $parent",
            "_chem_comp.one_letter_code $letter",
            "# ", "loop_", "_chem_comp_atom.comp_id", "_chem_comp_atom.atom_id",
            "_chem_comp_atom.alt_atom_id", "_chem_comp_atom.type_symbol"],
        [
            "$id $(q(n)) $(q(n)) $e 0 1 N" for (n, e) in vcat(collect(atoms),
                [("H$(rand(0:8))", "H")])
        ],
        ["# ", "loop_", "_chem_comp_bond.comp_id", "_chem_comp_bond.atom_id_1",
            "_chem_comp_bond.atom_id_2", "_chem_comp_bond.value_order"],
        ["$id $(q(a)) $(q(b)) SING" for (a, b) in bonds], ["# "])
    return join(lines, "\n")
end

# The bonds closing the ring `names` into a cycle.
ring_bonds(names) = collect(zip(names, vcat(names[2:end], [names[1]])))

const SUGAR_ATOMS = [("O4'", "O"), ("C1'", "C"), ("C2'", "C"), ("C3'", "C"), ("C4'", "C"),
    ("C5'", "C"), ("O3'", "O")]
const SUGAR_BONDS = vcat(ring_bonds(["C1'", "C2'", "C3'", "C4'", "O4'"]),
    [("C4'", "C5'"), ("C3'", "O3'")])

# The atoms and bonds of a nucleoside with a pyrimidine: the oxygen on C2, the atom `c4`
# ((name, element)) on C4 and, if given, `c5` on C5.
pyrimidine(c4, c5) = Dict{Symbol,Any}(
    :atoms => vcat(SUGAR_ATOMS,
        [("N1", "N"), ("C2", "C"), ("N3", "N"), ("C4", "C"),
            ("C5", "C"), ("C6", "C"), ("O2", "O"), c4], c5 === nothing ? [] : [c5]),
    :bonds => vcat(SUGAR_BONDS, [("C1'", "N1")],
        ring_bonds(["N1", "C2", "N3", "C4", "C5",
            "C6"]), [("C2", "O2"), ("C4", first(c4))],
        c5 === nothing ? [] : [("C5", first(c5))]))

# The atoms and bonds of a nucleoside with a purine: `c6` ((name, element)) on C6 and, if
# given, `c2` on C2.
purine(c6, c2) = Dict{Symbol,Any}(
    :atoms => vcat(SUGAR_ATOMS,
        [("N9", "N"), ("C8", "C"), ("N7", "N"), ("C5", "C"),
            ("C4", "C"), ("N3", "N"), ("C2", "C"), ("N1", "N"), ("C6", "C"), c6],
        c2 === nothing ? [] : [c2]),
    :bonds =>
        vcat(SUGAR_BONDS, [("C1'", "N9")], ring_bonds(["N9", "C8", "N7", "C5", "C4"]),
            [("C4", "N3"), ("N3", "C2"), ("C2", "N1"), ("N1", "C6"), ("C6", "C5")],
            [("C6", first(c6))], c2 === nothing ? [] : [("C2", first(c2))]))

const O4 = ("O4", "O")
const N4 = ("N4", "N")
const C5_METHYL = ("CM5", "C")
const C5_AMINE = ("N5", "N")

# the base of each synthetic nucleoside as the ring reads it
nucleosides() = Dict(
    "cytidine" => (pyrimidine(N4, nothing), "C"),
    "5-aminocytidine" => (pyrimidine(N4, C5_AMINE), "C"),
    "uridine" => (pyrimidine(O4, nothing), :ut),
    "thymidine" => (pyrimidine(O4, C5_METHYL), :ut),
    "5-aminothymidine" => (pyrimidine(O4, C5_AMINE), :ut),
    "adenosine" => (purine(("N6", "N"), nothing), "A"),
    "guanosine" => (purine(("O6", "O"), ("N2", "N")), "G"),
    "inosine-like" => (purine(("O6", "O"), nothing), nothing),
    "isoguanine-like" => (purine(("N6", "N"), ("O2", "O")), nothing),
    "abasic" => (
        Dict{Symbol,Any}(:atoms => vcat(SUGAR_ATOMS, [("O1'", "O")]),
            :bonds => vcat(SUGAR_BONDS, [("C1'", "O1'")])), nothing))

# one component from a dict of the keys of `block_text`
spec(d::Dict; kw...) = merge(d, Dict{Symbol,Any}(kw))
blocks_of(specs...) =
    C.read_blocks(IOBuffer(join((block_text(; s...) for s in specs), "\n")))
blocks_of_text(text) = C.read_blocks(IOBuffer(text))

# --- parsing

@testset "quotes, text blocks, empty values, atoms with quoted names, hydrogens" begin
    b = only(
        blocks_of(
            spec(pyrimidine(O4, nothing); id = "X1", name = "O'Neil",
                name_mode = :block),
        ),
    )
    @test b["name"] == "O'Neil continued line"
    @test ("O4'", "O") in b[:atoms]
    @test !any(a -> a[2] == "H", b[:atoms])
    @test ("C1'", "N1") in b[:bonds]
    @test only(
        blocks_of(Dict{Symbol,Any}(:id => "X2", :name => "ADENOSINE",
            :name_mode => :next)),
    )["name"] == "ADENOSINE"
    # a component that is not a nucleic acid keeps no atoms
    @test !haskey(
        only(
            blocks_of(
                Dict{Symbol,Any}(:id => "X3", :type => "NON-POLYMER",
                    :atoms => [("C", "C")]),
            ),
        ), :atoms)
    err = try
        blocks_of_text("data_Q\n_chem_comp.type X\n")
    catch e
        e
    end
    @test err isa ToolError && occursin("no _chem_comp.id", err.message)
end

@testset "tokens" begin
    @test C.tokens("X \"O5'\" \"H5''\" 'a b' N") == ["X", "O5'", "H5''", "a b", "N"]
end

@testset "the word DNA or RNA decides, nothing else" begin
    @test C.component_class.(["dna linking", "l-dna linking", "rna linking",
        "l-rna linking",
        "rna oh 3 prime terminus", "non-polymer", "dnarna-like"]) ==
          ["dna", "dna", "rna", "rna", "rna", "other", "other"]
end

@testset "unquoting" begin
    @test C.unquote_value.(["'a b'", "\"a b\"", "ab", "'ab", "'", ""]) ==
          ["a b", "a b", "ab", "'ab", "'", ""]
end

# --- the base

@testset "the ring reads the base by position: $name" for (name, (structure, expected)) in
                                                          nucleosides()
    @test C.ring_base(only(blocks_of(spec(structure; id = "R")))) == expected
end

@testset "an amine only at C5 is not a cytosine; no sugar and no base give nothing" begin
    @test C.ring_base(only(blocks_of(spec(pyrimidine(O4, C5_AMINE); id = "R")))) != "C"
    @test C.ring_base(
        only(blocks_of(Dict{Symbol,Any}(:id => "R",
            :atoms => [("C1", "C")]))),
    ) === nothing
end

@testset "name and letter" begin
    @test C.name_base.(["adenosine", "2'-deoxyguanosine", "5-methylcytidine", "THYMIDINE",
        "URIDINE-5'-MONOPHOSPHATE", "inosine", "adenosine-guanosine dimer"]) ==
          ["A", "G", "C", "T", "U", nothing, nothing]
    @test C.letter_base.(["A", "t", "N", "?"]) == ["A", "T", nothing, nothing]
end

@testset "parent chain" begin
    parentOf =
        Dict("TTD" => "DT", "P1" => "P2", "P2" => "P1", "M" => "TTD", "X" => "DT, DA")
    @test C.parent_base(parentOf, "DT, DT") == "T"
    @test C.parent_base(parentOf, "TTD") == "T"
    @test C.parent_base(parentOf, "M") == "T"
    @test C.parent_base(parentOf, "X") === nothing
    @test C.parent_base(parentOf, "P1") === nothing
    @test C.parent_base(parentOf, "NOPE") === nothing
    @test C.parent_base(parentOf, "-") === nothing
end

@testset "signal order" begin
    infer(m) = C.infer_base(only(blocks_of(merge(Dict{Symbol,Any}(:id => "Z"), m))))
    @test infer(spec(pyrimidine(N4, nothing); name = "unrelated")) == ("C", "ring")
    @test infer(spec(pyrimidine(N4, nothing); letter = "C")) == ("C", "letter")
    @test infer(Dict{Symbol,Any}(:name => "cytidine")) == ("C", "name")
    # ring and name disagree
    @test infer(spec(pyrimidine(N4, nothing); name = "adenosine")) == ("-", "-")
    # a uracil or thymine ring takes the base from the name...
    @test infer(spec(pyrimidine(O4, C5_METHYL); name = "thymidine")) == ("T", "name")
    # ...and decides nothing alone
    @test infer(pyrimidine(O4, C5_METHYL)) == ("-", "-")
    # a letter that is not U or T contradicts a uracil ring
    @test infer(spec(pyrimidine(O4, nothing); letter = "A")) == ("-", "-")
    @test infer(spec(purine(("O6", "O"), nothing); name = "inosine")) == ("-", "-")
    @test infer(Dict{Symbol,Any}(:id => "DA")) == ("A", "self")
end

@testset "declared parent first, non-nucleic acids '-', the five columns unchanged" begin
    rows = C.rowsOf(
        blocks_of(
            Dict{Symbol,Any}(:id => "AAA", :type => "DNA LINKING", :parent => "DT, DT",
                :letter => "A"),
            Dict{Symbol,Any}(:id => "BBB", :type => "NON-POLYMER", :name => "adenosine"),
            spec(pyrimidine(N4, nothing); id = "CCC"),
            Dict{Symbol,Any}(:id => "DDD", :parent => "TTD"),
            Dict{Symbol,Any}(:id => "TTD", :parent => "DT")),
    )
    by_id = Dict(r[1] => r for r in rows)
    @test by_id["AAA"] == ["AAA", "dna", "dna linking", "DT, DT", "C1", "T", "parent"]
    @test by_id["BBB"] == ["BBB", "other", "non-polymer", "-", "C1", "-", "-"]
    @test by_id["CCC"][6:7] == ["C", "ring"]
    @test by_id["DDD"][6:7] == ["T", "parent"]
end

# --- validation

@testset "each signal against the base the declared parent leads to" begin
    blocks = blocks_of(
        spec(
            pyrimidine(N4, nothing);
            id = "V1",
            parent = "C",
            letter = "C",
            name = "cytidine",
        ),
        spec(pyrimidine(N4, nothing); id = "V2", parent = "DA", name = "adenosine"),
        spec(pyrimidine(O4, nothing); id = "V3", parent = "U"),
        Dict{Symbol,Any}(:id => "V4"))
    v = C.validate(blocks)
    @test v.total == 3
    @test (v.signals[:letter].found, v.signals[:letter].correct) == (1, 1)
    @test (v.signals[:ring].found, v.signals[:ring].correct) == (2, 1)
    @test (v.signals[:name].found, v.signals[:name].correct) == (2, 2)
    @test (v.ring_ut.found, v.ring_ut.correct) == (1, 1)
    @test occursin("A -> C: 1   <-- wrong", C.validation_text(v))
end

# --- the table

const CIF = join(
    ["data_ZZZ", "_chem_comp.id ZZZ", "_chem_comp.name \"x\"",
        "_chem_comp.type NON-POLYMER", "_chem_comp.formula \"C2 H4 O3\"",
        "_chem_comp.mon_nstd_parent_comp_id ?", "#", "loop_", "_chem_comp_atom.comp_id",
        "ZZZ C C C 0", "#", "data_DA", "_chem_comp.id DA",
        "_chem_comp.type 'DNA LINKING'",
        "_chem_comp.formula \"C10 H14 N5 O6 P\"",
        "_chem_comp.mon_nstd_parent_comp_id ?", "#",
        "data_5MC", "_chem_comp.id 5MC", "_chem_comp.type \"RNA linking\"",
        "_chem_comp.formula \"C10 H16 N3 O8 P\"",
        "_chem_comp.mon_nstd_parent_comp_id C", "#",
        "data_LR", "_chem_comp.id LR", "_chem_comp.type \"L-RNA LINKING\"",
        "_chem_comp.formula 'C9 H14 N3 O8 P'", "_chem_comp.mon_nstd_parent_comp_id ?",
        "#",
        "data_DT5", "_chem_comp.id DT5", "_chem_comp.type \"DNA OH 5 prime terminus\"",
        "_chem_comp.formula \"C10 H15 N2 O7 P\"",
        "_chem_comp.mon_nstd_parent_comp_id DT", "#",
        "data_TAB", "_chem_comp.id TAB", "_chem_comp.type \"PEPTIDE-LIKE\"",
        "_chem_comp.formula \"C1\tH2\"", "_chem_comp.mon_nstd_parent_comp_id ?", "#",
        "data_BARE", "_chem_comp.id BARE", "_chem_comp.type SACCHARIDE", ""], "\n")

const EXPECTED_ROWS = [
    ["5MC", "rna", "rna linking", "C", "C10 H16 N3 O8 P", "C", "parent"],
    ["BARE", "other", "saccharide", "-", "?", "-", "-"],
    ["DA", "dna", "dna linking", "-", "C10 H14 N5 O6 P", "A", "self"],
    ["DT5", "dna", "dna oh 5 prime terminus", "DT", "C10 H15 N2 O7 P", "T", "parent"],
    ["LR", "rna", "l-rna linking", "-", "C9 H14 N3 O8 P", "-", "-"],
    ["TAB", "other", "peptide-like", "-", "C1 H2", "-", "-"],
    ["ZZZ", "other", "non-polymer", "-", "C2 H4 O3", "-", "-"]]

@testset "quotes, ? parents, classes, tabs, missing fields, the base columns" begin
    @test sort(C.rowsOf(blocks_of_text(CIF)); by = first) == EXPECTED_ROWS
end

@testset "sorted by id, header counts the rows, duplicates are an error" begin
    head = (url = "U", source_date = "D", fetched = "F")
    text = C.table_text(head, reverse(EXPECTED_ROWS))
    lines = split_lines(text)
    @test lines[2:3] == ["# Source: U", "# Last-Modified D; fetched F."]
    @test lines[7] == "# Generated by `bysl extract components`; do not edit by hand."
    @test lines[8] == "# rows: 7"
    @test lines[9] == "#id\tclass\ttype\tparent\tformula\tbase\tbase_source"
    @test lines[10:end] == [join(r, "\t") for r in EXPECTED_ROWS]
    @test all(l -> length(l) <= 92, lines[1:9])
    @test endswith(text, "\n")
    @test C.header_meta(text) == head
    err = try
        C.table_text(head, [["A", "other", "t", "-", "f"], ["A", "other", "t", "-", "f"]])
    catch e
        e
    end
    @test err isa ToolError && occursin("occurs twice", err.message)
end

# --- the command line

function write_gz(path, text)
    open(path, "w") do io
        stream = GzipCompressorStream(io)
        write(stream, text)
        close(stream)
    end
end

const OPTS = ["--source-date", "Sat, 10 Oct 2026 05:56:05 GMT", "--fetched", "2026-10-14"]

@testset "stdout, --update, --check (stale and fresh) and --val-inference" begin
    scratch = scratch_dir()
    gz = joinpath(scratch, "c.cif.gz")
    out = joinpath(scratch, "out.tsv")
    write_gz(gz, CIF)
    status, text = run_tool("extract", "components", gz, OPTS...)
    @test status == 0
    @test occursin("5MC\trna\trna linking\tC\tC10 H16 N3 O8 P\tC\tparent\n", text)
    @test occursin("# rows: 7\n", text)
    @test run_tool("extract", "components", gz, "--update", "--out", out, OPTS...)[1] == 0
    @test run_tool("extract", "components", gz, "--check", "--out", out)[1] == 0
    # a changed row is reported and fails
    write(out, replace(read(out, String), "C10 H14 N5 O6 P" => "X"))
    status, text = run_tool("extract", "components", gz, "--check", "--out", out)
    @test status == 1 && occursin("out of date", text)
    @test occursin("DA\tdna\tdna linking\t-\tX", text)
    status, text = run_tool("extract", "components", gz, "--val-inference")
    @test status == 0 && occursin("validation on 2 nucleic acid", text)
end

end

# --- FormFactor: the script runs in the root project (it needs
# SQLite.jl); its own tests are in formfactor-script-test.jl

module TFormFactor

using Test
using Dev.Common
using .Main.Helpers

@testset "the form-factor script passes its tests in the root project" begin
    script = joinpath(@__DIR__, "formfactor-script-test.jl")
    cmd = ignorestatus(`$(Base.julia_cmd()) --project=$(repo_dir) $script`)
    out = IOBuffer()
    p = run(pipeline(cmd; stdout = out, stderr = out))
    @test success(p)
    success(p) || println(String(take!(out)))
end

@testset "the command line of the subcommand" begin
    status, out = run_tool("extract", "formfactor", "--help")
    @test status == 0 && occursin("xraydb.sqlite", out)
    status, out = run_tool("extract", "formfactor", "/no/such/file", "/tmp/x.sqlite3")
    @test status == 1 && occursin("no such file", out)
end

end
