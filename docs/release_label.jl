# SPDX-License-Identifier: LGPL-3.0-or-later

# The small line under the sidebar's "BAYSOL.jl": the release a page documents
# (ex: `v0.3.0-wʋsg_n_yɩɩda`: the tag, then its name, which is the tag's message) or `dev`.
# docs/make.jl stamps it into the built pages; the same function patched the pages of
# releases deployed before it existed (run on a gh-pages checkout). Its style is
# `.docs-release` in docs/src/assets/themes/academic.scss and academic-dark.scss.

"""
    release_label(repo; env = ENV) -> String

The label for the docs being built: on a tag build in GitHub Actions
(`GITHUB_REF_TYPE` is `tag`), the tag joined to its message's subject line by `-`, or the
bare tag when it is a lightweight tag or its message is empty; otherwise `dev` (a push to
master, or a local build).

# Returns
- `String`: the label, not yet HTML-escaped.

# Exceptions
- `ProcessFailedException` when `git` fails in `repo`.
"""
function release_label(repo; env = ENV)
    get(env, "GITHUB_REF_TYPE", "") == "tag" || return "dev"
    tag = env["GITHUB_REF_NAME"]
    # `objecttype` tells an annotated tag (`tag`) from a lightweight one (`commit`), whose
    # `contents` would be the commit message instead of a release name.
    fmt = "%(objecttype) %(contents:subject)"
    parts = split(readchomp(`git -C $repo for-each-ref refs/tags/$tag --format=$fmt`), ' ';
        limit = 2)
    kind = first(parts)
    name = length(parts) == 2 ? strip(parts[2]) : ""
    return kind == "tag" && !isempty(name) ? tag * "-" * name : tag
end

"""
    stamp_release_label(dir, label) -> Int

Adds `label` as `<span class="docs-release">` after the package name in the sidebar title
of every HTML page under `dir`. A page that already has a label is left as it is, so a
second run changes nothing.

# Returns
- `Int`: the number of pages changed.

# Exceptions
- `SystemError` when a page cannot be read or written.
"""
function stamp_release_label(dir, label)
    escaped = replace(label, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
    span = "<span class=\"docs-release\">" * escaped * "</span>"
    subst = replace(span, "\\" => "\\\\")   # a literal backslash in a SubstitutionString
    # The title is `<div class="docs-package-name"><span class="docs-autofit">...</span>`;
    # the label goes after the autofit span, so Documenter's autofit sizes the name only.
    title = Regex(
        "(<div class=\"docs-package-name\"><span class=\"docs-autofit\">.*?</span>)" *
        "(</div>)",
    )
    stamp = SubstitutionString("\\1" * subst * "\\2")
    changed = 0
    for (root, _, files) in walkdir(dir), file in files
        endswith(file, ".html") || continue
        path = joinpath(root, file)
        html = read(path, String)
        occursin("class=\"docs-release\"", html) && continue
        stamped = replace(html, title => stamp; count = 1)
        stamped == html && continue
        write(path, stamped)
        changed += 1
    end
    return changed
end
