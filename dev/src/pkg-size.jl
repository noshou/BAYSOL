# SPDX-License-Identifier: LGPL-3.0-or-later

# `bysl pkg size`: where the bytes of a bundle are, and the opt-in reductions of the build
# (`BAYSOL_DEDUPE`, `BAYSOL_PY_PRUNE`, `BAYSOL_JULIA_PRUNE`, all off by default). Every
# reduction is a small function of a folder that returns what it removed and has a dry-run
# mode, so the tests run it on a temp tree. Included into `PkgTool`.

using SHA: sha256

"Files smaller than this are neither reported as duplicates nor linked (nothing to gain)."
const DEDUPE_MIN_BYTES = 4096

"The globs of the Python tools folder that `BAYSOL_PY_PRUNE=on` removes, one per line."
const PY_PRUNE_FILE = joinpath(@__DIR__, "..", "pytools-prune.txt")

"The size of a file or of a group in the report: `group`, `name` and `bytes`."
struct SizeRow
    group::String
    name::String
    bytes::Int
end

"""
The measured size of a bundle folder.

- `total`, `files`: bytes and number of files (links count as nothing).
- `components`, `kinds`, `largest`: by top-level component, by file kind, the largest
  files (name => bytes, biggest first).
- `artifacts`, `packages`: Julia artifact folders and depot package folders inside the
  bundle, by name.
- `unreferenced`, `judged`: artifact folders no `Artifacts.toml` of the bundle names
  (candidates only), and whether any `Artifacts.toml` was there to judge by.
- `python`: top-level Python packages of the frozen tools.
- `extras`: test, docs, examples, markdown, `.git` and licence files.
- `identical`, `differing`: duplicates (same name and content, wasted bytes) and files
  of one name with different content (report only).
- `archive`: the size of the compressed archive, `nothing` without one.
"""
struct SizeReport
    total::Int
    files::Int
    components::Vector{Pair{String,Int}}
    kinds::Vector{Pair{String,Int}}
    largest::Vector{Pair{String,Int}}
    artifacts::Vector{Pair{String,Int}}
    packages::Vector{Pair{String,Int}}
    unreferenced::Vector{Pair{String,Int}}
    judged::Bool
    python::Vector{Pair{String,Int}}
    extras::Vector{Pair{String,Int}}
    identical::Vector{NamedTuple}
    differing::Vector{NamedTuple}
    archive::Union{Int,Nothing}
end

"""
    bundle_files(dir) -> Vector{Pair{String,Int}}

The regular files below `dir` (links not followed, not counted) as `relative path => bytes`,
the path with `/` on every system.

# Returns
The pairs.

# Exceptions
`SystemError` when a folder cannot be read.
"""
function bundle_files(dir::AbstractString)::Vector{Pair{String,Int}}
    found = Pair{String,Int}[]
    for (d, _, names) in walkdir(dir), n in names
        p = joinpath(d, n)
        (islink(p) || !isfile(p)) && continue
        push!(found, replace(relpath(p, dir), '\\' => '/') => filesize(p))
    end
    return sort!(found; by = first)
end

"The top-level component of the bundle a file belongs to (by its path relative to it)."
function size_component(rel::AbstractString)::String
    base = basename(rel)
    startswith(base, "libLLVM") && return "libLLVM"
    startswith(rel, "lib/pytools/") && return "Python tools (lib/pytools)"
    base == exe("baysol") && return "baysol (Julia code, compiled in)"
    base == exe("baysol-tui") && return "Node and TUI (baysol-tui)"
    top = first(split(rel, '/'))
    top == "julia" && return "Julia runtime and JLL libraries (julia/)"
    top == "share" && return "artifact markers (share/)"
    occursin(r"\.dll$"i, base) && !occursin('/', rel) &&
        return "Julia runtime and JLL libraries (julia/)"
    return "other (launcher, icon, licence)"
end

"The kind of a file for the report: shared library, python, julia source, data, other."
function size_kind(rel::AbstractString)::String
    b = lowercase(basename(rel))
    occursin(r"\.(so(\.\d+)*|dylib|dll|pyd)$", b) && return "shared library"
    occursin(r"\.(py|pyc|pyi)$", b) && return "python (.py/.pyc/.pyi)"
    endswith(b, ".jl") && return "julia source (.jl)"
    occursin(r"\.(json|tsv|csv|7z|toml)$", b) && return "data (.json/.tsv/.7z/...)"
    b in lowercase.(exe.(["baysol", "baysol-tui", "baysol-pytools"])) && return "executable"
    return "other"
