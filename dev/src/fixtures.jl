# SPDX-License-Identifier: LGPL-3.0-or-later

# Fixture archives of any "archive set" (a root folder with one <name>.7z per item; the
# registered sets are `experiments` and `synthetic`, any other folder is given with
# `--root`): `bysl fixtures list`, `pack`, `unpack` and `clean`. The work is in
# `fixture-store.jl` (shared with `fit-seed.jl`); `fits run` unpacks before a fit starts
# and removes the copy afterwards.
module Fixtures

using ..Common

include("fixture-store.jl")

const WHO = "bysl fixtures"

# Runs `f()` and turns the store's plain errors into a tool error (exit status 1).
function guarded(f)
    try
        return f()
    catch err
        err isa ErrorException || rethrow()
        throw(ToolError(string(WHO, ": ", err.msg), 1))
    end
end

"""
The folder of the fixtures of `id` (an archive is unpacked on demand); see `FixtureStore`.
`set` names the archive set (default `experiments`).
"""
fixture_dir(id; kw...) = guarded(() -> FixtureStore.resolve(id; kw...))

"""
Runs `f(dir)` with the fixtures of `id` available
and the set's environment variable set; see `FixtureStore`.
"""
with_fixture(f, id; kw...) = guarded(() -> FixtureStore.with_fixture(f, id; kw...))

# The options every subcommand shares: `--set NAME` (a registered set), `--root DIR`
# (any directory, named after its folder), `--tmp DIR` (the unpack folder).
const TARGET_OPTS = ["--set", "--root", "--tmp"]

const TARGET_HELP = """
    --set NAME  the archive set, one of
                $(join(FixtureStore.set_names(), ", ")) (default experiments)
    --root DIR  any folder with one <name>.7z per item instead of a set (its tmp root
                is \$BAYSOL_FIXTURES_<FOLDER NAME> or <cache>/fixtures/<folder name>)
    --tmp DIR   unpack into DIR instead of the set's tmp root (\$BAYSOL_FIXTURES for
                experiments, \$BAYSOL_FIXTURES_<SET>, else <cache>/fixtures/<set>)"""

# The archive set the options name: `(; set, base, root, explicit)`; `explicit` is true
# when `--set` or `--root` was given.
function target(who, opts)
    o = Dict(opts)
    haskey(o, "--set") && haskey(o, "--root") &&
        fail(who, "give --set or --root, not both")
    explicit = haskey(o, "--set") || haskey(o, "--root")
    set, base = if haskey(o, "--root")
        dir = abspath(o["--root"])
        isdir(dir) || fail(who, "no folder $dir")
        basename(dir), dir
    else
        name = get(o, "--set", "experiments")
        name in FixtureStore.set_names() ||
            fail(
                who,
                "unknown set $name (registered: $(join(FixtureStore.set_names(), ", ")))",
            )
        name, FixtureStore.set_dir(name)
    end
    root = haskey(o, "--tmp") ? abspath(o["--tmp"]) : FixtureStore.tmp_root(set)
    return (; set, base, root, explicit)
end

# The items named on the command line, or every
# one with a folder (pack) / archive (unpack).
function entries(specs, available)
    for s in specs
        s in available || fail(WHO, "no fixtures for $s")
    end
    return isempty(specs) ? available : specs
end

module List
using ...Common
import ..FixtureStore, ..guarded, ..target, ..WHO, ..TARGET_OPTS, ..TARGET_HELP

const USAGE = """
Shows the archive sets: the folder, the tmp root, how many items are packed (an archive
exists), stale (a file of the folder is newer) and unpacked (a copy in the tmp root).
With --set or --root, one line per item.

    bysl fixtures list [--set NAME | --root DIR] [--tmp DIR]

$TARGET_HELP
"""

# One item's state: folder yes/no, archive KiB or -, fresh/stale, unpacked.
function item_state(id, t)
    arc = FixtureStore.archive_path(id, t.base)
    packed = isfile(arc)
    return (;
        folder = isdir(FixtureStore.plain_dir(id, t.base)),
        packed,
        kib = packed ? round(filesize(arc) / 1024; digits = 1) : 0.0,
        stale = packed && !FixtureStore.archive_fresh(id, t.base),
        unpacked = isfile(string(joinpath(t.root, id), ".stamp")) &&
                   isdir(joinpath(t.root, id)),
    )
end

function show_set(t, items::Bool)
    ids = FixtureStore.entry_ids(t.base)
    states = [item_state(id, t) for id in ids]
    println(
        rpad(t.set, 12),
        length(ids), " items, ",
        count(s -> s.packed, states), " packed, ",
        count(s -> s.stale, states), " stale, ",
        count(s -> s.unpacked, states), " unpacked",
    )
    println("  archives  ", t.base)
    println("  tmp root  ", t.root, "  (", FixtureStore.env_var(t.set), ")")
    items || return
    for (id, s) in zip(ids, states)
        println(
            "  ", rpad(id, 28),
            s.folder ? "folder  " : "no folder  ",
            s.packed ? string(s.kib, " KiB ", s.stale ? "stale" : "fresh") : "no archive",
            s.unpacked ? "  unpacked" : "",
        )
    end
end

