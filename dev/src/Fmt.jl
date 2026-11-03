# SPDX-License-Identifier: LGPL-3.0-or-later

# Formats the code: Julia with JuliaFormatter.jl, SCSS with its own indentation rules, the
# prose of all languages re-wrapped, the license headers, the line-length rule, and the
# checks of the terminal interface's settings pages, setting names and release name.
module Fmt

using ..Common
using ..Common: LINE_LIMIT

const WHO = "bysl fmt"

const USAGE = """
Formats the code and checks its layout.

    bysl fmt [--julia|--ts|--scss] [PATH ...]
    bysl fmt --check [--julia|--ts|--scss] [PATH ...]
    bysl fmt --lines [PATH ...]

    (none)      rewrite Julia (JuliaFormatter), TypeScript (Biome) and SCSS files;
                re-wrap long comments; add license headers
    --check     change nothing; list what a rewrite would change; exit 1 if any
    --lines     list lines over 92 characters and tabs in code files; exit 1 if any
    --julia     only Julia files (likewise --ts, --scss)

Also checked: the release name in Project.toml (35 characters at most), the names in
src/*/Params.jl (23 at most) and the settings pages of the terminal interface.
"""

const LICENSE_ID = "LGPL-3.0-or-later"

# The line-comment syntax of each code extension (see `Common.CODE_EXTENSIONS`).
const TS_EXTENSIONS = (".ts", ".tsx", ".mts", ".cts")

const COMMENT_PREFIXES = merge(Dict(".jl" => "#", ".scss" => "//"),
    Dict(e => "//" for e in TS_EXTENSIONS))

# The extensions each language flag of the tool covers.
const LANGUAGE_EXTENSIONS =
    Dict(:julia => (".jl",), :ts => TS_EXTENSIONS, :scss => (".scss",))

const LANGUAGES = (:julia, :ts, :scss)

# --- text helpers

"""
    trim_eof(text) -> String

`text` without the blank lines before the end of the file: it ends with exactly one
newline (a text of nothing but white space becomes empty).
"""
function trim_eof(text::AbstractString)::String
    body = replace(text, r"\s+\z" => "")
    return isempty(body) ? "" : body * "\n"
end

"`text` with the spaces and tabs at the end of each line removed."
trim_trailing_space(text::AbstractString) = replace(text, r"[ \t]+(?=\n|\z)" => "")

# --- license headers

"""
    with_header(text, ext) -> String

`text` of a file with extension `ext` (with its dot) with the license header in place:
`<comment> SPDX-License-Identifier: <LICENSE_ID>` as the first line, or as the second when
the first is a shebang, and a blank line after it.
"""
function with_header(text::AbstractString, ext::AbstractString)::String
    prefix = get(COMMENT_PREFIXES, ext, nothing)
    prefix === nothing && return String(text)
    header = "$prefix SPDX-License-Identifier: $LICENSE_ID"
    lines = String.(split(text, '\n'; keepempty = true))
    shebang = startswith(lines[1], "#!")
    top, rest = shebang ? (lines[1:1], lines[2:end]) : (String[], lines)
    isspdx(l) = occursin(r"^\s*(#|;+|//)\s*SPDX-License-Identifier:", l)
    # the lines after the header: a stale one is dropped
    body = (!isempty(rest) && isspdx(first(rest))) ? rest[2:end] : rest
    # an empty file is the one empty line `split` gives: no body at all
    body == [""] && (body = String[])
    spacer = (isempty(body) || isblank(first(body))) ? String[] : [""]
    return join(vcat(top, [header], spacer, body, isempty(body) ? [""] : String[]), "\n")
end

"The extension of `path` with its dot, `\"\"` if it has none."
header_ext(path) = splitext(path)[2]

# Adds (`apply`) or checks the license header of `files` (paths relative to the root)
# whose extension is in `exts`; returns the files that were (or would be) changed.
function header_files(apply::Bool, files, exts)
    changed = String[]
    for f in files
        header_ext(f) in exts || continue
        old = slurp8(in_root(f))
        fresh = with_header(old, header_ext(f))
        old == fresh && continue
        apply && spit8(in_root(f), fresh)
        push!(changed, f)
    end
    return changed
end