end

"The group of a file in the test, docs, examples, markdown, `.git` and licence list."
function size_extra(rel::AbstractString)::Union{String,Nothing}
    parts = split(rel, '/')
    dirs = parts[1:(end-1)]
    ".git" in dirs && return ".git"
    any(in(("test", "tests")), dirs) && return "test and tests folders"
    any(in(("docs", "doc")), dirs) && return "docs folders"
    any(in(("examples", "example")), dirs) && return "examples folders"
    endswith(lowercase(parts[end]), ".md") && return "*.md files"
    occursin(r"^(licen[cs]e|copying|notice|authors)"i, parts[end]) && return "licence files"
    return nothing
end

# bytes by key, biggest first (ties by name)
function _grouped(files, key)::Vector{Pair{String,Int}}
    sums = Dict{String,Int}()
    for (rel, n) in files
        k = key(rel)
        k === nothing || (sums[k] = get(sums, k, 0) + n)
    end
    return sort!(collect(sums); by = p -> (-last(p), first(p)))
end

# the hex SHA-256 of a file, streamed
file_sha(path::AbstractString)::String = open(io -> bytes2hex(sha256(io)), path)

# the tables of the hashes of the Artifacts.toml files below `dir` => "package: name"
function artifact_references(dir::AbstractString)::Dict{String,String}
    refs = Dict{String,String}()
    for (d, _, names) in walkdir(dir), n in names
        n in ("Artifacts.toml", "JuliaArtifacts.toml") || continue
        at = replace(relpath(d, dir) * "/", '\\' => '/')
        pkg = match(r"packages/([^/]+)/", at)
        owner = pkg === nothing ? basename(abspath(d)) : String(pkg[1])
        name = ""
        for line in eachline(joinpath(d, n))
            if (m = match(r"^\s*\[\[?\s*\"?([^\]\"]+)\"?\s*\]\]?\s*$", line)) !== nothing
                name = m[1]
            elseif (m = match(r"git-tree-sha1\s*=\s*\"([0-9a-fA-F]{40})\"", line)) !==
                   nothing
                refs[lowercase(m[1])] = "$owner: $name"
            end
        end
    end
    return refs
end

"""
    artifact_candidates(dir, files = bundle_files(dir)) -> NamedTuple

The folders `artifacts/<hash>` below `dir` that no `Artifacts.toml` below `dir` names.
They are only candidates: nothing is removed, and the packaged `baysol` opens its
libraries by name (the folders hold a marker), so the bundle usually has no
`Artifacts.toml` to judge by.

# Returns
`(candidates, judged)`: `candidates` as `hash => bytes`, `judged` false when no
`Artifacts.toml` was found (then `candidates` is empty).

# Exceptions
None.
"""
function artifact_candidates(dir::AbstractString, files = bundle_files(dir))
    refs = artifact_references(dir)
    isempty(refs) && return (; candidates = Pair{String,Int}[], judged = false)
    sums = _grouped(
        files,
        rel -> begin
            m = match(r"(?:^|/)artifacts/([^/]+)/", rel)
            m === nothing || lowercase(m[1]) in keys(refs) ? nothing : String(m[1])
        end,
    )
    return (; candidates = sums, judged = true)
end

"""
    size_duplicates(dir, files; min_bytes = DEDUPE_MIN_BYTES) -> NamedTuple

The files of `files` (from `bundle_files`) of one base name, at least `min_bytes` big,
grouped by SHA-256 (hashed only when another file of the name has the same size).

# Returns
`(identical, differing)`: `identical` has one entry per set of byte-identical copies
(`name`, `bytes`, `copies`, `wasted`, `paths`), biggest waste first; `differing` has one
entry per name with more than one content (`name`, `copies`, `variants`, `bytes`,
`paths`), report only.

# Exceptions
`SystemError` when a file cannot be read.
"""
function size_duplicates(dir, files; min_bytes = DEDUPE_MIN_BYTES)
    byname = Dict{String,Vector{Pair{String,Int}}}()
    for f in files
        last(f) >= min_bytes && push!(get!(byname, basename(first(f)), []), f)
    end
    identical = NamedTuple[]
    differing = NamedTuple[]
    for (name, fs) in byname
        length(fs) > 1 || continue
        sizes = last.(fs)
        groups = Dict{Tuple{Int,String},Vector{String}}()
        for (rel, n) in fs
            sha = count(==(n), sizes) > 1 ? file_sha(joinpath(dir, rel)) : ""
            push!(get!(groups, (n, sha), String[]), rel)
        end
        length(groups) > 1 && push!(differing,
            (; name, copies = length(fs), variants = length(groups),
                bytes = sum(sizes), paths = sort!(first.(fs))))
        for ((n, _), paths) in groups
            length(paths) > 1 || continue
            push!(identical,
                (; name, bytes = n, copies = length(paths),
                    wasted = n * (length(paths) - 1), paths = sort(paths)))
        end
    end
    sort!(identical; by = d -> (-d.wasted, d.name, d.paths[1]))
    sort!(differing; by = d -> (-d.bytes, d.name))
    return (; identical, differing)
