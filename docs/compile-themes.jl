# SPDX-License-Identifier: LGPL-3.0-or-later

# Compiles the site's themes: every docs/src/assets/themes/<name>.scss to
# docs/src/assets/themes/<name>.css, the file the built pages load (`register_themes` in
# register-themes.jl links it by that name). The compiler is libsass through Sass.jl, with
# compressed output, the same one Documenter's own theme tooling uses. Documenter's Sass
# sources (bulma, documenter, darkly, highlightjs) and docs/scss (flatly, which Documenter
# does not ship) are the include paths. The CSS is committed, so this runs only after a
# change to an SCSS file:
#
#     julia --project=docs docs/compile-themes.jl [name ...]

using Documenter
using Sass

"The themes, in the order the toggle cycles through them (see theme-toggle.jl)."
const THEMES = ["academic", "academic-dark", "day-blue", "midnight-purple"]

const THEMES_DIR = joinpath(@__DIR__, "src", "assets", "themes")

"""
    compile_themes(names = THEMES) -> Vector{String}

Compiles `<name>.scss` to `<name>.css` in the themes folder for each of `names`.

# Returns
- `Vector{String}`: the paths of the CSS files written.

# Exceptions
- `ErrorException` when a theme has no SCSS file.
- `Sass.SassError`-style errors from libsass when a file does not compile; no CSS is
  written for that theme (libsass' error message names the file and line).
"""
function compile_themes(names = THEMES)
    include_path = [
        joinpath(pkgdir(Documenter), "assets", "html", "scss"),
        joinpath(@__DIR__, "scss"),
    ]
    out = String[]
    for name in names
        src = joinpath(THEMES_DIR, name * ".scss")
        isfile(src) || error("no theme source: $src")
        dst = joinpath(THEMES_DIR, name * ".css")
        Sass.compile_file(src, dst; include_path, output_style = Sass.compressed)
        push!(out, dst)
    end
    return out
end

if abspath(PROGRAM_FILE) == @__FILE__
    for path in compile_themes(isempty(ARGS) ? THEMES : ARGS)
        println(relpath(path, dirname(@__DIR__)), "  ", filesize(path), " bytes")
    end
end
