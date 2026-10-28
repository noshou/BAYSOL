# SPDX-License-Identifier: LGPL-3.0-or-later

# Documenter ships six themes (`HTMLWriter.THEMES`, a constant with no keyword to change
# it) and lists all of them in the settings menu. This site has two, `documenter-light`
# and `documenter-dark`, both compiled from docs/src/assets/themes/academic*.scss, so
# docs/make.jl removes the Catppuccin ones from the built pages the same way it stamps the
# release label (see release_label.jl).

"""
    prune_themes(dir; keep = ["documenter-light", "documenter-dark"]) -> Int

Removes every theme other than `keep` from the built site under `dir`: its `<link>` tag
and its `<option>` in the settings menu on every HTML page, and its stylesheet. A second
run changes nothing.

# Returns
- `Int`: the number of pages changed.

# Exceptions
- `SystemError` when a page cannot be read or written.
"""
function prune_themes(dir; keep = ["documenter-light", "documenter-dark"])
    others = ["catppuccin-latte", "catppuccin-frappe", "catppuccin-macchiato",
        "catppuccin-mocha"]
    others = setdiff(others, keep)
    names = join(others, "|")
    link = Regex("<link [^>]*data-theme-name=\"(?:$names)\"[^>]*/>")
    option = Regex("<option value=\"(?:$names)\">[^<]*</option>")
    changed = 0
    for (root, _, files) in walkdir(dir), file in files
        path = joinpath(root, file)
        if  endswith(file, ".css") && basename(root) == "themes" &&
            splitext(file)[1] in others
            rm(path)
        elseif endswith(file, ".html")
            html = read(path, String)
            pruned = replace(replace(html, link => ""), option => "")
            pruned == html && continue
            write(path, pruned)
            changed += 1
        end
    end
    return changed
end
