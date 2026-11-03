# SPDX-License-Identifier: LGPL-3.0-or-later

# Shared helpers of the dev tools: the repository root, the tool error, the code-file walk
# and the character count the line-length rule depends on.
module Common

using Printf: Printf
using Base.ScopedValues: ScopedValue, with

export rm_tree, split_lines, run_step, git_output, dispatch, cache_root, clear_cache!,
    manifest_entries, track_cache, register_cache,
    ToolError, fail, root, in_root,
    char_count, code_files, usage, slurp8,
    spit8,
    split_args, take_threads, sh, run_cmd, find_julia, git, num_str, fmt, FIT_DIR,
    check_folders, check_specs, ids, tags_of, script_of, specs_of, single_run,
    list_fits, resolve_rev, latest_release, baseline_for, git_bytes, as_number

"""
An error a tool reports as a plain message with an exit `status` (1 for a failed run, 2
for a wrong command line) instead of a stack trace.
"""
struct ToolError <: Exception
    message::String
    status::Int
end

"""
    fail(who, msg)

Stops the tool with `who: msg` on stderr and exit status 2 (a wrong command line).
"""
fail(who::AbstractString, msg::AbstractString) = throw(ToolError("$who: $msg", 2))

"The longest line the code may have, in characters (`bysl linelen --check`)."
const LINE_LIMIT = 92

"The extensions of the code the layout rules apply to."
const CODE_EXTENSIONS = (".jl", ".ts", ".tsx", ".mts", ".cts", ".scss", ".yml")

# Folders that hold no code of ours: version control, build output, caches, notes.
const SKIP_DIRS = ("build", ".git", "_cache", "sources", "manuscript", ".CondaPkg",
    "node_modules")


"The repository this package lives in (its tools, test/format environment, scripts)."
const REPO = normpath(joinpath(@__DIR__, "..", ".."))

"A scratch tree for tests: the root the helpers use when it is set."
const ROOT_OVERRIDE = Ref{Union{Nothing,String}}(nothing)

"""
    root() -> String

The repository root: the folder above this package (`dev/`), `BAYSOL_ROOT` if that is set,
or what a test put in `ROOT_OVERRIDE`.
"""
function root()::String
    ROOT_OVERRIDE[] !== nothing && return ROOT_OVERRIDE[]
    haskey(ENV, "BAYSOL_ROOT") && return normpath(ENV["BAYSOL_ROOT"])
    return REPO
end

"The path of `parts` under the root."
in_root(parts...) = joinpath(root(), parts...)

"Characters of `s`, not UTF-8 bytes or UTF-16 units: a code point counts once."
char_count(s::AbstractString) = length(s)

"The text of the file `path`, read as UTF-8."
slurp8(path) = read(string(path), String)

"Writes `text` to the file `path` as UTF-8."
spit8(path, text) = write(string(path), text)

"The text of the `USAGE` string of a tool, printed for `--help`."
usage(text::AbstractString) = print(text, endswith(text, "\n") ? "" : "\n")

"""
    code_files(path) -> Vector{String}

Every code file under `path` (a file or a directory, relative paths relative to the
working directory) as a path relative to the root, sorted by path.
"""
function code_files(path::AbstractString)::Vector{String}
    top = normpath(abspath(root()))
    rel(p) = replace(relpath(normpath(p), top), '\\' => '/')
    iscode(p) = any(ext -> endswith(p, ext), CODE_EXTENSIONS)
    path = normpath(abspath(path))
    isfile(path) && return iscode(path) ? [rel(path)] : String[]
    found = String[]
    for name in sort(readdir(path))
        entry = joinpath(path, name)
        if isdir(entry)
            name in SKIP_DIRS && continue
            append!(found, code_files(entry))
        elseif iscode(entry)
            push!(found, rel(entry))
        end
    end
    return found
end

"""
The lines of `s` the way editors count them: split at `\\n` or `\\r\\n`, the empty lines
at the end dropped.
"""
function split_lines(s::AbstractString)::Vector{String}
    lines = String.(split(s, r"\r?\n"; keepempty = true))
    while !isempty(lines) && isempty(last(lines))
        pop!(lines)
    end
    return lines
end

# --- the cache
#
# The programs the tools start (the unit suite, the fits, the formatter bridge) keep their
# downloads and derived files in the cache folder of the operating system, the folder the
# terminal interface uses: `BAYSOL_CACHE` when that is an absolute path, else
# `baysol/_cache` in the cache home (`%LOCALAPPDATA%` on Windows, `~/Library/Caches` on
# macOS, `$XDG_CACHE_HOME` or `~/.cache` elsewhere). Never the `_cache/` of the repository.
#
# What a program creates there is recorded in a manifest, and the daemon clears those
# files when it exits (`clear_cache!`): downloaded structures (`.pdb`, `.cif`,
# `.mmcif`, `.ent`) and the component files under `components/` are kept, since they
# are expensive to get again, and so is anything that was there before a program ran.

