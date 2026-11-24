# SPDX-License-Identifier: LGPL-3.0-or-later

# Fixture archives: for an "archive set", a root folder holding one `<name>.7z` per item
# next to the item's plain folder `<name>/` (test/fixtures/experiments, .../synthetic, or
# any directory given as `--root`). A plain file, not part of the module `Dev`, because
# `fit-seed.jl` (included by scripts that run without `Dev`) needs the same resolver as
# the tool `bysl fixtures` and `bysl fits run`; it uses nothing but Base and `7z`.
#
# Archive layout: every entry path starts with `<name>/` (the archive of SASDMJ9 holds
# `SASDMJ9/SASDMJ9_fit1.fit`, ...), so `7z x -o<tmp root> <name>.7z` yields
# `<tmp root>/<name>/`. A flat archive (`pack(...; flat = true)`) holds the files of the
# item directly (`<name>.7z` with `a.dat`, `b.pdb`); unpacking puts them in `<name>/`
# too, and the layout is detected from the entry list.
#
# Unpacked copies live in the set's tmp root (`tmp_root(set)`): `<name>/` plus a stamp
# `<name>.stamp` (archive size and mtime) written after the folder is complete. A folder
# without a matching stamp is incomplete and is unpacked again.
# `fit-seed.jl` includes this file outside `Dev`, so it brings the system module itself.
isdefined(@__MODULE__, :Platform) ||
    include(joinpath(@__DIR__, "..", "..", "platform.jl"))

module FixtureStore

using ..Platform: Platform

const REPO = normpath(joinpath(@__DIR__, "..", ".."))

# The registry of named sets: name => root folder of the archives.
const SETS = [
    "experiments" => joinpath(REPO, "test", "fixtures", "experiments"),
    "synthetic" => joinpath(REPO, "test", "fixtures", "synthetic"),
]
# (test/fixtures/molecules holds loose files, not one folder per item: not a set; use
# `--root` with `--flat` for any folder that is organised per item.)

const EXPERIMENTS = last(SETS[1])

# the marker that makes a folder the tool's own tmp root (`clean` refuses without it)
const MARKER = ".baysol-fixtures"

# 7z a: 7z format, LZMA2, maximum level, solid, 64 MiB dictionary
const PACK_ARGS = ["-t7z", "-m0=lzma2", "-mx=9", "-md=64m", "-ms=on", "-bso0", "-bsp0"]

"The names of the registered sets."
set_names()::Vector{String} = first.(SETS)

"The archive root of the registered set `set`; an error for an unknown name."
function set_dir(set::AbstractString)::String
    i = findfirst(p -> first(p) == set, SETS)
    i === nothing &&
        error("unknown fixture set $set (registered: $(join(set_names(), ", ")))")
    return last(SETS[i])
end

"""
The environment variable that names the tmp root of `set`: `BAYSOL_FIXTURES` for
`experiments` (kept for the fitting scripts), else `BAYSOL_FIXTURES_<SET>` upper case with
every character other than a letter or digit as `_`.
"""
env_var(set::AbstractString)::String =
    set == "experiments" ? "BAYSOL_FIXTURES" :
    "BAYSOL_FIXTURES_" * uppercase(replace(String(set), r"[^A-Za-z0-9]" => "_"))

"""
The folder of the unpacked fixtures of `set`:
`\$(env_var(set))`, else `fixtures/<set>` in the general cache (`Platform.default_cache()`:
`_cache` in the caches folder of the system, see `Platform.cache_dir`).
"""
tmp_root(set::AbstractString = "experiments")::String = abspath(
    get(ENV, env_var(set),
        joinpath(Platform.default_cache(), "fixtures", String(set))),
)

"The archive of the item `id` in the root `base`."
archive_path(id::AbstractString, base = EXPERIMENTS) = joinpath(base, string(id, ".7z"))

"The plain folder of the item `id` in the root `base`."
plain_dir(id::AbstractString, base = EXPERIMENTS) = joinpath(base, String(id))

"""
The items of `base`: every `<name>.7z` and every folder, sorted, without duplicates.
"""
function entry_ids(base = EXPERIMENTS)::Vector{String}
    isdir(base) || return String[]
    names = String[]
    for n in readdir(base)
        p = joinpath(base, n)
        isdir(p) && push!(names, n)
        endswith(n, ".7z") && isfile(p) && push!(names, n[1:(end-3)])
    end
    return sort!(unique!(names))
end

# --- 7z

function _sevenzip()::String
    exe = Platform.find_tool("7z", "7zz")
    exe === nothing &&
        error("7z (7-Zip) is not on the PATH nor in the folders installers use for it")
    return exe
end

# The files (not folders) of the plain folder, as `<id>/<relative path>` with `/`
# (without the `<id>/` when `flat`).
function _folder_entries(id, root; flat = false)::Vector{String}
    base = plain_dir(id, root)
    out = String[]
    for (dir, _, files) in walkdir(base)
        for f in files
            rel = relpath(joinpath(dir, f), base)
            push!(out, string(flat ? "" : string(id, "/"), replace(rel, '\\' => '/')))
        end
    end
    return sort!(out)