# Adds (`apply`) or checks the license headers of the code files under `paths` of the
# `languages`; true on success.
function format_headers(apply::Bool, languages, paths)
    exts = Tuple(reduce(vcat, [collect(LANGUAGE_EXTENSIONS[l]) for l in languages]))
    files = unique(reduce(vcat, code_files.(paths); init = String[]))
    changed = header_files(apply, files, exts)
    for f in changed
        println(apply ? "license header added:" : "license header missing:", " ", f)
    end
    return apply || isempty(changed)
end

# --- Julia (the external formatter) and TypeScript

"The Julia files under `paths`, formatted (`apply`) or checked with JuliaFormatter."
format_julia(apply::Bool, paths) = run_cmd([find_julia(), "--startup-file=no",
    "--project=" * joinpath(Common.REPO, "test", "format"),
    joinpath(Common.REPO, "dev", "scripts", "format.jl"),
    apply ? "--apply" : "--check", paths])

# The Biome command: `BIOME` if set, else `node_modules/.bin/biome` in the root or in a
# folder just below it, else `biome` on the PATH; `nothing` if there is none.
function biome_command()
    haskey(ENV, "BIOME") && return ENV["BIOME"]
    for name in ("biome", "biome.cmd")
        for dir in vcat([root()], filter(isdir, readdir(root(); join = true)))
            path = joinpath(dir, "node_modules", ".bin", name)
            isfile(path) && return path
        end
    end
    return Sys.which("biome")
end

# Formats (`apply`) or checks the TypeScript files under `paths`: trailing white
# space and the final newline here, then Biome (`biome.json`) for the layout and
# the lint. A missing Biome with TypeScript files present is a failure.
function format_ts(apply::Bool, paths)
    files = [
        f for f in unique(reduce(vcat, code_files.(paths); init = String[]))
        if splitext(f)[2] in TS_EXTENSIONS
    ]
    isempty(files) && return true
    changed = String[]
    for f in files
        old = slurp8(in_root(f))
        fresh = trim_eof(trim_trailing_space(old))
        old == fresh && continue
        apply && spit8(in_root(f), fresh)
        push!(changed, f)
    end
    for f in changed
        println(apply ? "formatted" : "not formatted:", " ", f)
    end
    biome = biome_command()
    if biome === nothing
        println(WHO, ": Biome is not installed (npm install --save-dev @biomejs/biome), ",
            "so TypeScript layout and lint could not be checked")
        return false
    end
    checked = run_cmd([biome, "check", apply ? ["--write"] : [], "--config-path=" * root(),
        [in_root(f) for f in files]])
    return (apply || isempty(changed)) && checked
end

# --- SCSS indentation
#
# 4 spaces a level and no trailing white space; nothing else is rewritten.
#     - a line is indented by the brackets still open, less its leading closers;
#     - a continued declaration (`name: value`) is one level deeper;
#     - `//` comments take the indentation of the code around them, `/* */` bodies stay;
#     - strings, comments, `url(...)` and `#{...}` are read, so their brackets do not count.

"The spaces of one level of nesting."
const SCSS_INDENT_UNIT = 4

const SCSS_OPENERS = ('{', '(', '[')
const SCSS_CLOSERS = ('}', ')', ']')

"""
Reads `line` from the start.
"""
function scan_scss(line::AbstractString, in_block::Bool)
    cs = collect(line)
    n = length(cs)
    at(i) = i <= n ? cs[i] : nothing
    i = 1
    open_quote = nothing
    delta = 0
    lead = 0
    leading = true
    code_end = n
    while i <= n
        ch = cs[i]
        if in_block
            if ch == '*' && at(i + 1) == '/'
                in_block = false
                i += 2
            else
                i += 1
            end
        elseif open_quote !== nothing
            leading = false
            if ch == '\\'
                i += 2
            elseif ch == open_quote
                open_quote = nothing
                i += 1
            else
                i += 1
            end
        elseif ch == '"' || ch == '\''
            open_quote = ch
            leading = false
            i += 1
        elseif ch == '/' && at(i + 1) == '/'
            code_end = i - 1
            leading = false
            i = n + 1
        elseif ch == '/' && at(i + 1) == '*'
            in_block = true
            leading = false
            i += 2
        elseif ch == '(' && i > 1 && endswith(String(cs[1:(i-1)]), "url") &&
               !(at(i + 1) in ('"', '\''))
            # unquoted url(...) may hold // and quotes: skip to its closing bracket
            close = findnext(==(')'), cs, i)
            leading = false
            i = close === nothing ? n + 1 : close + 1
        elseif ch in SCSS_OPENERS
            delta += 1
            leading = false
            i += 1
        elseif ch in SCSS_CLOSERS
            delta -= 1
            leading && (lead += 1)
            i += 1
        elseif java_whitespace(ch)
            i += 1
        else
            leading = false
            i += 1
        end
    end
    return (delta = delta, lead = lead, code = String(cs[1:code_end]), in_block = in_block)