"The folder of the operating system in which programs keep their caches."
function cache_home()::String
    home = homedir()
    if Sys.iswindows()
        return get(ENV, "LOCALAPPDATA", joinpath(home, "AppData", "Local"))
    elseif Sys.isapple()
        return joinpath(home, "Library", "Caches")
    end
    xdg = get(ENV, "XDG_CACHE_HOME", "")
    return isabspath(xdg) ? xdg : joinpath(home, ".cache")
end

"The cache folder of the programs the tools start (see above)."
function cache_root()::String
    env = get(ENV, "BAYSOL_CACHE", "")
    return isabspath(env) ? env : joinpath(cache_home(), "baysol", "_cache")
end

"""
The file that lists what the tools' programs created in the cache, one relative path a
line.
"""
cache_manifest() = joinpath(dirname(cache_root()), "dev-cache-manifest.txt")

"Whether the cache file `rel` (a path relative to the cache folder) is never cleared."
protected(rel::AbstractString) =
    occursin(r"\.(pdb|cif|mmcif|ent)(\.gz)?$"i, rel) ||
    startswith(replace(rel, '\\' => '/'), "components/")

"The files under the cache folder, as paths relative to it."
function cache_files()::Set{String}
    root = cache_root()
    found = Set{String}()
    isdir(root) || return found
    for (dir, _, files) in walkdir(root), f in files
        push!(found, replace(relpath(joinpath(dir, f), root), '\\' => '/'))
    end
    return found
end

"Adds `paths` (relative to the cache folder) to the manifest, those that are not protected."
function register_cache(paths)
    kept = sort!([p for p in paths if !protected(p)])
    isempty(kept) && return nothing
    mkpath(dirname(cache_manifest()))
    open(cache_manifest(), "a") do io
        foreach(p -> println(io, p), kept)
    end
    return nothing
end

"""
    track_cache(f)

Runs `f()` and records in the manifest the files it created in the cache folder; returns
what `f` returns.
"""
function track_cache(f)
    before = cache_files()
    try
        return f()
    finally
        register_cache(setdiff(cache_files(), before))
    end
end

"The relative paths the manifest lists, in order, without repeats."
function manifest_entries()::Vector{String}
    isfile(cache_manifest()) || return String[]
    return unique(filter(!isempty, strip.(split(read(cache_manifest(), String), '\n'))))
end

"""
    clear_cache!() -> Int

Removes the files the manifest lists that still exist, except the protected ones, then the
folders that were left empty, and empties the manifest.
"""
function clear_cache!()::Int
    root = cache_root()
    removed = 0
    folders = Set{String}()
    for rel in manifest_entries()
        (isabspath(rel) || occursin("..", rel) || protected(rel)) && continue
        path = joinpath(root, rel)
        if isfile(path)
            rm(path)
            removed += 1
            push!(folders, dirname(path))
        end
    end
    # the folders the removed files were in, when nothing else is in them
    for dir in sort!(collect(folders); by = length, rev = true)
        d = dir
        while startswith(d, root) && d != root && isdir(d) && isempty(readdir(d))
            rm(d)
            d = dirname(d)
        end
    end
    rm(cache_manifest(); force = true)
    return removed
end

# --- tools with subcommands

"""
    dispatch(who, summary, subs, argv) -> Int

Runs the subcommand `argv[1]` of a tool: `subs` is a vector of `name => (module, doc)`,
the module having a `run(argv)`.
"""
function dispatch(
    who::AbstractString,
    summary::AbstractString,
    subs,
    argv::Vector{String},
)::Int
    if isempty(argv) || first(argv) in ("--help", "-h")
        println(summary)
        println()
        for (name, (_, doc)) in subs
            println("    ", who, " ", rpad(name, 10), " ", doc)
        end
        println("\n`", who, " <subcommand> --help` describes one.")
        return 0
    end
    i = findfirst(p -> first(p) == first(argv), subs)
    i === nothing && fail(
        who,
        "unknown subcommand $(first(argv)) " *
        "(one of: $(join(first.(subs), ", ")))",
    )
    return last(subs[i])[1].run(argv[2:end])
end

# --- the program

"""
The environment variables added to the programs `sh` and `run_cmd` start (the `--threads`
option), as a `Dict`.
"""
const EXTRA_ENV = ScopedValue(Dict{String,String}())

