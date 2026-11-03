# SPDX-License-Identifier: LGPL-3.0-or-later

# The end-to-end fitting tests (test/fitting_tests/<ID>/) and what is done with them:
# running them (`bysl fits run`), listing them (`bysl fits list`), the sampler diagnostics
# (`bysl fits diagnose`) and the profile of the static build (`bysl fits profile`).
module Fits

using ..Common

module Fit

using ...Common

const WHO = "bysl fits run"

const USAGE = """
Runs the fitting tests (test/fitting_tests/<ID>/) and what follows them.

    bysl fits run [ID ...] [options]

    ID          fitting-test folders (default: all)
    --no-fit    skip the fits
    --bench     then run the benchmark (a plan only, without --approved)
    --approved  the owner approved this benchmark run (needs --bench)
    --report    then print the Results-table rows of the fits
    --table     then rewrite the Results table of the README
    --fixme     then run the sampler diagnostics (`fits diagnose --report`)
    --trace-compile FILE
                run the fits with Julia's --trace-compile=FILE
    --threads N Julia threads (4, auto, 4,1); default one
    --dry-run   print the commands, run nothing

A failing step does not stop the others; the exit status is 1 if any failed.
"""

const FLAG_NAMES = [
    "--bench", "--approved",
    "--no-fit", "--report",
    "--table", "--fixme",
    "--dry-run"]

# The options that take a value.
const VALUED = ["--trace-compile"]

# The command that runs another tool of this package by its task name: `bysl <task> args`.
tool(task, args...) = vcat(["bysl", task], collect(String, args))

# The steps to run, in order, as (label, failure name, command).
function steps(flag, selected, requested, julia, trace)
    out = Tuple{String,String,Vector{String}}[]
    # 1. the fits: one Julia process per fitting test, in the fitting-test project
    if !flag("--no-fit")
        for id in selected
            push!(
                out,
                (
                    "fit: $id",
                    "fit $id",
                    vcat([julia, "--startup-file=no"],
                        trace === nothing ? String[] : ["--trace-compile=$trace"],
                        ["--project=" * in_root(FIT_DIR), script_of(id)]),
                ),
            )
        end
    end
    # 2. the benchmark (a no-op that prints its plan unless --approved is given)
    if flag("--bench")
        approved = flag("--approved") ? ["--approved"] : String[]
        push!(
            out,
            (
                "benchmark",
                "benchmark",
                tool("fits", "bench", approved..., specs_of(selected)...),
            ),
        )
    end
    # 3. the report: the Results-table rows of the selected fits
    flag("--report") &&
        push!(out, ("report", "report", tool("results", "table", requested...)))
    # 3b. the Results table of the fitting tests' README
    flag("--table") &&
        push!(out, ("table", "table", tool("results", "table", "--update")))
    # 4. the diagnostics
    flag("--fixme") && push!(
        out,
        ("diagnostics", "diagnostics",
            tool("fits", "diagnose", "--report", specs_of(selected)...)),
    )
    return out
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, flags, specs) = split_args(WHO, VALUED, FLAG_NAMES, argv; word = "one of")
    flag(f) = f in flags
    trace =
        haskey(Dict(opts), "--trace-compile") ?
        abspath(Dict(opts)["--trace-compile"]) : nothing
    flag("--approved") && !flag("--bench") &&
        fail(WHO, "--approved only applies together with --bench")
    # every folder asked for must exist; none asked for means all of them
    check_folders(WHO, specs, false)
    selected = isempty(specs) ? ids() : specs
    julia = find_julia()
    dry = flag("--dry-run")
    # a failing step does not stop the others
    failed = String[]
    for (label, failure, cmd) in steps(flag, selected, specs, julia, trace)
        println("\n=== ", label)
        run_step(dry, cmd) || push!(failed, failure)
    end
    isempty(failed) && return 0
    println(stderr, "\n", WHO, ": failed: ", join(failed, ", "))
    return 1
end

end

module Diagnose

using ...Common

const WHO = "bysl fits diagnose"

