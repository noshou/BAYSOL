# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/MolecularStructure/Components.jl against the bundled table
# src/MolecularStructure/components.tsv: the table's integrity (read here independently of
# the package's own reader), the records `component` returns for ids it holds, the
# hydrogen count of a formula, the Amber aliases, `is_nucleotide`, and the parent
# normalisation. Nothing here reads the cache directory or the network: every id used is
# in the table (or an Amber alias), so no lookup can reach the hook.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_components

using Test
using BAYSOL

using BAYSOL.MolecularStructure: component, is_nucleotide, ComponentError,
    COMPONENTS_TABLE, STANDARD_NUCLEOTIDES, AMBER_NUCLEIC_NAMES, WATER_NAMES,
    _count_hydrogens, _component_class, _resolve_parent, _read_components,
    _COMPONENT_DOWNLOAD

# The table's rows as text: (id, class, type, parent, formula, base, base_source)
function _raw_rows()
    rows = Vector{Vector{String}}()
    for l in eachline(COMPONENTS_TABLE)
        (isempty(l) || startswith(l, '#')) && continue
        push!(rows, String.(split(l, '\t')))
    end
    return rows
end

@testset "components table and records" begin
    rows = _raw_rows()
    header = [l for l in eachline(COMPONENTS_TABLE) if startswith(l, '#')]

    # the hook must stay unreachable in this file: any call is a bug of the test
    saved_hook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> error("unexpected download of $url")

    try
        @testset "table integrity" begin
            @test length(rows) == 51437
            @test all(r -> length(r) == 7, rows)
            ids = [r[1] for r in rows]
            @test allunique(ids)
            @test issorted(ids)
            @test all(r -> r[2] in ("dna", "rna", "other"), rows)
            # the header states the row count
            @test any(l -> l == "# rows: $(length(rows))", header)
            @test any(l -> startswith(l, "#id\tclass\ttype\tparent\tformula\tbase"), header)
            # ids are upper case, one to five characters
            @test all(i -> occursin(r"^[A-Z0-9]{1,5}$", i), ids)

            # class agrees with the dictionary type
            for r in rows
                cls =
                    occursin("dna", r[3]) ? "dna" : occursin("rna", r[3]) ? "rna" : "other"
                r[2] == cls || @test r[2] == cls
            end
            nd = count(r -> r[2] == "dna", rows)
            nr = count(r -> r[2] == "rna", rows)
            @test (nd, nr) == (473, 370)
            @test nd + nr == 843

            # base is a natural base for a nucleotide, absent for everything else
            bases = ("A", "C", "G", "U", "T")
            @test all(r -> r[6] in (bases..., "-"), rows)
            @test all(r -> r[2] != "other" || r[6] == "-", rows)
            # base_source: "-" if and only if there is no base
            sources = ("parent", "self", "letter", "ring", "name")
            @test all(r -> (r[6] == "-") == (r[7] == "-"), rows)
            @test all(r -> r[7] in (sources..., "-"), rows)
            # a declared (resolvable) parent gives the base of that parent
            @test all(r -> r[7] != "parent" || r[4] != "-", rows)
            # the standard ids are their own base
            std = Dict(r[1] => r for r in rows if r[1] in STANDARD_NUCLEOTIDES)
            for (id, b) in (
                "A" => "A", "C" => "C", "G" => "G", "U" => "U", "DA" => "A",
                "DC" => "C", "DG" => "G", "DT" => "T", "DU" => "U", "T" => "T",
            )
                @test std[id][6] == b && std[id][7] == "self"
            end
            # the placeholders have no base
            for id in ("N", "DN", "I", "DI")
                @test std[id][6] == "-" && std[id][7] == "-"
            end
            @test length(std) == length(STANDARD_NUCLEOTIDES)
        end

        @testset "resolved parents" begin
            tab = _read_components()
            @test length(tab) == length(rows)
            @test all(
                p -> p === nothing || p in STANDARD_NUCLEOTIDES,
                (i.parent for i in values(tab)),
            )
            # 565 of the 843 nucleotide components declare a parent
            nuc = [i for i in values(tab) if i.class in (:dna, :rna)]
            @test count(i -> i.parent !== nothing, nuc) == 565
            # the lists of the dictionary are split and deduplicated, a non-standard
            # parent is followed
            @test tab["05A"].parent == "DT"
            @test tab["TTD"].parent == "DT"
            @test tab["PSU"].parent == "U"
            @test tab["5MC"].parent == "C"
            @test tab["1MA"].parent == "A"
            # a multi-parent peptide list is unresolved, never an error
            @test tab["0YG"].parent === nothing
            @test tab["175"].parent === nothing
            # the table's declared base agrees with the resolved parent's base
            for i in nuc
                i.base_source === :parent || continue
                @test i.base == tab[i.parent].base
            end
        end

        @testset "_resolve_parent" begin
            none = p -> nothing
            @test _resolve_parent(nothing, none) === nothing
            @test _resolve_parent("DT, DT", none) == "DT"
            @test _resolve_parent("DT,DT", none) == "DT"
            @test _resolve_parent("A", none) == "A"
            @test _resolve_parent("A, C", none) === nothing
            @test _resolve_parent("ALA, SER, GLY", none) === nothing
            @test _resolve_parent("", none) === nothing
            # a non-standard parent is followed, a chain that never ends is cut
            chain = Dict("TTD" => "TTE", "TTE" => "DT")
            @test _resolve_parent("TTD", p -> get(chain, p, nothing)) == "DT"
            cyc = Dict("XA" => "XB", "XB" => "XA")
            @test _resolve_parent("XA", p -> get(cyc, p, nothing)) === nothing
            @test _resolve_parent("XA", none) === nothing
        end

        @testset "component records of known ids" begin
            psu = component("PSU")
            @test psu.id == "PSU" && psu.class === :rna && psu.type == "rna linking"
            @test psu.parent == "U" && psu.formula == "C9 H13 N2 O9 P"
            @test psu.n_hydrogens == 13 && psu.source === :builtin
            @test psu.base == "U" && psu.base_source === :parent
            @test component("5MC").parent == "C" && component("5MC").base == "C"
            @test component("1MA").parent == "A" && component("1MA").base == "A"
            da = component("DA")
            @test da.class === :dna && da.parent === nothing && da.base == "A" &&
                  da.base_source === :self
            n = component("N")
            @test n.class === :rna && n.base === nothing && n.base_source === :none
            @test component("DN").class === :dna
            hoh = component("HOH")
            @test hoh.class === :other && hoh.n_hydrogens == 2 && hoh.base === nothing
            dod = component("DOD")
            @test dod.class === :other && dod.n_hydrogens == 2   # D counts as hydrogen
            @test component("MG").class === :other && component("MG").n_hydrogens == 0
            # the free bases of older files are ligands in the dictionary
            for id in ("ADE", "CYT", "GUA", "URI", "THY")
                @test component(id).class === :other
                @test component(id).type == "non-polymer"
            end
            @test component("ATP").class === :other
            # D-amino acid and sugar look-alikes of nucleotide names
            @test component("DCY").class === :other
            @test component("DGU").class === :other
            @test component("DTH").class === :other
            @test component("DAD").class === :other
            @test component("DCP").class === :other
            # ids are matched case-insensitively and stripped, stored upper case
            @test component("psu") == component("PSU")
            @test component(" 5mc ") == component("5MC")
            @test component(SubString("xxPSUxx", 3, 5)).id == "PSU"
            # every record has the documented fields
            @test keys(psu) == (:id, :class, :type, :parent, :formula, :n_hydrogens,
                :source, :base, :base_source)
        end

        @testset "is_nucleotide" begin
            for id in ("A", "C", "G", "U", "DA", "DC", "DG", "DT", "DU", "N", "DN", "I",
                "PSU", "5MC", "1MA", "2MG", "H2U", "OMC", "YYG", "7MG", "M2G", "OMG",
                "5MU", "0C", "psu")
                @test is_nucleotide(id)
            end
            for id in ("ALA", "GLY", "MG", "NA", "ZN", "ATP", "DCP", "ADE", "CYT",
                "GUA", "URI", "THY", "DAD", "DCY", "DGU", "DTH", "CL")
                @test !is_nucleotide(id)
            end
            # the water names are false and are not even looked up
            for id in WATER_NAMES
                @test !is_nucleotide(id)
                @test !is_nucleotide(lowercase(id))
            end
            @test_throws MethodError is_nucleotide(1)
        end

        @testset "hydrogen count of a formula" begin
            @test _count_hydrogens("C9 H13 N2 O9 P") == 13
            @test _count_hydrogens("H2 O") == 2
            @test _count_hydrogens("D2 O") == 2
            @test _count_hydrogens("C2 H3 D3 O") == 6
            @test _count_hydrogens("H") == 1
            @test _count_hydrogens("C H4") == 4          # a bare element counts once
            @test _count_hydrogens("C H") == 1
            @test _count_hydrogens("D") == 1
            @test _count_hydrogens("") == 0
            @test _count_hydrogens("Mg") == 0
            # elements whose symbol starts with H or D are not hydrogen
            @test _count_hydrogens("Hf") == 0
            @test _count_hydrogens("Hg") == 0
            @test _count_hydrogens("Ho") == 0
            @test _count_hydrogens("Hs") == 0
            @test _count_hydrogens("Hg2 H4") == 4
            @test _count_hydrogens("Dy") == 0
            @test _count_hydrogens("Ho H12 O6") == 12
            @test _count_hydrogens("H10 O5 Hf2") == 10
            # the count agrees with the stored formula for every row
            tab = _read_components()
            @test all(i -> i.n_hydrogens == _count_hydrogens(i.formula), values(tab))
            @test tab["HOH"].n_hydrogens == 2 && tab["HG"].n_hydrogens == 0 &&
                  tab["HO"].n_hydrogens == 0
        end

        @testset "class from the dictionary type" begin
            @test _component_class("dna linking") === :dna
            @test _component_class("rna linking") === :rna
            @test _component_class("l-rna linking") === :rna
            @test _component_class("l-dna linking") === :dna
            @test _component_class("dna oh 5 prime terminus") === :dna
            @test _component_class("rna oh 3 prime terminus") === :rna
            @test _component_class("non-polymer") === :other
            @test _component_class("l-peptide linking") === :other
            @test _component_class("") === :other
        end

        @testset "Amber aliases" begin
            for (n, b) in (("RA", "A"), ("RC", "C"), ("RG", "G"))
                for suf in ("", "5", "3", "N")
                    c = component(n * suf)
                    @test c.class === :rna && c.type == "rna linking"
                    @test c.parent == b && c.base == b && c.base_source === :self
                    @test c.source === :builtin
                    @test c.formula == component(b).formula
                    @test c.n_hydrogens == component(b).n_hydrogens
                    @test is_nucleotide(n * suf)
                end
            end
            for suf in ("5", "3", "N")
                @test component("RU" * suf).class === :rna
                @test component("RU" * suf).base == "U"
            end
            for n in ("DA", "DC", "DG", "DT")
                for suf in ("5", "3", "N")
                    c = component(n * suf)
                    @test c.class === :dna && c.type == "dna linking"
                    @test c.parent == n && c.source === :builtin
                    @test c.base == component(n).base && c.base_source === :self
                    @test is_nucleotide(n * suf)
                end
            end
            # the Amber alias wins over the table's unrelated ligand of the same name
            @test component("DA5").class === :dna && component("RG3").class === :rna
            # RU is ruthenium in the dictionary and stays so
            ru = component("RU")
            @test ru.class === :other && ru.formula == "Ru"
            @test !is_nucleotide("RU")
            @test !haskey(AMBER_NUCLEIC_NAMES, "RU")
            # lower case works for the aliases too
            @test component("ra") == component("RA")
            # plain DA DC DG DT are table components, not aliases
            @test !haskey(AMBER_NUCLEIC_NAMES, "DA") && component("DA").source === :builtin
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
    end
end

end # module