end

"""
    size_report(dir; archive = nothing, limit = 30) -> SizeReport

Walks the bundle folder `dir` and measures it: per component, per file kind, the `limit`
largest files, the Julia artifacts and depot packages in it, the Python packages of the
frozen tools, the test/docs/example/licence folders, and the duplicates. `archive` is the
compressed archive, measured when the file exists.

# Returns
The [`SizeReport`](@ref).

# Exceptions
A `ToolError` when `dir` is not a folder; `SystemError` when something cannot be read.
"""
function size_report(dir::AbstractString; archive = nothing, limit::Int = 30)::SizeReport
    isdir(dir) || fail(WHO, "$dir is not a folder")
    files = bundle_files(dir)
    inpy(rel) = begin
        m = match(r"(?:^|/)site-packages/([^/]+)", rel)
        m !== nothing && return String(m[1])
        startswith(rel, "lib/pytools/") || return nothing
        parts = split(rel, '/')
        return length(parts) > 3 ? String(parts[3]) : "(files in lib/pytools)"
    end
    cand = artifact_candidates(dir, files)
    dups = size_duplicates(dir, files)
    refs = artifact_references(dir)
    artifact(rel) = begin
        m = match(r"(?:^|/)artifacts/([^/]+)/", rel)
        m === nothing ? nothing :
        "artifacts/" * m[1] *
        (haskey(refs, lowercase(m[1])) ? " (" * refs[lowercase(m[1])] * ")" : "")
    end
    package(rel) = begin
        m = match(r"(?:^|/)packages/([^/]+)/[^/]+/", rel)
        m === nothing ? nothing : String(m[1])
    end
    largest = sort(files; by = f -> (-last(f), first(f)))[1:min(limit, length(files))]
    return SizeReport(
        sum(last.(files); init = 0), length(files),
        _grouped(files, size_component), _grouped(files, size_kind), largest,
        _grouped(files, artifact), _grouped(files, package), cand.candidates, cand.judged,
        _grouped(files, rel -> inpy(rel)), _grouped(files, size_extra),
        dups.identical, dups.differing,
        archive !== nothing && isfile(archive) ? filesize(archive) : nothing,
    )
end

_mib(b) = round(b / 2^20; digits = 1)

"""
    size_log_rows(r; archive = r.archive) -> Vector{SizeRow}

The report as the rows of the `--- size ---` block of the build log
(`group<TAB>name<TAB>bytes`): `total`, `archive`, `component`, `kind`,
`largest`, `artifact`, `package`, `unreferencedArtifact`, `pyPackage`,
`extra`, `duplicateIdentical` (bytes wasted) and `duplicateSameName`.

# Returns
The rows.

# Exceptions
None.
"""
function size_log_rows(r::SizeReport; archive = r.archive)::Vector{SizeRow}
    rows = SizeRow[SizeRow("total", "bundle", r.total)]
    archive === nothing || push!(rows, SizeRow("archive", "compressed", archive))
    add(group, pairs) =
        for (n, b) in pairs
            push!(rows, SizeRow(group, n, b))
        end
    add("component", r.components)
    add("kind", r.kinds)
    add("largest", r.largest)
    add("artifact", r.artifacts)
    add("package", r.packages)
    add("unreferencedArtifact", r.unreferenced)
    add("pyPackage", r.python)
    add("extra", r.extras)
    paths(d) = d.name * " x" * string(d.copies) * ": " * join(first(d.paths, 3), " ; ")
    add("duplicateIdentical", [paths(d) => d.wasted for d in first(r.identical, 40)])
    add("duplicateSameName", [paths(d) => d.bytes for d in first(r.differing, 40)])
    return rows