end

"The file entries of an archive, as 7z lists them (`<id>/...`, sorted)."
function archive_entries(archive::AbstractString)::Vector{String}
    text = read(`$(_sevenzip()) l -slt -ba $archive`, String)
    out = String[]
    for block in split(text, r"\r?\n\r?\n")
        path = nothing
        folder = false
        for line in split(block, r"\r?\n")
            startswith(line, "Path = ") && (path = line[8:end])
            startswith(line, "Attributes = D") && (folder = true)
        end
        path === nothing || folder || push!(out, replace(path, '\\' => '/'))
    end
    return sort!(out)
end

"True when the archive passes `7z t`."
_tests_ok(archive) = success(pipeline(`$(_sevenzip()) t $archive`; stdout = devnull))

# --- pack

"""
    archive_fresh(id, base = EXPERIMENTS) -> Bool

True when the archive exists and is newer than every file of the plain folder (a missing
plain folder counts as fresh: the archive is then the only copy).
"""
function archive_fresh(id, base = EXPERIMENTS)::Bool
    arc = archive_path(id, base)
    isfile(arc) || return false
    isdir(plain_dir(id, base)) || return true
    stamp = mtime(arc)
    for (dir, _, files) in walkdir(plain_dir(id, base))
        for f in files
            mtime(joinpath(dir, f)) > stamp && return false
        end
    end
    return true
end

"""
    bytes_match(id; flat = false, base = EXPERIMENTS) -> Bool

True when extracting `<id>.7z` into a scratch folder gives exactly the files of the plain
folder, byte for byte (the scratch copy is removed again).
"""
function bytes_match(id::AbstractString; flat::Bool = false, base = EXPERIMENTS)::Bool
    arc = archive_path(id, base)
    dir = plain_dir(id, base)
    isfile(arc) && isdir(dir) || return false
    scratch = mktempdir()
    try
        success(
            pipeline(`$(_sevenzip()) x -y $(string("-o", scratch)) $arc`;
                stdout = devnull),
        ) || return false
        copy = flat ? scratch : joinpath(scratch, id)
        want = _folder_files(dir)
        want == _folder_files(copy) || return false
        return all(f -> read(joinpath(dir, f)) == read(joinpath(copy, f)), want)
    finally
        rm(scratch; recursive = true, force = true)
    end
end

# The files of a folder, relative to it, sorted.
_folder_files(dir) = sort!([
    relpath(joinpath(d, f), dir) for (d, _, fs) in walkdir(dir) for f in fs
])

"""
    pack(id; force = false, flat = false, keep_source = false, base = EXPERIMENTS) -> Symbol

Packs the plain folder of `id` into `<id>.7z` (written under a temporary name, verified with
`7z t` and by comparing its entry list with the folder's files, then moved into place).
`:skipped` when the archive is fresh and `force` is false, else `:packed`. An error when
there is no folder or the verification fails (the old archive is then untouched).

Unless `keep_source`, the plain folder is removed afterwards, but only once
[`bytes_match`](@ref) has shown that the archive extracts to exactly its files (an
archive that does not match leaves the folder and is an error). This also holds for an
archive that was already fresh.
"""
function pack(
    id::AbstractString;
    force::Bool = false,
    flat::Bool = false,
    keep_source::Bool = false,
    base = EXPERIMENTS,
)::Symbol
    isdir(plain_dir(id, base)) || error("no folder $(plain_dir(id, base))")
    result = _pack(id; force, flat, base)
    if !keep_source
        bytes_match(id; flat, base) ||
            error("the archive of $id does not extract to its folder; the folder is kept")
        rm(plain_dir(id, base); recursive = true)
    end
    return result
end

function _pack(id::AbstractString; force::Bool, flat::Bool, base)::Symbol
    !force && archive_fresh(id, base) && return :skipped
    arc = archive_path(id, base)
    part = string(arc, ".partial-", getpid())
    isfile(part) && rm(part)
    try
        # flat: the item's files at the top of the archive, run from inside the folder
        cmd =
            flat ?
            Cmd(
                `$(_sevenzip()) a $PACK_ARGS $part $(readdir(plain_dir(id, base)))`;
                dir = plain_dir(id, base),
            ) : Cmd(`$(_sevenzip()) a $PACK_ARGS $part $id`; dir = base)
        success(cmd) || error("7z a failed for $id")
        _tests_ok(part) || error("7z t failed for the new archive of $id")
        want = _folder_entries(id, base; flat)
        got = archive_entries(part)
        want == got || error(
            "the archive of $id differs from its folder: " *
            "missing $(setdiff(want, got)), extra $(setdiff(got, want))",
        )
        mv(part, arc; force = true)
    finally
        isfile(part) && rm(part)
    end
    return :packed
end

# --- unpack

# The stamp of an archive: what the unpacked copy was made from.
_stamp(archive) = string(filesize(archive), " ", mtime(archive))

