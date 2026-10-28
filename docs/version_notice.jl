# SPDX-License-Identifier: LGPL-3.0-or-later

# A short "Latest: v0.4.0 →" link in the navbar of every older release, in place of
# Documenter's "This documentation is for an older version ..." pop-up (hidden by
# `.warning-overlay-base` in docs/src/assets/themes/academic.scss and academic-dark.scss;
# Documenter's own warner.js still runs and still adds the `noindex` tag that keeps search
# engines off old releases). docs/make.jl writes the script into the built pages, like
# theme_toggle.jl does the light/dark button.
#
# Which release is the latest is read in the browser from the same two variables the
# pop-up uses (`DOCUMENTER_CURRENT_VERSION` from siteinfo.js, `DOCUMENTER_NEWEST` and
# `DOCUMENTER_STABLE` from the root versions.js), so a new release needs no change to the
# old pages. The link goes to the same page of the latest release, as the pop-up's did.

const VERSION_NOTICE_SCRIPT = """
<script>
document.addEventListener("DOMContentLoaded", function () {
  var cur = window.DOCUMENTER_CURRENT_VERSION;
  var latest = window.DOCUMENTER_STABLE;
  var newest = window.DOCUMENTER_NEWEST;
  if (newest === undefined || cur === undefined || latest === undefined) return;
  if (!/v(\\d+\\.)*\\d+/.test(cur) || newest === cur) return;
  var right = document.querySelector(".docs-navbar .docs-right");
  if (!right) return;
  var base = new URL(window.documenterBaseURL, window.location.href).pathname;
  if (!base.endsWith("/")) base += "/";
  var path = window.location.pathname;
  var page = path.startsWith(base) ? path.substring(base.length) : "";
  if (page === "index.html") page = "";
  var link = document.createElement("a");
  link.className = "docs-navbar-link docs-version-notice";
  link.href = base + "../" + latest + "/" + page + window.location.hash;
  link.title = "This is " + cur + ". Go to the latest release, " + latest + ".";
  var label = document.createElement("span");
  label.className = "docs-version-label";
  label.textContent = "Latest: " + latest + " ";
  link.appendChild(label);
  link.appendChild(document.createTextNode("\\u2192"));
  right.insertBefore(link, right.querySelector(".docs-theme-toggle") || right.firstChild);
});
</script>"""

"""
    add_version_notice(dir) -> Int

Adds the version-notice script at the end of `<head>` on every HTML page under `dir`. A page
that already has it is left as it is, so a second run changes nothing.

# Returns
- `Int`: the number of pages changed.

# Exceptions
- `SystemError` when a page cannot be read or written.
"""
function add_version_notice(dir)
    changed = 0
    for (root, _, files) in walkdir(dir), file in files
        endswith(file, ".html") || continue
        path = joinpath(root, file)
        html = read(path, String)
        occursin("docs-version-notice", html) && continue
        added = replace(html, "</head>" => VERSION_NOTICE_SCRIPT * "</head>"; count = 1)
        added == html && continue
        write(path, added)
        changed += 1
    end
    return changed
end
