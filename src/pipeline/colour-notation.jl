# SPDX-License-Identifier: LGPL-3.0-or-later

# The notations a figure colour may be written in, and the maths that turns each into the
# 8-bit sRGB colour and back: `#rrggbb` (and `#rgb`), `rgb(r, g, b)`, `hsl(h, s%, l%)`
# and `cmyk(c%, m%, y%, k%)`. The terminal interface (`tui/src/store/
# colour-notation.ts`) has the same maths line for line, and both read the golden file
# `test/fixtures/colours/notations.json`, so the two cannot drift apart.
#
# A colour is three whole numbers 0 to 255 (a `NTuple{3,Int}`); every value in between is a
# `Float64`. Rounding is always `floor(x + 0.5)` (half up), as in JavaScript.

using Colors: Colors
using Printf: @sprintf

"`x` rounded half up to a whole number."
_roundHalfUp(x::Real) = floor(Int, x + 0.5)

"A number of 0 to 255 for a channel of 0 to 1, rounded and kept in range."
_channel8(x::Real) = clamp(_roundHalfUp(255 * x), 0, 255)

"A fixed-point number as text, trailing zeros and the point dropped (`-0` is `0`)."
function _trim(text::AbstractString)
    text = occursin('.', text) ? replace(replace(text, r"0+$" => ""), r"\.$" => "") : text
    return text == "-0" ? "0" : text
end
# rounded half up first (`@sprintf` rounds an exact tie to even, JavaScript's `toFixed` up)
_fixed2(x) = _trim(@sprintf("%.2f", floor(x * 100 + 0.5) / 100))

# ---- HSL ---------------------------------------------------------------------------------

function _rgbToHsl(r8::Int, g8::Int, b8::Int)
    r, g, b = r8 / 255, g8 / 255, b8 / 255
    hi, lo = max(r, g, b), min(r, g, b)
    l = (hi + lo) / 2
    d = hi - lo
    d == 0 && return (0.0, 0.0, 100 * l)
    s = d / (1 - abs(2l - 1))
    h = if hi == r
        ((g - b) / d) % 6
    elseif hi == g
        (b - r) / d + 2
    else
        (r - g) / d + 4
    end
    h = 60 * h
    h < 0 && (h += 360)
    return (h, 100 * s, 100 * l)
end

function _hslToRgb(h::Real, s::Real, l::Real)
    sat, light = s / 100, l / 100
    a = sat * min(light, 1 - light)
    f(n) = begin
        k = (n + h / 30) % 12
        light - a * max(-1, min(k - 3, 9 - k, 1))
    end
    return (_channel8(f(0)), _channel8(f(8)), _channel8(f(4)))
end

# ---- CMYK (the plain formula, no colour profile)
# -------------------------------------------

function _rgbToCmyk(r8::Int, g8::Int, b8::Int)
    r, g, b = r8 / 255, g8 / 255, b8 / 255
    k = 1 - max(r, g, b)
    k == 1 && return (0.0, 0.0, 0.0, 100.0)
    return (
        100 * (1 - r - k) / (1 - k),
        100 * (1 - g - k) / (1 - k),
        100 * (1 - b - k) / (1 - k),
        100 * k,
    )
end

function _cmykToRgb(c::Real, m::Real, y::Real, k::Real)
    key = 1 - k / 100
    return (
        _channel8((1 - c / 100) * key),
        _channel8((1 - m / 100) * key),
        _channel8((1 - y / 100) * key),
    )
end

# ---- writing -----------------------------------------------------------------------------

"""
    colourNotations(rgb) -> NamedTuple

The colour written in every notation, each with enough digits to
be read back as the same 8-bit colour: `hex` (`#a52a2a`), `rgb`
(`rgb(165, 42, 42)`), `hsl` (`hsl(0, 59.41%, 40.59%)`) and `cmyk`
(`cmyk(0%, 74.55%, 74.55%, 35.29%)`), both with up to 2 decimals.

# Arguments
- `rgb`: the colour as three whole numbers 0 to 255.

# Returns
- a `NamedTuple` `(; hex, rgb, hsl, cmyk)` of strings.
"""
function colourNotations(rgb::NTuple{3,Int})
    r, g, b = rgb
    h, s, l = _rgbToHsl(r, g, b)
    cy, ma, ye, k = _rgbToCmyk(r, g, b)
    return (
        hex = "#" * join(string.(rgb; base = 16, pad = 2)),
        rgb = "rgb($r, $g, $b)",
        hsl = "hsl($(_fixed2(h)), $(_fixed2(s))%, $(_fixed2(l))%)",
        cmyk = "cmyk($(_fixed2(cy))%, $(_fixed2(ma))%, $(_fixed2(ye))%, $(_fixed2(k))%)",
    )
