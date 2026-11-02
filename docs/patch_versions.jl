# SPDX-License-Identifier: LGPL-3.0-or-later

# Releases already deployed keep the pages they were built with, so their theme button and
# stylesheets stay as they were when the themes change. This brings the older versions of
# the site (the ones in the version dropdown) up to date: on a checkout of the `gh-pages`
# branch, every version folder gets the current theme stylesheets and fonts and the pages
# are switched to them with the same two functions docs/make.jl uses (register_themes.jl,
# theme_toggle.jl), so an old release offers the same four themes and the same cycling
# button as a fresh build. Nothing here runs in CI or touches the remote: the owner commits
# and pushes the checkout.
#
#     git archive origin/gh-pages | tar -x -C /path/to/empty/folder   # or a gh-pages clone
#     julia docs/patch_versions.jl /path/to/that/folder

include(joinpath(@__DIR__, "register_themes.jl"))
include(joinpath(@__DIR__, "theme_toggle.jl"))

"A folder of a deployed version: a release (`v0.4.0`) or `dev`; `stable`, `v0.4` are links."
is_version_folder(site, name) =
    isdir(joinpath(site, name)) && !islink(joinpath(site, name)) &&
    occursin(r"^(v\d+\.\d+\.\d+|dev)$", name)

"""
    patch_versions(site; themes_dir = <docs/src/assets/themes>) -> Dict{String,Int}

Copies the current `<theme>.css` files and the `fonts` folder from `themes_dir` into
`<version>/assets/themes` for every version folder of the `gh-pages` checkout `site`, then
runs `register_themes` and `add_theme_toggle` on it. A second run changes nothing.

# Returns
- `Dict{String,Int}`: for each version folder, the number of pages changed.

# Exceptions
- `ErrorException` when `site` has no version folder, or a stylesheet is missing from
  `themes_dir`.
- `SystemError` when a file cannot be read or written.
"""
function patch_versions(site; themes_dir = joinpath(@__DIR__, "src", "assets", "themes"))
    versions = filter(n -> is_version_folder(site, n), readdir(site))
    isempty(versions) && error("no version folder (vX.Y.Z or dev) in $site")
    changed = Dict{String,Int}()
    for version in versions
        dir = joinpath(site, version)
        target = joinpath(dir, "assets", "themes")
        mkpath(target)
        for theme in SITE_THEMES
            cp(joinpath(themes_dir, theme * ".css"), joinpath(target, theme * ".css");
                force = true)
        end
        cp(joinpath(themes_dir, "fonts"), joinpath(target, "fonts"); force = true)
        changed[version] = register_themes(dir) + add_theme_toggle(dir)
    end
    return changed
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 1 || error("usage: julia docs/patch_versions.jl <gh-pages checkout>")
    for (version, n) in sort!(collect(patch_versions(ARGS[1])))
        println(version, ": ", n, " pages changed")
    end
end