"""
The working directory of the programs `run_cmd` and `sh` start: `nothing`, the directory
the tool was started in.
"""
const CMD_DIR = ScopedValue{Union{Nothing,String}}(nothing)

"""
    take_threads(argv) -> (rest, env)

Takes `--threads N` (N as `julia -t` takes it: `4`, `auto`, `4,1` for four workers and one
interactive thread) out of an argument list: the rest of the arguments and the
environment, `Dict("JULIA_NUM_THREADS" => N)` or empty.
"""
function take_threads(argv::Vector{String})
    i = findfirst(==("--threads"), argv)
    i === nothing && return argv, Dict{String,String}()
    i < length(argv) ||
        throw(ToolError("--threads needs a value (e.g. 4, auto, 4,1)", 1))
    rest = vcat(argv[1:(i-1)], argv[(i+2):end])
    return rest, Dict("JULIA_NUM_THREADS" => argv[i+1])
end

"""
    split_args(who, allowed, flags, argv; word = "options")

Splits `argv` into the options of `allowed` (each `--key value`, in command-line order, as
`key => value` pairs), the `flags` that were given and the positional specs: a named tuple
`(; opts, flags, specs)`.
"""
function split_args(who, allowed, flags, argv; word = "options")
    opts = Pair{String,String}[]
    given = String[]
    specs = String[]
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a in flags
            push!(given, a)
        elseif startswith(a, "--")
            a in allowed || fail(
                who,
                "unknown option $a ($word: " *
                join(vcat(collect(allowed), collect(flags)), ", ") * ")",
            )
            i == length(argv) && fail(who, "option $a needs a value")
            push!(opts, a => argv[i+1])
            i += 1
        else
            push!(specs, a)
        end
        i += 1
    end
    return (; opts, flags = given, specs)
end

# --- running programs

"The command `cmd` (a nested collection of strings and numbers, flattened) as a `Cmd`."
function to_cmd(cmd)
    flat = String[]
    walk(x) = x isa Union{AbstractVector,Tuple} ? foreach(walk, x) : push!(flat, string(x))
    walk(cmd)
    c = ignorestatus(Cmd(flat))
    CMD_DIR[] === nothing || (c = Cmd(c; dir = CMD_DIR[]))
    env = copy(EXTRA_ENV[])
    haskey(ENV, "BAYSOL_CACHE") || haskey(env, "BAYSOL_CACHE") ||
        (env["BAYSOL_CACHE"] = cache_root())
    return addenv(c, env...)
end

"""
    run_cmd(cmd) -> Bool

Runs a command with our terminal (input, output and error), the variables of `EXTRA_ENV`
added to its environment.
"""
run_cmd(cmd)::Bool = track_cache(() -> success(run(to_cmd(cmd))))

"Prints a command and, unless `dry`, runs it with our terminal. True when it succeeded."
function sh(dry::Bool, cmd...)::Bool
    flat = String[]
    walk(x) = x isa Union{AbstractVector,Tuple} ? foreach(walk, x) : push!(flat, string(x))
    walk(cmd)
    println("\$ ", join(flat, " "))
    return dry || run_cmd(flat)
end

"""
    run_step(dry, cmd) -> Bool

Prints a command and, unless `dry`, runs it: `["bysl", tool, args...]` is another tool of
this package, run in this process, anything else a program run with our terminal.
"""
function run_step(dry::Bool, cmd)::Bool
    first(cmd) == "bysl" || return sh(dry, cmd)
    println("\$ ", join(cmd, " "))
    dry && return true
    main = Base.moduleroot(@__MODULE__).main
    return Base.invokelatest(main, cmd[2], String.(cmd[3:end])) == 0
end

"""
    find_julia() -> String

The Julia executable: `\$JULIA` if set, else `julia` from the PATH. An error if it cannot
be found.
"""
function find_julia()::String
    julia = get(ENV, "JULIA", "julia")
    Sys.which(julia) === nothing &&
        throw(ToolError("julia not found (set JULIA to its path)", 1))
    return julia
end

# --- git

"""
    git(args...) -> String

Output of `git -C <root> args`, decoded as UTF-8 (tag and path names can be non-ASCII).
"""
function git(args...)::String
    cmd = Cmd(`git -C $(root()) $(collect(string.(args)))`)
    try
        return read(pipeline(cmd; stderr = stderr), String)
    catch
        throw(ToolError("git $(join(args, " ")) failed", 1))
    end
end

