# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of Harvest: the mean PMV uncertainty and the solute index, on small tables.

using Test

# --- PmvMean

module TPmvMean
using Test
using Dev.Common
using Dev.Harvest.PmvMean: mean_uncertainty, replace_literal

const MODULE_TEXT = join(
    [
        "module M",
        "# BEGIN harvested: nonbio-mean-uncertainty",
        "const NONBIO_MEAN_UNCERTAINTY = 1.0",
        "# END harvested: nonbio-mean-uncertainty",
        "end",
        "",
    ], "\n")

@testset "mean skips null and rounds" begin
    @test mean_uncertainty("""{"a":[1,2.0,0.1],"b":[1,2.0,null],"c":[1,2.0,0.3]}""") == 0.2
    @test mean_uncertainty("""{"a":[1,2,0],"b":[1,2,0],"c":[1,2,1]}""") == 0.333333
end

@testset "replace_literal is idempotent" begin
    once = replace_literal(MODULE_TEXT, 3.044643)
    @test occursin("const NONBIO_MEAN_UNCERTAINTY = 3.044643\n# END", once)
    @test startswith(once, "module M\n# BEGIN")
    @test endswith(once, "end\n")
    @test replace_literal(once, 3.044643) == once
end

@testset "replace_literal needs the markers" begin
    @test_throws ToolError replace_literal("const NONBIO_MEAN_UNCERTAINTY = 1.0\n", 2.0)
    @test_throws ToolError replace_literal(
        replace(MODULE_TEXT, "= 1.0" => "= 1.0\nconst X = 1"), 2.0)
end

end

# --- Solutes

module TSolutes
using Test
using Dev
using JSON3
const H = Dev.Harvest.Solutes

@testset "basis rules" begin
    @test H.basis_of("dextran", String[]) == "per monomer unit"
    @test H.basis_of("poly(1-vinylpyrrolidin-2-one)", ["pvp", "povidone"]) ==
          "per monomer unit"
    @test H.basis_of("poly(vinyl alcohol)", ["pva"]) == "per monomer unit"
    @test H.basis_of("poly(acrylic acid) amphipol a8-35 (35% coona)", ["a8-35"]) ==
          "per monomer unit"
    @test H.basis_of("ficoll 70", ["ficoll pm 70"]) == "per 1000 Da"
    # no rule, no basis; a word that only contains pva is not PVA
    @test H.basis_of("poloxamer 407", ["poloxamer p407"]) === nothing
    @test H.basis_of("xpvax", String[]) === nothing
end

const NB_VALUES = Dict("Tris" => [66, 90.6, 0.05], "water" => [10, 18.0, nothing],
    "zinc" => [28, 1.0, 0])
const NB_LOOKUP = Dict("TRIS" => "Tris", "trizma" => "Tris", "H2O" => "water",
    "ghost" => "nowhere", "zinc" => "zinc")

@testset "kind_table shape" begin
    t = H.kind_table(NB_LOOKUP, NB_VALUES, Set{String}())
    # targets sorted and lower case, names sorted, each with its target position
    @test t.targets == ["tris", "water", "zinc"]
    @test t.names == [("h2o", 1), ("tris", 0), ("trizma", 0), ("water", 1), ("zinc", 2)]
    # an alias of a target that is not in the table is dropped and counted
    @test t.dropped == 1
    @test all(n -> n[1] != "ghost", t.names)
    # reserved names are left out
    @test H.kind_table(NB_LOOKUP, NB_VALUES, Set(["zinc"])).names ==
          [("h2o", 1), ("tris", 0), ("trizma", 0), ("water", 1)]
end

@testset "index and render" begin
    families = [Dict{Symbol,Any}(:id => "peg", :names => ["PEG", "polyethylene glycol"])]
    idx = H.index(NB_LOOKUP, NB_VALUES,
        Dict("peg 3350" => "peg 3350", "pegx" => "peg 3350", "peg" => "peg 3350",
            "dextran" => "dextran"),
        Dict("peg 3350" => [1, 2, 3], "dextran" => [1, 2, 3]), families)
    # a name of a family is the family's, not the grade's
    @test idx.polymers.names == [("dextran", 0), ("peg 3350", 1), ("pegx", 1)]
    @test idx.families == ["peg" => "peg", "polyethylene glycol" => "peg"]
    @test idx.polymers.basis == ["dextran" => "per monomer unit"]
    # the text is JSON and reads back as the index
    text = H.render(idx)
    back = JSON3.read(text)
    names(kind) = [(String(n), Int(i)) for (n, i) in back[kind][:names]]
    @test names(:nonbiological) == idx.nonbiological.names
    @test names(:polymers) == idx.polymers.names
    @test String.(back[:polymers][:targets]) == idx.polymers.targets
    @test [(String(n), String(i)) for (n, i) in back[:families]] ==
          [(n, String(i)) for (n, i) in idx.families]
    @test Dict(String(k) => String(v) for (k, v) in back[:polymers][:basis]) ==
          Dict("dextran" => "per monomer unit")
    # a name too long for a line is kept whole
    @test occursin(
        repeat("ab", 150),
        H.render(
            H.index(Dict(repeat("ab", 150) => "tris"),
                Dict("tris" => [1, 2, 3]), Dict{String,String}(), Dict{String,Any}(), Any[],
            ),
        ),
    )
end

end