end


# The first line of `name: value`, `$var: value` or `--custom: value`; a selector such as
# `a:hover` has no space after its colon.
const SCSS_DECLARATION_START = r"^[$@A-Za-z_-][\w-]*:\s"

"""
    reindent_scss(text) -> String

`text` of a .scss file with every line indented by the nesting rules above and without
trailing whitespace.
"""
function reindent_scss(text::AbstractString)::String
    out = String[]
    depth = 0
    in_block = false
    decl = nothing  # the open declaration: the depth it started at
    for line in split(text, '\n'; keepempty = true)
        trimmed = strip(line)
        if in_block
            s = scan_scss(line, true)
            push!(out, rstrip(line))
            depth += s.delta
            in_block = s.in_block
            continue
        elseif isempty(trimmed)
            push!(out, "")
            in_block = false
            continue
        end
        s = scan_scss(trimmed, false)
        comment = startswith(trimmed, "//") || startswith(trimmed, "/*")
        level = max(0, depth - s.lead)
        continued = decl !== nothing && decl == depth && s.lead == 0 && !comment
        indent = SCSS_INDENT_UNIT * (level + (continued ? 1 : 0))
        depth2 = max(0, depth + s.delta)
        c = rstrip(s.code)
        ended = isempty(c) || last(c) in (';', '{', '}') || s.lead > 0 || s.delta > 0
        decl2 = if comment
            decl
        elseif decl === nothing && occursin(SCSS_DECLARATION_START, trimmed) && !ended
            depth2
        elseif ended
            nothing
        else
            decl
        end
        push!(out, " "^indent * trimmed)
        depth = depth2
        in_block = s.in_block
        decl = decl2
    end
    return join(out, "\n")
end

# Formats (`apply`) or checks the indentation of the .scss files under `paths`; true on
# success.
function format_scss(apply::Bool, paths)
    changed = String[]
    for f in unique(reduce(vcat, code_files.(paths); init = String[]))
        endswith(f, ".scss") || continue
        old = slurp8(in_root(f))
        fresh = trim_eof(reindent_scss(old))
        old == fresh && continue
        apply && spit8(in_root(f), fresh)
        push!(changed, f)
    end
    for f in changed
        println(apply ? "formatted" : "not formatted:", " ", f)
    end
    return apply || isempty(changed)
end

# Re-wraps (`apply`) or checks the prose of the `language` files under `paths`; true on
# success.
function reflow_prose(apply::Bool, language::Symbol, paths)
    changed = reflow_files(apply, language, paths)
    for f in changed
        println(apply ? "re-wrapped" : "prose to re-wrap:", " ", f)
    end
    return apply || isempty(changed)
end

# --- the release name, the setting names and the settings pages of the TUI

# The release name `v<version>-<release_name>` is shown on the main menu of the TUI, which
# has room for this many characters: from the left edge of the box, under it.
const MAX_VERSION_NAME_LENGTH = 35

"""
The release name `v<version>-<release_name>` of the Project.toml text `toml`, or `nothing`
if it lacks either key.
"""
function version_name(toml::AbstractString)
    version = match(r"(?m)^version\s*=\s*\"([^\"]*)\"", toml)
    release = match(r"(?m)^release_name\s*=\s*\"([^\"]*)\"", toml)
    (version === nothing || release === nothing) && return nothing
    return "v" * version[1] * "-" * release[1]
end

"""
What is wrong with the release name in the Project.toml text `toml`, or `nothing` if it is
fine: a missing key, or more than `MAX_VERSION_NAME_LENGTH` characters.
"""
function version_problem(toml::AbstractString)
    release = version_name(toml)
    release === nothing && return "there is no `version` or no `release_name`"
    n = char_count(release)
    n > MAX_VERSION_NAME_LENGTH || return nothing
    return "the release name $release has $n characters, the limit is " *
           "$MAX_VERSION_NAME_LENGTH (the main menu of the TUI has room for that many)"
end

"""
The most characters the name of a setting may have: the width of the name column of the
TUI's settings sheets.
"""
const MAX_PARAMETER_NAME_LENGTH = 23