const USAGE = """
Sampler diagnostics on fits, without rerunning them.

    bysl fits diagnose [PART ...] [options] [ID[:tag] ...]

    --report    MAP starts, Hessian, step size, tree depth, modes
    --residuals are the residuals at the MAP white; reduced chi-squared
    --chains    every chain of a run: start, mode, divergences, steps, acceptance
                (no part named: all three, in this order)
    --samples N --adapt N   NUTS iterations (default: those of run_model)
    --seeds 1,2,3           RNG seeds for --chains (default 7)
    --retry 0|1             --chains: also the rerun made when R-hat is high
    --out DIR   write DIR/<part>.txt instead of stdout
    --threads N Julia threads (4, auto, 4,1); default one
    --dry-run   print the commands, run nothing
"""

# The parts, in the order they run (the slow ones last), each with the options it accepts.
const PARTS = [("report", ["--out", "--samples", "--adapt"]), ("residuals", ["--out"]),
    ("chains", ["--out", "--samples", "--adapt", "--seeds", "--retry"])]

integer_text(s) = occursin(r"^[-+]?\d+$", s)

# Stops with a message if the value of option `k` is bad.
function check_option((k, v))
    if k in ("--samples", "--adapt")
        (integer_text(v) && parse(Int, v) >= 1) ||
            fail(WHO, "$k needs a positive integer, got '$v'")
    elseif k == "--seeds"
        all(integer_text, split(v, ','; keepempty = true)) ||
            fail(WHO, "--seeds needs integers separated by commas, got '$v'")
    elseif k == "--retry"
        v in ("0", "1") || fail(WHO, "--retry needs 0 or 1, got '$v'")
    end
end

# The command that runs `part` on `specs` with the options `opts` (pairs): diagnose.jl in
# the fitting-test project.
command(julia, part, opts, specs) = vcat(
    [julia, "--startup-file=no",
        "--project=" * in_root(FIT_DIR), in_root("dev", "scripts", "diagnose.jl"),
        "--" * part],
    reduce(vcat, [[k, v] for (k, v) in opts]; init = String[]), specs)

# The options that go to `part`: those it accepts, in command-line order, and its own
# output file under `outdir` when one was asked for.
function part_options(part, opts, outdir)
    accepted = last(only(filter(p -> first(p) == part, PARTS)))
    chosen = [(k, v) for (k, v) in opts if k in accepted]
    outdir === nothing || push!(chosen, ("--out", joinpath(outdir, part * ".txt")))
    return chosen
end

# Runs one part (or, with `dry`, prints its command); true if it succeeded.
function run_part(julia, part, opts, outdir, specs, dry)
    cmd = command(julia, part, part_options(part, opts, outdir), specs)
    println("\n=== diagnose: ", part)
    dry && (println(join(cmd, " ")); return true)
    return run_cmd(cmd)
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if isempty(argv) || any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    part_flags = ["--" * first(p) for p in PARTS]
    (; opts, flags, specs) = split_args(WHO, unique(reduce(vcat, last.(PARTS))),
        vcat(part_flags, ["--dry-run"]), argv)
    outdir = get(Dict(opts), "--out", nothing)
    # --out is per part, set by `part_options`
    opts = filter(o -> first(o) != "--out", opts)
    isempty(specs) && (specs = specs_of(ids()))
    # the parts asked for, in the order given; none: all, in order
    asked = [f[3:end] for f in flags if f in part_flags]
    chosen = isempty(asked) ? first.(PARTS) : asked
    dry = "--dry-run" in flags
    # the command line is checked before Julia is looked for or started
    foreach(check_option, opts)
    check_specs(WHO, specs)
    julia = find_julia()
    outdir !== nothing && !dry && mkpath(outdir)
    # every part runs even if one fails; the failures are named
    failed = [p for p in chosen if !run_part(julia, p, opts, outdir, specs, dry)]
    isempty(failed) && return 0
    println(stderr, "\n", WHO, ": failed: ", join(failed, ", "))
    return 1
end

end

module Profile

using ...Common

const WHO = "bysl fits profile"

const USAGE = """
Profiles the static build of fitting tests.

    bysl fits profile ID[:tag] ... [--delay SECONDS] [--nuts] [--dry-run]

    --delay S   sampling interval (default 0.0005)
    --nuts      also profile the sampling, after a short warm-up run
    --threads N Julia threads (4, auto, 4,1); default one
    --dry-run   print the command, run nothing
"""

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, flags, specs) = split_args(WHO, ["--delay"], ["--nuts", "--dry-run"], argv)
    interval = get(Dict(opts), "--delay", nothing)
    isempty(specs) && fail(WHO, "give at least one ID[:tag]")
    check_folders(WHO, specs)
    # one Julia process profiles every spec, so the compiler warms up once
    cmd = vcat(
        [find_julia(), "--startup-file=no", "--project=" * in_root(FIT_DIR),
            in_root("dev", "scripts", "profile_seed.jl")],
        interval === nothing ? String[] : ["--delay", interval],
        "--nuts" in flags ? ["--nuts"] : String[], specs)
    # a failed run is the tool's failure: status 1
    return sh("--dry-run" in flags, cmd) ? 0 : 1
