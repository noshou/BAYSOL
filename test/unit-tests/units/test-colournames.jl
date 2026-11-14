# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/pipeline/colour-notation.jl: the colours a figure setting may name. Julia
# reads a code (`#rgb`, `#rrggbb`, `rgb()`, `hsl()`, `cmyk()`) and a name that Colors.jl
# knows (the CSS and X11 names); the long list of names of the terminal interface is its
# own, and it saves a name here only when it is a CSS name, else the colour as a code.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Pipeline: colourRgb, colourNotations, parseColourCode, _isColour
using BAYSOL.BulkElectronDensity: JSON3

const FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures", "colours")

function hexOf(spec)
    c = colourRgb(spec)
    channels = (reinterpret(UInt8, c.r), reinterpret(UInt8, c.g), reinterpret(UInt8, c.b))
    return "#" * join(string.(channels; base = 16, pad = 2))
end

@testset "ColourNotation" begin
    @testset "the names of Colors.jl" begin
        @test hexOf("crimson") == "#dc143c"
        @test hexOf(:crimson) == "#dc143c"
        @test hexOf("green") == "#008000"
        @test hexOf("grey") == "#808080"
        @test hexOf("gray") == "#808080"
        @test hexOf("gray20") == "#333333"
        @test hexOf("antiquewhite4") == "#8b8378"
        @test hexOf("rebeccapurple") == "#663399"
        @test hexOf("light goldenrod yellow") == hexOf("lightgoldenrodyellow")
    end
    @testset "the names Colors.jl knows keep the colours of the static list" begin
        # test/fixtures/colours/colors-jl-names.json: the CSS and X11 names with the
        # colour each has (the terminal interface keeps such a name as written)
        listed = JSON3.read(read(joinpath(FIXTURES, "colors-jl-names.json"), String))
        @test length(listed.colours) > 500
        for (name, hex) in pairs(listed.colours)
            @test hexOf(String(name)) == String(hex)
        end
    end
    @testset "case does not matter, nor blanks" begin
        @test hexOf("Crimson") == hexOf("crimson")
        @test hexOf("INDIAN RED") == hexOf("indian red")
        @test hexOf("  indian red  ") == hexOf("indianred")
    end
    @testset "codes" begin
        @test hexOf("#ff0000") == "#ff0000"
        @test hexOf("#A0b1C2") == "#a0b1c2"
        @test hexOf("#f00") == "#ff0000"
        @test hexOf("rgb(255, 0, 0)") == "#ff0000"
        @test hexOf("rgb(0,128,255)") == "#0080ff"
        @test hexOf("hsl(0, 100%, 50%)") == "#ff0000"
        @test hexOf("hsl(120, 100%, 25%)") == "#008000"
        @test hexOf(Symbol("#0000ff")) == "#0000ff"
        @test hexOf("cmyk(0%, 100%, 100%, 0%)") == "#ff0000"
        @test hexOf("cmyk(0%,0%,0%,100%)") == "#000000"
        @test hexOf("CMYK(100%, 0%, 0%, 0%)") == "#00ffff"
    end
    @testset "bad input" begin
        for bad in (
            "notacolour", "", "#12", "#gggggg", "rgb(1,2)", "hsl(x)", "rgb(",
            "cmyk(0, 0, 0, 0)", "cmyk(0%, 0%, 0%)", "cmyk(101%, 0%, 0%, 0%)",
            "hsl(361, 0%, 0%)", "rgb(256, 0, 0)", "rgb(1.5, 0, 0)", "not-a-colour",
            "nunavut yellow",
        )
            @test_throws ArgumentError colourRgb(bad)
            @test !_isColour(bad)
        end
        @test !_isColour(3)
        @test !_isColour(nothing)
        @test _isColour("hsl(10, 50%, 50%)")
    end
    @testset "the notations of a colour" begin
        n = colourNotations((165, 42, 42))
        @test n.hex == "#a52a2a"
        @test n.rgb == "rgb(165, 42, 42)"
        @test startswith(n.hsl, "hsl(0, 59.")
        @test startswith(n.cmyk, "cmyk(0%, 74.55%, 74.55%, 35.29%)")
    end
    @testset "every colour of the static list round-trips through every notation" begin
        listed = JSON3.read(read(joinpath(FIXTURES, "colors-jl-names.json"), String))
        @test length(listed.colours) > 500
        for (_, hex) in pairs(listed.colours)
            hex = String(hex)
            rgb = Tuple(parse(Int, hex[i:(i+1)]; base = 16) for i in (2, 4, 6))
            n = colourNotations(rgb)
            @test n.hex == hex
            for text in (n.hex, n.rgb, n.hsl, n.cmyk)
                @test parseColourCode(text) == rgb
            end
        end
    end
    @testset "golden file shared with the terminal interface" begin
        file = joinpath(@__DIR__, "..", "..", "fixtures", "colours", "notations.json")
        golden = JSON3.read(read(file, String))
        @test length(golden.colours) > 100
        for row in golden.colours
            rgb = parseColourCode(row.hex)
            n = colourNotations(rgb)
            @test n.rgb == row.rgb
            @test n.hsl == row.hsl
            @test n.cmyk == row.cmyk
        end
        for row in golden.codes
            @test parseColourCode(row.text) == parseColourCode(row.hex)
        end
        for text in golden.invalid
            @test parseColourCode(text) === nothing
        end
    end
end