"""
The names of the constants declared in the text `text` of a Julia `Params.jl` file (`const
NAME = ...`, with or without a type annotation `const NAME::T = ...`).
"""
parameter_names(text::AbstractString) =
    String[m[1] for m in eachmatch(r"(?m)^const\s+([^\s:=]+)", text)]

"""
What is wrong with the names in the `Params.jl` text `text`: one sentence for each name of
more than `MAX_PARAMETER_NAME_LENGTH` characters; empty if all fit.
"""
function parameter_problems(text::AbstractString)
    return String[
        "$n has $(char_count(n)) characters, the limit is " *
        "$MAX_PARAMETER_NAME_LENGTH (the name column of the settings sheets)"
        for n in parameter_names(text) if char_count(n) > MAX_PARAMETER_NAME_LENGTH
    ]
end

# Checks the names of the settings in every `src/<Module>/Params.jl`; prints each problem
# and returns false, or returns true.
function check_parameter_names()
    src = in_root("src")
    files = sort([
        joinpath(src, d, "Params.jl") for d in readdir(src)
        if isfile(joinpath(src, d, "Params.jl"))
    ])
    problems = String[]
    for f in files, p in parameter_problems(slurp8(f))
        push!(problems, "$f: $p")
    end
    foreach(p -> println(WHO, ": ", p), problems)
    return isempty(problems)
end

# The pages of the TUI's settings sheets (tui/resources/<category>-settings/pages/*.txt):
# a table of three fields, `name | description | value`, of these widths (the first
# character of a field is a space, so a name has room for width - 1 characters).
const PAGE_FIELD_WIDTHS = (24, 29, 19)

# A horizontal rule of the page table: `left`, then a run of `═` for each field with
# `between` after each field but the last, then `right`.
page_rule(left, between, right) =
    "   " * left * join(("═"^w for w in PAGE_FIELD_WIDTHS), between) * right

const PAGE_HEADER =
    "   ║        name            ║" * "        description          ║" *
    "      value        ║"

# The regex of a row of the table (3 spaces of indent) whose edges are `left`, `mid` and
# `right`.
function page_row_re(left, mid, right)
    a, b, c = (".{$w}" for w in PAGE_FIELD_WIDTHS)
    return Regex("^   $left$a$mid$b$mid$c$right\$")
end

const PAGE_NAME_ROW = page_row_re("╠", "╬", "╣")
const PAGE_MORE_ROW = page_row_re("║", "║", "║")

"""
What is wrong with the text `text` of a settings page, as sentences that start with the
line number; empty if the page is fine.
"""
function page_problems(text::AbstractString)::Vector{String}
    lines = String.(split(text, '\n'; keepempty = true))
    rule_under = page_rule("╠", "╬", "╣")
    # the footer box hangs under the value field, so its junction is `╬`, not `╩`
    a, b, c = ("═"^w for w in PAGE_FIELD_WIDTHS)
    bottom = "   ╚" * a * "╩" * b * "╬" * c * "╣"
    bottom_at = findfirst(==(bottom), lines)
    problems = String[]
    problem!(i, msg) = push!(problems, "line $i: $msg")
    first(lines) == PAGE_HEADER || problem!(1, "the table header is not the standard one")
    (length(lines) >= 2 && lines[2] == rule_under) ||
        problem!(2, "the rule under the header is not the standard one")
    if bottom_at === nothing
        problem!(length(lines), "no standard bottom rule of the table")
    else
        for i in 3:(bottom_at-1)
            l = lines[i]
            marked = startswith(l, " > ")
            body = marked ? "   " * l[nextind(l, 3):end] : l
            if occursin(PAGE_NAME_ROW, body)
                continue
            elseif occursin(PAGE_MORE_ROW, body)
                marked && problem!(i,
                    "the marker `>` is on a continuation line, not on a setting")
            else
                problem!(
                    i,
                    "not a row of the table: $(char_count(l)) characters; a row " *
                    "is `╠ name ╬ description ╬ value ╣` or a continuation " *
                    "`║ ║ ║ ║`, $(7 + sum(PAGE_FIELD_WIDTHS)) characters in all " *
                    "(3 of indent), without trailing spaces",
                )
            end
        end
    end
    n = count(startswith(" > "), lines)
    n == 1 || push!(problems,
        "the marker `>` appears $n times, it must appear exactly once")
    return problems
end