end

end

# The cold / steady-state benchmark driver.
module Bench

using JSON3

using ...Common

const WHO = "bysl fits bench"

const USAGE = """
Cold / steady-state benchmark.

    bysl fits bench --approved [--state cold|warm] [--keep] [--out FILE.json]
        [--samples N --adapt N] ID[:tag] ...

Without --approved only the plan is printed: timings need a quiet machine, so each run
needs the owner's approval.

    --state     cold (default): throwaway depot, repository copy and cache;
                warm: the real ones, for comparison only
    --keep      keep the cold state's temporary directory
    --out FILE  result file (default: test/baselines/results/, untracked)
    --samples N --adapt N   NUTS iterations, together (default: those of run_model)
    --threads N Julia threads (4, auto, 4,1); default one

`bysl results compare --bench` reads the result.
"""

# Directories of a Julia depot that a user has after installing (sources, not compiled
# caches).
const DEPOT_SOURCE_DIRS = ["packages", "artifacts", "registries", "clones",
    "conda_environments", "environments"]

"""
    parse_args(argv)

The `--key value` options (and the value-less `--keep`) and the positional specs of the
command line: `(; opts, specs)`, `opts` mapping the option name without its dashes to its
value.
"""
function parse_args(argv)
    (; opts, flags, specs) = split_args(WHO, ["--state", "--out", "--samples", "--adapt"],
        ["--keep"], argv)
    d = Dict{String,Any}(k[3:end] => v for (k, v) in opts)
    for f in flags
        d[f[3:end]] = 1
    end
    return (; opts = d, specs)
end

"""
    excluded(f) -> Bool

Is the repository file `f` (a path relative to the root) left out of the cold state's
repository copy? Docs, the visual-check snapshots, the fitting tests' result files and
untracked benchmark results are: none of them is needed to build a Seed and fit it.
"""
excluded(f) =
    startswith(f, "docs/") || startswith(f, "test/visualize/xyz/") ||
    startswith(f, "test/baselines/results/") ||
    occursin(r"^test/fitting_tests/.*/res[^/]*\.(txt|png)$", f)

# Copies the repository's tracked and untracked-but-not-ignored files (minus the excluded
# ones) to `dest`.
function copy_repo(dest)
    n = 0
    for f in split_lines(
        git("-c", "core.quotepath=false", "ls-files", "-co",
            "--exclude-standard"),
    )
        (isempty(f) || excluded(f) || !isfile(in_root(f))) && continue
        mkpath(dirname(joinpath(dest, f)))
        cp(in_root(f), joinpath(dest, f); force = true)
        n += 1
    end
    return n
end

"""
    make_depot(dest, real)

Builds a depot at `dest` from symlinks to the source parts of the real depot `real`.
"""
function make_depot(dest, real)
    mkpath(dest)
    for d in DEPOT_SOURCE_DIRS
        isdir(joinpath(real, d)) && symlink(joinpath(real, d), joinpath(dest, d))
    end
end

# Julia's version, CPU name, hardware threads and first depot, from one short call.
function julia_facts(julia)
    out = read(
        Cmd([julia, "--startup-file=no", "-e",
            "print(join((VERSION, Sys.CPU_NAME, Sys.CPU_THREADS, " *
            "first(DEPOT_PATH)), \"\\n\"))",
        ]),
        String)
    version, cpu, cores, depot = split(out, '\n')
    return (; version, cpu, cores, depot)
end

"""
    json_line(out) -> Union{Nothing,String}

The JSON object a child process printed: the last line that is a whole object (opens and
closes with a curly brace), or `nothing`.
"""
function json_line(out)
    lines = [strip(l) for l in split(out, '\n')]
    found = filter(l -> startswith(l, "{") && endswith(l, "}"), lines)
    return isempty(found) ? nothing : String(last(found))
end