# Makes `root` the tool's own tmp root: created with the marker, or an existing empty
# folder adopted; a non-empty folder without the marker is refused.
function _own_root(root)
    marker = joinpath(root, MARKER)
    isfile(marker) && return
    if isdir(root)
        isempty(readdir(root)) ||
            error("$root is not empty and not made by this tool; refusing to use it")
    else
        mkpath(root)
    end
    write(
        marker,
        "unpacked fixtures; `bysl fixtures clean` empties this folder\n",
    )
    return
end

"""
    unpack(id; set = "experiments", root = tmp_root(set), base = set_dir(set))
        -> (dir, unpackedNow)

Unpacks `<id>.7z` into `<root>/<id>/` unless a complete copy (its stamp
matches the archive) is already there; `unpackedNow` says whether this call
did the work. The extraction goes into a private folder first and is moved
into place, so an interrupted run leaves no half folder that looks complete.
"""
function unpack(
    id::AbstractString;
    set::AbstractString = "experiments",
    root = tmp_root(set),
    base = set_dir(set),
)
    arc = archive_path(id, base)
    isfile(arc) || error("no archive $arc (`bysl fixtures pack $id` makes it)")
    dest = joinpath(root, id)
    stamp = string(dest, ".stamp")
    isdir(dest) && isfile(stamp) && read(stamp, String) == _stamp(arc) &&
        return dest, false
    _own_root(root)
    work = mktempdir(root; prefix = string(id, ".partial-"), cleanup = false)
    try
        # layout: every entry under `<id>/`, or (flat) the item's files at the top
        flat = !any(startswith(string(id, "/")), archive_entries(arc))
        out = flat ? joinpath(work, id) : work
        success(`$(_sevenzip()) x -y -bso0 -bsp0 -o$out $arc`) ||
            error("7z x failed for $arc")
        isdir(joinpath(work, id)) || error("$arc has no $id/ folder")
        isfile(stamp) && rm(stamp)
        isdir(dest) && rm(dest; recursive = true)   # our own stale, incomplete copy
        mv(joinpath(work, id), dest)
        write(stamp, _stamp(arc))
    finally
        rm(work; recursive = true, force = true)
    end
    return dest, true
end

"""
    resolve(id; set = "experiments", root = tmp_root(set), base = set_dir(set))
        -> (dir, unpackedNow)

The folder to read the fixtures of `id` from: the unpacked
archive when the archive is fresh (unpacked on demand), else the
plain folder in the repository. An error when there is neither.
"""
function resolve(
    id::AbstractString;
    set::AbstractString = "experiments",
    root = tmp_root(set),
    base = set_dir(set),
)
    if isfile(archive_path(id, base)) && archive_fresh(id, base)
        return unpack(id; root, base)
    end
    isdir(plain_dir(id, base)) && return plain_dir(id, base), false
    error("no fixtures for $id: neither $(archive_path(id, base)) nor a folder")
end

"""
    release(id; set = "experiments", root = tmp_root(set))

Removes the unpacked copy of `id` (folder and stamp) from the tmp root; nothing else.
"""
function release(
    id::AbstractString;
    set::AbstractString = "experiments",
    root = tmp_root(set),
)
    isfile(joinpath(root, MARKER)) || return nothing
    rm(joinpath(root, id); recursive = true, force = true)
    rm(joinpath(root, string(id, ".stamp")); force = true)
    return nothing
end

"""
    with_fixture(f, id; set, root, base)

Calls `f(dir)` with the fixture folder of `id` (see [`resolve`](@ref)) and the environment
variable of the set (`env_var(set)`, `BAYSOL_FIXTURES` for experiments) set to the tmp
root; the copy this call unpacked is removed afterwards, one that was there before is left.
"""
function with_fixture(
    f,
    id::AbstractString;
    set::AbstractString = "experiments",
    root = tmp_root(set),
    base = set_dir(set),
)
    dir, fresh = resolve(id; root, base)
    try
        return withenv(env_var(set) => root) do
            f(dir)
        end
    finally
        fresh && release(id; root)
    end
end

"""
    clean(; set = "experiments", root = tmp_root(set)) -> Int

Empties the tool's own tmp root: unpacked folders (those with a stamp), stamps,
abandoned partial folders and the marker, then the root itself when nothing else is
left in it. Refuses a folder without the marker. Returns the number of entries removed.
"""
function clean(; set::AbstractString = "experiments", root = tmp_root(set))::Int
    isdir(root) || return 0
    isfile(joinpath(root, MARKER)) ||
        error("$root is not the tool's unpack folder (no $MARKER); refusing to clean it")
    n = 0
    names = readdir(root)
    for name in names
        p = joinpath(root, name)
        owned =
            endswith(name, ".stamp") ||
            (
                isdir(p) && !islink(p) &&
                (occursin(".partial-", name) ||
                 string(name, ".stamp") in names)
            )
        owned || continue
        rm(p; recursive = true, force = true)
        n += 1
    end
    if isempty(setdiff(readdir(root), [MARKER]))
        rm(joinpath(root, MARKER))
        rm(root)
    end
    return n
end

end