# The text files of the TUI's settings sheets, tui/resources/*-settings/pages/*.txt (the
# pages and the blocs they are made from; not the art pages of the settings menu, whose
# trailing spaces are part of the picture), as a sorted list of paths; `pattern` is a
# regex for the file name inside the folders.
function settings_page_files(pattern::Regex)
    base = in_root("tui", "resources")
    isdir(base) || return String[]
    found = String[]
    for d in readdir(base)
        endswith(d, "-settings") || continue
        pages = joinpath(base, d, "pages")
        isdir(pages) || continue
        for f in readdir(pages)
            occursin(pattern, f) && push!(found, joinpath(pages, f))
        end
    end
    return sort(found)
end

# Trims (`apply`) or checks the trailing spaces and tabs of every text file of the TUI's
# settings sheets (pages and blocs); true on success.
function format_settings_pages(apply::Bool)
    changed = String[]
    for f in settings_page_files(r"^.*\.txt$")
        old = slurp8(f)
        fresh = trim_trailing_space(old)
        old == fresh && continue
        apply && spit8(f, fresh)
        push!(changed, f)
    end
    for f in changed
        println(apply ? "trailing spaces trimmed:" : "trailing spaces:", " ", f)
    end
    return apply || isempty(changed)
end

# Checks every page of the TUI's settings sheets (the blocs they are made from are not
# pages): prints each problem with its file and returns false, or returns true.
function check_settings_pages()
    problems = String[]
    for f in settings_page_files(r"^page.*\.txt$"),
        p in
        page_problems(trim_trailing_space(slurp8(f)))

        push!(problems, "$f: $p")
    end
    foreach(p -> println(WHO, ": ", p), problems)
    return isempty(problems)
end

# Checks the release name in the Project.toml at the root of the repository: prints the
# problem and returns false, or returns true.
function check_version_name()
    path = in_root("Project.toml")
    problem = isfile(path) ? version_problem(slurp8(path)) : nothing
    problem === nothing || println(WHO, ": Project.toml: ", problem)
    return problem === nothing
end

# --- prose re-wrapping
#
# The comment blocks and docstring paragraphs of Julia, TypeScript and SCSS files
# that contain a line over the limit are filled again, balanced (all lines about
# equally long, no stray last word). Code, lists, tables, code blocks and indented
# text are left alone, and a block that fits is kept as it is, so a second pass
# changes nothing. The formatters do not wrap prose; `bysl fmt` runs this after them.

const LIMIT = LINE_LIMIT

len(s) = char_count(s)

# Whether `c` separates words: white space, but not the no-break spaces (unlike
# `isspace`).
java_whitespace(c::Char) =
    isspace(c) && !(c in (' ', ' ', ' ', '\u0085')) ||
    c in ('\u001c', '\u001d', '\u001e', '\u001f')

"""
    words(text) -> Vector{String}

The words of a paragraph.
"""
function words(text::AbstractString)::Vector{String}
    if isodd(count('`', text))
        return String[m.match for m in eachmatch(r"\S+", text)]
    end
    out = String[]
    cur = IOBuffer()
    code = false
    link = false
    prev = nothing
    for ch in text
        ch == '`' && (code = !code)
        if code
            # inside a code span the link state is unchanged
        elseif ch == '(' && prev == ']'
            link = true
        elseif ch == ')' && link
            link = false
        end
        brk = java_whitespace(ch) && !code && !link
        if brk
            if position(cur) > 0
                push!(out, String(take!(cur)))
            end
        else
            print(cur, ch)
        end
        prev = ch
    end
    position(cur) > 0 && push!(out, String(take!(cur)))
    return out
end

"Greedy wrap of `ws` to lines of at most `w` characters."
function greedy(ws, w)
    lines = String[]
    cur = nothing
    for word in ws
        if cur === nothing
            cur = word
        elseif len(cur) + 1 + len(word) <= w
            cur = cur * " " * word
        else
            push!(lines, cur)
            cur = word
        end
    end
    cur === nothing || push!(lines, cur)
    return lines
end

"Would Markdown read the line as a list, heading, quote or table?"
bad_start(line) = occursin(r"^(?:[-*+#>|=]|\d+[.)])(?:\s|$)|^```", line)

"""
    balanced(ws, width)

`ws` wrapped balanced into lines of at most `width` characters: as few lines as greedy
needs, at the smallest width that still gives that many lines (and no continuation line
that Markdown would read as structure).
"""
function balanced(ws, width)
    k = length(greedy(ws, width))
    k <= 1 && return greedy(ws, width)
    longest = maximum(len, ws)
    lo = max(longest, len(join(ws, " ")) ÷ k)
    for w in lo:width
        wrapped = greedy(ws, w)
        length(wrapped) <= k && !any(bad_start, wrapped[2:end]) && return wrapped
    end
    return greedy(ws, width)