end

# ---- reading -----------------------------------------------------------------------------

const _NUM = "[+-]?(?:\\d+\\.?\\d*|\\.\\d+)"

"The numbers of a code `name(...)` with `count` numbers, each with `suffix` (`%` or none)."
function _codeNumbers(text::AbstractString, name::AbstractString, suffixes::Vector{String})
    m = match(Regex("^$name\\(\\s*(.*?)\\s*\\)\$", "i"), text)
    m === nothing && return nothing
    words = split(m.captures[1], r"\s*,\s*|\s+"; keepempty = false)
    length(words) == length(suffixes) || return nothing
    numbers = Float64[]
    for (word, suffix) in zip(words, suffixes)
        n = match(Regex("^($_NUM)$suffix\$"), word)
        n === nothing && return nothing
        push!(numbers, parse(Float64, n.captures[1]))
    end
    return numbers
end

"""
    parseColourCode(text) -> Union{Nothing,NTuple{3,Int}}

The 8-bit colour a code writes: `#rgb`, `#rrggbb`, `rgb(r, g, b)` (whole numbers 0 to
255), `hsl(h, s%, l%)` (hue in degrees, 0 to 100 for the rest) or `cmyk(c%, m%, y%, k%)`
(0 to 100). The numbers are read as they are written and rounded only once, to 8 bits.

# Returns
- the colour, or `nothing` if `text` is no valid code.
"""
function parseColourCode(text::AbstractString)
    t = strip(text)
    m = match(r"^#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$", t)
    if m !== nothing
        d = m.captures[1]
        length(d) == 3 && (d = join(c * c for c in d))
        return Tuple(parse(Int, d[i:(i+1)]; base = 16) for i in (1, 3, 5))
    end
    n = _codeNumbers(t, "rgb", ["", "", ""])
    if n !== nothing
        all(x -> x == round(x) && 0 <= x <= 255, n) || return nothing
        return (Int(n[1]), Int(n[2]), Int(n[3]))
    end
    n = _codeNumbers(t, "hsl", ["", "%", "%"])
    if n !== nothing
        (0 <= n[1] <= 360 && 0 <= n[2] <= 100 && 0 <= n[3] <= 100) || return nothing
        return _hslToRgb(n...)
    end
    n = _codeNumbers(t, "cmyk", ["%", "%", "%", "%"])
    if n !== nothing
        all(x -> 0 <= x <= 100, n) || return nothing
        return _cmykToRgb(n...)
    end
    return nothing
end

"Whether `s` is written as a colour code, not as a name: `#...`, `rgb(`, `hsl(` or `cmyk(`."
function _isColourCode(s::AbstractString)
    return startswith(s, '#') || occursin(r"^(rgb|hsl|cmyk)\s*\("i, s)
end

"""
    colourRgb(spec) -> Colors.RGB

The colour a figure setting names. `spec` is a colour code (see
`parseColourCode`: `#rgb`, `#rrggbb`, `rgb(r, g, b)`, `hsl(h, s%, l%)` or
`cmyk(c%, m%, y%, k%)`) or a name that Colors.jl knows (the CSS and X11 names, any
case, blanks ignored). The long list of names the terminal interface offers is its
own: it saves a name here only when Colors.jl knows it, else the colour as a code.

# Returns
- the colour as a `Colors.RGB{Colors.N0f8}`.

# Exceptions
- `ArgumentError`: `spec` is neither a colour code nor a known name; the message names it.
"""
function colourRgb(spec::Union{AbstractString,Symbol})
    text = strip(String(spec))
    if _isColourCode(text)
        code = parseColourCode(text)
        code === nothing && throw(ArgumentError("not a colour: \"$text\""))
        return Colors.RGB{Colors.N0f8}(code[1] / 255, code[2] / 255, code[3] / 255)
    end
    try
        return convert(Colors.RGB{Colors.N0f8}, Colors.parse(Colors.Colorant, text))
    catch
        throw(ArgumentError("unknown colour name: \"$text\""))
    end
end