# Runs a command and returns `(wall seconds, stdout)`.
function timed(env, cmd)
    out = IOBuffer()
    c = Common.to_cmd(cmd)
    isempty(env) || (c = addenv(c, env...))
    t0 = time_ns()
    ok = success(run(pipeline(c; stdout = out, stderr = stderr)))
    seconds = (time_ns() - t0) / 1e9
    text = String(take!(out))
    ok || throw(ToolError("command failed: $(join(first(cmd, 4), " ")) ...\n$text", 1))
    return seconds, text
end

# --- the result file
#
# Written by hand, not by a JSON library: the keys keep their order, and
# the child's own JSON text is kept as it printed (no digit is rewritten).

jstr(s) = JSON3.write(String(s))

# A JSON object from `(key, already-encoded value)` pairs, one key per line at `indent`
# spaces, the colons aligned.
function pretty_object(pairs, indent)
    pad = maximum(length(first(p)) for p in pairs)
    ind = " "^indent
    lines = [ind * "    " * jstr(k) * " "^(pad - length(k)) * " : " * v for (k, v) in pairs]
    return "{\n" * join(lines, ",\n") * "\n" * ind * "}"
end

function meta_object(facts, state, repo)
    rev =
        strip(git("rev-parse", "--short", "HEAD")) *
        (isempty(strip(git("status", "--porcelain"))) ? "" : "+dirty")
    note =
        state == "cold" ?
        "compiled caches, _cache/ and result files wiped; conda env and package sources " *
        "kept (provisioning is not measured)" : "real depot and repo; caches warm"
    return pretty_object(
        [
            ("date", jstr(Libc.strftime("%Y-%m-%dT%H:%M:%S", time()))),
            ("host", jstr(gethostname())), ("julia", jstr(facts.version)),
            ("cpu", jstr(facts.cpu)), ("cores", string(facts.cores)),
            ("state", jstr(state)), ("git_rev", jstr(rev)), ("repo", jstr(repo)),
            ("note", jstr(note)),
        ], 4)
end

# --- the run

# What an unapproved run prints instead of running.
plan(argv) = join(
    [
        "benchmarks: not running. A benchmark needs a QUIET machine, and an " *
        "unattended agent cannot tell whether it is",
        "quiet, so each run needs the repository owner's explicit approval " *
        "(they confirm nothing else is running).",
        "Planned: " * join(argv, " "),
        "It uses one core for minutes (cold: a full precompile first), " *
        "builds a throwaway depot",
        "and repo copy under the temp directory, and leaves your real depot, cache and " *
        "repository untouched.",
        "Re-run with --approved once the run has been approved."], "\n")

# Instantiates and precompiles the project at the repository (timed): the repository to
# run in, the environment of the fits and the text of the install object.
function install!(julia, state, facts, tmp)
    if state == "cold"
        repo = joinpath(tmp, "repo")
        depot = joinpath(tmp, "depot")
        env = Dict("JULIA_DEPOT_PATH" => depot, "BAYSOL_CACHE" => joinpath(tmp, "cache"))
        println("cold state in ", tmp)
        println("  copied ", copy_repo(repo), " files")
        make_depot(depot, facts.depot)
        t_pre, txt = timed(
            env,
            [julia, "--project=$repo", "-e",
                "using Pkg\nPkg.instantiate()\nt = @elapsed Pkg.precompile()\n" *
                "println(\"PRECOMPILE_S=\", t)"],
        )
        m = match(r"PRECOMPILE_S=([0-9.eE+-]+)", txt)
        m === nothing && throw(ToolError("no PRECOMPILE_S in the precompile output", 1))
        println("  instantiate + precompile: ", fmt("%.1f", t_pre), " s (precompile alone ",
            fmt("%.1f", m[1]), " s)")
        return (;
            repo,
            env,
            install = pretty_object(
                [
                    ("instantiate_and_precompile_s", string(t_pre)), ("precompile_s", m[1]),
                ], 4),
        )
    end
    t_pre, _ = timed(Dict{String,String}(),
        [julia, "--project=" * root(), "-e", "using Pkg\nPkg.precompile()"])
    return (;
        repo = root(),
        env = Dict{String,String}(),
        install = pretty_object(
            [
                ("instantiate_and_precompile_s", string(t_pre)),
                ("precompile_s", string(t_pre))], 4),
    )
end