end

"""
    parse_size_row(line) -> Union{SizeRow,Nothing}

Reads one `group<TAB>name<TAB>bytes` line of a `--- size ---` block; `nothing` for any
other line, so an older or newer log still reads.

# Returns
The row or `nothing`.

# Exceptions
None.
"""
function parse_size_row(line::AbstractString)::Union{SizeRow,Nothing}
    parts = split(line, '\t')
    length(parts) == 3 || return nothing
    n = tryparse(Int, parts[3])
    return n === nothing ? nothing : SizeRow(parts[1], parts[2], n)
end

"""
    format_size_report(r; limit = 15) -> Vector{String}

The human table of a report: every group with its sizes in MiB (at most `limit` lines
each, except the components and kinds).

# Returns
The lines.

# Exceptions
None.
"""
function format_size_report(r::SizeReport; limit::Int = 15)::Vector{String}
    out = String["bundle: $(_mib(r.total)) MiB in $(r.files) files"]
    share =
        r.archive === nothing ? 0.0 : round(100 * r.archive / max(r.total, 1); digits = 1)
    r.archive === nothing ||
        push!(out, "archive: $(_mib(r.archive)) MiB compressed ($share % of the bundle)")
    function table(title, pairs; all = false, none = "none")
        push!(out, "", title)
        isempty(pairs) && return push!(out, "  ($none)")
        for (n, b) in (all ? pairs : first(pairs, limit))
            push!(out, "  " * lpad(string(_mib(b)), 10) * " MiB  " * n)
        end
        all || length(pairs) <= limit || push!(out, "  ... $(length(pairs) - limit) more")
    end
    table("by component", r.components; all = true)
    table("by file kind", r.kinds; all = true)
    table("largest files", r.largest; all = true)
    table("Julia artifacts (folders artifacts/<hash>)", r.artifacts)
    table("Julia depot packages (packages/<Name>)", r.packages)
    table(
        "artifact folders no Artifacts.toml names" *
        (
            r.judged ? " (candidates only)" :
            " (no Artifacts.toml in the bundle: not judged)"
        ),
        r.unreferenced,
    )
    table("Python packages of the frozen tools", r.python)
    table("tests, docs, examples, markdown, .git, licences", r.extras; all = true)
    table("identical duplicates (wasted bytes = size x (copies - 1))",
        [d.name * " x" * string(d.copies) => d.wasted for d in r.identical])
    table("same name, different content (report only)",
        [
            d.name * " x" * string(d.copies) * ", " * string(d.variants) * " variants" =>
                d.bytes for d in r.differing
        ])
    return out
end

"""
    size_command(argv) -> Int

`bysl pkg size DIR [--archive FILE] [--dry-run]`: prints the size report of the bundle
folder `DIR`; with `--archive` also the compressed size. `--dry-run` additionally prints
what the three reductions would remove from `DIR` (all of them, whatever the environment
says); nothing is changed.

# Returns
The exit status.

# Exceptions
`ToolError` (through `fail`) for a missing folder or argument.
"""
function size_command(argv::Vector{String})::Int
    a = split_args(WHO, ["--archive"], ["--dry-run"], argv)
    length(a.specs) == 1 || fail(WHO, "size needs one bundle folder")
    dir = abspath(a.specs[1])
    opts = Dict(a.opts)
    r = size_report(dir; archive = get(opts, "--archive", nothing))
    foreach(println, format_size_report(r))
    if "--dry-run" in a.flags
        println("\nreductions (dry run, nothing is changed)")
        for (k, v) in reduce_prune(dir; dry = true, force = true)
            println("  ", rpad(k, 12), v)
        end
        for (k, v) in reduce_dedupe(dir; dry = true, force = true)
            println("  ", rpad(k, 12), v)
        end
    end
    return 0
end

# --- the reductions

"""
    reduction_mode(name, allowed; env = ENV) -> String

The value of the environment variable `name`, lower case; unset or empty is `"off"`.

# Returns
The value, one of `allowed` (which holds `"off"`).

# Exceptions
A `ToolError` for any other value.
"""
function reduction_mode(name::AbstractString, allowed; env = ENV)::String
    v = lowercase(strip(get(env, name, "")))
    isempty(v) && return "off"
    v in allowed || fail(WHO, "$name=$v: use one of " * join(allowed, ", "))
    return String(v)