end

# Is this comment text the start of a list item, a table row, an aligned column or other
# structure?
structured(text) =
    occursin(r"^(?:[-*+]\s|\d+[.)]\s|\||```|[A-Za-z_0-9`]+\s*(?:=|:)\s*$)", text)

# Is this comment text a section banner (`--- name` or `=== name`)?
banner(ext, text) = occursin(ext == "jl" ? r"^#+\s*[-=─]{3}" : r"^[-=─]{3}", text)

# The comment prefix of a file type: `#` for Julia, `//` for TypeScript and SCSS.
function comment_re(ext)
    ext in ("ts", "tsx", "mts", "cts", "scss") && return r"^(\s*//) (\S.*)$"
    return r"^(\s*#) (\S.*)$"
end

struct Ctx
    lines::Vector{String}
    ext::String
    in_doc::Bool
end

# Each rule looks at the line at index `i` and returns `(out, next, toggle)` (the lines it
# writes, the index to continue at, whether it opens or closes a docstring), or `nothing`
# when it does not apply; the first rule that applies wins.

# A line that opens a plain triple-quoted string (`const X = """`, text before the quotes,
# none after) starts a stretch of text that is not a docstring: its lines are copied as
# they are up to the line that holds the closing quotes.
function raw_string(c::Ctx, i)
    (c.ext == "jl" && !c.in_doc) || return nothing
    line = c.lines[i]
    (
        endswith(rstrip(line), "\"\"\"") && strip(line) != "\"\"\"" &&
        isodd(length(collect(eachmatch(r"\"\"\"", line))))
    ) || return nothing
    j = i + 1
    while j <= length(c.lines) && !occursin("\"\"\"", c.lines[j])
        j += 1
    end
    j = min(j, length(c.lines))
    return (out = c.lines[i:j], next = j + 1, toggle = false)
end

# A line that is exactly three quotes opens or closes a Julia docstring.
function docstring_fence(c::Ctx, i)
    (c.ext == "jl" && strip(c.lines[i]) == "\"\"\"") || return nothing
    return (out = [c.lines[i]], next = i + 1, toggle = true)
end

# A one-line Julia docstring that is too long becomes a block docstring.
function one_line_docstring(c::Ctx, i)
    line = c.lines[i]
    (
        c.ext == "jl" && !c.in_doc && startswith(line, "\"") &&
        occursin(r"^\"[^\"]*\"$", line) && len(line) > LIMIT
    ) || return nothing
    inner = chop(line; head = 1, tail = 1)
    return (out = vcat(["\"\"\""], balanced(words(inner), LIMIT), ["\"\"\""]),
        next = i + 1, toggle = false)
end

# The indented lines after index `i` that continue a docstring list item: `(hang, parts,
# next)`, `hang` being the indent of the first one.
function continuation(lines, i)
    cont = Tuple{String,String}[]
    for j in (i+1):length(lines)
        l = lines[j]
        (isblank(l) || occursin(r"^\s*([-*]\s|\d+[.)]\s|```|#|@|\||\")", l)) && break
        m = match(r"^(\s+)(\S.*)$", l)
        m === nothing && break
        push!(cont, (m[1], m[2]))
    end
    hang = isempty(cont) ? "" : first(cont)[1]
    return hang, [p[2] for p in cont], i + 1 + length(cont)
end

isblank(s) = all(java_whitespace, s)

# A too long list item of a Julia docstring (`- text` with its indented continuation
# lines) is re-wrapped under its marker, with a hanging indent.
function docstring_list_item(c::Ctx, i)
    (c.ext == "jl" && c.in_doc) || return nothing
    m = match(r"^(\s*)([-*]\s+|\d+[.)]\s+)(\S.*)$", c.lines[i])
    m === nothing && return nothing
    ind, mark, text = m[1], m[2], m[3]
    hang, more, j = continuation(c.lines, i)
    parts = vcat([text], more)
    long = len(c.lines[i]) > LIMIT || any(p -> len(hang * p) > LIMIT, more)
    if !long
        return (out = c.lines[i:(j-1)], next = j, toggle = false)
    end
    hang = isempty(hang) ? " "^max(len(ind * mark), 4) : hang
    first_part = ind * mark
    width = LIMIT - max(len(first_part), len(hang))
    wrapped = balanced(words(join(parts, " ")), width)
    out = vcat([first_part * wrapped[1]], [hang * w for w in wrapped[2:end]])
    return (out = out, next = j, toggle = false)
