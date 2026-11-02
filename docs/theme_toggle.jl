# SPDX-License-Identifier: LGPL-3.0-or-later

# The theme button in the navbar, a sun on a light theme and a crescent moon on a dark one.
# Each click goes to the next of the four themes (`SITE_THEMES` in register_themes.jl) and
# wraps around: sun on academic -> academic-dark (moon) -> day-blue (sun) -> midnight-purple
# (moon) -> academic. docs/make.jl writes it into the built pages (like release_label.jl does
# the release name): the button's HTML below, and the only browser code it needs, the click
# handler, as an inline script. Everything else is Julia or style: which icon shows is
# decided by `.docs-theme-toggle` in each docs/src/assets/themes/<theme>.scss. The click
# stores the choice the way Documenter's settings menu does (`documenter-theme` in
# localStorage) and calls Documenter's own `set_theme_from_local_storage` (themeswap.js) to
# swap the stylesheets.

"SVG for sun and moon (light / dark mode)"
const THEME_TOGGLE_BUTTON = """
<a class="docs-navbar-link docs-theme-toggle" href="#" role="button" \
title="Next theme" aria-label="Next theme">\
<svg class="docs-sun" viewBox="0 0 24 24" width="1.15em" height="1.15em" \
aria-hidden="true"><circle cx="12" cy="12" r="4.2" fill="currentColor"/>\
<path stroke="currentColor" stroke-width="2" stroke-linecap="round" \
d="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8\
M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8"/></svg>\
<svg class="docs-moon" viewBox="0 0 24 24" width="1.15em" height="1.15em" \
aria-hidden="true"><mask id="docs-moon-cut"><rect width="24" height="24" fill="#fff"/>\
<circle cx="14.5" cy="9.5" r="8.4" fill="#000"/></mask>\
<circle cx="12" cy="12" r="9" fill="currentColor" mask="url(#docs-moon-cut)"/></svg></a>"""

"Injected JavaScript for cycling through the themes"
const JSON_THEMES = "[" * join(("\"$t\"" for t in SITE_THEMES), ", ") * "]"

const THEME_TOGGLE_SCRIPT = """
<script>
/* theme-cycle */
document.addEventListener("click", function (ev) {
  if (!ev.target.closest || !ev.target.closest(".docs-theme-toggle")) return;
  ev.preventDefault();
  var themes = $(JSON_THEMES);
  var cls = document.documentElement.className.match(/theme--(\\S+)/);
  var current = cls ? cls[1]
    : window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "$(PRIMARY_DARK_THEME)" : "$(PRIMARY_LIGHT_THEME)";
  var next = themes[(themes.indexOf(current) + 1) % themes.length];
  try {
    window.localStorage.setItem("documenter-theme", next);
  } catch (e) {}
  set_theme_from_local_storage();
});
</script>"""

# The click script of an earlier release of this file (the light/dark one): the only
# `<script>` that handles `.docs-theme-toggle` and lacks the `theme-cycle` marker.
const OLD_THEME_TOGGLE_SCRIPT =
    r"<script>\ndocument\.addEventListener\(\"click\", function \(ev\) \{\n  if \(!ev\.target\.closest \|\| !ev\.target\.closest\(\"\.docs-theme-toggle\"\)\) return;.*?</script>"s

"""
    add_theme_toggle(dir) -> Int

Adds the theme button before the settings gear, and its click handler at the end of
`<head>`, on every HTML page under `dir`. A page that has the light/dark button of an earlier
release gets the new title and the cycling handler in its place (this is how the pages of
releases already deployed are brought up to date, see patch_versions.jl). A page that already
has the current button is left as it is, so a second run changes nothing.

# Returns
- `Int`: the number of pages changed.

# Exceptions
- `SystemError` when a page cannot be read or written.
"""
function add_theme_toggle(dir)
    gear = r"<a class=\"docs-settings-button[^>]*>"
    changed = 0
    for (root, _, files) in walkdir(dir), file in files
        endswith(file, ".html") || continue
        path = joinpath(root, file)
        html = read(path, String)
        if occursin("docs-theme-toggle", html)
            occursin("theme-cycle", html) && continue
            added = replace(html, OLD_THEME_TOGGLE_SCRIPT => ""; count = 1)
            added = replace(added, "Toggle light/dark theme" => "Next theme")
        else
            added = replace(html, gear => g -> THEME_TOGGLE_BUTTON * g; count = 1)
            added == html && continue
        end
        added = replace(added, "</head>" => THEME_TOGGLE_SCRIPT * "</head>"; count = 1)
        write(path, added)
        changed += 1
    end
    return changed
end