end

"""
    glob_regex(glob) -> Tuple{Regex,Bool}

A glob of `dev/pytools-prune.txt` as a regular expression over the path relative to the
tools folder (with `/`), and whether it names folders (a trailing `/`). `**/` is any
number of folders (also none), `**` anything, `*` anything but `/`, `?` one character.

# Returns
`(regex, folders)`.

# Exceptions
None.
"""
function glob_regex(glob::AbstractString)::Tuple{Regex,Bool}
    folders = endswith(glob, "/")
    g = collect(rstrip(glob, '/'))
    b = IOBuffer()
    print(b, "^")
    i = 1
    while i <= length(g)
        if g[i] == '*' && i + 2 <= length(g) && g[i+1] == '*' && g[i+2] == '/'
            print(b, "(?:.*/)?")
            i += 3
        elseif g[i] == '*' && i < length(g) && g[i+1] == '*'
            print(b, ".*")
            i += 2
        elseif g[i] == '*'
            print(b, "[^/]*")
            i += 1
        elseif g[i] == '?'
            print(b, "[^/]")
            i += 1
        else
            print(b, replace(string(g[i]), r"([\\^$.|+()\[\]{}])" => s"\\\1"))
            i += 1
        end
    end
    print(b, "\$")
    return (Regex(String(take!(b))), folders)
end

"""
    load_prune_globs(path) -> Vector{String}

The globs of the prune list: one per line, `glob  # why it is safe`; blank lines and
lines starting with `#` are comments.

# Returns
The globs.

# Exceptions
A `ToolError` for a glob line without a reason.
"""
function load_prune_globs(path::AbstractString)::Vector{String}
    globs = String[]
    for (i, raw) in enumerate(eachline(path))
        line = strip(raw)
        (isempty(line) || startswith(line, '#')) && continue
        m = match(r"^(\S+)\s+#\s*(\S.*)$", line)
        m === nothing && fail(WHO, "$path:$i: a glob needs a `# reason` on its line")
        push!(globs, String(m[1]))
    end
    return globs
end

# the bytes below a path (a file: its size; a link: nothing)
function _bytes(path)
    islink(path) && return 0
    isfile(path) && return filesize(path)
    return sum((last(f) for f in bundle_files(path)); init = 0)
end

"""
    prune_python(dir; globs, dry = false) -> NamedTuple

Removes from `dir` (the copy of the frozen Python tools in the bundle) every file and
folder that one of `globs` names (see [`glob_regex`](@ref)): nothing the tools import at
run time, by the reasons in `dev/pytools-prune.txt`. `dry` only lists.

# Returns
`(removed, freed)`: the relative paths and the bytes (freed, or that would be).

# Exceptions
None.
"""
function prune_python(dir::AbstractString; globs, dry::Bool = false)
    rules = glob_regex.(globs)
    removed = String[]
    freed = 0
    function scan(rel)
        here = isempty(rel) ? dir : joinpath(dir, rel)
        for name in sort(readdir(here))
            childrel = isempty(rel) ? name : rel * "/" * name
            path = joinpath(dir, childrel)
            isdir_real = isdir(path) && !islink(path)
            hit = any(r -> r[2] == isdir_real && occursin(r[1], childrel), rules)
            if hit
                push!(removed, childrel)
                freed += _bytes(path)
                dry || rm(path; recursive = true, force = true)
            elseif isdir_real
                scan(childrel)
            end
        end
    end
    isdir(dir) && scan("")
    return (; removed, freed)
end

"The removable source files of a package's `deps/` (the built `deps.jl` and binaries stay)."
const JULIA_DEPS_SOURCES = Regex(
    "(\\.(c|h|cc|cpp|cxx|hpp|f|f90|patch|tar|gz|tgz|zip|cmake|sh|mk|in)|" *
    "^(build\\.jl|Makefile|CMakeLists\\.txt))\$",
)