end

# A trailing comment that makes a Julia code line too long moves above the line.
function trailing_comment(c::Ctx, i)
    line = c.lines[i]
    (c.ext == "jl" && !c.in_doc && len(line) > LIMIT) || return nothing
    m = match(r"^(\s*)([^#\s][^#]*?)\s+# (\S.*)$", line)
    m === nothing && return nothing
    ind, code, cmt = m[1], m[2], m[3]
    (iseven(count('"', code)) && !occursin(r"^\s*\"", code)) || return nothing
    out = vcat(["$(ind)# $w" for w in balanced(words(cmt), LIMIT - len(ind) - 2)],
        [ind * code])
    return (out = out, next = i + 1, toggle = false)
end

# The consecutive lines from `i` that form one paragraph, and the prefix they share:
# `(prefix, texts)`, or `nothing` when line `i` starts none.
function paragraph_lines(c::Ctx, i)
    line = c.lines[i]
    rx = comment_re(c.ext)
    m = match(rx, line)
    if m !== nothing
        pre = m[1]
        texts = String[]
        for j in i:length(c.lines)
            mj = match(rx, c.lines[j])
            (
                mj !== nothing && mj[1] == pre && !structured(mj[2]) &&
                !banner(c.ext, mj[2])
            ) || break
            push!(texts, mj[2])
        end
        return pre * " ", texts
    elseif c.ext == "jl" && c.in_doc && occursin(r"^\S", line) && !structured(line) &&
           !occursin(r"^[@#!]", line)
        texts = String[]
        for j in i:length(c.lines)
            l = c.lines[j]
            (occursin(r"^\S", l) && !structured(l) && !occursin(r"^[@#!\"]", l)) || break
            push!(texts, l)
        end
        return "", texts
    end
    return nothing
end

# A paragraph with a line over the limit is re-wrapped balanced under its prefix; one that
# fits is kept.
function paragraph(c::Ctx, i)
    found = paragraph_lines(c, i)
    found === nothing && return nothing
    prefix, texts = found
    isempty(texts) && return nothing
    out = if any(t -> len(prefix * t) > LIMIT, texts)
        [prefix * w for w in balanced(words(join(texts, " ")), LIMIT - len(prefix))]
    else
        [prefix * t for t in texts]
    end
    return (out = out, next = i + length(texts), toggle = false)
end

const RULES =
    (raw_string, docstring_fence, one_line_docstring, docstring_list_item, trailing_comment,
        paragraph)

"""
    reflow_lines(lines, ext) -> Vector{String}

The `lines` of a file of type `ext` (`"jl"`, `"ts"`, `"tsx"`, `"mts"`, `"cts"` or
`"scss"`) with the paragraphs that contain a long line re-wrapped.
"""
function reflow_lines(lines::Vector{String}, ext::AbstractString)::Vector{String}
    out = String[]
    i = 1
    in_doc = false
    while i <= length(lines)
        ctx = Ctx(lines, String(ext), in_doc)
        hit = nothing
        for rule in RULES
            hit = rule(ctx, i)
            hit === nothing || break
        end
        if hit === nothing
            push!(out, lines[i])
            i += 1
        else
            append!(out, hit.out)
            hit.toggle && (in_doc = !in_doc)
            i = hit.next
        end
    end
    return out
end

"The file types the engine knows, by language flag."
const EXTENSIONS =
    Dict(:julia => ("jl",), :ts => ("ts", "tsx", "mts", "cts"), :scss => ("scss",))

"""
    reflow_files(apply, language, paths) -> Vector{String}

Re-wraps the files of `language` (`:julia`, `:ts` or `:scss`) under `paths`.
"""
function reflow_files(apply::Bool, language::Symbol, paths)::Vector{String}
    changed = String[]
    for f in unique(reduce(vcat, code_files.(paths); init = String[]))
        ext = lstrip(splitext(f)[2], '.')
        ext in EXTENSIONS[language] || continue
        old = String.(split(slurp8(in_root(f)), '\n'; keepempty = true))
        fresh = reflow_lines(old, ext)
        fresh == old && continue
        apply && spit8(in_root(f), join(fresh, "\n"))
        push!(changed, f)
    end
    return changed
end