function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, specs) = split_args(WHO * " list", TARGET_OPTS, String[], argv)
    isempty(specs) || fail(WHO * " list", "takes no argument")
    t = target(WHO * " list", opts)
    if t.explicit
        show_set(t, true)
    else
        for name in FixtureStore.set_names()
            show_set(
                (; set = name, base = FixtureStore.set_dir(name),
                    root = haskey(Dict(opts), "--tmp") ? t.root :
                           FixtureStore.tmp_root(name)),
                false,
            )
        end
    end
    return 0
end
end

module Pack
using ...Common
import ..FixtureStore, ..guarded, ..entries, ..target, ..WHO, ..TARGET_OPTS, ..TARGET_HELP

const USAGE = """
Packs <root>/<name>/ into <name>.7z (7z, LZMA2, -mx=9, solid, entry paths start with
<name>/, or with --flat the item's files directly), checks it with `7z t` and against the
folder, then removes the plain folder once the archive has been extracted into a scratch
folder and found identical to it byte for byte (a mismatch keeps the folder and fails).
--keep-source leaves the folder. <root> is test/fixtures/experiments unless --set
or --root says otherwise.

    bysl fixtures pack [NAME ...] [--set NAME | --root DIR] [--force] [--flat]
        [--keep-source]

    NAME        items with a folder (default: all of them)
    --force     pack again although the archive is newer than every file of the folder
    --keep-source
                keep the plain folder after packing (default: removed after the byte check)
    --flat      the archive holds the files of the item at its top level (no <name>/
                folder); `unpack` detects either layout
$TARGET_HELP
"""

function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, flags, specs) =
        split_args(WHO * " pack", TARGET_OPTS, ["--force", "--flat", "--keep-source"], argv)
    t = target(WHO * " pack", opts)
    folders = filter(id -> isdir(FixtureStore.plain_dir(id, t.base)),
        FixtureStore.entry_ids(t.base))
    failed = String[]
    for id in entries(specs, folders)
        try
            r = guarded(
                () -> FixtureStore.pack(
                    id;
                    force = "--force" in flags,
                    flat = "--flat" in flags,
                    keep_source = "--keep-source" in flags,
                    base = t.base,
                ),
            )
            kib = round(filesize(FixtureStore.archive_path(id, t.base)) / 1024; digits = 1)
            println(
                rpad(id, 10),
                " ",
                r == :skipped ? "up to date" : "packed",
                " ",
                kib,
                " KiB",
            )
        catch err
            err isa ToolError || rethrow()
            println(stderr, err.message)
            push!(failed, id)
        end
    end
    isempty(failed) && return 0
    println(stderr, WHO, " pack: failed: ", join(failed, ", "))
    return 1
end
end

module Unpack
using ...Common
import ..FixtureStore, ..guarded, ..entries, ..target, ..WHO, ..TARGET_OPTS, ..TARGET_HELP

const USAGE = """
Unpacks <name>.7z into the set's tmp root as <root>/<name>/. A complete copy that is
already there is reused. The copies stay until `bysl fixtures clean` (`bysl fits run`
removes the ones it unpacked itself).

    bysl fixtures unpack NAME ... [--set NAME | --root DIR] [--tmp DIR]

$TARGET_HELP
"""

function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, specs) = split_args(WHO * " unpack", TARGET_OPTS, String[], argv)
    isempty(specs) && fail(WHO * " unpack", "name at least one item")
    t = target(WHO * " unpack", opts)
    archives = [
        id for id in FixtureStore.entry_ids(t.base)
        if isfile(FixtureStore.archive_path(id, t.base))
    ]
    for id in entries(specs, archives)
        dir, now = guarded(() -> FixtureStore.unpack(id; root = t.root, base = t.base))
        println(rpad(id, 10), " ", now ? "unpacked" : "already there", " ", dir)
    end
    return 0
end
end

module Clean
using ...Common
import ..FixtureStore, ..guarded, ..target, ..WHO, ..TARGET_OPTS, ..TARGET_HELP

const USAGE = """
Removes the unpacked fixtures: the tool's own tmp root of the set and nothing else.
Refuses a folder this tool did not create (no marker file). Plain folders and archives
are never touched.

    bysl fixtures clean [--set NAME | --root DIR] [--tmp DIR]

$TARGET_HELP
"""

function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, specs) = split_args(WHO * " clean", TARGET_OPTS, String[], argv)
    isempty(specs) || fail(WHO * " clean", "takes no argument")
    t = target(WHO * " clean", opts)
    n = guarded(() -> FixtureStore.clean(; root = t.root))
    println(n, " entries removed from ", t.root)
    return 0
end
end

const SUBS = [
    "list" => (List, "show the archive sets, their archives and what is unpacked"),
    "pack" => (Pack, "create or refresh the .7z archives from the plain folders"),
    "unpack" => (Unpack, "unpack archives into the tmp folder"),
    "clean" => (Clean, "remove the unpacked copies (only the tool's own tmp folder)"),
]

const SUMMARY = "Fixture archive sets.\n\n    bysl fixtures SUBCOMMAND [options]"

"`bysl fixtures`: a subcommand and its options."
run(argv::Vector{String})::Int = dispatch("bysl fixtures", SUMMARY, SUBS, argv)

end