"""
    git_output(args...) -> String

Output of `git -C <root> args` whatever its exit status (`git diff --check` exits 1 when
it finds something, which is a result here, not an error).
"""
function git_output(args...)::String
    cmd = Cmd(`git -C $(root()) $(collect(string.(args)))`)
    return read(pipeline(ignorestatus(cmd); stderr = stderr), String)
end

"Output of `git -C <root> args` as bytes (a binary file at a revision)."
function git_bytes(args...)::Vector{UInt8}
    cmd = Cmd(`git -C $(root()) $(collect(string.(args)))`)
    try
        return read(pipeline(cmd; stderr = stderr))
    catch
        throw(ToolError("git $(join(args, " ")) failed", 1))
    end
end

"The commit hash of `rev`, or `nothing` if git does not know it."
function resolve_rev(rev)::Union{Nothing,String}
    try
        return strip(git("rev-parse", "--verify", "--quiet", "$(rev)^{commit}"))
    catch err
        err isa ToolError && return nothing
        rethrow()
    end
end

"""
    latest_release() -> Union{Nothing,String}

The newest release tag: the most recently created tag whose name starts with `v` and a
digit (`v0.2.0-soukouratou`, ...), or `nothing`.
"""
function latest_release()
    tags = split(
        git("for-each-ref", "--sort=-creatordate", "--format=%(refname:short)",
            "refs/tags"), '\n'; keepempty = false)
    i = findfirst(t -> occursin(r"^v\d", t), tags)
    return i === nothing ? nothing : String(tags[i])
end

"""
    baseline_for(tag) -> Union{Nothing,String}

The newest benchmark baseline recorded for release `tag`: the last (by name) of
`test/baselines/<tag>*.json`, or `nothing`.
"""
function baseline_for(tag)
    dir = in_root("test", "baselines")
    isdir(dir) || return nothing
    found = sort(filter(f -> startswith(f, tag) && endswith(f, ".json"), readdir(dir)))
    return isempty(found) ? nothing : joinpath(dir, last(found))
end

# --- files

"""
    rm_tree(dir)

Removes the benchmark's throwaway directory `dir` and everything in it, never following a
symbolic link: a link is unlinked and its target left alone (the cold state's depot is
made of links into the real one).
"""
function rm_tree(dir::AbstractString)
    startswith(basename(rstrip(dir, '/')), "baysol-bench-") ||
        throw(ToolError("rm_tree: refusing to delete $dir", 1))
    isdir(dir) && rm(dir; recursive = true, force = true)
    return nothing
end

# --- the fitting tests under test/fitting_tests/

const FIT_DIR = "test/fitting_tests"

# Scripts whose tags are not in a `const RUNS = [...]` table; the Julia side of these is
# the SEED_ENTRY_OVERRIDES table in fit_seed.jl.
const SPECIAL_TAGS = Dict("SASDMZ9" => ["model1", "model2", "model3"],
    "SASDJ72" => ["model1", "model2"])

"The ids of all fitting tests, sorted."
ids() = sort(filter(n -> startswith(n, "SASD"), readdir(in_root(FIT_DIR))))

"The script of fitting test `id`: `<id>.jl`, or the folder's only `.jl` file."
function script_of(id)
    dir = in_root(FIT_DIR, id)
    scripts = filter(endswith(".jl"), readdir(dir))
    if "$id.jl" in scripts
        return joinpath(dir, "$id.jl")
    elseif length(scripts) == 1
        return joinpath(dir, only(scripts))
    end
    throw(ToolError("$dir: expected $id.jl or a single script, found $scripts", 1))
end

"""
The tags a fitting test accepts: the `tag = "..."` entries of its `RUNS` table, a fixed
list for the special scripts, or `[""]` for a script with a single run.
"""
function tags_of(id)
    haskey(SPECIAL_TAGS, id) && return SPECIAL_TAGS[id]
    m = match(r"const RUNS = \[(.*?)\n\]"s, slurp8(script_of(id)))
    m === nothing && return [""]
    return [String(t[1]) for t in eachmatch(r"tag = \"([^\"]+)\"", m[1])]
end

"True for the tag list of a script with a single run, which is the one empty tag."
single_run(tags) = tags == [""]

"The `ID[:tag]` specs of the fitting tests `selected`: one per tag, or the bare ID."
specs_of(selected) =
    [tag == "" ? id : "$id:$tag" for id in selected for tag in tags_of(id)]

