# SPDX-License-Identifier: LGPL-3.0-or-later

# Formats the code: Julia with JuliaFormatter.jl, SCSS with its own indentation rules, the
# prose of all languages re-wrapped, the license headers, the line-length rule, and the
# checks of the setting names and the release name.
module Fmt

using ..Common
using ..Common: LINE_LIMIT

const WHO = "bysl fmt"

const USAGE = """
Formats the code and checks its layout.

    bysl fmt [--julia|--ts|--scss|--py] [PATH ...]
    bysl fmt --check [--julia|--ts|--scss|--py] [PATH ...]
    bysl fmt --lines [PATH ...]

    (none)      rewrite Julia (JuliaFormatter), TypeScript (Biome), Python (ruff) and
                SCSS files;
                re-wrap long comments; add license headers
    --check     change nothing; list what a rewrite would change; exit 1 if any
    --lines     list lines over 92 characters and tabs in code files; exit 1 if any
    --julia     only Julia files (likewise --ts, --scss, --py)

Also checked: the release name in Project.toml (35 characters at most), the names in
src/*/Params.jl (23 at most).
"""

const LICENSE_ID = "LGPL-3.0-or-later"

# The line-comment syntax of each code extension (see `Common.CODE_EXTENSIONS`).
const TS_EXTENSIONS = (".ts", ".tsx", ".mts", ".cts")

const COMMENT_PREFIXES = merge(Dict(".jl" => "#", ".py" => "#", ".scss" => "//"),
    Dict(e => "//" for e in TS_EXTENSIONS))

# The extensions each language flag of the tool covers.
const LANGUAGE_EXTENSIONS =
    Dict(:julia => (".jl",), :ts => TS_EXTENSIONS, :scss => (".scss",), :py => (".py",))

const LANGUAGES = (:julia, :ts, :scss, :py)

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
# space and the final newline here, then Biome (`biome.json`, formatter off) for the
# lint. A missing Biome with TypeScript files present is a failure.
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

# --- Python (ruff)

# The ruff command: `RUFF` if set, else `ruff` on the PATH; `nothing` if there is none.
ruff_command() = haskey(ENV, "RUFF") ? ENV["RUFF"] : Sys.which("ruff")

# Formats (`apply`) or checks the Python files under `paths` with `ruff format`, then
# lints them with `ruff check` (`ruff.toml` at the root); `--fix` only when `apply`. A
# missing ruff with Python files present is a failure.
function format_py(apply::Bool, paths)
    files = [
        f for f in unique(reduce(vcat, code_files.(paths); init = String[]))
        if endswith(f, ".py")
    ]
    isempty(files) && return true
    ruff = ruff_command()
    if ruff === nothing
        println(WHO, ": ruff is not installed (pipx install ruff), so Python layout ",
            "and lint could not be checked")
        return false
    end
    abs_files = [in_root(f) for f in files]
    config = "--config=" * in_root("ruff.toml")
    formatted = run_cmd([ruff, "format", config, apply ? [] : ["--check"], abs_files])
    linted = run_cmd([ruff, "check", config, apply ? ["--fix"] : [], abs_files])
    return formatted && linted
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

# --- the release name and the setting names

# A hard cap on the release name `v<version>-<release_name>`: a longer one is hard to read
# where it is shown.
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
           "$MAX_VERSION_NAME_LENGTH (a longer name is hard to read)"
end

"""
The most characters the name of a setting may have, a hard cap: a longer name is hard to
read.
"""
const MAX_PARAMETER_NAME_LENGTH = 23

"""
The names of the constants declared in the text `text` of a Julia `params.jl` file (`const
NAME = ...`, with or without a type annotation `const NAME::T = ...`).
"""
parameter_names(text::AbstractString) =
    String[m[1] for m in eachmatch(r"(?m)^const\s+([^\s:=]+)", text)]

"""
What is wrong with the names in the `params.jl` text `text`: one sentence for each name of
more than `MAX_PARAMETER_NAME_LENGTH` characters; empty if all fit.
"""
function parameter_problems(text::AbstractString)
    return String[
        "$n has $(char_count(n)) characters, the limit is " *
        "$MAX_PARAMETER_NAME_LENGTH (a longer name is hard to read)"
        for n in parameter_names(text) if char_count(n) > MAX_PARAMETER_NAME_LENGTH
    ]
end

# Checks the names of the settings in every `src/<Module>/Params.jl`; prints each problem
# and returns false, or returns true.
function check_parameter_names()
    src = in_root("src")
    files = sort([
        joinpath(src, d, "params.jl") for d in readdir(src)
        if isfile(joinpath(src, d, "params.jl"))
    ])
    problems = String[]
    for f in files, p in parameter_problems(slurp8(f))
        push!(problems, "$f: $p")
    end
    foreach(p -> println(WHO, ": ", p), problems)
    return isempty(problems)
end

# --- file and folder names (kebab-case)

