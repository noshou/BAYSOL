# SPDX-License-Identifier: LGPL-3.0-or-later

# The checks to run before a commit and the two big suites: `bysl precommit` (everything),
# `bysl unit` (the Julia unit suite) and `bysl docs` (the documentation build).
module Checks

using ..Common

# --- the unit suite and the documentation build

module Unit

using ...Common

const USAGE = """
The Julia unit and integration suite (about 5 minutes).

    bysl unit [NAME ...] [--threads N]

    NAME        run the test files whose name contains it (default: all)
    --threads N Julia threads (4, auto, 4,1); default one
"""

"`bysl unit`: the suite, in a Julia process of its own; returns its exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    return run_cmd([find_julia(), "--startup-file=no", "--project=" * in_root("test"),
        in_root("dev", "scripts", "unittests.jl"), argv]) ? 0 : 1
end

end

module Docs

using ...Common

const USAGE = """
The documentation build (strict, about a minute) into docs/build.

    bysl docs
"""

"`bysl docs`: the build, in a Julia process of its own; returns its exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    isempty(argv) || fail("bysl docs", "takes no argument")
    return run_cmd([find_julia(), "--startup-file=no", "--project=" * in_root("docs"),
        in_root("docs", "make.jl")]) ? 0 : 1
end

end

# --- the precommit

module Precommit

using ...Common

const WHO = "bysl precommit"

const USAGE = """
Every check before a commit.

    bysl precommit [--quick] [--dry-run] [--threads N]

Steps, in order; all run, and the exit status is 1 if any failed:
    tool-tests, pmv-mean, solute-index, unit-tests, concurrency-tests, whitespace,
    default-settings, ts-format, ts-unused, julia-format, line-length, results-table,
    docs-build

    --quick     skip the Julia steps (unit-tests, concurrency-tests,
                default-settings, julia-format, docs-build)
    --dry-run   print the steps, run nothing
    --threads N Julia threads (4, auto, 4,1); default one

whitespace strips trailing blanks on changed lines and fails on conflict markers. The
harvest steps rewrite stale files, which belong in the commit.
"""

# File types scanned for trailing whitespace in untracked files.
const TEXT_EXTENSIONS = ("jl", "ts", "tsx", "md", "tsv", "toml", "json", "yml")

# --- the whitespace step

"""
    strip_lines(path, only) -> Int

Strips the trailing blanks (spaces and tabs) from the lines of file `path` listed in
`only` (a set of 1-based line numbers, or `:all`), leaving everything else, line endings
included, untouched.
"""
function strip_lines(path, only)::Int
    endswith(path, ".tsv") && return 0
    lines = String.(split(slurp8(path), '\n'; keepempty = true))
    stripped = [
        (only === :all || i in only) ? replace(l, r"[ \t]+(\r?)$" => s"\1") : l
        for (i, l) in enumerate(lines)
    ]
    n = count(lines .!= stripped)
    n > 0 && spit8(path, join(stripped, "\n"))
    return n
end

# The report of what was stripped (at most 12 files) and of the problems (at most 12), as
# printed lines.
function summary_lines(stripped, problems)
    out = String[]
    if !isempty(stripped)
        push!(
            out,
            "  stripped trailing whitespace from $(sum(last, stripped)) lines in " *
            "$(length(stripped)) files:",
        )
        append!(out, ["    $f ($n)" for (f, n) in stripped[1:min(12, end)]])
        length(stripped) > 12 && push!(out, "    ... and $(length(stripped) - 12) more")
    end
    append!(out, ["  $p" for p in problems[1:min(12, end)]])
    length(problems) > 12 && push!(out, "  ... and $(length(problems) - 12) more")
    return out
end