"Checks the ID[:tag] specs: at least one, each a fitting test (with a tag where needed)."
function check_specs(who, specs)
    isempty(specs) && fail(who, "give at least one ID[:tag] (see: --list)")
    known = Set(ids())
    for spec in specs
        parts = split(spec, ':'; limit = 2)
        id, tag = parts[1], length(parts) == 2 ? parts[2] : nothing
        id in known || fail(who, "no fitting test '$id' (see: --list)")
        tags = tags_of(id)
        (something(tag, "") in tags) && continue
        if single_run(tags)
            fail(who, "$id has a single run and takes no tag, got '$tag'")
        else
            fail(
                who,
                "$id needs a tag, one of: $(join(tags, ", ")) (got '" *
                (isempty(something(tag, "")) ? "none" : tag) * "')",
            )
        end
    end
end

"""
Stops unless every one of `specs` names a fitting-test folder; only the ID before a `:`
counts when `tagged` is true (the default), the whole word otherwise.
"""
function check_folders(who, specs, tagged = true)
    known = Set(ids())
    idof(s) = tagged ? first(split(s, ':'; limit = 2)) : s
    bad = [s for s in specs if !(idof(s) in known)]
    isempty(bad) || fail(
        who,
        "no fitting test folder for: $(join(bad, ", ")) " *
        "(available: $(join(ids(), " ")))",
    )
end

"Prints every fitting test with the tags it accepts."
function list_fits()
    for id in ids()
        tags = tags_of(id)
        what = single_run(tags) ? "(single run, no tag)" : join(tags, " ")
        println(rpad(id, 8), " ", what)
    end
end

# --- numbers
#
# C-style `printf` conversions on the exact binary value of the double: Julia's `Printf`
# is C's, so `%.1f` of 0.15 is 0.1 as in the C tools these were checked against.

"""
A numeric string as the number it stands for (`"3.20"` is 3.2, `"+7"` is 7), anything else
unchanged.
"""
function as_number(v)
    v isa AbstractString || return v
    occursin(r"^[-+]?\d+$", v) && return parse(Int, v)
    occursin(r"^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$", v) &&
        return parse(Float64, v)
    return v
end

"""
    fmt(spec, x) -> String

A number (or numeric string) by the C conversion `spec`: `%d`, `%.<n>f`, `%+.<n>f` or
`%.<n>g`.
"""
function fmt(spec::AbstractString, x)::String
    m = match(r"^%(\+?)(?:\.(\d+))?([dfg])$", spec)
    m === nothing && throw(ToolError("unsupported conversion $spec", 1))
    x = as_number(x)
    x isa Number || throw(ToolError("expected a number, got '$x'", 1))
    conv = m[3]
    s = if conv == "d"
        string(trunc(Int, x))
    else
        n = parse(Int, m[2])
        Printf.format(Printf.Format("%.$(n)$(conv)"), Float64(x))
    end
    # C prints the exponent of %g with at least two digits, as Printf does
    return (m[1] == "+" && !startswith(s, "-")) ? "+" * s : s
end

"""
    num_str(v) -> String

A value as the tools print a number: a double by its shortest digits (a whole one keeps
its `.0`; outside 1e-4 .. 1e16 the exponent form, `6.75e-7`), anything else by `string`.
"""
function num_str(v)::String
    v isa AbstractFloat || return string(v)
    isfinite(v) || return string(v)
    v == 0 && return signbit(v) ? "-0.0" : "0.0"
    digits, e = _digits_exp(abs(Float64(v)))
    sign = v < 0 ? "-" : ""
    if -5 < e < 17
        plain =
            e >= 0 ?
            (
                length(digits) > e + 1 ? digits[1:(e+1)] * "." * digits[(e+2):end] :
                digits * "0"^(e + 1 - length(digits)) * ".0"
            ) :
            "0." * "0"^(-e - 1) * digits
        return sign * plain
    end
    return sign * digits[1] * (length(digits) > 1 ? "." * digits[2:end] : "") * "e" *
           (e < 0 ? "-" : "+") * string(abs(e))
end

# The shortest digits of a positive double and the decimal exponent of the first one.
function _digits_exp(x::Float64)
    s = string(x)  # "12170.0", "6.75346e-7", "1.0e-5", "1.0e16"
    mant, ex = occursin('e', s) ? split(s, 'e') : (s, "0")
    e10 = parse(Int, ex)
    ip, fp = occursin('.', mant) ? split(mant, '.') : (mant, "")
    all_digits = ip * fp
    lead = findfirst(!=('0'), all_digits)
    e = e10 + length(ip) - lead
    digits = rstrip(all_digits[lead:end], '0')
    return isempty(digits) ? "0" : digits, e
end

"A decimal number as a regex fragment, one capture group: sign, fraction and exponent."
const NUM_RE = "([-+]?\\d+\\.?\\d*(?:[eE][-+]?\\d+)?)"

end