# --- the line-length rule
#
# Every line of the code at most 92 characters, no tab character (`bysl fmt --lines`).

const LINES_WHO = "bysl fmt --lines"

# The lines of the file `rel` (relative to the root), split on newlines only: a carriage
# return stays at the end of its line.
lines_of(rel) = split(read(in_root(rel), String), '\n'; keepempty = true)

"(file, line number, length) of every line over the limit in `files`."
function long_lines(files)
    found = Tuple{String,Int,Int}[]
    for f in files, (i, line) in enumerate(lines_of(f))
        n = char_count(chopsuffix(line, "\r"))
        n > LINE_LIMIT && push!(found, (f, i, n))
    end
    return found
end

"(file, line number) of every line holding a tab character (indent with 4 spaces)."
function tab_lines(files)
    found = Tuple{String,Int}[]
    for f in files, (i, line) in enumerate(lines_of(f))
        occursin('\t', line) && push!(found, (f, i))
    end
    return found
end

"Lists the lines over the limit and the tabs; true when there are none."
function check_lines(paths)::Bool
    files = reduce(vcat, code_files.(isempty(paths) ? [root()] : paths))
    too_long = long_lines(files)
    tabs = tab_lines(files)
    for (f, i, n) in too_long
        println(f, ":", i, ": ", n, " characters")
    end
    for (f, i) in tabs
        println(f, ":", i, ": tab character (indent with 4 spaces)")
    end
    isempty(tabs) ||
        println(stderr, LINES_WHO, ": ", length(tabs), " line(s) with a tab character")
    isempty(too_long) ||
        println(stderr, LINES_WHO, ": ", length(too_long), " line(s) over ",
            LINE_LIMIT, " characters in ", length(unique(first.(too_long))),
            " file(s)")
    ok = isempty(too_long) && isempty(tabs)
    ok && println("layout: ", length(files), " code files, no line over ",
        LINE_LIMIT, " characters, no tab character")
    return ok
end

# --- the main program

const LANGUAGE_FLAGS = Dict("--julia" => :julia, "--ts" => :ts, "--scss" => :scss)

"""
    run(argv) -> Int

The tool's main program: the options and the paths.
"""
function run(argv::Vector{String})::Int
    if isempty(argv) || any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    check = "--check" in argv
    lines = "--lines" in argv
    check && lines && fail(WHO, "give --check or --lines, not both")
    rest_args = filter(a -> a != "--check" && a != "--lines", argv)
    # a typo must not reach the formatters as a path
    bad = findfirst(a -> startswith(a, "--") && !haskey(LANGUAGE_FLAGS, a), rest_args)
    bad === nothing || fail(
        WHO,
        "unknown option $(rest_args[bad]) (options: --check, --lines, " *
        "--julia, --ts, --scss)",
    )
    if lines
        any(haskey(LANGUAGE_FLAGS, a) for a in rest_args) &&
            fail(WHO, "--lines checks every code file; no language option")
        paths = rest_args
        return check_lines(isempty(paths) ? [root()] : paths) ? 0 : 1
    end
    apply = !check
    languages = Set(LANGUAGE_FLAGS[a] for a in rest_args if haskey(LANGUAGE_FLAGS, a))
    every = isempty(languages)  # no language flag: all
    wanted(l) = every || l in languages
    paths = filter(a -> !haskey(LANGUAGE_FLAGS, a), rest_args)
    isempty(paths) && (paths = [root()])
    # the formatter first, then the prose; both run even if one fails
    both_ok(language, format_fn) = (formatted = format_fn(apply, paths);
        prose = reflow_prose(apply, language, paths); formatted && prose)
    header_ok = format_headers(apply, every ? LANGUAGES : filter(wanted, LANGUAGES), paths)
    julia_ok = !wanted(:julia) || both_ok(:julia, format_julia)
    ts_ok = !wanted(:ts) || both_ok(:ts, format_ts)
    scss_ok = !wanted(:scss) || both_ok(:scss, format_scss)
    # whatever the mode and the language: the release name must fit the main menu, the
    # names of the settings the name column of the TUI's sheets, and the pages of those
    # sheets must be well formed (trailing spaces trimmed first)
    version_ok = check_version_name()
    names_ok = check_parameter_names()
    trim_ok = format_settings_pages(apply)
    pages_ok = check_settings_pages()
    return all((header_ok, julia_ok, ts_ok, scss_ok, version_ok, names_ok,
        trim_ok, pages_ok)) ? 0 : 1
end

end