"""
    julia_package_roots(dir) -> Vector{String}

The package folders `packages/<Name>/<slug>` of a Julia depot below `dir` (a folder with
a `Project.toml`).

# Returns
The absolute paths, sorted.

# Exceptions
None.
"""
function julia_package_roots(dir::AbstractString)::Vector{String}
    roots = String[]
    for (d, _, _) in walkdir(dir)
        parts = splitpath(relpath(d, dir))
        length(parts) >= 3 && parts[end-2] == "packages" || continue
        (isfile(joinpath(d, "Project.toml")) || isfile(joinpath(d, "JuliaProject.toml"))) &&
            push!(roots, d)
    end
    return sort!(roots)
end

"""
    prune_julia(dir; dry = false) -> NamedTuple

Removes from every package of the depot below `dir`: its `test/` and `docs/`
folders, the `*.md` files outside `src/`, and the build sources of `deps/`
([`JULIA_DEPS_SOURCES`](@ref)). Never `src/`, the `Project.toml`,
`Manifest.toml` or `Artifacts.toml`, the artifacts, nor `deps/deps.jl`. A juliac
executable carries its packages' code and reads none of this; `dry` only lists.

# Returns
`(removed, freed)`: the paths relative to `dir` and the bytes.

# Exceptions
None.
"""
function prune_julia(dir::AbstractString; dry::Bool = false)
    removed = String[]
    freed = 0
    drop!(path) = begin
        push!(removed, replace(relpath(path, dir), '\\' => '/'))
        freed += _bytes(path)
        dry || rm(path; recursive = true, force = true)
    end
    for root in julia_package_roots(dir)
        for sub in ("test", "docs")
            p = joinpath(root, sub)
            isdir(p) && !islink(p) && drop!(p)
        end
        for (d, dirs, names) in walkdir(root)
            rel = relpath(d, root)
            (rel == "src" || startswith(rel, "src" * Base.Filesystem.path_separator)) &&
                continue
            isdir(d) || continue    # a folder removed above
            for n in names
                p = joinpath(d, n)
                islink(p) && continue
                top = first(splitpath(rel == "." ? n : rel))
                isdeps = top == "deps"
                if endswith(lowercase(n), ".md") ||
                   (isdeps && occursin(JULIA_DEPS_SOURCES, n))
                    drop!(p)
                end
            end
        end
    end
    return (; removed, freed)
end

"""
    dedupe_identical(dir; dry, os, exes, installname, min_bytes) -> NamedTuple

Replaces byte-identical files of the same base name (same SHA-256 and size, at least
`min_bytes`) by relative symbolic links to the copy with the shortest path. Never the
main executables (`exes` and the three of the bundle), nothing inside a `.app` folder,
and on macOS no library whose install name (`installname(path)`) differs from its file
name: those are listed in `skipped`. On Windows nothing is linked: the result only
reports. `dry` reports without linking. A link is written beside the file and renamed
over it, so a file is never missing; a failed link leaves the file.

# Returns
`(mode, freed, items, skipped)`: `mode` is `:linked`, `:dry` or `:report`; `items` are
`path => target` (relative); `skipped` are `path => reason`.

# Exceptions
None.
"""
function dedupe_identical(
    dir::AbstractString;
    dry::Bool = false,
    os::Symbol = this_os(),
    exes = String[],
    installname = nothing,
    min_bytes::Int = DEDUPE_MIN_BYTES,
)
    protect = Set(replace(relpath(abspath(e), abspath(dir)), '\\' => '/') for e in exes)
    mains = Set(exe.(["baysol", "baysol-tui", "baysol-pytools"]))
    skipped = Pair{String,String}[]
    cands = Pair{String,Int}[]
    for (rel, n) in bundle_files(dir)
        n >= min_bytes || continue
        if rel in protect || basename(rel) in mains
            continue
        elseif any(p -> endswith(p, ".app"), split(rel, '/'))
            push!(skipped, rel => "inside a .app folder (signature scope)")
            continue
        elseif os === :macos && installname !== nothing
            id = installname(joinpath(dir, rel))
            if id !== nothing && basename(id) != basename(rel)
                push!(skipped, rel => "install name $id differs from the file name")
                continue
            end
        end
        push!(cands, rel => n)
    end
    mode = os === :windows ? :report : dry ? :dry : :linked
    items = Pair{String,String}[]
    freed = 0
    groups = Dict{Tuple{String,Int},Vector{String}}()
    for (rel, n) in cands
        push!(get!(groups, (basename(rel), n), String[]), rel)
    end
    for ((_, n), paths) in sort!(collect(groups); by = g -> g[1])
        length(paths) > 1 || continue
        bysha = Dict{String,Vector{String}}()
        for p in paths
            push!(get!(bysha, file_sha(joinpath(dir, p)), String[]), p)
        end
        for same in values(bysha)
            length(same) > 1 || continue
            sort!(same; by = p -> (count('/', p), p))
            keeper = same[1]
            for p in same[2:end]
                if mode === :linked
                    path = joinpath(dir, p)
                    tmp = path * ".dedupe"
                    try
                        symlink(relpath(joinpath(dir, keeper), dirname(path)), tmp)
                        mv(tmp, path; force = true)
                    catch e
                        rm(tmp; force = true)
                        push!(skipped, p => "link failed: " * sprint(showerror, e))
                        continue
                    end
                end
                push!(items, p => keeper)
                freed += n
            end
        end
    end
    sort!(items; by = first)
    return (; mode, freed, items, skipped)