"""
    whitespace() -> Bool

Strips trailing whitespace from the lines you changed (`git diff --check HEAD` names them
in the tracked files; an untracked, unignored text file is stripped whole) and says what
it did.
"""
function whitespace()::Bool
    checked =
        split_lines(git_output("-c", "core.quotepath=false", "diff", "--check", "HEAD"))
    # tracked files: file => line numbers, in the order git names them
    at = Pair{String,Set{Int}}[]
    for line in checked
        m = match(r"^(\S.*?):(\d+): trailing whitespace\.$", line)
        m === nothing && continue
        i = findfirst(p -> first(p) == m[1], at)
        i === nothing ? push!(at, String(m[1]) => Set([parse(Int, m[2])])) :
        push!(last(at[i]), parse(Int, m[2]))
    end
    other = [
        l for l in checked if occursin(r"^\S.*:\d+: ", l) &&
            !occursin(r": trailing whitespace\.$", l)
    ]
    tracked = [(f, strip_lines(in_root(f), lines)) for (f, lines) in at]
    listed = split_lines(
        git("-c", "core.quotepath=false", "ls-files", "-o",
            "--exclude-standard"),
    )
    untracked_files = [f for f in listed if !isempty(f) &&
        lstrip(splitext(f)[2], '.') in TEXT_EXTENSIONS]
    untracked = [(f, strip_lines(in_root(f), :all)) for f in untracked_files]
    markers = String[]
    for f in untracked_files,
        (i, line) in enumerate(split(slurp8(in_root(f)), '\n';
            keepempty = true))

        occursin(r"^(<<<<<<<|>>>>>>>) ", line) && push!(markers, "$f:$i: conflict marker")
    end
    stripped = [(f, n) for (f, n) in vcat(tracked, untracked) if n > 0]
    problems = vcat(other, markers)
    foreach(println, summary_lines(stripped, problems))
    return isempty(problems)
end

# --- the steps

"""
The checks, in order: `(name, quick, action)`.
"""
function steps(julia)
    unit = [julia, "--startup-file=no", "--project=" * in_root("test"),
        in_root("dev", "scripts", "unittests.jl")]
    return [
        ("tool-tests", true, ["bysl", "test"]),
        ("pmv-mean", true, ["bysl", "harvest", "pmv-mean"]),
        ("solute-index", true, ["bysl", "harvest", "solutes"]),
        ("residue-table", true, ["bysl", "harvest", "residues"]),
        ("unit-tests", false, unit),
        ("concurrency-tests", false,
            [julia, "--startup-file=no", "-t", "6,1", "--project=" * in_root("test"),
                in_root("dev", "scripts", "unittests.jl"), "concurrency", "parallel",
                "gcpause",
                "cache"]),
        ("whitespace", true, :whitespace),
        ("default-settings", false, ["bysl", "harvest", "defaults"]),
        ("ts-format", true, ["bysl", "fmt", "--check", "--ts"]),
        # Knip (config: knip.jsonc): unused dependencies, files, exports and types of tui/
        ("ts-unused", true, [in_root("node_modules", ".bin", "knip"), "--no-progress"]),
        ("julia-format", false, ["bysl", "fmt", "--check", "--julia"]),
        ("line-length", true, ["bysl", "fmt", "--lines"]),
        ("results-table", true, ["bysl", "results", "table", "--check"]),
        ("docs-build", false, ["bysl", "docs"]),
    ]
end

# Runs one step; `(state, seconds)` with state "ok" or "FAILED".
function run_one(action)
    t0 = time()
    ok = action === :whitespace ? whitespace() : run_step(false, action)
    return (ok ? "ok" : "FAILED", time() - t0)
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    unknown = findfirst(a -> !(a in ("--quick", "--dry-run")), argv)
    unknown === nothing ||
        fail(WHO, "unknown option $(argv[unknown]) (one of: --quick, --dry-run, --threads)")
    quick = "--quick" in argv
    dry = "--dry-run" in argv
    julia = (dry || quick) ? "julia" : find_julia()
    results = Tuple{String,String,Float64}[]
    for (name, is_quick, action) in steps(julia)
        if quick && !is_quick
            push!(results, (name, "skipped", 0.0))
            continue
        end
        println("\n=== ", name)
        if dry
            println(
                action === :whitespace ?
                "(strip trailing whitespace from the changed lines; fail on conflict " *
                "markers)" :
                "\$ " * join((a == julia ? "JULIA" : a for a in action), " "),
            )
            continue
        end
        state, secs = run_one(action)
        push!(results, (name, state, secs))
    end
    dry && return 0
    println("\n=== summary")
    for (name, state, secs) in results
        println("  ", rpad(name, 14), " ", rpad(state, 8), " ",
            state == "skipped" ? "" : fmt("%.1f", secs) * " s")
    end
    failed = any(r -> r[2] == "FAILED", results)
    println(
        failed ? "NOT ready to commit" :
        quick ? "quick checks passed (the unit suite and the docs build were skipped)" :
        "ready to commit",
    )
    return failed ? 1 : 0
end

end

end