# One fresh process for the fit `spec`: the child's JSON with the process wall time added,
# as text.
function fit!(julia, st, spec, iterations)
    t_proc, out = timed(
        st.env,
        vcat(
            [
                julia, "--project=" * st.repo,
                joinpath(st.repo, "dev", "scripts", "child.jl"), st.repo, spec,
            ], iterations),
    )
    raw = json_line(out)
    (raw === nothing || raw == "{}") && throw(
        ToolError(
            "child.jl printed no JSON object for $spec:\n$raw",
            1),
    )
    r = JSON3.read(raw)
    println(rpad(string("  ", spec), 24), "process ", lpad(fmt("%.1f", t_proc), 6),
        " s | using BAYSOL ", lpad(fmt("%.1f", r.using_baysol_s), 5), " s | first fit ",
        lpad(fmt("%.1f", r.first.total_s), 6), " s (seed ",
        lpad(fmt("%.1f", r.first.seed_s), 5),
        " + run ", lpad(fmt("%.1f", r.first.run_s), 5), ") | steady fit ",
        lpad(fmt("%.1f", r.second.total_s), 6), " s")
    # the parent measured the process wall time; add it to the child's object
    return raw[1:(end-1)] * ",\"process_wall_s\":" * string(t_proc) * "}"
end

"`bysl fits bench`: the benchmark; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    # the safeguard: no approval, no benchmark
    if !("--approved" in argv)
        println(plan(argv))
        return 0
    end
    (; opts, specs) = parse_args(filter(!=("--approved"), argv))
    state = get(opts, "state", "cold")
    isempty(specs) && throw(
        ToolError(
            "usage: bysl fits bench --approved " *
            "[--state cold|warm] [--out FILE.json] " *
            "[--samples N --adapt N] ID[:tag] ...", 1),
    )
    state in ("cold", "warm") || throw(ToolError("--state must be cold or warm", 1))
    # NUTS iterations: only when given; otherwise the child uses the run_model defaults of
    # the code it measures
    haskey(opts, "samples") == haskey(opts, "adapt") ||
        throw(ToolError("give --samples and --adapt together, or neither", 1))
    iterations = haskey(opts, "samples") ? [opts["samples"], opts["adapt"]] : String[]
    out = get(
        opts,
        "out",
        in_root("test", "baselines", "results",
            string(
                Libc.strftime("%Y%m%d-%H%M", time()),
                "-",
                state,
                "-",
                gethostname(),
                ".json",
            )),
    )
    julia = find_julia()
    facts = julia_facts(julia)
    tmp = state == "cold" ? mktempdir(; prefix = "baysol-bench-", cleanup = false) : nothing
    mkpath(dirname(abspath(out)))
    try
        st = install!(julia, state, facts, tmp)
        fits = [(spec, fit!(julia, st, spec, iterations)) for spec in specs]
        spit8(
            out,
            pretty_object(
                [("meta", meta_object(facts, state, st.repo)),
                    ("install", st.install), ("fit", pretty_object(fits, 4))], 0) * "\n",
        )
        println("wrote ", out)
    finally
        if tmp !== nothing
            if haskey(opts, "keep")
                println("kept the cold state in ", tmp,
                    " (remove it with rm -r; the links ",
                    "inside are not followed)")
            else
                rm_tree(tmp)
                println("removed ", tmp)
            end
        end
    end
    return 0
end

end

"The fitting tests with the tags each accepts."
module List
using ...Common
"`bysl fits list`: one line per fitting test, with its tags."
function run(argv::Vector{String})::Int
    if !isempty(argv)
        any(a -> a in ("--help", "-h"), argv) &&
            (
                println(
                    "Lists the fitting tests with the tags each accepts.\n\n" *
                    "    bysl fits list",
                );
                return 0
            )
        fail("bysl fits list", "takes no argument")
    end
    list_fits()
    return 0
end
end

const SUBS = [
    "run" => (Fit, "run the fitting tests and the steps that follow them"),
    "list" => (List, "the fitting tests and their tags"),
    "diagnose" => (Diagnose, "sampler diagnostics on fits, without rerunning them"),
    "profile" => (Profile, "profile the static build of fitting tests"),
    "bench" => (Bench, "the cold / steady-state benchmark (needs --approved)"),
]

const SUMMARY = "The SASBDB fitting tests.\n\n    bysl fits SUBCOMMAND [options]"

"`bysl fits`: a subcommand and its options."
run(argv::Vector{String})::Int = dispatch("bysl fits", SUMMARY, SUBS, argv)

end