end

# the first lines of a list of removed paths, for the report
function _show(title, paths; limit = 40)
    isempty(paths) && return
    println(title)
    for p in first(paths, limit)
        println("  ", p)
    end
    length(paths) > limit && println("  ... $(length(paths) - limit) more")
end

"""
    reduce_prune(out; env = ENV, dry = false, force = false, globs_file = PY_PRUNE_FILE)

Runs the removals chosen by `BAYSOL_PY_PRUNE=on` ([`prune_python`](@ref) on
`lib/pytools`) and `BAYSOL_JULIA_PRUNE=on` ([`prune_julia`](@ref) on `share/julia`) on the
bundle folder `out`; `force` takes both as on. With `dry` it prints what it would remove.

# Returns
The log rows `pyPrune` and `juliaPrune` as `name => value` (`off`, or the counts and MiB).

# Exceptions
A `ToolError` for a bad value of a variable or a prune list line without a reason.
"""
function reduce_prune(
    out;
    env = ENV,
    dry = false,
    force = false,
    globs_file = PY_PRUNE_FILE,
)
    rows = Pair{String,String}[]
    text(r) =
        (dry ? "dry run: would remove " : "on: removed ") *
        "$(length(r.removed)) paths, $(_mib(r.freed)) MiB"
    py = force ? "on" : reduction_mode("BAYSOL_PY_PRUNE", ("off", "on"); env)
    if py == "on"
        r = prune_python(joinpath(out, "lib", "pytools");
            globs = load_prune_globs(globs_file), dry)
        dry && _show("python tools:", r.removed)
        push!(rows, "pyPrune" => text(r))
    else
        push!(rows, "pyPrune" => "off")
    end
    jl = force ? "on" : reduction_mode("BAYSOL_JULIA_PRUNE", ("off", "on"); env)
    if jl == "on"
        r = prune_julia(joinpath(out, "share", "julia"); dry)
        dry && _show("julia depot:", r.removed)
        push!(rows, "juliaPrune" => text(r))
    else
        push!(rows, "juliaPrune" => "off")
    end
    return rows
end

"""
    reduce_dedupe(out; env = ENV, dry = false, force = false, os, exes, installname)

Runs [`dedupe_identical`](@ref) on the bundle folder `out` when `BAYSOL_DEDUPE=identical`
(`force`: always). With `dry` it prints the links it would make, and on Windows it only
reports.

# Returns
The log row `dedupe` as `name => value`.

# Exceptions
A `ToolError` for a bad value of the variable.
"""
function reduce_dedupe(
    out;
    env = ENV,
    dry = false,
    force = false,
    os = this_os(),
    exes = String[],
    installname = nothing,
)
    mode = force ? "identical" : reduction_mode("BAYSOL_DEDUPE", ("off", "identical"); env)
    mode == "off" && return ["dedupe" => "off"]
    r = dedupe_identical(out; dry, os, exes, installname)
    (dry || r.mode === :report) && _show("identical copies:",
        [p * " -> " * t for (p, t) in r.items])
    _show("not touched:", [p * ": " * why for (p, why) in r.skipped])
    verb =
        r.mode === :linked ? "linked" :
        r.mode === :dry ? "dry run: would link" :
        "report only (no links on Windows): would link"
    return [
        "dedupe" =>
            "identical, $verb $(length(r.items)) files, $(_mib(r.freed)) MiB, " *
            "$(length(r.skipped)) not touched",
    ]
end

# --- the build

