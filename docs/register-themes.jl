# SPDX-License-Identifier: LGPL-3.0-or-later

# Documenter knows six theme names (`HTMLWriter.THEMES`, a constant with no keyword to
# change it): `documenter-light`, `documenter-dark` and four Catppuccin ones. It links
# exactly those stylesheets in every page and lists them in the settings menu. This
# site has four themes of its own (docs/src/assets/themes/<name>.scss, compiled to
# <name>.css by compile-themes.jl), so docs/make.jl swaps Documenter's links for ours
# in the built pages, the same way it stamps the release label (see release-label.jl).

"The site's themes in the order the toggle cycles through them (theme-toggle.jl)."
const SITE_THEMES = ["academic", "academic-dark", "day-blue", "midnight-purple"]

"""
The theme used when the visitor has made no choice and the OS prefers a light colour scheme.
"""
const PRIMARY_LIGHT_THEME = "academic"

"""
The theme used when the visitor has made no choice and the OS prefers a dark colour scheme.
"""
const PRIMARY_DARK_THEME = "academic-dark"

# Documenter's `<link>` for a theme (the six built-in ones, whatever their order).
const THEME_LINK = r"<link [^>]*data-theme-name=\"[^\"]*\"[^>]*/>"

# Documenter's settings-menu entry for a built-in theme, but not "Automatic (OS)".
const THEME_OPTION = r"<option value=\"(?!auto\")[^\"]*\">[^<]*</option>"

"""
    theme_link(name, prefix) -> String

The `<link>` tag of theme `name`; `prefix` is the relative path from the page to the site
root (`""` on the home page, `"../"` one folder down). The primary light theme carries
`data-theme-primary` and the primary dark one `data-theme-primary-dark`, the two attributes
Documenter's `themeswap.js` looks for.

# Returns
- `String`: the HTML of the tag.

# Exceptions
None.
"""
function theme_link(name, prefix)
    flag =
        name == PRIMARY_LIGHT_THEME ? " data-theme-primary" :
        name == PRIMARY_DARK_THEME ? " data-theme-primary-dark" : ""
    return "<link class=\"docs-theme-link\" rel=\"stylesheet\" type=\"text/css\" " *
           "href=\"$(prefix)assets/themes/$(name).css\" data-theme-name=\"$name\"$flag/>"
end

"""
    register_themes(dir; themes = SITE_THEMES) -> Int

Replaces Documenter's theme `<link>` tags in every HTML page under `dir` with one for
each of `themes`, empties the settings menu's theme list down to "Automatic (OS)"
(the menu is hidden by the stylesheets; the sun/moon button of theme-toggle.jl is the
way to change theme), and removes the stylesheets of Documenter's built-in themes,
and the `.scss` sources Documenter copies along with the assets, from `dir`. A page
that already links the themes is left as it is, so a second run changes nothing.

# Returns
- `Int`: the number of pages changed.

# Exceptions
- `SystemError` when a page cannot be read or written.
"""
function register_themes(dir; themes = SITE_THEMES)
    changed = 0
    for (root, _, files) in walkdir(dir), file in files
        path = joinpath(root, file)
        if basename(root) == "themes" && (
            endswith(file, ".scss") ||
            endswith(file, ".css") && !(splitext(file)[1] in themes)
        )
            rm(path)
        elseif endswith(file, ".html")
            html = read(path, String)
            occursin("data-theme-name=\"$(first(themes))\"", html) && continue
            first_link = match(THEME_LINK, html)
            first_link === nothing && continue
            prefix = match(r"href=\"((?:\.\./)*)assets/themes/", first_link.match)
            prefix = prefix === nothing ? "" : prefix.captures[1]
            links = join((theme_link(t, prefix) for t in themes), "")
            # Our links go where Documenter's first one was, the rest are dropped.
            at = first(findfirst(first_link.match, html))
            done = html[1:(at-1)] * links * replace(html[at:end], THEME_LINK => "")
            done = replace(done, THEME_OPTION => "")
            write(path, done)
            changed += 1
        end
    end
    return changed
end
