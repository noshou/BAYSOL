# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Pipeline/ColourNotation.jl: the colours a figure setting may name. Julia
# reads a code (`#rgb`, `#rrggbb`, `rgb()`, `hsl()`, `cmyk()`) and a name that Colors.jl
# knows (the CSS and X11 names); the long list of names of the terminal interface is its
# own, and it saves a name here only when it is a CSS name, else the colour as a code.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Pipeline: colour_rgb, colour_notations, parse_colour_code, _is_colour
using BAYSOL.BulkElectronDensity: JSON3

const ASSETS = joinpath(@__DIR__, "..", "..", "..", "tui", "assets", "data")

function hex_of(spec)
    c = colour_rgb(spec)
    channels = (reinterpret(UInt8, c.r), reinterpret(UInt8, c.g), reinterpret(UInt8, c.b))
    return "#" * join(string.(channels; base = 16, pad = 2))
end

@testset "ColourNotation" begin
    @testset "the names of Colors.jl" begin
        @test hex_of("crimson") == "#dc143c"
        @test hex_of(:crimson) == "#dc143c"
        @test hex_of("green") == "#008000"
        @test hex_of("grey") == "#808080"
        @test hex_of("gray") == "#808080"
        @test hex_of("gray20") == "#333333"
        @test hex_of("antiquewhite4") == "#8b8378"
        @test hex_of("rebeccapurple") == "#663399"
        @test hex_of("light goldenrod yellow") == hex_of("lightgoldenrodyellow")
    end
    @testset "the 148 CSS names are read as the W3C table gives them" begin
        file = joinpath(@__DIR__, "..", "..", "..", "dev", "data", "colours", "css148.txt")
        rows = [split(line) for line in eachline(file) if !isempty(strip(line))]
        @test length(rows) == 148
        for (name, hex) in rows
            @test hex_of(String(name)) == hex
        end
        # the names of the interface that Julia reads: the CSS names and the X11 names,
        # each the colour the list gives it
        known = JSON3.read(read(joinpath(ASSETS, "colour-julia.json"), String))
        listed = JSON3.read(read(joinpath(ASSETS, "colours.json"), String))
        names = Set(String.(known))
        @test issubset(Set(String(first(r)) for r in rows), names)
        for name in names
            @test hex_of(name) == listed[Symbol(name)]
        end
    end
    @testset "case does not matter, nor blanks" begin
        @test hex_of("Crimson") == hex_of("crimson")
        @test hex_of("INDIAN RED") == hex_of("indian red")
        @test hex_of("  indian red  ") == hex_of("indianred")
    end
    @testset "codes" begin
        @test hex_of("#ff0000") == "#ff0000"
        @test hex_of("#A0b1C2") == "#a0b1c2"
        @test hex_of("#f00") == "#ff0000"
        @test hex_of("rgb(255, 0, 0)") == "#ff0000"
        @test hex_of("rgb(0,128,255)") == "#0080ff"
        @test hex_of("hsl(0, 100%, 50%)") == "#ff0000"
        @test hex_of("hsl(120, 100%, 25%)") == "#008000"
        @test hex_of(Symbol("#0000ff")) == "#0000ff"
        @test hex_of("cmyk(0%, 100%, 100%, 0%)") == "#ff0000"
        @test hex_of("cmyk(0%,0%,0%,100%)") == "#000000"
        @test hex_of("CMYK(100%, 0%, 0%, 0%)") == "#00ffff"
    end
    @testset "bad input" begin
        for bad in (
            "notacolour", "", "#12", "#gggggg", "rgb(1,2)", "hsl(x)", "rgb(",
            "cmyk(0, 0, 0, 0)", "cmyk(0%, 0%, 0%)", "cmyk(101%, 0%, 0%, 0%)",
            "hsl(361, 0%, 0%)", "rgb(256, 0, 0)", "rgb(1.5, 0, 0)", "not-a-colour",
            "nunavut yellow",
        )
            @test_throws ArgumentError colour_rgb(bad)
            @test !_is_colour(bad)
        end
        @test !_is_colour(3)
        @test !_is_colour(nothing)
        @test _is_colour("hsl(10, 50%, 50%)")
    end
    @testset "the notations of a colour" begin
        n = colour_notations((165, 42, 42))
        @test n.hex == "#a52a2a"
        @test n.rgb == "rgb(165, 42, 42)"
        @test startswith(n.hsl, "hsl(0, 59.")
        @test startswith(n.cmyk, "cmyk(0%, 74.55%, 74.55%, 35.29%)")
    end
    @testset "every colour of the interface's list round-trips through every notation" begin
        listed = JSON3.read(read(joinpath(ASSETS, "colours.json"), String))
        @test length(listed) > 2000
        for (_, hex) in pairs(listed)
            hex = String(hex)
            rgb = Tuple(parse(Int, hex[i:(i+1)]; base = 16) for i in (2, 4, 6))
            n = colour_notations(rgb)
            @test n.hex == hex
            for text in (n.hex, n.rgb, n.hsl, n.cmyk)
                @test parse_colour_code(text) == rgb
            end
        end
    end
    @testset "golden file shared with the terminal interface" begin
        file = joinpath(@__DIR__, "..", "..", "fixtures", "colours", "notations.json")
        golden = JSON3.read(read(file, String))
        @test length(golden.colours) > 100
        for row in golden.colours
            rgb = parse_colour_code(row.hex)
            n = colour_notations(rgb)
            @test n.rgb == row.rgb
            @test n.hsl == row.hsl
            @test n.cmyk == row.cmyk
        end
        for row in golden.codes
            @test parse_colour_code(row.text) == parse_colour_code(row.hex)
        end
        for text in golden.invalid
            @test parse_colour_code(text) === nothing
        end
    end
end