"The log rows of the reductions of this build (empty when the bundle stage did not run)."
const SIZE_ROWS = Pair{String,String}[]

"The size report of the bundle of this build, `nothing` before the size step."
const SIZE_REPORT = Ref{Union{Nothing,SizeReport}}(nothing)

"""
Stage `bundle`, before the strip: the prunes chosen
by the environment; their rows go to the log.
"""
function size_prune!(out)
    empty!(SIZE_ROWS)
    SIZE_REPORT[] = nothing
    for (k, v) in reduce_prune(out)
        push!(SIZE_ROWS, k => v)
        note("  $k: $v")
    end
    return nothing
end

"""
Stage `bundle`, after the strip and before the
signing: the dedupe chosen by the environment.
"""
function size_dedupe!(out, exes)
    for (k, v) in
        reduce_dedupe(out; exes, installname = Platform.ismacos() ? install_name : nothing)
        push!(SIZE_ROWS, k => v)
        note("  $k: $v")
    end
    return nothing
end

"Whether the build ran any reduction (a row that is not `off`)."
reductions_active() = any(p -> last(p) != "off", SIZE_ROWS)

"""
    smoke_pytools(bundle; timeout = 60) -> Bool

Starts the frozen tools of the bundle with `propka3 --help` and `pdb2pqr --help`: the
check after a reduction that touched them (the entry point imports each tool's package
only when asked for it).

# Returns
True when both answered with status 0 and some text.

# Exceptions
A `ToolError` naming the tool and what it printed when one does not.
"""
function smoke_pytools(bundle::AbstractString; timeout::Real = 60)::Bool
    program = joinpath(bundle, "lib", "pytools", exe("baysol-pytools"))
    need(isfile(program), "the frozen tools are missing: $program")
    for tool in ("propka3", "pdb2pqr")
        ok, text = smoke_run(`$program $tool --help`; timeout)
        need(ok && !isempty(strip(text)),
            "the frozen tool $tool does not start (`$tool --help`): $(strip(text))",
        )
    end
    return true
end

"""
    size_steps(work) -> Bool

The steps after the bundle and its smoke test: measures the bundle folder (stored for the
build log; a failure to measure is reported, never fails the build), and, when a reduction
ran, starts the frozen Python tools ([`smoke_pytools`](@ref)).

# Returns
False when the tools smoke test failed.

# Exceptions
None.
"""
function size_steps(work::AbstractString)::Bool
    bundle = joinpath(work, "bundle", "baysol")
    step("size (bundle)",
        () -> begin
            try
                r = size_report(bundle)
                SIZE_REPORT[] = r
                println("bundle $(_mib(r.total)) MiB in $(r.files) files")
            catch e
                println("size report failed: ", sprint(showerror, e))
            end
            true
        end; top = true)
    reductions_active() || return true
    return step("smoke (frozen tools)", () -> smoke_pytools(bundle); top = true)
end

"""
    size_header_rows(archive) -> Vector{Pair{String,String}}

The rows next to `juliacStrip` in the build log: `bundleBytes` and `archiveBytes` (when the
archive exists) and the reductions of the build (`dedupe`, `pyPrune`, `juliaPrune`, or
`unknown` when the bundle stage did not run in this invocation).

# Returns
The rows.

# Exceptions
None.
"""
function size_header_rows(archive::AbstractString)::Vector{Pair{String,String}}
    r = SIZE_REPORT[]
    rows = Pair{String,String}["bundleBytes"=>r===nothing ? "unknown" : string(r.total)]
    isfile(archive) && push!(rows, "archiveBytes" => string(filesize(archive)))
    known = Dict(SIZE_ROWS)
    for k in ("dedupe", "pyPrune", "juliaPrune")
        push!(rows, k => get(known, k, "unknown"))
    end
    return rows
end

"""
    size_block_lines(archive) -> Vector{String}

The `--- size ---` block of the build log (empty without a report): one
`group<TAB>name<TAB>bytes` line per [`SizeRow`](@ref), the compressed archive among them.

# Returns
The lines.

# Exceptions
None.
"""
function size_block_lines(archive::AbstractString)::Vector{String}
    r = SIZE_REPORT[]
    r === nothing && return String[]
    rows = size_log_rows(r; archive = isfile(archive) ? filesize(archive) : nothing)
    return vcat(["", "--- size ---"], ["$(x.group)\t$(x.name)\t$(x.bytes)" for x in rows])
end