# Trees whose entries are named by an identifier (fitting-test and synthetic entry IDs,
# deposited-data folders), by an external convention or are not source, so they are skipped.
const NAME_SKIP_DIRS = (
    "test/fitting_tests", "test/synthetic_tests", "test/fixtures", "test/baselines",
    "test/.CondaPkg", "docs/build", "dev/pmv-rism/legacy", "dev/pmv-rism/out",
)
const NAME_ROOTS = ("src", "dev", "docs", "test", "tui")
# Names the toolchain fixes: Julia wants src/<Package>.jl, Python wants `__init__.py`; these
# are conventional.
const NAME_EXCEPTIONS = (
    "BAYSOL.jl", "Dev.jl", "README.md", "LICENSE", "Project.toml", "Manifest.toml",
    "CHANGELOG.md",
    "JuliaManifest.toml", "CondaPkg.toml", "SPEC.md", "AGENTS.md", "__init__.py",
)
const NAME_CHECKED_EXTENSIONS =
    (".jl", ".ts", ".tsx", ".mts", ".cts", ".scss", ".py", ".yml")
const KEBAB_NAME = r"^_?[a-z0-9]+(-[a-z0-9]+)*$"   # a leading `_` is a Sass partial

# True if the file or folder name `n` (a path component) is kebab-case: the stem of a file
# (up to its first dot) and every folder name are lower case words joined by `-`; a name
# starting with `.`, a `.sqlite3` file and the names of `NAME_EXCEPTIONS` are allowed.
function kebab_name(n::AbstractString)
    (startswith(n, ".") || n in NAME_EXCEPTIONS || endswith(n, ".sqlite3")) && return true
    stem = first(split(n, '.'; limit = 2))
    return occursin(KEBAB_NAME, stem)
end

# Checks the names of the files and folders under `src`, `dev`, `docs`, `test` and `tui`
# (not `node_modules`, `NAME_SKIP_DIRS`, and the data files, whose names follow their
# source: `.txt`, `.tsv`, `.json`, `.dat`, `.pdb`, `.fit`); prints each offender and
# returns false, or returns true.
function check_path_names()
    bad = String[]
    for top in NAME_ROOTS
        base = in_root(top)
        isdir(base) || continue
        for (dir, dirs, files) in walkdir(base)
            rel = relpath(dir, root())
            filter!(
                d ->
                    d != "node_modules" && d != "__pycache__" &&
                    !(joinpath(rel, d) in NAME_SKIP_DIRS), dirs)
            for d in dirs
                kebab_name(d) || push!(bad, joinpath(rel, d) * "/")
            end
            for f in files
                any(e -> endswith(f, e), NAME_CHECKED_EXTENSIONS) || continue
                kebab_name(f) || push!(bad, joinpath(rel, f))
            end
        end
    end
    sort!(bad)
    foreach(b -> println(WHO, ": not kebab-case: ", b), bad)
    return isempty(bad)
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
# Every line of the code at most 92 characters, no tab character, and in TypeScript, Julia
# and SCSS every indentation a multiple of 4 spaces (`bysl fmt --lines`).

const LINES_WHO = "bysl fmt --lines"

# The lines of the file `rel` (relative to the root), split on newlines only: a carriage
# return stays at the end of its line.
linesOf(rel) = split(read(in_root(rel), String), '\n'; keepempty = true)

"(file, line number, length) of every line over the limit in `files`."
function long_lines(files)
    found = Tuple{String,Int,Int}[]
    for f in files, (i, line) in enumerate(linesOf(f))
        n = char_count(chopsuffix(line, "\r"))
        n > LINE_LIMIT && push!(found, (f, i, n))
    end
    return found
end

"(file, line number) of every line holding a tab character (indent with 4 spaces)."
function tab_lines(files)
    found = Tuple{String,Int}[]
    for f in files, (i, line) in enumerate(linesOf(f))
        occursin('\t', line) && push!(found, (f, i))
    end
    return found
end

"""
    skewed_indent(lines, lang = :ts) -> Vector{Tuple{Int,Int}}

`(line number, leading spaces)` of every line of code whose indentation is not a multiple
of 4 spaces, for `lang` one of `:ts`, `:julia` or `:scss`. Every level of nesting is
exactly 4 spaces, a continuation line included (a ternary arm, a wrapped argument): write
it one level deeper, never half a level.

Not counted, because their offset is part of the text and not a level of nesting: blank
lines; comments and the lines of a block or doc comment (TypeScript and SCSS: ` *` lines
and `/* ... */`; Julia: `#` lines); the lines of a multi-line string (TypeScript template
literals, Julia `\"\"\"` strings and docstrings). In Julia also a line that continues an
expression after a trailing operator (`a ==`, `x *`, `&&`, `=`, `?`, `,` is not one),
because JuliaFormatter aligns it under the operand it continues and the check must not
fight the formatter.
"""
function skewed_indent(lines, lang::Symbol = :ts)::Vector{Tuple{Int,Int}}
    found = Tuple{Int,Int}[]
    in_comment = false
    in_string = false
    depth = 0                       # open brackets, Julia only
    floor = nothing                 # the depth where a continued expression began
    for (i, raw) in enumerate(lines)
        line = chopsuffix(raw, "\r")
        body = lstrip(line, ' ')
        lead = length(line) - length(body)
        comment_line =
            lang === :julia ? startswith(body, "#") :
            (startswith(body, "*") || startswith(body, "//"))
        counted =
            !isempty(body) && !in_comment && !in_string && !comment_line &&
            floor === nothing
        counted && lead % 4 != 0 && push!(found, (i, lead))
        # what this line opens or closes, for the lines after it
        if lang !== :julia
            if in_comment
                occursin("*/", body) && (in_comment = false)
            elseif startswith(body, "/*") && !occursin("*/", body)
                in_comment = true
            end
        end
        if lang === :ts
            # an odd number of unescaped backticks toggles a multi-line template literal
            ticks = count(==('`'), replace(body, "\\`" => ""))
            isodd(ticks) && (in_string = !in_string)
        elseif lang === :julia
            # an odd number of triple quotes toggles a multi-line string or docstring
            isodd(length(collect(eachmatch(r"\"\"\"", body)))) && (in_string = !in_string)
            if !(isempty(body) || comment_line || in_string)
                code = julia_code(body)
                ends_open = occursin(JULIA_CONTINUES, code)
                # a line that ends in an operator starts (or goes on with) an expression
                # continued on the next lines: JuliaFormatter aligns those under the
                # operand, so they are exempt until the brackets are back where they were
                ends_open && floor === nothing && (floor = depth)
                depth += count(c -> c in "([{", code) - count(c -> c in ")]}", code)
                !ends_open && floor !== nothing && depth <= floor && (floor = nothing)
            end
        end
    end
    return found
end

# A Julia code line that ends in an operator: the next line continues the expression.
const JULIA_CONTINUES = Regex(
    "(==|!=|<=|>=|&&|\\|\\||\\+|-|\\*|/|=|\\?|:|->|\\|>|<|>|\\^|%|\\\\" *
    "|\\bisa|\\bin|\\bfor|[≈≤≥≠∈∉∪∩⊆⊂])\\s*\$",
)

# The code of a Julia line for counting brackets and operators: strings and the comment
# at the end are cut out.
julia_code(body) = replace(replace(body, r"\"([^\"\\]|\\.)*\"" => "\"\""), r"\s#.*$" => "")

"(file, line number, leading spaces) of every skewed line in `files`."
function skewed_lines(files)
    found = Tuple{String,Int,Int}[]
    for f in files
        lang =
            endswith(f, ".ts") || endswith(f, ".tsx") ? :ts :
            endswith(f, ".jl") ? :julia : endswith(f, ".scss") ? :scss : nothing
        lang === nothing && continue
        for (i, lead) in skewed_indent(linesOf(f), lang)
            push!(found, (f, i, lead))
        end
    end
    return found
end

"Lists the lines over the limit, the tabs and the skewed indentation; true when none."
function check_lines(paths)::Bool
    files = reduce(vcat, code_files.(isempty(paths) ? [root()] : paths))
    too_long = long_lines(files)
    tabs = tab_lines(files)
    skewed = skewed_lines(files)
    for (f, i, n) in too_long
        println(f, ":", i, ": ", n, " characters")
    end
    for (f, i) in tabs
        println(f, ":", i, ": tab character (indent with 4 spaces)")
    end
    for (f, i, n) in skewed
        println(f, ":", i, ": indented by ", n, " spaces (a multiple of 4 is required)")
    end
    isempty(skewed) ||
        println(stderr, LINES_WHO, ": ", length(skewed), " line(s) whose indentation is ",
            "not a multiple of 4 spaces in ", length(unique(first.(skewed))), " file(s)")
    isempty(tabs) ||
        println(stderr, LINES_WHO, ": ", length(tabs), " line(s) with a tab character")
    isempty(too_long) ||
        println(stderr, LINES_WHO, ": ", length(too_long), " line(s) over ",
            LINE_LIMIT, " characters in ", length(unique(first.(too_long))),
            " file(s)")
    ok = isempty(too_long) && isempty(tabs) && isempty(skewed)
    ok && println("layout: ", length(files), " code files, no line over ",
        LINE_LIMIT, " characters, no tab character, indented in 4s")
    return ok
end

# --- the main program

const LANGUAGE_FLAGS =
    Dict("--julia" => :julia, "--ts" => :ts, "--scss" => :scss, "--py" => :py)

"""
    run(argv) -> Int

The tool's main program: the options and the paths.
"""
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
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
        "--julia, --ts, --scss, --py)",
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
    py_ok = !wanted(:py) || format_py(apply, paths)
    # whatever the mode and the language: the release name and the names of the settings
    # stay within their length caps
    version_ok = check_version_name()
    names_ok = check_parameter_names() & check_path_names()
    return all((header_ok, julia_ok, ts_ok, scss_ok, py_ok, version_ok, names_ok)) ? 0 : 1
end

end
