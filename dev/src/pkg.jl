# SPDX-License-Identifier: LGPL-3.0-or-later

# `bysl pkg`: builds the packaged app, one bundle of three executables, for THIS system
# (juliac and Nuitka do not cross-compile). The scratch folder (`--work`) lives in the
# cache home of the system, the archive is written to the folder the tool is run from
# (`--out`), and the scratch folder is removed afterwards unless `--keep-work` is given:
#
#   baysol          the Julia program (`tui/julia/app/baysol.jl`, built by juliac with the
#                   fits of the workload folder run at build time, so the code of a real
#                   fit is compiled in and the first fit has the JIT share of a warm one)
#   baysol-tui      the terminal interface: an esbuild bundle in a Node single executable
#   lib/pytools/baysol-pytools   propka3 and pdb2pqr frozen by Nuitka (one program)
#
# plus `julia/` (the runtime libraries), the icon of the system and the launcher script, at
# the root. The data tables, the revision are inside `baysol` and the assets and the version
# inside `baysol-tui`.
module PkgTool

using ..Common
using ..Platform: Platform
using Dates

const WHO = "bysl pkg"

const USAGE = """
Build the packaged app for this system: ONE archive with the three executables, the runtime
and the icons, `baysol-<semver>-<os>-<arch>.zip` (deflate, 7-Zip maximum settings).

    bysl pkg    [--out DIR] [--work DIR] [--workload DIR] [--stage NAME] [--resume]
                [--keep-work] [--dry-run]
    bysl pkg log [NAME...] [--steps]
    bysl pkg size DIR [--archive FILE] [--dry-run]

    --out DIR      the folder the archive is written to (default: the folder you run
                    this from)
    --work DIR      scratch folder (default `baysol-pkg-work` in the cache folder of
                    BAYSOL, `Platform.cache_dir()`); a build starts COLD: an earlier
                    folder is removed first, and the build uses its own Julia depot, uv,
                    Nuitka and fit caches inside it, never yours. Removed when the
                    archive is written, the caches even with --keep-work (a failed run
                    keeps all of it)
    --workload DIR  project folders the build fits once (default: exported by `bysl fits
                    export` from the entries of WORKLOAD)
    --stage NAME    run only this stage (pytools, tui, trace, julia, bundle); it needs
                    the earlier stages' folder, so it implies --resume
    --resume        continue the folder of a failed build (its caches included) instead
                    of starting cold; stages with a marker are skipped
    --keep-work     keep the scratch folder after the archive is written
    --dry-run       print the plan and the preflight, build nothing

    Environment: BAYSOL_JULIAC_STRIP=metadata|none|ir  strip flags of the juliac compile
                    command (default metadata: --strip-metadata; none: stock; ir adds
                    --strip-metadata --strip-ir, opt-in); recorded as `juliacStrip` in the
                    build LOG. BAYSOL_JULIAC_THREADS=N  threads of the build process
                    Size reductions, all off by default, each a row of the build LOG and
                    followed by the smoke test (a Python reduction also starts the
                    frozen tools): BAYSOL_DEDUPE=identical  byte-identical files of one
                    name become relative symlinks (Linux, macOS; Windows only reports;
                    the zip must carry links: test the unpack); BAYSOL_PY_PRUNE=on
                    removes the globs of dev/pytools-prune.txt from lib/pytools;
                    BAYSOL_JULIA_PRUNE=on removes test, docs, *.md and build sources of
                    the depot packages in the bundle (never src, artifacts, tomls)
                    Guards and limits (each a documented const of pkg-machine.jl):
                    BAYSOL_PKG_FIT_TIMEOUT_MIN=N (480) and BAYSOL_PKG_STEP_TIMEOUT_MIN=N
                    (360) end one trace fit or step after N minutes; BAYSOL_PKG_HANG_MIN=N
                    (30) ends a step with no output and no CPU for N minutes (0 turns a
                    limit off; the killed step fails, `--resume` runs it again; row
                    `timeouts`). BAYSOL_PKG_JOBS=N (1) runs the independent cold-depot
                    installs up to N at once when the memory allows (the first alone).
                    BAYSOL_PATH_SCAN=warn|fail|off (warn) counts home, work and repository
                    paths in the bundle (row `buildPathStrings`).
                    BAYSOL_JULIAC_DEBUG_INFO=0|1|2 sets --debug-info of the juliac Julia
                    (default 0).

    size            where the bytes of a bundle folder are: per component and file kind,
                    the 30 largest files, Julia artifacts and packages, Python packages,
                    test/docs/example/licence folders, duplicates; --archive FILE adds the
                    compressed size, --dry-run what the three reductions would remove
                    (nothing is changed)
    log             read the build logs of `dev/build-logs/` (those whose file name contains
                    a NAME, else all) as a short view: version, system, host, and the time
                    and peak RAM and swap of each stage; several logs end with one
                    comparison row each; --steps adds the steps inside a stage

The stages, in order: `pytools` (propka and pdb2pqr, Nuitka), `tui` (Node single
executable), `trace` (the fits of TRACE_ENTRIES and every synthetic fit, run on copies
under `<work>/trace/results` so the repository's LOGs, workbooks and plots stay as they
are; the unit suite, the TUI tests, a real command-line and interface run of every
WORKLOAD project and the output variants, all with Julia's --trace-compile, the statements
merged), `julia` (juliac: the WORKLOAD fits and the traced statements compiled into
`baysol`), `bundle` (the folder, the archive).
"""

"""
The fitting-test entries of the build, one row each: the `id`, what it is run for (`covers`)
and whether it is also a `workload` entry (compiled into `baysol` at build time and run
for real through the command line and the terminal interface). The trace stage runs every
row, then all the synthetic entries (`Common.synthetic_ids`). [`WORKLOAD`](@ref) and
[`TRACE_FITS`](@ref) are derived from it.
"""
const TRACE_ENTRIES = [
    (id = "SASDMJ9", covers = "protein; the output variants fit it", workload = true),
    (id = "SASDAN8", covers = "DNA", workload = true),
    (id = "SASDAH5", covers = "protein and DNA mixed", workload = true),
    (id = "SASDVA2", covers = "ligands; c1 kink", workload = true),
    (id = "SASDMC6", covers = "c1 kink", workload = true),
    (id = "SASDUX3", covers = "protein, 99 000 atoms", workload = false),
    (id = "SASDX52", covers = "protein, divergent", workload = false),
    (id = "SASDJ66", covers = "protein, marginal", workload = false),
    (id = "SASDP74", covers = "protein, small, divergent", workload = false),
    (id = "SASDG44", covers = "ladder class divergent", workload = false),
    (id = "SASDAP8", covers = "ladder class marginal", workload = false),
    (id = "SASDT65", covers = "ladder class step collapse", workload = false),
    (id = "SASDTV4", covers = "ladder class split chains", workload = false),
    (id = "SASDCE8", covers = "q blocking: built in two blocks", workload = false),
]

"The entries compiled into `baysol` at build time (the `workload` rows of `TRACE_ENTRIES`)."
const WORKLOAD = [e.id for e in TRACE_ENTRIES if e.workload]

"The entries the trace stage fits (every row of `TRACE_ENTRIES`), besides the synthetic."
const TRACE_FITS = [e.id for e in TRACE_ENTRIES]

# The program `trace_output_variants` runs with `--trace-compile` (arguments: project
# folder, temperature, whether to render): fits one project folder (two
# models, so that the combined comparison is drawn) five times through `runProject`,
# each time with other settings, so that the figure, table and retry code is compiled into
# the app as well: terminal plots at all sizes with `.tex`; rendered figures in every
# format; the LaTeX default font; and, with samples too few to pass the gates, the two
# rungs no LOG reaches, `structural` (sample c1) and `generic` (the next seed), which every
# failure class is mapped to.
const OUTPUT_DRIVER = raw"""
using BAYSOLRun, BAYSOL
project, temperature, compile = ARGS[1], parse(Float64, ARGS[2]), ARGS[3] == "true"
rung(overrides) = Dict(
    string(c) => [(name = "trace", overrides)] for c in BAYSOL.Pipeline.LADDER_CLASSES
)
few = (; nSamples = 60, nAdapt = 60, retryNAdapt = 60, retryNDraws = 60)
variants = [
    (; ui = :tui, watchStdin = false, tex = true, compile = false),
    (; ui = :cli, tex = true, compile, formats = [:pdf, :png, :svg]),
    (;
        ui = :cli,
        tex = true,
        compile,
        formats = [:pdf],
        style = BAYSOL.PlotStyle(font = nothing),
    ),
    (; ui = :cli, few..., ladder = rung((; SAMPLE_C1 = true))),
    (; ui = :cli, few..., ladder = rung((; RNG_SEED_STEP = 1))),
]
failed = 0
for (i, v) in enumerate(variants)
    try
        BAYSOLRun.runProject(
            project; temperature, runDir = mkpath(joinpath(project, "variant-$i")), v...,
        )
    catch e
        global failed += 1
        println(stderr, "variant $i failed: ", sprint(showerror, e))
    end
end
exit(failed == 0 ? 0 : 1)
"""

"Free swap (MiB) under which a build is stopped."
const MIN_FREE_SWAP_MIB = 500

"The pinned Node.js of the single executable (official build; the distro's is a shim)."
const NODE_VERSION = "26.13.1"

"The Python tools and their pins (`CondaPkg.toml`), the interpreter and the freezer."
const PY_PACKAGES = ["propka==3.5.1", "pdb2pqr==3.7.1", "nuitka==4.3.5", "patchelf"]
const PY_VERSION = "3.12"

"""
    py_packages(os = Platform.os()) -> Vector{String}

The pins [`PY_PACKAGES`](@ref) installs into the build's venv. `patchelf` (which sets the
RUNPATH of the Julia executable, Linux only: [`set_runtime_rpath`](@ref)) is left out on
the other systems, where it has no wheel and pip would try to build it.
"""
py_packages(os::Symbol = Platform.os()) =
    os === :linux ? copy(PY_PACKAGES) : filter(p -> p != "patchelf", PY_PACKAGES)

const STAGES = ["pytools", "tui", "trace", "julia", "bundle"]

# --- memory

"The `Key: value` lines of /proc/meminfo text as a Dict of kibibytes."
function parse_meminfo(text::AbstractString)::Dict{String,Int}
    d = Dict{String,Int}()
    for m in eachmatch(r"^(\w+):\s+(\d+)"m, text)
        d[m.captures[1]] = parse(Int, m.captures[2])
    end
    return d
end

"""
    swap_low(info; floor = MIN_FREE_SWAP_MIB) -> Bool

Whether the free swap of a [`parse_meminfo`](@ref) result is under `floor` MiB. A machine
without swap is never low (the watch has nothing to say).
"""
function swap_low(info; floor = MIN_FREE_SWAP_MIB)::Bool
    get(info, "SwapTotal", 0) > 0 || return false
    return get(info, "SwapFree", 0) ÷ 1024 < floor
end

"""
    process_memory(status) -> NTuple{2,Int}

The `(RSS, swap)` in MiB of one process, from the text of its `/proc/<pid>/status`
(`VmRSS`, `VmSwap`); `(0, 0)` for a kernel thread or an empty text.
"""
function process_memory(status::AbstractString)::NTuple{2,Int}
    function field(k)
        m = match(Regex("^$k:\\s+(\\d+) kB", "m"), status)
        return m === nothing ? 0 : parse(Int, m[1])
    end
    return (field("VmRSS") ÷ 1024, field("VmSwap") ÷ 1024)
end

"""
    descendants(parents, root; include_root = true) -> Vector{Int}

`root` (unless `include_root` is false) and every process below it, from a
`pid => parent pid` map.
"""
function descendants(
    parents::AbstractDict{Int,Int},
    root::Integer;
    include_root::Bool = true,
)::Vector{Int}
    found = [Int(root)]
    i = 1
    while i <= length(found)
        for (pid, ppid) in parents
            ppid == found[i] && pid ∉ found && push!(found, pid)
        end
        i += 1
    end
    return include_root ? found : found[2:end]
end

"""
    machine_memory() -> (ram, swap)

The total RAM and swap of the machine in MiB (`nothing` for a value the system does not
give: the swap of Windows). Linux reads `/proc/meminfo`, macOS `vm.swapusage`.
"""
function machine_memory()
    ram = Int(Sys.total_memory()) ÷ 1024^2
    swap = if Platform.islinux()
        get(parse_meminfo(read("/proc/meminfo", String)), "SwapTotal", 0) ÷ 1024
    else
        s = Platform.swap_usage()
        s === nothing ? nothing : s[1] ÷ 1024^2
    end
    return (ram = ram, swap = swap)
end

"""
    logical_cores(; os = Platform.os(), sysctl = _sysctl_logicalcpu) -> Int

The logical cores of the machine: on macOS `sysctl -n hw.logicalcpu` (asked of the system
itself, not of the Julia process), elsewhere `Sys.CPU_THREADS`; `Sys.CPU_THREADS` also when
the system does not answer a positive integer. `sysctl` is a function returning its text.
"""
function logical_cores(; os::Symbol = Platform.os(), sysctl = _sysctl_logicalcpu)::Int
    if os === :macos
        n = try
            tryparse(Int, strip(sysctl()))
        catch
            nothing
        end
        n !== nothing && n > 0 && return n
    end
    return Sys.CPU_THREADS
end

_sysctl_logicalcpu() = read(`sysctl -n hw.logicalcpu`, String)

"A MiB value for the report, `unknown` when the system does not give it."
mib_or_unknown(v) = v === nothing ? "unknown" : "$v MiB"

"""
    tree_memory(root = getpid()) -> (ram, swap)

The `(RSS, swap)` MiB summed over the CHILDREN of `root` (every process below it, not
`root` itself: the bysl driver would add its own ~1 GB to every step). Linux reads
`/proc` (`VmRSS`, `VmSwap` of those processes). macOS reads `ps` for the RSS and gives the
swap in use of the WHOLE machine (it has no per-process figure; [`watch_memory`](@ref)
turns it into a delta); `swap` is `nothing` where the system does not give it.
"""
function tree_memory(root::Integer = getpid())
    Platform.iswindows() && return windows_tree_memory(root)
    if Platform.ismacos()
        parents = Dict{Int,Int}()
        rss = Dict{Int,Int}()
        for l in split(read(`ps -axo pid=,ppid=,rss=`, String), '\n')
            f = split(l)
            length(f) == 3 || continue
            pid, ppid, kb = parse.(Int, f)
            parents[pid] = ppid
            rss[pid] = kb
        end
        used = Platform.swap_usage()
        kids = descendants(parents, root; include_root = false)
        return (sum((get(rss, p, 0) for p in kids); init = 0) ÷ 1024,
            used === nothing ? nothing : used[2] ÷ 1024^2)
    end
    parents = Dict{Int,Int}()
    for d in readdir("/proc")
        all(isdigit, d) || continue
        try
            m = match(r"^\d+ \(.*\) \S (\d+)"s, read("/proc/$d/stat", String))
            m === nothing || (parents[parse(Int, d)] = parse(Int, m[1]))
        catch
        end
    end
    total = (0, 0)
    for pid in descendants(parents, root; include_root = false)
        try
            total = total .+ process_memory(read("/proc/$pid/status", String))
        catch
        end
    end
    return total
end

"""
    sleep_unless(running, seconds; slice = 0.05)

Sleeps `seconds` in slices of `slice`, returning early once `running[]` is false, so a
watcher ends within about one slice of the signal instead of after its whole period.
"""
function sleep_unless(running::Ref{Bool}, seconds::Real; slice::Real = 0.05)
    t0 = time()
    while running[] && time() - t0 < seconds
        sleep(min(slice, max(seconds - (time() - t0), 0.0)))
    end
    return nothing
end

"""
    watch_memory(f; period = 2) -> (value, peak)

Calls `f()` and samples the memory of the processes it starts (the children of this
process: juliac, gcc, Nuitka or 7-Zip, never the bysl driver itself nor the rest of the
machine) every `period` seconds meanwhile (Linux and macOS; on Windows the peak is
`nothing`). `peak` is `(ram = MiB, swap = MiB or nothing)`, each the highest sample.
Linux: the swapped-out memory of those processes. macOS: the swap in use is machine-wide
and only grows, so it is reported as the increase over the swap in use when `f` started
(never below 0). The watcher stops within about 0.1 s of `f` returning.
"""
function watch_memory(f; period = 2)
    (Platform.islinux() || Platform.ismacos() || Platform.iswindows()) ||
        return f(), nothing
    peak = [0, 0]
    ram_unknown = Ref(false)
    unknown = Ref(false)
    base = Ref(0)
    first_sample = Ref(true)
    function sample()
        ram, swap = tree_memory()
        if ram === nothing   # the probe gave nothing (Windows): unknown, never 0
            ram_unknown[] = true
            ram = 0
        end
        if swap === nothing
            unknown[] = true
            swap = 0
        elseif Platform.ismacos()
            first_sample[] && (base[] = swap)
            swap = max(swap - base[], 0)
        end
        first_sample[] = false
        peak .= max.(peak, (ram, swap))
    end
    sample()
    running = Ref(true)
    watcher = @async while running[]
        sample()
        sleep_unless(running, period)
    end
    value = try
        f()
    finally
        running[] = false
        wait(watcher)
        sample()
    end
    return value,
    (
        ram = ram_unknown[] && peak[1] == 0 ? nothing : peak[1],
        swap = unknown[] ? nothing : peak[2],
    )
end

"""
    guarded(cmd; env = Dict(), dir = pwd(), log = nothing) -> Bool

Runs `cmd` (output to the file `log` when given) and kills it, by PID, when the swap runs
low; true when it finished with status 0. The watch is Linux only (elsewhere: none).
"""
function guarded(cmd::Cmd; env = Dict{String,String}(), dir = pwd(), log = nothing)::Bool
    c = addenv(Cmd(cmd; dir, ignorestatus = true), env...)
    out = log === nothing ? stdout : open(log, "w")
    proc = Base.run(pipeline(c; stdout = out, stderr = out); wait = false)
    stopped = Ref("")
    watch = @async begin
        while process_running(proc)
            why = current_guard_reason()   # Linux: swap; macOS, Windows: free disk
            if why !== nothing
                stopped[] = why
                kill_tree(getpid(); include_root = false)   # by PID, never pkill -f
                kill(proc)
            end
            sleep(2)
        end
    end
    wait(proc)
    wait(watch)
    log === nothing || close(out)
    isempty(stopped[]) || throw(ToolError("$WHO: stopped, $(stopped[])", 1))
    return success(proc)
end

# --- the report

"The terminal the tool was started with (`step` points `stdout` and `stderr` elsewhere)."
const REAL_OUT = Ref{IO}(stdout)

"The lines of the report file, in order: stages, steps, problems."
const REPORT = String[]

"""
The folder of the step logs (`<work>/logs`): the
whole output of each step, never the report.
"""
const LOG_DIR = Ref("")

"""
The steps run so far as `name => log path`, in the order they started: what the build log
([`write_build_log`](@ref)) is made from. Emptied at the start of a build.
"""
const STEP_LOGS = Pair{String,String}[]

"""
The file `<work>/history.tsv` that keeps the report lines (`R<TAB>line`) and steps
(`S<TAB>name<TAB>log`) of every run of one work folder, so that the build log of a resumed
build has the whole build and not only its last run. Empty outside a build.
"""
const HISTORY = Ref("")

"The report lines and steps of the earlier runs of this work folder (`--resume`)."
const PRIOR_REPORT = String[]
const PRIOR_STEPS = Pair{String,String}[]

"Appends one row to [`HISTORY`](@ref); never an error (the history is a record only)."
function remember(fields::AbstractString...)::Nothing
    isempty(HISTORY[]) && return nothing
    try
        open(io -> println(io, join(fields, '\t')), HISTORY[], "a")
    catch
    end
    return nothing
end

"Loads the rows of [`HISTORY`](@ref) into [`PRIOR_REPORT`](@ref) and [`PRIOR_STEPS`](@ref)."
function load_history()::Nothing
    empty!(PRIOR_REPORT)
    empty!(PRIOR_STEPS)
    isfile(HISTORY[]) || return nothing
    for l in eachline(HISTORY[])
        f = split(l, '\t')
        f[1] == "R" && length(f) >= 2 && push!(PRIOR_REPORT, join(f[2:end], '\t'))
        f[1] == "S" && length(f) == 3 && push!(PRIOR_STEPS, f[2] => f[3])
    end
    return nothing
end

"Lines of a step log that `problems` reports for a failed step."
const PROBLEM_LINE =
    r"Test Failed|Error During Test|Some tests did not pass|^ERROR|[Ee]xception|" *
    r"FAILED|failed:"

"""
    note(line; terminal = false)

Adds `line` to the report (and shows it on the terminal the tool was started with when
`terminal`).
"""
function note(line::AbstractString; terminal::Bool = false)
    push!(REPORT, line)
    remember("R", line)
    if terminal
        println(REAL_OUT[], line)
        flush(REAL_OUT[])
    end
    return nothing
end

"""
    problems(path, pattern = PROBLEM_LINE; limit = 12) -> Vector{String}

The lines of the log `path` that match `pattern`, trimmed to 160 characters, at most `limit`
(the last ones when there are more); the last 6 lines of the log when none matches, and
none when the file does not exist.
"""
function problems(path::AbstractString, pattern = PROBLEM_LINE; limit = 12)::Vector{String}
    isfile(path) || return String[]
    lines = [strip(l) for l in eachline(path)]
    cut(l) = length(l) > 160 ? first(l, 157) * "..." : String(l)
    hits = [cut(l) for l in lines if occursin(pattern, l)]
    isempty(hits) && return [cut(l) for l in lines[max(1, end-5):end] if !isempty(l)]
    return hits[max(1, end-limit+1):end]
end

"The log file of the step `name` (`<work>/logs/<name with odd characters as ->.log`)."
step_log(name::AbstractString) =
    joinpath(LOG_DIR[], replace(name, r"[^A-Za-z0-9._-]+" => "-") * ".log")

"""
    logged(f, path)

Calls `f()` with `stdout` and `stderr` (also those of the programs it starts) written to
the file `path`; returns what `f` returns.
"""
function logged(f, path::AbstractString)
    mkpath(dirname(path))
    return open(path, "w") do io
        redirect_stdio(f; stdout = io, stderr = io)
    end
end

"""
    step(name, f; top = false, pattern = PROBLEM_LINE) -> Bool

Runs `f()` with its output in `<LOG_DIR>/<name>.log`, timing it and sampling the memory of
the processes it starts ([`watch_memory`](@ref)), and adds one line to the report:
`name`, `ok` or `FAIL`, the wall time and the peak RAM and swap. A step fails when `f`
returns `false` or throws; the lines of its log that matter ([`problems`](@ref)) follow
the report line, and a failure is also shown on the terminal, as every `top` step (a
stage) is. True when it did not fail.
"""
function step(name::AbstractString, f; top::Bool = false, pattern = PROBLEM_LINE)::Bool
    path = step_log(name)
    push!(STEP_LOGS, name => path)
    remember("S", name, path)
    t0 = time()
    ok, peak = watch_memory() do
        try
            logged(f, path) !== false
        catch e
            open(path, "a") do io
                println(io, "ERROR: ", sprint(showerror, e))
            end
            false
        end
    end
    mem =
        peak === nothing ? "" :
        "   peak RAM $(peak.ram === nothing ? "unknown" : "$(peak.ram) MiB")" *
        (peak.swap === nothing ? "" : ", swap $(peak.swap) MiB")
    line = string(top ? "" : "  ", rpad(name, top ? 10 : 36), ok ? " ok    " : " FAIL  ",
        lpad(round(time() - t0; digits = 1), 8), " s", mem)
    note(line; terminal = top || !ok)
    if !ok
        for l in problems(path, pattern)
            note("      " * l; terminal = true)
        end
        note("      log: $path"; terminal = true)
    end
    return ok
end

"""
    write_report(path, archive)

Writes the report file: the date, the revision, the machine, then [`REPORT`](@ref).
"""
function write_report(path::AbstractString, archive::AbstractString)
    m = machine_memory()
    open(path, "w") do io
        println(io, "bysl pkg   ", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
        println(io, "revision   ", build_revision())
        println(io, "machine    ", Platform.arch(), ", ", logical_cores(),
            " logical cores (build: ", juliac_threads(), " threads), RAM ",
            mib_or_unknown(m.ram), ", swap ", mib_or_unknown(m.swap))
        println(io, "archive    ", archive)
        println(
            io,
            "peaks      the child processes of the step only (RSS and swapped-out " *
            "memory; macOS: swap in use over its level at the start of the step, " *
            "machine-wide)",
        )
        println(io)
        foreach(l -> println(io, l), REPORT)
    end
    return nothing
end

# --- the build log (tracked in the repository)

"The folder of the build logs below the repository root."
const BUILD_LOG_DIR = ("dev", "build-logs")

"Lines of a step log kept at its start and at its end (the middle is progress output)."
const LOG_KEEP_HEAD = 40
const LOG_KEEP_TAIL = 120

"The longest line of a step log kept; a longer one is cut."
const LOG_LINE_MAX = 160

"""
A line of a terminal plot: Braille cells (the scatter plots), block characters (the
histograms) or the frame characters. Such lines are left out of the build log.
"""
const PLOT_CHARS = r"[\u2800-\u28ff\u2580-\u259f\u2502\u250c\u2510\u2514\u2518]"

"A terminal colour or cursor sequence."
const ANSI_SEQUENCE = r"\e\[[0-9;?]*[ -/]*[@-~]"

"""
    clean_log(text) -> Vector{String}

The lines of one step log worth keeping: no terminal colours, a progress bar redrawn with
`\\r` counts as its last drawing, terminal plots and their centred titles and labels are
left out ([`PLOT_CHARS`](@ref); a line indented 30 columns or more), trailing blanks and
runs of blank lines are removed, a line is cut at [`LOG_LINE_MAX`](@ref) characters and a
line repeated right after itself becomes one line with `(x N)`.
"""
function clean_log(text::AbstractString)::Vector{String}
    kept = String[]
    for raw in split(text, '\n')
        parts = filter(!isempty, split(raw, '\r'))
        line =
            rstrip(replace(isempty(parts) ? "" : String(parts[end]), ANSI_SEQUENCE => ""))
        (occursin(PLOT_CHARS, line) || occursin(r"^\s{30,}\S", line)) && continue
        isempty(line) && (isempty(kept) || isempty(last(kept))) && continue
        length(line) > LOG_LINE_MAX && (line = first(line, LOG_LINE_MAX - 3) * "...")
        push!(kept, line)
    end
    while !isempty(kept) && isempty(last(kept))
        pop!(kept)
    end
    out = String[]
    i = 1
    while i <= length(kept)
        n = 1
        while i + n <= length(kept) && kept[i+n] == kept[i] && !isempty(kept[i])
            n += 1
        end
        push!(out, n == 1 ? kept[i] : "$(kept[i])   (x $n)")
        i += n
    end
    return out
end

"""
    trim_log(lines; head = LOG_KEEP_HEAD, tail = LOG_KEEP_TAIL) -> Vector{String}

`lines` when there are at most `head + tail` of them, else the first `head`, one line that
says how many were left out, and the last `tail`.
"""
function trim_log(
    lines::Vector{String};
    head::Int = LOG_KEEP_HEAD,
    tail::Int = LOG_KEEP_TAIL,
)
    length(lines) <= head + tail && return lines
    gone = length(lines) - head - tail
    return vcat(lines[1:head], ["... $gone lines left out ..."], lines[(end-tail+1):end])
end

"""
The processor model: `Sys.cpu_info` when it knows it, else the `Model name` of `lscpu`
(Asahi reports `unknown` there), else `unknown`.
"""
function cpu_model()::String
    model = Sys.cpu_info()[1].model
    model == "unknown" || return model
    try
        m = match(r"^Model name:\s*(.+)$"m, read(`lscpu`, String))
        m === nothing || return String(strip(m[1]))
    catch
    end
    return model
end

"The pretty name of the operating system (Linux: `PRETTY_NAME` of `os-release`)."
function os_description()::String
    if Sys.islinux() && isfile("/etc/os-release")
        m = match(r"^PRETTY_NAME=\"?([^\"\n]*)"m, read("/etc/os-release", String))
        m === nothing || return String(m[1])
    end
    return string(Sys.KERNEL)
end

"""
    write_build_log(path, archive)

Writes the build log of a finished full build: flat `name<TAB>value` rows (version,
archive, revision, tools, machine), the stages as the report has them (time and peak memory
of each), the cleaned log of every step ([`clean_log`](@ref), [`trim_log`](@ref); a step
with nothing left is not listed) and the machine. It is the only record of a build kept
in the repository; the step logs themselves go with the scratch folder.
"""
function write_build_log(path::AbstractString, archive::AbstractString)
    m = machine_memory()
    os, arch = system_names()
    # before the file is opened: this log is tracked, and the rewrite of it would make the
    # revision read `-dirty` on a build that started from a clean tree
    revision = build_revision()
    mkpath(dirname(path))
    open(path, "w") do io
        row(k, v) = println(io, rpad(k, cld(length(k) + 1, 8) * 8), "\t", v)
        row(
            "datetime",
            string(Libc.strftime("%Y-%m-%d %H:%M:%S", time()), " ",
                Platform.utc_offset_text()),
        )
        row("version", version_line())
        row("archive", basename(archive))
        row("revision", revision)
        row("julia", VERSION)
        row("juliacStrip", juliac_strip())
        foreach(r -> row(r...), size_header_rows(archive))    # pkg-size.jl
        row("macosDeploymentTarget", something(macos_deployment_target(), "none"))
        row("node", NODE_VERSION)
        row("python", PY_VERSION)
        row("system", "$os-$arch, $(os_description())")
        foreach(r -> row(r...), machine_log_rows())    # pkg-machine.jl
        println(io, "\n--- stages ---")
        if !isempty(PRIOR_REPORT)
            println(io, "(the runs before the last one of this build, then the last run)")
            foreach(l -> println(io, l), PRIOR_REPORT)
            println(io, "--- last run ---")
        end
        foreach(l -> println(io, l), REPORT)
        # a step of an earlier run keeps its log in the work folder; a step run again has
        # the log of its last run only
        again = Set(first.(STEP_LOGS))
        for (name, log) in vcat(filter(p -> !(first(p) in again), PRIOR_STEPS), STEP_LOGS)
            isfile(log) || continue
            lines = trim_log(clean_log(read(log, String)))
            isempty(lines) && continue
            println(io, "\n--- step: ", name, " ---")
            foreach(l -> println(io, l), lines)
        end
        foreach(l -> println(io, l), size_block_lines(archive))    # pkg-size.jl
        println(io, "\n--- machine ---")
        row("cpu", cpu_model())
        row("threads", logical_cores())
        row("buildThreads", juliac_threads())
        row("ram", mib_or_unknown(m.ram))
        row("swap", mib_or_unknown(m.swap))
    end
    return nothing
end

# --- the system

"The `(os, arch)` names Node and the notes use: `(\"linux\", \"arm64\")` and the like."
function system_names()
    os = Platform.islinux() ? "linux" : Platform.ismacos() ? "darwin" : "win"
    a = Platform.arch()
    arch = a === :aarch64 ? "arm64" : a === :x86_64 ? "x64" : string(a)
    return os, arch
end

"The URL and archive name of the official Node.js build for this system."
function node_download(version = NODE_VERSION)
    os, arch = system_names()
    ext = os == "win" ? "zip" : os == "darwin" ? "tar.gz" : "tar.xz"
    name = "node-v$version-$os-$arch"
    return "https://nodejs.org/dist/v$version/$name.$ext", name, ext
end

exe(name) = Platform.exe(name)

"""
The icon of the bundle on this system, at its root: `baysol.ico` (Windows), `baysol.icns`
(macOS) or the folder `icons` (Linux: `icons/hicolor/<size>/baysol.png`, which the setup
wizard copies into the user's `hicolor` theme). [`pack_icon`](@ref) writes it: on macOS it
is the hand-made `icons/icon.icns` verbatim, on Windows an `.ico` and on Linux the PNG
sizes of `icons/` as they are.
"""
icon_file() =
    Platform.iswindows() ? "baysol.ico" : Platform.ismacos() ? "baysol.icns" : "icons"

"The largest side of an `.ico` entry (the directory byte is 0 for 256)."
const ICO_MAX = 256

"""
    icon_sizes(dir) -> Vector{Pair{Int,String}}

The hand-made PNG sizes in the root of `dir`, named `icon_NxN.png` (N pixels) or
`icon_NxN@2x.png` (2N pixels), as `pixels => path`, smallest first. Nothing is resized: a
size that has both names takes the plain one. The pixel size in the file name must match
the PNG header.

# Returns
The sizes found, empty if there are none.

# Exceptions
`ErrorException` for a file that is not a PNG of the size its name says.
"""
function icon_sizes(dir::AbstractString)::Vector{Pair{Int,String}}
    found = Dict{Int,String}()
    isdir(dir) || return Pair{Int,String}[]
    for f in sort(readdir(dir))
        m = match(r"^icon_(\d+)x\1(@2x)?\.png$", f)
        m === nothing && continue
        px = parse(Int, m[1]) * (m[2] === nothing ? 1 : 2)
        (haskey(found, px) && m[2] !== nothing) && continue
        path = joinpath(dir, f)
        png_pixels(read(path)) == px || error("icon: $f is not a $(px)x$(px) PNG")
        found[px] = path
    end
    return sort!(collect(found); by = first)
end

"The width of a PNG (and `0` if it is not square or not a PNG), from its header."
function png_pixels(bytes::AbstractVector{UInt8})::Int
    sig = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    (length(bytes) >= 24 && bytes[1:8] == sig) || return 0
    w = Int(ntoh(only(reinterpret(UInt32, bytes[17:20]))))
    h = Int(ntoh(only(reinterpret(UInt32, bytes[21:24]))))
    return w == h ? w : 0
end

_be32(n) = collect(reinterpret(UInt8, [hton(UInt32(n))]))
_le16(n) = collect(reinterpret(UInt8, [htol(UInt16(n))]))
_le32(n) = collect(reinterpret(UInt8, [htol(UInt32(n))]))

"""
    ico_bytes(sizes) -> Vector{UInt8}

An `.ico` file with a PNG entry for each size up to 256 pixels (PNG inside `.ico` is read
by Windows since Vista).

# Returns
The file's bytes.

# Exceptions
`ErrorException` if no size is small enough.
"""
function ico_bytes(sizes)::Vector{UInt8}
    use = [(px, read(path)) for (px, path) in sizes if px <= ICO_MAX]
    isempty(use) && error("icon: no size fits an .ico entry")
    out = UInt8[0, 0, 1, 0]
    append!(out, _le16(length(use)))
    offset = 6 + 16 * length(use)
    for (px, data) in use
        side = px == ICO_MAX ? 0 : px
        append!(out, UInt8[side, side, 0, 0], _le16(1), _le16(32),
            _le32(length(data)), _le32(offset))
        offset += length(data)
    end
    for (_, data) in use
        append!(out, data)
    end
    return out
end

"The hand-made macOS icon in the root of `icons/`, shipped as it is on macOS."
const MAC_ICNS = "icon.icns"

"""
    check_icns(path) -> String

Checks the hand-made `.icns` of macOS: the file exists, starts with `icns`, its length
field matches the file and it holds at least one entry (each entry has a four-letter type
and a length that fits).

# Returns
`path`.

# Exceptions
`ErrorException` naming the problem, for a missing or malformed file.
"""
function check_icns(path::AbstractString)::String
    isfile(path) || error("icon: the macOS icon $path is missing")
    d = read(path)
    (length(d) >= 16 && d[1:4] == codeunits("icns")) ||
        error("icon: $path is not an .icns file (no `icns` header)")
    be(at) = Int(ntoh(only(reinterpret(UInt32, d[at:(at+3)]))))
    be(5) == length(d) ||
        error("icon: $path says $(be(5)) bytes but has $(length(d))")
    entries, i = 0, 9
    while i <= length(d)
        (i + 7 <= length(d) && be(i + 4) >= 8 && i + be(i + 4) - 1 <= length(d)) ||
            error("icon: $path has a broken entry at byte $i")
        entries += 1
        i += be(i + 4)
    end
    entries > 0 || error("icon: $path has no entries")
    return path
end

"""
    icon_bytes(system, dir) -> Vector{UInt8}

The bytes of the icon file for `system` (`:macos`, `:windows` or `:linux`) from the root of
`dir`: on `:macos` the hand-made `icon.icns` of `dir`, checked ([`check_icns`](@ref)) and
otherwise untouched (never replaced by one built from the PNGs); on `:windows` an `.ico` of
the PNG sizes. Linux has no single file (its PNGs go in as they are, see
[`pack_icon`](@ref)).

# Returns
The file's bytes.

# Exceptions
`ErrorException` for a bad macOS icon, no usable PNG size, or a `system` that is not
`:macos` or `:windows`.
"""
function icon_bytes(system::Symbol, dir::AbstractString)::Vector{UInt8}
    system in (:macos, :windows) || error("icon: no single icon file for $system")
    system === :macos && return read(check_icns(joinpath(dir, MAC_ICNS)))
    sizes = icon_sizes(dir)
    isempty(sizes) && error("icon: no icon_NxN.png files in $dir")
    return ico_bytes(sizes)
end

"""
The folder of the `hicolor` theme for a pixel size (the `@2` of 512 is 1024 pixels),
the name the setup wizard looks for under `icons/hicolor` in the bundle.
"""
hicolor_folder(px::Integer) = px == 1024 ? "512x512@2" : "$(px)x$(px)"

"The icon system of this machine, as [`icon_bytes`](@ref) takes it."
icon_system() = Platform.iswindows() ? :windows : Platform.ismacos() ? :macos : :linux

"Whether the icon source of `system` in `dir` is usable (the preflight check)."
function _icon_ready(system::Symbol, dir::AbstractString)::Bool
    system === :macos && return try
        check_icns(joinpath(dir, MAC_ICNS))
        true
    catch
        false
    end
    return !isempty(icon_sizes(dir))
end

"""
    pack_icon(dest, dir; system) -> String

Writes the icon of `system` (default this one) to `dest`: on macOS the hand-made
`icons/icon.icns` of `dir` verbatim, on Windows an `.ico` built from the PNG sizes in the
root of `dir` ([`icon_bytes`](@ref)); on Linux `dest` is a folder that gets those PNGs as
they are, `dest/hicolor/<size>/baysol.png` ([`hicolor_folder`](@ref)).

# Returns
`dest`.

# Exceptions
`ErrorException` as [`icon_bytes`](@ref), and for no PNG size on Linux; nothing is
written then.
"""
function pack_icon(
    dest::AbstractString,
    dir::AbstractString;
    system::Symbol = icon_system(),
)::String
    if system === :linux
        sizes = icon_sizes(dir)
        isempty(sizes) && error("icon: no icon_NxN.png files in $dir")
        for (px, path) in sizes
            folder = mkpath(joinpath(dest, "hicolor", hicolor_folder(px)))
            cp(path, joinpath(folder, "baysol.png"); force = true)
        end
        return dest
    end
    write(dest, icon_bytes(system, dir))
    return dest
end

"The zsh text of the macOS launcher (`BAYSOL.command`), see [`launcher`](@ref)."
const MACOS_LAUNCHER = raw"""
#!/bin/zsh
cd "${0:A:h}" || exit 1
# The Terminal window this script runs in, empty in another terminal or with more tabs.
# Terminal reports stale ttys, so the window is found by a unique title this script sets
# on its own tab (an escape sequence), never by its tty.
window=""
if [[ $TERM_PROGRAM == Apple_Terminal && -t 1 ]]; then
    mark="baysol-launch-$$-$RANDOM"
    printf '\033]0;%s\007' "$mark"
    sleep 0.3
    window=$(/usr/bin/osascript - "$mark" 2>/dev/null <<'END'
on run argv
    tell application "Terminal"
        repeat with w in windows
            try
                if (count of tabs of w) is 1 and name of w contains (item 1 of argv) then
                    return id of w
                end if
            end try
        end repeat
    end tell
    return ""
end run
END
)
    printf '\033]0;BAYSOL\007'
fi
./baysol "$@"
code=$?
# Finder and BAYSOL.app open a window only for this: close it after a clean end, once its
# shell is gone (a shell the user works in stays, and so does its window)
if [[ $window == <-> && ( $code == 0 || $code == 130 || $code == 22 ) ]]; then
    (
        trap "" HUP
        for _ in {1..50}; do
            sleep 0.2
            kill -0 $PPID 2>/dev/null && continue
            sleep 0.5
            /usr/bin/osascript - "$window" <<'END'
on run argv
    tell application "Terminal"
        set w to window id ((item 1 of argv) as integer)
        if (count of tabs of w) is 1 then close w saving no
    end tell
end run
END
            break
        done
    ) </dev/null >/dev/null 2>&1 &!
fi
exit $code
"""

"""
    launcher() -> (file name, text)

The script of this system that starts `baysol` (it opens what the setup wizard
chose, TUI or CLI) from the unpacked folder (a double click on macOS, the menu
entry or a terminal elsewhere): a bash script on Linux, a zsh `.command` file
on macOS, a `.cmd` file on Windows (untested). The macOS one closes the Terminal window that
was opened for it after a clean end; an error, or a shell of the user, keeps it.
"""
function launcher()
    if Platform.iswindows()
        return "baysol.cmd", "@echo off\r\n\"%~dp0baysol.exe\" %*\r\n"
    elseif Platform.ismacos()
        return "BAYSOL.command", MACOS_LAUNCHER
    end
    return "baysol.sh", raw"""
        #!/usr/bin/env bash
        cd "$(dirname "$(readlink -f "$0")")" || exit 1
        exec ./baysol "$@"
        """
end

"The semantic version of the root `Project.toml` (`0.5.0`)."
function semver()
    toml = read(joinpath(Common.root(), "Project.toml"), String)
    return match(r"^version\s*=\s*\"([^\"]*)\""m, toml)[1]
end

"""
    archive_name(version, os, arch) -> String

The name of the archive: `baysol-<semver>-<os>-<architecture>.zip`, `os` one of `linux`,
`macos`, `windows` and `arch` one of `arm64`, `x64`.
"""
archive_name(version, os, arch) = "baysol-$version-$os-$arch.zip"

"The archive name of this system for the version in `Project.toml`."
function this_archive()
    os, arch = system_names()
    return archive_name(
        semver(),
        os == "darwin" ? "macos" : os == "win" ? "windows" : os,
        arch,
    )
end

"""
The 7-Zip program that starts: `7zz`, `7z` or `7za` on the PATH first, then the `7za` of the
npm package `7zip-bin` ([`archiver_candidates`](@ref), [`pick_archiver`](@ref); each is
started once to see that it runs: the x64 one cannot start on Intel macOS under Rosetta 2).
The package ships `mac/x64/7za` without the execute bit (only `mac/arm64/7za` has it), so it
is made executable here. `nothing` when none starts; the choice is kept for the run and
logged as `archiver`.
"""
function find_7z()
    ARCHIVER_PATH[] === nothing || return ARCHIVER_PATH[]
    os, arch = system_names()
    bundled = joinpath(Common.root(), "node_modules", "7zip-bin",
        os == "win" ? "win" : os == "darwin" ? "mac" : "linux", arch, exe("7za"))
    if isfile(bundled) && !Platform.iswindows() && !Sys.isexecutable(bundled)
        try
            chmod(bundled, 0o755)
        catch
            # a read-only tree: it then fails the start probe and the chain goes on
        end
    end
    pick =
        pick_archiver(archiver_candidates(; bundled = isfile(bundled) ? bundled : nothing))
    ARCHIVER_PATH[] = pick
    ARCHIVER[] = pick === nothing ? nothing : "7-Zip $pick"
    return pick
end

"""
    node_tool(name; modules = joinpath(Common.root(), "node_modules")) -> String

The program `name` of the npm packages (`node_modules/.bin/name`). On Windows `.bin/name`
is a shell script that cannot be spawned, and `name.cmd` is the shim that can, so that one
is taken when it exists (npm writes it only on Windows).
"""
function node_tool(name::AbstractString; modules = joinpath(Common.root(), "node_modules"))
    shim = joinpath(modules, ".bin", name * ".cmd")
    return isfile(shim) ? shim : joinpath(modules, ".bin", name)
end

"""
    node_program(node_dir) -> String

The `node` program of an unpacked official Node.js build: `node.exe` in the top folder on
Windows (the archive is a zip), `bin/node` elsewhere.
"""
node_program(node_dir::AbstractString) =
    Platform.iswindows() ? joinpath(node_dir, exe("node")) :
    joinpath(node_dir, "bin", exe("node"))

"""
    unpack_command(archive, dir) -> Union{Cmd,Nothing}

The command that unpacks the Node.js `archive` into `dir`: 7-Zip for a `.zip` (the `tar`
on a Windows PATH may be Git's GNU tar, which cannot read a zip), `tar` otherwise; `nothing`
for a zip when no 7-Zip is found.
"""
function unpack_command(archive::AbstractString, dir::AbstractString)
    if endswith(archive, ".zip")
        seven = find_7z()
        seven === nothing && return nothing
        return `$seven x -y $("-o" * dir) $archive`
    end
    return `tar -xf $archive -C $dir`
end

# --- stages

"Runs a command written as a backtick `Cmd` through the tools' runner."
rc(cmd::Cmd) = run_cmd(cmd.exec)

marker(work, stage) = joinpath(work, stage * ".done")
done(work, stage) = isfile(marker(work, stage))
finish(work, stage) = write(marker(work, stage), string(time()))

function need(ok, what)
    ok || throw(ToolError("$WHO: $what", 1))
    return nothing
end

# The Python side of the packaged program, written to the scratch folder and compiled by
# Nuitka (stage `pytools`): propka3 and pdb2pqr are Python packages, so their entry point
# has to be Python.
const PYTOOLS_ENTRY = raw"""
# The Python tools of BAYSOL in one executable (compiled by `bysl pkg` with Nuitka):
#   baysol-pytools propka3 ARGS...    propka 3.5.1
#   baysol-pytools pdb2pqr ARGS...    pdb2pqr 3.7.1, its repair limit lifted
# The Julia side runs them as `<baysol-pytools> <tool> ARGS`; no Python is installed.
import sys

USAGE = "usage: baysol-pytools propka3|pdb2pqr ARGS...\n"


def main() -> int:
    tool = sys.argv.pop(1) if len(sys.argv) > 1 else ""
    if tool == "propka3":
        from propka.run import main as run
    elif tool == "pdb2pqr":
        import pdb2pqr.main as m

        # pdb2pqr repairs missing heavy atoms only while at most 10 % are missing; the limit
        # is a module constant without an option (`PDB2PQR_NO_REPAIR_LIMIT` of BAYSOL).
        m.REPAIR_LIMIT = float("inf")
        sys.argv[0] = "pdb2pqr"
        run = m.main
    else:
        sys.stderr.write(USAGE)
        return 2
    result = run()
    return result if isinstance(result, int) else 0


if __name__ == "__main__":
    sys.exit(main())
"""

"Stage `pytools`: propka3 and pdb2pqr as one Nuitka standalone program."
function stage_pytools(work)
    Platform.which("uv") === nothing && need(false, "uv is needed for the Python tools")
    venv = joinpath(work, "pyvenv")
    py = joinpath(venv, Platform.iswindows() ? "Scripts" : "bin", exe("python"))
    ok = isdir(venv) || rc(`uv venv --python $PY_VERSION $venv`)
    ok &= rc(`uv pip install --python $py $(py_packages())`)
    need(ok, "the Python environment failed")
    out = joinpath(work, "pytools")
    entry = joinpath(work, "baysol-pytools.py")
    write(entry, "# SPDX-License-Identifier: LGPL-3.0-or-later\n\n" * PYTOOLS_ENTRY)
    ok = guarded(
        `$py -m nuitka --standalone --include-package=pdb2pqr --include-package=propka
        --include-package-data=pdb2pqr --include-package-data=propka
        --python-flag=no_docstrings --noinclude-unittest-mode=nofollow
        --noinclude-setuptools-mode=nofollow --noinclude-pytest-mode=nofollow
        --noinclude-pydoc-mode=nofollow --assume-yes-for-downloads --output-dir=$out
       
        --output-filename=$(exe("baysol-pytools"))
        $entry`; log = joinpath(work, "pytools.log"),
        env = Dict("PATH" => dirname(py) * Platform.PATH_SEP * ENV["PATH"]))
    need(ok, "Nuitka failed (see $(joinpath(work, "pytools.log")))")
    finish(work, "pytools")
end

"""
    sea_config(assets) -> String

The Node single-executable configuration (JSON): the bundle `baysol-tui.mjs` as the main
script, and every file below `assets` as an asset keyed by its path below `assets` with
`/` separators, which is how `readAssetText` of the interface asks for it. The files go
into the executable, so the bundle has no `assets` folder.
"""
function sea_config(assets; extra = Dict{String,String}())
    files = Dict{String,String}(extra)
    for (dir, _, names) in walkdir(assets), n in names
        path = joinpath(dir, n)
        files[join(splitpath(relpath(path, assets)), "/")] = path
    end
    entries = join(
        ["$(repr(k)): $(repr(files[k]))" for k in sort!(collect(keys(files)))],
        ", ",
    )
    return """{"main": "baysol-tui.mjs", "output": "sea.blob", "mainFormat": "module", """ *
           """"disableExperimentalSEAWarning": true, "assets": {$entries}}"""
end

"""
    native_assets(modules; os, arch) -> Dict{String,String}

The native files the interface needs, as `asset key => file` for the SEA configuration: the
resvg addon (SVG figures), the pdf-raster addon and its PDFium library (PDF figures) and
the 7-Zip program (the run archive), each taken from the npm package of the system being
built on (`modules` is the `node_modules` folder). The program unpacks them into its cache
on first use (`tui/src/core/native-assets.ts`), because an executable cannot run a program
or load an addon from its own bytes. A missing file is an error naming it.
"""
function native_assets(modules; os = system_names()[1], arch = system_names()[2])
    node_os = os == "win" ? "win32" : os
    abi = os == "linux" ? "-gnu" : os == "win" ? "-msvc" : ""
    target = "$node_os-$arch$abi"
    pdfium =
        os == "win" ? "pdfium.dll" : os == "darwin" ? "libpdfium.dylib" : "libpdfium.so"
    zip_os = os == "darwin" ? "mac" : os
    zip = os == "win" ? "7za.exe" : "7za"
    files = [
        "native/resvg.node" =>
            joinpath(modules, "@resvg", "resvg-js-$target", "resvgjs.$target.node"),
        "native/pdf-raster.node" =>
            joinpath(modules, "pdf-raster-$target", "pdf-raster.$target.node"),
        "native/pdfium" => joinpath(modules, "pdf-raster-$target", pdfium),
        "native/$zip" => joinpath(modules, "7zip-bin", zip_os, arch, zip),
    ]
    for (key, file) in files
        isfile(file) || error("the native file for $key is missing: $file")
    end
    return Dict{String,String}(files)
end

"Stage `tui`: the esbuild bundle in the Node single executable (the natives are assets)."
function stage_tui(work)
    tui = joinpath(Common.root(), "tui")
    dir = mkpath(joinpath(work, "tui"))
    url, name, ext = node_download()
    node_dir = joinpath(dir, name)
    if !isdir(node_dir)
        archive = joinpath(dir, "node." * ext)
        isfile(archive) || need(rc(`curl -fL -o $archive $url`), "download of Node")
        unpack = unpack_command(archive, dir)
        need(unpack !== nothing && rc(unpack), "unpacking Node (a zip needs 7-Zip)")
    end
    node = node_program(node_dir)
    stub = joinpath(dir, "stub.mjs")
    write(
        stub,
        "export default {}; export const path7za = \"\"\n",
    )
    banner =
        "import{createRequire as __cr}from'node:module';" *
        "const require=__cr(import.meta.url);"
    bundle = joinpath(dir, "baysol-tui.mjs")
    esbuild = node_tool("esbuild")
    aliases = [
        "--alias:$m=$stub" for
        m in ("react-devtools-core", "7zip-bin")
    ]
    ok = rc(
        `$esbuild $(joinpath(tui, "src", "main.tsx")) --bundle --platform=node
        --main-fields=module,main --format=esm --target=node24 --minify
        --log-level=warning --outfile=$bundle --banner:js=$banner
        $aliases`,
    )
    need(ok, "esbuild failed")
    version_file = joinpath(dir, "VERSION")
    write(version_file, version_line() * "\n")
    write(
        joinpath(dir, "sea.json"),
        sea_config(
            joinpath(tui, "assets");
            extra = merge(
                Dict("VERSION" => version_file),
                native_assets(joinpath(Common.root(), "node_modules")),
            ),
        ),
    )
    cd(dir) do
        need(rc(`$node --experimental-sea-config sea.json`), "SEA blob")
        out = exe("baysol-tui")
        cp(node, out; force = true)
        # before the blob goes in, never after; not on Windows: the official node.exe is
        # built with MSVC (its symbols are in a PDB, so there is nothing to strip) and
        # carries an Authenticode signature that a strip tool may refuse
        Platform.iswindows() || strip_binary(out)
        # postject must not leave a stale signature behind the injected segment
        Platform.ismacos() && need(rc(`codesign --remove-signature $out`),
            "codesign --remove-signature failed")
        postject = node_tool("postject")
        fuse = "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"
        extra = Platform.ismacos() ? ["--macho-segment-name", "NODE_SEA"] : String[]
        need(rc(`$postject $out NODE_SEA_BLOB sea.blob --sentinel-fuse $fuse $extra`),
            "postject (is it installed? npm i -D postject at the repository root)")
        Platform.ismacos() && sign_macos([joinpath(dir, out)])
    end
    finish(work, "tui")
end

"The workload folder: `bysl fits export` of the entries of [`WORKLOAD`](@ref)."
function workload_folder(work, given)
    given === nothing || return given
    dir = joinpath(work, "workload")
    isdir(dir) ||
        need(
            run_step(
                false,
                ["bysl", "fits", "export", WORKLOAD..., "--out", dir,
                    "--from", joinpath(work, "trace", "results")],
            ),
            "export of the workload projects")
    return dir
end

"""
    app_modules() -> Set{String}

The names of the top-level modules the packaged program holds: `Base`, `Core` and every
package of the manifest of `tui/julia` (the app's own packages, their dependencies and the
standard libraries). A trace statement that names any other module (a test helper, JET, a
test-only package) cannot be compiled into `baysol`.

# Returns
The names, as a `Set{String}`.

# Exceptions
An error when `tui/julia/Manifest.toml` cannot be read.
"""
function app_modules()::Set{String}
    text = read(joinpath(Common.root(), "tui", "julia", "Manifest.toml"), String)
    names = [m.captures[1] for m in eachmatch(r"^\[\[deps\.([^\]]+)\]\]"m, text)]
    return Set(vcat(["Base", "Core"], names))
end

# `Char(0x67000000)` is how a trace file prints a `Char`; the constructor refuses it
# (`CodePointError`), `reinterpret(Char, ...)` is the same value. The Printf formats
# of every fit are written that way, so they are rewritten rather than lost.
const _CHAR_LITERAL = r"\bChar\((0x[0-9a-fA-F]+)\)"

# The module a statement names: an identifier that starts with a capital letter and is
# followed by a dot, not itself part of a longer name (`Base.string`, `Printf.Spec`).
const _MODULE_NAME = r"(?<![\w.])([A-Z][A-Za-z0-9_]*)\."

"""
    merge_statements(lines; allowed = nothing) -> Vector{String}

The `precompile(...)` statements of the `--trace-compile` files (`lines`, all files
joined), first occurrence kept, in order. Statements that name code the packaged program
does not hold are dropped: `Main.`, `Test.`, `Dev.`, the test scripts' closures, and, when
`allowed` is a set of module names ([`app_modules`](@ref)), every module outside it (the
test helper modules of the unit suite, JET, Aqua and the like). A printed `Char(0x...)` is
rewritten to `reinterpret(Char, 0x...)` so that the statement can be evaluated.

# Returns
The statements, one `String` each.

# Exceptions
None.
"""
function merge_statements(lines; allowed = nothing)::Vector{String}
    seen = Set{String}()
    out = String[]
    for l in lines
        startswith(l, "precompile(") || continue
        occursin(r"\b(Main|Test|Dev|PkgTool)\.", l) && continue
        l = replace(l, _CHAR_LITERAL => s"reinterpret(Char, \1)")
        allowed === nothing ||
            all(m -> m.captures[1] in allowed, eachmatch(_MODULE_NAME, l)) || continue
        l in seen && continue
        push!(seen, l)
        push!(out, l)
    end
    return out
end

"The environment of every program the trace stage runs: the frozen Python tools, 4 threads,
the unit suite in one process (`UNIT_JOBS=1`) so that its trace is whole. The interface's
runs read `BAYSOL_THREADS` (their launcher passes `--threads=auto,1` otherwise, which
overrides `JULIA_NUM_THREADS`): with 8 threads two of five of them hung for ever under
Rosetta 2, and the fits and command-line runs at 4 threads never did."
function trace_env(work)
    return Dict(
        "BAYSOL_PYTOOLS" => joinpath(work, "pytools", "baysol-pytools.dist",
            exe("baysol-pytools")), "JULIA_NUM_THREADS" => "4",
        "BAYSOL_THREADS" => "4",
        "UNIT_JOBS" => "1")  # the unit suite in one process, so its trace is whole
end

"Runs `cmd` with the environment `env`; true on status 0."
function run_env(cmd::Cmd, env)
    c = addenv(Cmd(cmd; dir = Common.root(), ignorestatus = true), env...)
    # a step past its time, or silent with no CPU, is ended by PID and fails (see `watched`)
    return watched(; name = current_step(), limit_min = step_timeout_min(),
        hang_minutes = hang_min()) do
        success(Base.run(c))
    end
end

"""
    unpack_references(project) -> Int

Unpacks `<project>/reference-fit.7z` (what `bysl fits export` writes and the interface
reads) into `<project>/reference-fit/`, the folder the command line (`baysol run`) and
`runProject` read, so a traced run takes the reference path a user's run takes. A project
that has the folder, or no archive, is left alone.

# Returns
The number of files unpacked.

# Exceptions
A `ToolError` when no 7-Zip is found or the archive does not unpack.
"""
function unpack_references(project)::Int
    archive = joinpath(project, "reference-fit.7z")
    target = joinpath(project, "reference-fit")
    (isfile(archive) && !isdir(target)) || return 0
    sevenzip = find_7z()
    need(sevenzip !== nothing, "no 7-Zip found to unpack $archive")
    need(rc(`$sevenzip x -y -o$target $archive`), "unpacking $archive")
    return length(readdir(target))
end

"""
    check_no_skipped_reference(name)

Fails the build when the log of the step `name` says a reference fit was skipped: the
workload exists to compile that code, so a skip means it was not exercised.

# Exceptions
A `ToolError` naming the step, when its log has a "reference fit was skipped" line.
"""
function check_no_skipped_reference(name)
    path = step_log(name)
    isfile(path) || return nothing
    occursin("reference fit was skipped", read(path, String)) &&
        throw(ToolError("$WHO: $name skipped its reference fit (see $path)", 1))
    return nothing
end

"""
    trace_output_variants(work, dir, julia, env)

Fits a copy of the first `WORKLOAD` entry (under `<dir>/projects/outputs`), with a second
model so that the comparison is drawn, five times with other settings (`OUTPUT_DRIVER`),
under `--trace-compile`; the trace is `<dir>/outputs/outputs.jl`, and `outputs.done` marks
the step as finished. The rendered variants need `lualatex` and `pdftocairo`; without
them the figures are written as `.tex` only. A failed driver is reported and does not stop
the build.
"""
function trace_output_variants(work, dir, julia, env)
    out = mkpath(joinpath(dir, "outputs"))
    isfile(joinpath(out, "outputs.done")) && return nothing
    project = joinpath(mkpath(joinpath(dir, "projects")), "outputs")
    rm(project; recursive = true, force = true)
    cp(joinpath(workload_folder(work, nothing), first(WORKLOAD)), project)
    unpack_references(project)
    models = joinpath(project, "models")
    first_model = joinpath(models, only(filter(endswith(".pdb"), readdir(models))))
    cp(first_model, replace(first_model, r"\.pdb$" => "-2.pdb"))
    driver = joinpath(work, "output-driver.jl")
    write(driver, OUTPUT_DRIVER)
    compile =
        Platform.which("lualatex") !== nothing && Platform.which("pdftocairo") !== nothing
    label = "output variants $(first(WORKLOAD)) (rendered: $compile)"
    ok = step(label,
        () -> run_env(
            `$julia --startup-file=no --threads=4
            --trace-compile=$(joinpath(out, "outputs.jl"))
            --project=$(joinpath(Common.root(), "tui", "julia")) $driver $project 20
            $compile`,
            env))
    # a failed variant run is a build error, and a rerun must not skip it as done
    ok || throw(ToolError("$WHO: the output variants failed (see $(step_log(label)))", 1))
    check_no_skipped_reference(label)
    write(joinpath(out, "outputs.done"), "")
    return nothing
end

"""
    trace_project_runs(work, dir, julia, env)

Runs every project of [`WORKLOAD`](@ref) twice for real, each on its own copy under
`<dir>/projects`, one program at a time: through the command line (`runProjectCli`, what
`baysol run` calls) and through the code of the interface (`test/support/trace-run.ts`,
which starts the run as the run screen does, with `BAYSOL_TRACE_COMPILE` set so the Julia
child writes its trace). The traces go to `<dir>/runs`. `<name>.done` marks a run that
ended, so an interrupted build resumes at the run it was in.
"""
function trace_project_runs(work, dir, julia, env)
    root = Common.root()
    runs = mkpath(joinpath(dir, "runs"))
    projects = mkpath(joinpath(dir, "projects"))
    workload = workload_folder(work, nothing)
    node = Platform.which("node")
    need(node !== nothing, "node is needed to run the interface's run code")
    app = joinpath(root, "tui", "julia")
    cli = "using BAYSOLRun; exit(BAYSOLRun.runProjectCli(ARGS; io = stderr))"
    for id in WORKLOAD, how in ("cli", "tui")
        name = "$id-$how"
        isfile(joinpath(runs, name * ".done")) && continue
        copy = joinpath(projects, name)
        rm(copy; recursive = true, force = true)
        cp(joinpath(workload, id), copy)
        how == "cli" && unpack_references(copy)  # the interface reads the archive itself
        step("$how run $id",
            () -> if how == "cli"
                run_env(
                    `$julia --startup-file=no --threads=4
                    --trace-compile=$(joinpath(runs, name * ".jl")) --project=$app -e $cli
                    $copy --temperature 20`, env)
            else
                driver = joinpath(root, "tui", "test", "support", "trace-run.ts")
                run_env(`$node --import tsx $driver $copy 20`,
                    merge(env, Dict("BAYSOL_TRACE_COMPILE" => runs)))
            end)
        check_no_skipped_reference("$how run $id")
        write(joinpath(runs, name * ".done"), "")
    end
    return nothing
end

"""
    fit_pending(fits, results, id) -> Bool

Whether the trace fit `id` has to run: it has no `<ID>.done` marker in `fits`, or it has
one but no workbook (`*.xlsx`) in a folder named `id` below `results` (a marker left by an
interrupted or failed run, or a scratch folder that lost its results).
"""
function fit_pending(
    fits::AbstractString,
    results::AbstractString,
    id::AbstractString,
)::Bool
    isfile(joinpath(fits, id * ".done")) || return true
    for (d, _, fs) in walkdir(results)
        basename(d) == id && any(endswith(".xlsx"), fs) && return false
    end
    return true
end

"""
Stage `trace`: runs everything once with `--trace-compile` (one file per program
under `<work>/trace`), in this order, one program at a time: the fits of `TRACE_FITS`
and every synthetic fit (`bysl fits run --scratch <work>/trace/results`, so their
workbooks, LOGs and plots land in the scratch folder and the repository's stay
untouched), the unit suite, the Julia tests of the TUI, then every project of `WORKLOAD`
once through the command line and once through the interface's run code
(`trace_project_runs`), and the output variants (`trace_output_variants`). A fit that
fails is reported and does not stop the stage; one that finished before an interruption
(its `<ID>.done` marker) is not run again. The merged statements are
`<work>/statements.jl` (`merge_statements`, restricted to `app_modules`).
"""
function stage_trace(work)
    root = Common.root()
    julia = find_julia()
    env = trace_env(work)
    need(isfile(env["BAYSOL_PYTOOLS"]), "the trace stage needs the pytools stage first")
    dir = mkpath(joinpath(work, "trace"))
    fits = mkpath(joinpath(dir, "fits"))
    # the workbooks, run logs and plots of the fits land here, not in the repository; the
    # folder goes with the scratch folder (kept by `--keep-work`)
    results = mkpath(joinpath(dir, "results"))
    # one fit at a time; `<ID>.done` marks a fit that ended (well or not), so an interrupted
    # build resumes at the fit it was in, whose partial trace is then overwritten
    pending = filter(id -> fit_pending(fits, results, id),
        vcat(TRACE_FITS, Common.synthetic_ids()))
    note("  trace: $(length(pending)) fits to run")
    for id in pending
        ok = step("fit $id",
            () -> watched(; name = "fit $id", limit_min = fit_timeout_min(),
                hang_minutes = hang_min()) do
                withenv(env...) do
                    Common.run_step(
                        false,
                        ["bysl", "fits", "run", id, "--trace-compile", fits,
                            "--scratch", results, "--threads", "4"],
                    )
                end
            end)
        # only a fit that passed is done: a resume runs a failed one again
        ok && write(joinpath(fits, id * ".done"), "")
    end
    tests = joinpath(dir, "tests")
    mkpath(tests)
    unit = joinpath(root, "dev", "scripts", "unittests.jl")
    if !isfile(joinpath(tests, "unit.jl"))
        ok = step("unit suite",
            () -> run_env(
                `$julia --startup-file=no --trace-compile=$(joinpath(tests, "unit.jl"))
                --project=$(joinpath(root, "test")) $unit`, env);
            pattern = r"Test Failed|Error During Test|Some tests did not pass|^ERROR")
        if !ok  # a partial trace must not count as done on a rerun
            rm(joinpath(tests, "unit.jl"); force = true)
            throw(
                ToolError("$WHO: the unit suite failed (see $(step_log("unit suite")))", 1),
            )
        end
    end
    for f in sort(filter(endswith(".test.jl"), readdir(joinpath(root, "tui", "test"))))
        out = joinpath(tests, "tui-" * f)
        isfile(out) && continue
        step("tui test $f",
            () -> run_env(`$julia --startup-file=no --trace-compile=$out
                --project=$(joinpath(root, "test")) $(joinpath(root, "tui", "test", f))`,
                env))
    end
    trace_project_runs(work, dir, julia, env)
    trace_output_variants(work, dir, julia, env)
    lines = String[]
    for (d, _, fs) in walkdir(dir), f in fs
        endswith(f, ".jl") && append!(lines, eachline(joinpath(d, f)))
    end
    statements = merge_statements(lines; allowed = app_modules())
    write(joinpath(work, "statements.jl"), join(statements, "\n") * "\n")
    note("  trace: $(length(statements)) merged statements")
    finish(work, "trace")
end

"""
    link_wrapper(work) -> String

The compiler `juliac.jl` links with on Linux (`JULIA_CC`): `gcc` with `-lm` after the other
arguments. The link command of `juliac.jl` names `-ljulia -ljulia-internal` and no `-lm`,
and the linker of Ubuntu 24.04 (binutils 2.42) no longer takes `libm` from the libraries
that need it: the link failed with "undefined reference to symbol 'floorf@@GLIBC_2.2.5'
... DSO missing from command line" after a 4 hour run (the objects are in `<work>/tmp`,
so a link can be redone by hand with the failed command and `-lm`).

# Returns
The path of the script, in `work`.
"""
function link_wrapper(work::AbstractString)::String
    path = joinpath(work, "link-gcc.sh")
    write(path, "#!/bin/sh\nexec gcc \"\$@\" -lm\n")
    chmod(path, 0o755)
    return path
end

"""
The text of `juliac.jl` that fixes the threads of the process that builds the
image (and runs the workload fits of the build):
`addenv(cmd, "OPENBLAS_NUM_THREADS" => 1, "JULIA_NUM_THREADS" => 1)`. Neither the
environment nor `--threads` of `juliac.jl` changes it (measured: the build process
has 1 thread either way), so [`patched_juliac`](@ref) rewrites it in a copy.
"""
const JULIAC_THREADS_TEXT = "\"JULIA_NUM_THREADS\" => 1)"

"""
    juliac_threads() -> Int

The Julia threads of the process that builds the image: `BAYSOL_JULIAC_THREADS` if it is
a positive integer, else 1 under Rosetta 2 (more threads risk its garbage-collector
hang, see the README) and 4 elsewhere (as the trace stage runs its fits). The workload
fits of the julia stage took 3 h 54 min on one thread (linux-x86-64) and 9 h on Windows.
"""
function juliac_threads()::Int
    n = tryparse(Int, get(ENV, "BAYSOL_JULIAC_THREADS", ""))
    n !== nothing && n >= 1 && return n
    return Platform.isrosetta() ? 1 : 4
end

"""
The text of `juliac.jl` where the strip flags of the compile command are collected
(`strip_args = String[]`, filled only under `--trim`). See [`patch_juliac_text`](@ref).
"""
const JULIAC_STRIP_TEXT = "strip_args = String[]"

"The values of `BAYSOL_JULIAC_STRIP`, see [`juliac_strip`](@ref)."
const JULIAC_STRIP_MODES = ("none", "metadata", "ir")

"""
    juliac_strip() -> String

The strip mode of the juliac compile command: `BAYSOL_JULIAC_STRIP`, one of `metadata`
(default, `--strip-metadata`: the docstrings and source metadata of methods, nothing a
run needs), `none` (stock behaviour, nothing stripped without `--trim`) or `ir`
(`--strip-metadata --strip-ir`: also the inference IR; opt-in, because code that must be
inferred at run time cannot be compiled without it).

# Returns
The mode name.

# Exceptions
A `ToolError` for any other value.
"""
function juliac_strip()::String
    mode = get(ENV, "BAYSOL_JULIAC_STRIP", "metadata")
    mode in JULIAC_STRIP_MODES && return mode
    throw(
        ToolError(
            "$WHO: BAYSOL_JULIAC_STRIP=$mode is not one of " *
            join(JULIAC_STRIP_MODES, ", "),
            1,
        ),
    )
end

"""
    patch_juliac_text(text, strip = "none") -> String

The text of `juliac.jl` with the thread count of the build process read from
`BAYSOL_JULIAC_THREADS` (default 1) and, for `strip` `metadata` or `ir`, the strip flags
in `strip_args` (see [`juliac_strip`](@ref)).

# Returns
The patched text.

# Exceptions
A `ToolError` for an unknown `strip`, or when [`JULIAC_THREADS_TEXT`](@ref) or (for a
strip mode other than `none`) [`JULIAC_STRIP_TEXT`](@ref) is not in `text` exactly once.
"""
function patch_juliac_text(text::AbstractString, strip::AbstractString = "none")::String
    strip in JULIAC_STRIP_MODES ||
        throw(ToolError("$WHO: unknown juliac strip mode `$strip`", 1))
    count(JULIAC_THREADS_TEXT, text) == 1 || throw(
        ToolError(
            "$WHO: juliac.jl does not have exactly one `$JULIAC_THREADS_TEXT` " *
            "(a Julia other than 1.12 ?): the threads of the build cannot be set",
            1,
        ),
    )
    out = replace(
        text,
        JULIAC_THREADS_TEXT =>
            "\"JULIA_NUM_THREADS\" => " * "get(ENV, \"BAYSOL_JULIAC_THREADS\", \"1\"))",
    )
    strip == "none" && return out
    count(JULIAC_STRIP_TEXT, out) == 1 || throw(
        ToolError(
            "$WHO: juliac.jl does not have exactly one `$JULIAC_STRIP_TEXT` " *
            "(a Julia other than 1.12 ?): the strip flags cannot be set",
            1,
        ),
    )
    flags = strip == "ir" ? "\"--strip-metadata\", \"--strip-ir\"" : "\"--strip-metadata\""
    return replace(out, JULIAC_STRIP_TEXT => "strip_args = String[$flags]")
end

"""
    patched_juliac(work; bindir = Sys.BINDIR, strip = "none") -> String

A copy of the `juliac` folder of the Julia installation (with the `julia-config.jl` it
includes) under `<work>/juliac-threads`, patched by [`patch_juliac_text`](@ref): the thread
count of the build process is read from `BAYSOL_JULIAC_THREADS` (default 1, as before)
instead of being fixed at 1, and `strip` (`none`, `metadata`, `ir`) adds strip flags to the
compile command even without `--trim`. Everything else of `juliac.jl` is unchanged;
`OPENBLAS_NUM_THREADS` stays 1.

# Returns
The path of the patched `juliac.jl`.

# Exceptions
A `ToolError` when `juliac.jl` lacks the expected text exactly once (another Julia than the
one this was written for): the stage must not run unpatched unseen.
"""
function patched_juliac(
    work::AbstractString;
    bindir = Sys.BINDIR,
    strip::AbstractString = "none",
)::String
    share = normpath(joinpath(bindir, "..", "share", "julia"))
    src = joinpath(share, "juliac", "juliac.jl")
    patched_text = patch_juliac_text(read(src, String), strip)
    root = joinpath(work, "juliac-threads")
    ispath(root) && rm_tree(root)
    dest = mkpath(joinpath(root, "share", "julia"))
    cp(joinpath(share, "juliac"), joinpath(dest, "juliac"))
    cp(joinpath(share, "julia-config.jl"), joinpath(dest, "julia-config.jl"))
    patched = joinpath(dest, "juliac", "juliac.jl")
    write(patched, patched_text)
    return patched
end

"""
The CPU target of the compiled app. `generic` runs on every CPU of the architecture
(owner, 2026-11-23): juliac's default is `native`, which lets LLVM use the build machine's
own instructions (an Apple M2's, say) and crash with SIGILL elsewhere, and per-CPU variants
only add code for no measured gain on float64 NUTS loops.
"""
const CPU_TARGET = "generic"

"Stage `julia`: juliac builds `baysol` with the workload run at build time."
function stage_julia(work, workload)
    dir = mkpath(joinpath(work, "julia"))
    juliac = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")
    need(isfile(juliac), "juliac.jl not found: $juliac")
    # more than one thread only where it is safe (`juliac_threads`):
    # under Rosetta 2 the stock `juliac.jl` runs, as before
    threads = juliac_threads()
    strip = juliac_strip()
    (threads > 1 || strip != "none") && (juliac = patched_juliac(work; strip))
    entry = joinpath(Common.root(), "tui", "julia", "app", "baysol.jl")
    project = joinpath(Common.root(), "tui", "julia")
    # juliac and gcc write about 6 GB to the temp folder: a tmpfs /tmp is too small
    pytools = joinpath(work, "pytools", "baysol-pytools.dist", exe("baysol-pytools"))
    need(isfile(pytools), "the workload fits need the pytools stage first")
    # the workload fits read their reference fits as a user's run does (`reference-fit/`)
    for p in readdir(workload; join = true)
        isdir(p) && unpack_references(p)
    end
    statements = joinpath(work, "statements.jl")
    # the JLL libraries of depot artifacts are opened by bare name (see `jll_libraries`)
    libs = jll_libraries(project)
    write(joinpath(dir, "jll-libraries.tsv"), join([join(l, '\t') for l in libs], '\n'))
    # the thread count of the build process: `juliac.jl` fixes it
    # at 1 and overrides this environment, so `patched_juliac`
    # reads `BAYSOL_JULIAC_THREADS` instead (see `juliac_threads`)
    env = Dict("JULIA_CPU_TARGET" => CPU_TARGET, "BAYSOL_WORKLOAD" => workload,
        "BAYSOL_PYTOOLS" => pytools,
        "JULIA_LOAD_PATH" =>
            write_jll_preferences(joinpath(work, "jll-preferences"), libs),
        jll_search_env(joinpath(work, "jll-lib"), libs),
        "BAYSOL_STATEMENTS" => statements,
        "BAYSOL_BUILD_REVISION" => build_revision(),
        "TMPDIR" => mkpath(joinpath(work, "tmp")),
        # Windows takes its temp folder from TMP / TEMP, not TMPDIR
        "TMP" => joinpath(work, "tmp"), "TEMP" => joinpath(work, "tmp"))
    # `juliac.jl` splits `JULIA_CC` like a shell would: quote the path
    Platform.islinux() && (env["JULIA_CC"] = "\"" * link_wrapper(work) * "\"")
    threads > 1 && (env["BAYSOL_JULIAC_THREADS"] = string(threads))
    log = joinpath(work, "julia.log")
    ok = step("juliac (precompile, workload fits, compile, link)",
        () -> guarded(
            `$(find_julia()) --startup-file=no $(juliac_debug_args())
            --project=$project $juliac --output-exe $(exe("baysol"))
            $(juliac_flags()) $entry`;
            env, dir, log,
        ); pattern = r"^ERROR|Failed to|Exception")
    # what the build-time workload and the compiler said, from the juliac log
    if isfile(log)
        for l in eachline(log)
            occursin(r"^statements:", l) && note("  juliac: $l")
            occursin(r"model .* failed:|run cannot start", l) && note("  workload: $l")
        end
    end
    need(ok, "juliac failed (see $log)")
    isfile(log) && occursin("reference fit was skipped", read(log, String)) &&
        throw(ToolError("$WHO: a workload fit skipped its reference fit (see $log)", 1))
    finish(work, "julia")
end

"""
    juliac_flags(os = Platform.os()) -> Vector{String}

The flags after the output name in the command of `juliac.jl`: `--relative-rpath` (the exe
looks for its libraries in an adjacent `julia/` folder) everywhere but on Windows, where
`juliac.jl` stops with "unimplemented" on it; a Windows exe finds its DLLs in its own
folder, so [`runtime_layout`](@ref) puts them there.
"""
juliac_flags(os::Symbol = Platform.os()) =
    os === :windows ? String[] : ["--relative-rpath"]

"""
    runtime_layout(out, os = Platform.os()) -> NamedTuple

Where the runtime libraries go in the bundle `out`: `libjulia` (the libraries beside
libjulia in Julia's `lib`) and `private` (those of `lib/julia`, and the JLL libraries). On
Linux and macOS they are `out/julia` and `out/julia/julia`, named by the RUNPATH of the
exe. Windows has no RUNPATH: the loader looks in the folder of the exe first (and Julia
opens the libraries it names without a path the same way), and Julia's own `bin` holds
every DLL, so both are `out` itself.
"""
function runtime_layout(out::AbstractString, os::Symbol = Platform.os())
    os === :windows && return (; libjulia = String(out), private = String(out))
    return (; libjulia = joinpath(out, "julia"), private = joinpath(out, "julia", "julia"))
end

"""
    copy_runtime(dest)

Copies the runtime libraries of the running Julia to `dest` (`runtime_layout(out).libjulia`,
`julia/` beside the exe on Linux and macOS, the folder of the exe on Windows),
laid out as Julia's own installation is: `lib/*` (libjulia) in `dest` and `lib/julia/*`
(libjulia-internal, LLVM, OpenBLAS, the JLLs) in `dest/julia`, because libjulia asks for
`julia/libopenlibm.so`, `julia/libstdc++.so.6` ... relative to itself. The exe's RUNPATH
must name both folders (`runtime_rpath`). The bare names `libopenlibm.so` and
`libopenblas64_.so` are dlopen'd by Julia and are shipped as real files under those names.
On Windows Julia's `bin` holds all the DLLs and has no `julia/` folder, so they all land
in `dest`.
"""
function copy_runtime(dest)
    lib = normpath(joinpath(Sys.BINDIR, "..", Platform.iswindows() ? "bin" : "lib"))
    for (d, to) in ((lib, dest), (joinpath(lib, "julia"), joinpath(dest, "julia")))
        isdir(d) || continue
        mkpath(to)
        for (name, from) in runtime_files(d)
            # a library Julia opens by its bare name is shipped under that name
            bare = bare_name(d, from)
            names = Platform.ismacos() ? macos_names(from, bare) : [something(bare, name)]
            for n in names
                # forced: macOS names two real files of OpenBLAS alike
                cp(from, joinpath(to, n); follow_symlinks = true, force = true)
            end
        end
    end
end

"""
    macos_names(file, bare; id = install_name(file)) -> Vector{String}

The names the library `file` is shipped under on macOS: its install name, which is what the
programs that link it ask for (`libz.1.dylib`, where the file is `libz.1.3.1.dylib`), and
the `bare` name Julia opens it by, if it has one. `libjulia-internal` and
`libjulia-codegen` have only the name libjulia opens ([`versioned_julia`](@ref)): a second
copy would be a second Julia runtime in the process.
"""
function macos_names(file, bare; id = install_name(file))::Vector{String}
    base = basename(something(id, file))
    return unique([versioned_julia(base); something(bare, String[])])
end

"The install name of the Mach-O library `file` (`otool -D`), `nothing` if it has none."
function install_name(file)::Union{String,Nothing}
    lines = split(readchomp(`otool -D $file`), '\n')
    return length(lines) > 1 ? String(lines[end]) : nothing
end

"""
`libjulia-internal.dylib` (the install name) as `libjulia-internal.1.12.dylib` (the name
libjulia opens), `libjulia-codegen` likewise; any other `name` as it is.
"""
function versioned_julia(name::AbstractString)::String
    m = match(r"^(libjulia-(?:internal|codegen))\.dylib$", name)
    return m === nothing ? String(name) :
           "$(m[1]).$(VERSION.major).$(VERSION.minor).dylib"
end

"""
    relink_macos(files; runner = rc)

Points the links of `files` to the install names that [`versioned_julia`](@ref) renames at
the new names. Invalidates the signatures: before [`sign_macos`](@ref).
"""
function relink_macos(files; runner = rc)
    edits = String[]
    for lib in ("libjulia-internal.dylib", "libjulia-codegen.dylib")
        append!(edits, ["-change", "@rpath/$lib", "@rpath/$(versioned_julia(lib))"])
    end
    for f in files
        base = basename(f)
        isfile(f) && chmod(f, filemode(f) | 0o200)      # artifact libraries are read-only
        id =
            startswith(base, r"libjulia-(internal|codegen)") ? ["-id", "@rpath/$base"] :
            String[]
        need(runner(`install_name_tool $edits $id $f`),
            "install_name_tool failed: $base")
    end
    return nothing
end

"""
The bare name (`libopenblas64_.so`) of a file of `dir` when it is one of
`BARE_RUNTIME_NAMES` (libraries that Julia opens without a version), else `nothing`.
"""
function bare_name(dir, file)
    for b in BARE_RUNTIME_NAMES
        link = joinpath(dir, b)
        ispath(link) && realpath(link) == realpath(file) && return b
    end
    return nothing
end

"""
Libraries that Julia dlopens by a name without a version, so the bundle needs that name
(with the extension of this system: `.so`, `.dylib`, `.dll`).
"""
const BARE_RUNTIME_NAMES =
    ["libopenlibm", "libopenblas64_", "libpcre2-8"] .*
    ("." * Base.BinaryPlatforms.platform_dlext())

"""
    baked_artifacts(file) -> Vector{String}

The artifact hashes whose `.../artifacts/<40 hex digits>` paths are baked into the
executable `file` (every JLL asks for its artifact by that hash at startup), sorted.
The file is read in chunks, a chunk overlapping the last by the length of one match.

# Returns
The distinct hashes.

# Exceptions
`SystemError` when the file cannot be read.
"""
function baked_artifacts(file::AbstractString)::Vector{String}
    needle = Vector{UInt8}("/artifacts/")
    tail = length(needle) + 40
    hashes = Set{String}()
    carry = UInt8[]
    open(file) do io
        while !eof(io)
            chunk = vcat(carry, read(io, 1 << 26))
            i = 1
            while (r = findnext(needle, chunk, i)) !== nothing
                last(r) + 40 <= length(chunk) || break
                h = String(chunk[(last(r)+1):(last(r)+40)])
                occursin(r"^[0-9a-f]{40}$", h) && push!(hashes, h)
                i = last(r) + 1
            end
            carry = chunk[max(1, length(chunk)-tail+1):end]
        end
    end
    return sort!(collect(hashes))
end

"The script of `jll_libraries`: one tab-separated line per library of a non-stdlib JLL."
const JLL_LIBRARIES_SCRIPT = raw"""
using TOML
root = dirname(Sys.BINDIR)
manifest = joinpath(dirname(Base.active_project()), "Manifest.toml")
for (name, entries) in TOML.parsefile(manifest)["deps"]
    endswith(name, "_jll") || continue
    for e in entries
        M = Base.require(Base.PkgId(Base.UUID(e["uuid"]), name))
        for n in names(M; all = true)
            s = String(n)
            endswith(s, "_path") || continue
            isdefined(M, Symbol(s[1:(end - 5)] * "_handle")) || continue
            path = getfield(M, n)
            path isa String && occursin("artifacts", path) && !startswith(path, root) &&
                println(join((name, e["uuid"], s, path), "\t"))
        end
    end
end
"""

"""
    jll_libraries(project) -> Vector{NTuple{4,String}}

The libraries of the JLL packages of `project` that live in a depot artifact (not in
the Julia installation, not a system library): `(jll, uuid, preference, path)`. A
JLL bakes the absolute path of its library into a compiled executable, so the build
points each one at its bare file name with a preference (`write_jll_preferences`)
and the bundle ships the file beside the other runtime libraries.

# Returns
The tuples, sorted.

# Exceptions
`ErrorException` when the Julia subprocess fails.
"""
function jll_libraries(project::AbstractString)::Vector{NTuple{4,String}}
    out = read(
        `$(find_julia()) --startup-file=no --project=$project -e $JLL_LIBRARIES_SCRIPT`,
        String,
    )
    rows = [Tuple(split(l, '\t')) for l in split(out, '\n'; keepempty = false)]
    return sort!([NTuple{4,String}(r) for r in rows if length(r) == 4])
end

"""
    jll_search_env(dir, libs) -> Pair{String,String}

Copies the JLL libraries of `libs` into `dir` under their bare names and returns the
environment variable (`LD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH` or `PATH`) that
lets the loader find them there. The preferences of `write_jll_preferences` make every
JLL open its library by bare name, also while the packages precompile and while the
workload runs inside the build, so the build process needs those names to resolve (the
finished executable finds them beside itself).
"""
function jll_search_env(dir, libs)
    mkpath(dir)
    for (_, _, _, path) in libs
        cp(path, joinpath(dir, basename(path)); force = true, follow_symlinks = true)
    end
    var = Platform.library_path_variable()
    old = get(ENV, var, "")
    return var => isempty(old) ? dir : dir * Platform.PATH_SEP * old
end

"""
    write_jll_preferences(dir, libs) -> String

Writes an environment `dir` that sets the preference `<product>_path` of each JLL of
`libs` to the file name of its library. It is stacked on the load path of the build
(`JULIA_LOAD_PATH`, the returned value), so the checkout is not touched. A preference
counts only for packages the environment lists, hence the `[extras]`.
"""
function write_jll_preferences(dir, libs)
    mkpath(dir)
    extras = join(
        ["$j = \"$u\"" for (j, u) in unique(l -> l[1], libs) .|> l -> (l[1], l[2])],
        "\n",
    )
    write(joinpath(dir, "Project.toml"), "[extras]\n$extras\n")
    prefs = String[]
    for j in unique(first.(libs))
        push!(prefs, "[$j]")
        for (jj, _, key, path) in libs
            jj == j && push!(prefs, "$key = \"$(basename(path))\"")
        end
    end
    write(joinpath(dir, "LocalPreferences.toml"), join(prefs, "\n") * "\n")
    return "@" * Platform.PATH_SEP * dir * Platform.PATH_SEP *
           "@stdlib"
end

"""
    install_jll_libraries(exe_path, libs, dest)

Puts the libraries of `libs` into `dest/julia/julia` (where libjulia-internal looks for
what Julia opens by name; `dest` itself on Windows, see [`runtime_layout`](@ref)) and, for
every artifact hash baked into the executable, a folder
`dest/share/julia/artifacts/<hash>` with a marker file: every JLL still asks for its
artifact folder at startup (a juliac executable searches `<its folder>/share/julia` as a
depot), and only that the folder exists matters, because the libraries are opened by name.

# Returns
The hashes.

# Exceptions
`SystemError` when a file cannot be copied.
"""
function install_jll_libraries(exe_path, libs, dest)
    nested = mkpath(runtime_layout(dest).private)
    for (_, _, _, path) in libs
        cp(path, joinpath(nested, basename(path)); follow_symlinks = true, force = true)
    end
    hashes = baked_artifacts(exe_path)
    for h in hashes
        dir = mkpath(joinpath(dest, "share", "julia", "artifacts", h))
        write(joinpath(dir, "README"), "the library of this artifact is in julia/julia\n")
    end
    return hashes
end

"""
The RUNPATH of the exe on Linux: the folder of libjulia and its nested `julia/` folder
(`libjulia-internal` is needed by the exe itself, and sits in the nested one).
"""
const RUNTIME_RPATH = "\$ORIGIN/julia/julia:\$ORIGIN/julia"

"""
Points the exe's RUNPATH at the runtime folders: on Linux with `patchelf` of the build's
venv; on macOS the exe made by `juliac --relative-rpath` names `@loader_path/julia` and
`@loader_path` only, and `libjulia-internal` sits one folder deeper (`julia/julia`), so
that one is added with `install_name_tool` (untested; the signature it invalidates is the
reason for the ad-hoc `codesign` the first macOS build may need, see `dev/README.md`).
Windows has no RUNPATH ([`runtime_layout`](@ref)).
"""
function set_runtime_rpath(work, exe_path)
    if Platform.ismacos()
        rpath = "@loader_path/julia/julia"
        # juliac's rpath to the folder of the exe itself holds no library of the bundle;
        # the header has no room for both it and the longer names of `relink_macos`
        need(
            rc(
                `install_name_tool -delete_rpath @loader_path/ -add_rpath $rpath
                $exe_path`,
            ),
            "install_name_tool failed",
        )
        return
    end
    Platform.islinux() || return
    patchelf = joinpath(work, "pyvenv", "bin", "patchelf")
    need(isfile(patchelf), "patchelf not found: $patchelf (stage pytools installs it)")
    need(rc(`$patchelf --set-rpath $RUNTIME_RPATH $exe_path`), "patchelf failed")
end

"""
Libraries of the Julia installation that the app never loads: its own test libraries
(`libccalltest`, `libccalllazy*`, `libllvmcalltest`), debug files and the linker script
`libgcc_s.so` (a text file for linking; the loader asks for `libgcc_s.so.1`), and the
default system image `sys.so` (traced with `LD_DEBUG=files`: a juliac executable never
loads it, it carries its own compiled code).
"""
const RUNTIME_SKIP = Regex(
    "^(libccalltest|libccalllazy|libllvmcalltest)|\\.debug\$|^libgcc_s\\.so\$|" *
    "^sys\\.(so|dylib|dll)\$|" *
    "^(libgit2|libuv|libdSFMT|libgmpxx)\\.(so|dylib|dll)",
)

"""
Files of the frozen Python tools that propka and pdb2pqr never load, as paths relative to
`lib/pytools`: `numpy/random` is imported lazily and neither tool imports it (checked on
1CRN with the propka titration, the result is byte-identical without it). The numpy BLAS
(`libscipy_openblas64_*`) is NOT here: `numpy/_core/_multiarray_umath.so` needs it, and
pdb2pqr fails to import numpy without it (checked).
"""
const PYTOOLS_SKIP = r"^numpy/random/[^/]+\.(so|dylib|pyd)$"

"""
    prune_pytools(dir) -> Int

Removes the files of `dir` (the copy of the frozen tools in the bundle) that match
`PYTOOLS_SKIP`.

# Returns
The bytes freed.

# Exceptions
None.
"""
function prune_pytools(dir::AbstractString)::Int
    freed = 0
    for (d, _, files) in walkdir(dir), f in files
        path = joinpath(d, f)
        occursin(PYTOOLS_SKIP, replace(relpath(path, dir), '\\' => '/')) || continue
        freed += filesize(path)
        rm(path)
    end
    return freed
end

"""
    runtime_files(dir) -> Vector{Pair{String,String}}

The libraries of `dir` to ship, as `name => path`: ONE real file per library, no symlinks
(a zip does not carry them reliably: some extractors write the link's target as the text
of a file, and Windows has none). The libraries are chains of names (`libjulia.so`,
`libjulia.so.1.12`, `libjulia.so.1.12.7`); the shipped name is the shortest versioned one,
which is the SONAME the loader asks for (`libjulia.so.1.12`). The bare `libX.so` links are
for linking only and are left out, and so are the files of `RUNTIME_SKIP`.

# Returns
The pairs, sorted by name.

# Exceptions
None.
"""
function runtime_files(dir::AbstractString)::Vector{Pair{String,String}}
    groups = Dict{String,Vector{String}}()      # real file => the names that lead to it
    for n in sort(readdir(dir))
        path = joinpath(dir, n)
        occursin(r"\.(so|dylib|dll)", n) && isfile(path) || continue
        occursin(RUNTIME_SKIP, n) && continue
        bare = islink(path) && occursin(r"\.(so|dylib|dll)$", n)
        bare || push!(get!(groups, realpath(path), String[]), n)
    end
    out = Pair{String,String}[]
    for names in values(groups)
        keep = sort(names; by = n -> (length(n), n))[1]
        push!(out, keep => joinpath(dir, keep))
    end
    return sort!(out; by = first)
end

"""
The short git revision of the repository, with `-dirty` when tracked files have
uncommitted changes (what `_logRevision` of the package reports for a checkout).
"""
function build_revision()
    rev = strip(git_output("rev-parse", "--short", "HEAD"))
    dirty = !isempty(strip(git_output("status", "--porcelain", "--untracked-files=no")))
    return dirty ? rev * "-dirty" : rev
end

"The version line of the root `Project.toml`: `v<version> <release_name>`."
function version_line()
    toml = read(joinpath(Common.root(), "Project.toml"), String)
    field(k) = match(Regex("^$k\\s*=\\s*\"([^\"]*)\"", "m"), toml)[1]
    return "v" * field("version") * " " * field("release_name")
end

# --- strip: the symbols of the bundle's own copies

"The one strip program, LLVM's: it reads ELF, Mach-O and PE, so no system needs another."
const STRIP_TOOL = "llvm-strip"

"Most files one `strip` command line takes (a long list is split, never one huge line)."
const STRIP_CHUNK = 100

"The first bytes of the files strip can handle: ELF, Mach-O (thin and fat) and PE."
const BINARY_MAGIC = [
    UInt8[0x7f, 0x45, 0x4c, 0x46],
    UInt8[0xfe, 0xed, 0xfa, 0xce], UInt8[0xfe, 0xed, 0xfa, 0xcf],
    UInt8[0xce, 0xfa, 0xed, 0xfe], UInt8[0xcf, 0xfa, 0xed, 0xfe],
    UInt8[0xca, 0xfe, 0xba, 0xbe],
    UInt8[0x4d, 0x5a],  # PE (Windows): "MZ"
]

"""
    binary_file(path) -> Bool

True when `path` is a regular file (not a link) that starts with an ELF, Mach-O or PE magic
number, so that scripts and linker scripts named `.so` are left alone.

# Returns
`true` or `false`.

# Exceptions
None: an unreadable file is not a binary.
"""
function binary_file(path::AbstractString)::Bool
    (isfile(path) && !islink(path)) || return false
    head = try
        open(io -> read(io, 4), path)
    catch
        return false
    end
    return any(m -> length(head) >= length(m) && head[1:length(m)] == m, BINARY_MAGIC)
end

"""
    strip_targets(dir, exes) -> (libs, exes)

The files of `dir` to strip: every shared library (`.so`, `.so.N`,
`.dylib`, `.dll`) that is a binary, and the executables named in `exes`
(paths) that are binaries. Links are skipped, so a file is stripped once.

# Returns
Two sorted vectors of paths.

# Exceptions
Whatever `walkdir` throws for an unreadable folder.
"""
function strip_targets(dir::AbstractString, exes)
    libs = String[]
    for (d, _, names) in walkdir(dir), n in names
        occursin(r"\.(so(\.\d+)*|dylib|dll)$"i, n) || continue
        path = joinpath(d, n)
        binary_file(path) && push!(libs, path)
    end
    return sort!(libs), sort!(String[e for e in exes if binary_file(e)])
end

"The `files` in lists of at most `STRIP_CHUNK`, each behind `head` (an argument vector)."
function strip_lines(head::Vector{String}, files)
    files = String.(files)
    return [
        vcat(head, files[i:min(i+STRIP_CHUNK-1, end)]) for
        i in 1:STRIP_CHUNK:length(files)
    ]
end

"""
    strip_linux(tool, libs, exes) -> Vector{Vector{String}}

The `llvm-strip` command lines: `--strip-all` on the libraries and on the executables
(measured on linux-aarch64: the Julia metadata, hence the stack-trace file:line, is not
DWARF and survives; 12 fit runs of each variant passed; llvm's `--strip-all` removes only
17 KB more than `--strip-unneeded`, which is free). Pure: nothing is run.

# Returns
Argument vectors, `tool` first.

# Exceptions
None.
"""
function strip_linux(tool::AbstractString, libs, exes)
    tool = String(tool)
    return vcat(
        strip_lines([tool, "--strip-all"], libs),
        strip_lines([tool, "--strip-all"], exes),
    )
end

"""
    strip_macos(tool, libs, exes) -> Vector{Vector{String}}

The macOS `llvm-strip` command lines: `-x` (local symbols) on the dylibs, `-S -x` (debug
and local symbols) on the executables. Pure. Best effort, untested until the owner builds
on a Mac (stripping also invalidates a code signature, so sign after it).

# Returns
Argument vectors, `tool` first.

# Exceptions
None.
"""
function strip_macos(tool::AbstractString, libs, exes)
    tool = String(tool)
    return vcat(strip_lines([tool, "-x"], libs), strip_lines([tool, "-S", "-x"], exes))
end

"""
    strip_windows(tool, libs, exes) -> Vector{Vector{String}}

The Windows `llvm-strip` command lines (it reads PE/COFF): `--strip-all` on the
DLLs and the executables. Pure. Best effort, untested until the owner builds on Windows.

# Returns
Argument vectors, `tool` first.

# Exceptions
None.
"""
function strip_windows(tool::AbstractString, libs, exes)
    tool = String(tool)
    return vcat(
        strip_lines([tool, "--strip-all"], libs),
        strip_lines([tool, "--strip-all"], exes),
    )
end

"""
    strip_command_lines(os, tool, libs, exes) -> Vector{Vector{String}}

The command lines for `os` (`:linux`, `:macos` or `:windows`); each platform has its own
function ([`strip_linux`](@ref), [`strip_macos`](@ref), [`strip_windows`](@ref)).

# Returns
Argument vectors.

# Exceptions
A `ToolError` for an unknown `os`.
"""
function strip_command_lines(os::Symbol, tool, libs, exes)
    os === :linux && return strip_linux(tool, libs, exes)
    os === :macos && return strip_macos(tool, libs, exes)
    os === :windows && return strip_windows(tool, libs, exes)
    throw(ToolError("$WHO: no strip for the system $os", 1))
end

"The system as [`strip_command_lines`](@ref) names it."
this_os() = Platform.os() === :other ? :linux : Platform.os()

"Total size in bytes of the files below `dir` (links not followed)."
function tree_bytes(dir::AbstractString)
    total = 0
    for (d, _, names) in walkdir(dir), n in names
        p = joinpath(d, n)
        islink(p) || (total += filesize(p))
    end
    return total
end

"Bytes as MiB with one decimal."
mib_text(bytes) = round(bytes / 2^20; digits = 1)

"""
    strip_binary(path; os = this_os(), tool = nothing) -> Bool

Strips one executable with the command of [`strip_command_lines`](@ref). The Node binary
of the terminal interface goes through here BEFORE `postject` injects the blob: any strip
of the finished `baysol-tui` moves the injected segment and the program prints nothing
(measured), while a stripped Node takes the blob and runs (147 to 112 MiB on linux-aarch64).

# Returns
`true` when stripped, `false` (with a warning in the report) when there is no `llvm-strip`.

# Exceptions
A `ToolError` when the strip command fails.
"""
function strip_binary(path::AbstractString; os::Symbol = this_os(), tool = nothing)
    tool === nothing && (tool = Platform.find_tool(STRIP_TOOL))
    if tool === nothing
        note("  strip: WARNING, $(basename(path)) left unstripped (no $STRIP_TOOL)";
            terminal = true)
        return false
    end
    for l in strip_command_lines(os, tool, String[], [path])
        need(rc(Cmd(l)), "strip failed: $(basename(path))")
    end
    return true
end

"""
    run_strip(lines, files; runner = l -> rc(Cmd(l))) -> Vector{String}

Runs the strip command lines of `strip_command_lines` (`files` are the files they name).
Stripping only saves space, so a file the tool refuses (a signed PE file, say) must not fail
a build that took hours: when a line fails, each of its files is retried alone (the tool
leaves a file it refuses as it was) and the refused files are returned.

# Returns
The refused files; empty when every command succeeded.

# Exceptions
None.
"""
function run_strip(lines, files; runner = l -> rc(Cmd(l)))::Vector{String}
    named = Set(String.(files))
    failed = String[]
    for l in lines
        runner(l) && continue
        mine = [f for f in l if f in named]
        head = l[1:(length(l)-length(mine))]
        for f in mine
            runner(vcat(head, [f])) || push!(failed, f)
        end
    end
    return failed
end

"""
    elf_load_ok(path) -> Bool

`false` when `path` is a 64-bit little-endian ELF file whose loadable segments the loader
would refuse: for each `PT_LOAD` segment the file offset and the virtual address must agree
modulo the alignment of the segment (`ld.so` stops with "ELF load command address/offset
not page-aligned" otherwise). `llvm-strip` 18.1.3 (Ubuntu 24.04) breaks `libunwind.so.8` of
Julia this way (measured: segment 3 moved from offset 0x7d000 to 0x285f8 at address
0x233000). `true` for everything else, so a file that is no ELF file is left alone.
"""
function elf_load_ok(path::AbstractString)::Bool
    return open(path) do io
        magic = read(io, 4)
        magic == UInt8[0x7f, 0x45, 0x4c, 0x46] || return true
        read(io, UInt8) == 2 || return true          # ELFCLASS64 only
        read(io, UInt8) == 1 || return true          # little endian only
        seek(io, 0x20)
        phoff = read(io, UInt64)
        seek(io, 0x36)
        phentsize = Int(read(io, UInt16))
        phnum = Int(read(io, UInt16))
        for i in 0:(phnum-1)
            seek(io, phoff + i * phentsize)
            ptype = read(io, UInt32)
            skip(io, 4)                              # p_flags
            offset = read(io, UInt64)
            vaddr = read(io, UInt64)
            skip(io, 8 + 8 + 8)                      # p_paddr, p_filesz, p_memsz
            align = read(io, UInt64)
            ptype == 1 && align > 1 && (vaddr % align != offset % align) && return false
        end
        return true
    end
end

"""
    strip_checked(lines, files; os = this_os(), runner = l -> rc(Cmd(l))) -> NamedTuple

[`run_strip`](@ref), and on Linux a check of each stripped file with
[`elf_load_ok`](@ref): a file the strip tool left unloadable is put back as it
was (the copies made before stripping are removed afterwards). Stripping only
saves space, so an unstripped library is better than one that does not load.

# Returns
`(failed, restored)`: the files the tool refused, and the files that were put back.

# Exceptions
None.
"""
function strip_checked(lines, files; os::Symbol = this_os(), runner = l -> rc(Cmd(l)))
    check = os === :linux
    backup(f) = f * ".pre-strip"
    check && for f in files
        isfile(f) && !islink(f) && cp(f, backup(f); force = true)
    end
    failed = run_strip(lines, files; runner)
    restored = String[]
    if check
        for f in files
            isfile(backup(f)) || continue
            if !elf_load_ok(f)
                mv(backup(f), f; force = true)
                push!(restored, f)
            else
                rm(backup(f); force = true)
            end
        end
    end
    return (; failed, restored)
end

"""
    strip_bundle(out, exes; os = this_os(), tool = nothing) -> Bool

Strips the copies in the bundle folder `out` (never the Julia installation they came
from): every shared library and the executables `exes`, and adds the size before and
after to the report. Without a `strip` program, or on a system with none, it warns in the
report and on the terminal and leaves the files as they are.

# Returns
`true` when stripped, `false` when skipped.

# Exceptions
None: a file the strip tool refuses is reported (see [`run_strip`](@ref)) and left as it is.
"""
function strip_bundle(out::AbstractString, exes; os::Symbol = this_os(), tool = nothing)
    before = tree_bytes(out)
    libs, bins = strip_targets(out, exes)
    lines = try
        tool === nothing && (tool = Platform.find_tool(STRIP_TOOL))
        tool === nothing &&
            throw(
                ToolError(
                    "$WHO: no $STRIP_TOOL program on the PATH or in the usual install " *
                    "folders",
                    1,
                ),
            )
        strip_command_lines(os, tool, libs, bins)
    catch e
        e isa ToolError || rethrow()
        note(
            "  strip: WARNING, left unstripped ($(e.message)); " *
            "the bundle is $(mib_text(before)) MiB";
            terminal = true,
        )
        return false
    end
    (; failed, restored) = strip_checked(lines, vcat(libs, bins); os)
    isempty(restored) || note(
        "  strip: WARNING, $(length(restored)) files put back unstripped (the strip tool " *
        "left them unloadable): " *
        join(basename.(first(restored, 8)), ", ") *
        (length(restored) > 8 ? ", ..." : "");
        terminal = true,
    )
    isempty(failed) || note(
        "  strip: WARNING, $(length(failed)) files left unstripped (the tool refused " *
        "them): " *
        join(basename.(first(failed, 8)), ", ") * (length(failed) > 8 ? ", ..." : "");
        terminal = true,
    )
    after = tree_bytes(out)
    note(
        "  strip: $(length(libs)) libraries, $(length(bins)) executables, " *
        "$(mib_text(before)) MiB -> $(mib_text(after)) MiB " *
        "(saved $(mib_text(before - after)) MiB)",
    )
    return true
end

"""
    macho_files(dir) -> Vector{String}

The Mach-O files (thin 64-bit or universal, by their first four bytes) below `dir`, links
left out: the libraries first, the files without a library extension (the executables) last.
"""
function macho_files(dir::AbstractString)::Vector{String}
    magics = ([0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe])
    found = String[]
    for (d, _, names) in walkdir(dir), n in names
        path = joinpath(d, n)
        (islink(path) || !isfile(path)) && continue
        open(io -> read(io, 4), path) in magics && push!(found, path)
    end
    return sort!(found; by = f -> (!occursin(r"\.(so|dylib)$", f), f))
end

"""
    sign_macos(files; runner = rc)

Signs each of `files` ad hoc (no certificate) and verifies it. Stripping, `postject` and
`install_name_tool` invalidate a signature, and Apple Silicon kills a program whose
signature is not valid. An ad-hoc signature does NOT satisfy Gatekeeper: a copy that was
downloaded needs `xattr -dr com.apple.quarantine`, or a Developer ID and notarization.
"""
function sign_macos(files; runner = rc)
    for f in files
        need(runner(`codesign --force --sign - $f`), "codesign failed: $(basename(f))")
        need(runner(`codesign --verify --strict $f`),
            "the signature is not valid: $(basename(f))")
    end
    return nothing
end

"Stage `bundle`: puts the parts together in `<work>/bundle/baysol`."
function stage_bundle(work)
    root = Common.root()
    out = joinpath(work, "bundle", "baysol")
    rm(dirname(out); recursive = true, force = true)    # our own folder, rebuilt each time
    mkpath(out)
    cp(joinpath(work, "julia", exe("baysol")), joinpath(out, exe("baysol")))
    set_runtime_rpath(work, joinpath(out, exe("baysol")))
    libs = [
        Tuple(split(l, '\t')) for
        l in eachline(joinpath(work, "julia", "jll-libraries.tsv"))
    ]
    install_jll_libraries(joinpath(out, exe("baysol")), libs, out)
    cp(joinpath(work, "tui", exe("baysol-tui")), joinpath(out, exe("baysol-tui")))
    mkpath(joinpath(out, "lib"))
    cp(joinpath(work, "pytools", "baysol-pytools.dist"), joinpath(out, "lib", "pytools"))
    freed = prune_pytools(joinpath(out, "lib", "pytools"))
    note("  pytools: $(round(freed / 2^20; digits = 1)) MiB of unused numpy files left out")
    size_prune!(out)    # BAYSOL_PY_PRUNE / BAYSOL_JULIA_PRUNE, off by default (pkg-size.jl)
    copy_runtime(runtime_layout(out).libjulia)
    # only the icon of this system, and the script that starts the terminal interface
    pack_icon(joinpath(out, icon_file()), joinpath(root, "icons"))
    name, text = launcher()
    write(joinpath(out, name), text)
    Platform.iswindows() || chmod(joinpath(out, name), 0o755)
    cp(joinpath(root, "LICENSE"), joinpath(out, "LICENSE"))
    julia_files(dir) = filter(!startswith(joinpath(dir, "lib")), macho_files(dir))
    Platform.ismacos() && relink_macos(
        filter(f -> basename(f) != exe("baysol-tui"), julia_files(out)),
    )
    # last: every file is in place and patchelf is done; only the bundle's copies are
    # touched, never the Julia installation they came from
    strip_bundle(out,
        [
            joinpath(out, exe("baysol")),
            joinpath(out, "lib", "pytools", exe("baysol-pytools")),
        ])
    # BAYSOL_DEDUPE, off by default; links stripped files, before the signing (pkg-size.jl)
    size_dedupe!(out,
        [
            joinpath(out, exe("baysol")),
            joinpath(out, exe("baysol-tui")),
            joinpath(out, "lib", "pytools", exe("baysol-pytools")),
        ])
    # after everything that changes a binary
    Platform.ismacos() && sign_macos(macho_files(out))
    finish(work, "bundle")
end

"""
    make_archive(work, archive)

Packs `<work>/bundle/baysol` into the zip file `archive` (deflate at 7-Zip's maximum:
`-mx=9 -mfb=258 -mpass=15`, which every system opens; `-mmt=on` packs the files on all
cores, the output format is unchanged), the folder `baysol` at its top.
"""
function make_archive(work, archive)
    sevenzip = find_7z()
    if sevenzip === nothing
        # macOS only: the system's own `ditto` or `zip` packs the final zip (logged)
        fb = fallback_archiver()
        need(
            fb !== nothing,
            "no 7-Zip starts (npm install gives 7zip-bin, or put 7zz on PATH)",
        )
        ARCHIVER[] = "$(fb.kind) $(fb.path) (no 7-Zip started)"
        note("  archiver: $(ARCHIVER[])"; terminal = true)
        cmd, dir = fallback_archive_command(fb, archive, joinpath(work, "bundle", "baysol"))
        ok = rc(Cmd(cmd; dir))
        need(ok && isfile(archive), "the archive was not written")
        return
    end
    ok = rc(
        `$sevenzip a -tzip -mm=Deflate -mx=9 -mfb=258 -mpass=15 $archive
        $(joinpath(work, "bundle", "baysol"))`,
    )
    need(ok && isfile(archive), "the archive was not written")
end

"""
    smoke_run(cmd; timeout = 60) -> (ok, output)

Runs `cmd` and waits at most `timeout` seconds; it is killed after that.

# Returns
`ok` is true when it exited with status 0 in time; `output` is its stdout and stderr (a
timeout adds a line saying so).

# Exceptions
None: a program that cannot start is `ok = false` with the error as `output`.
"""
function smoke_run(cmd::Cmd; timeout::Real = 60)
    file = tempname()
    try
        proc = try
            piped = pipeline(ignorestatus(cmd); stdout = file, stderr = file)
            Base.run(piped; wait = false)
        catch e
            return (false, "cannot start: " * sprint(showerror, e))
        end
        t0 = time()
        while process_running(proc) && time() - t0 < timeout
            sleep(0.05)
        end
        timed_out = process_running(proc)
        timed_out && kill(proc)
        wait(proc)
        text = read(file, String)
        timed_out && return (false, text * "\nno answer within $timeout s")
        return (success(proc), text)
    finally
        rm(file; force = true)
    end
end

"""
    smoke_test(bundle; timeout = 60) -> Bool

Starts the built `baysol` of the bundle folder with `version` (the lightest entry that
proves the executable, its runtime libraries and its launcher code load) and checks that
it answers a `v<version>` line.

# Returns
True when it did.

# Exceptions
A `ToolError` naming the program and what it printed when it cannot start, fails or does
not answer in time.
"""
function smoke_test(bundle::AbstractString; timeout::Real = 60)::Bool
    program = joinpath(bundle, exe("baysol"))
    need(isfile(program), "the built program is missing: $program")
    ok, text = smoke_run(`$program version`; timeout)
    need(
        ok && occursin(r"v\d", text),
        "the built baysol does not start (`$program version`): $(strip(text))",
    )
    println(text)
    return true
end

# --- cold caches

"The caches inside the scratch folder (names of folders there) that are always deleted."
const COLD_CACHES = ["depot", "uv-cache", "nuitka-cache", "fit-cache"]

"""
    cold_env(work) -> Dict{String,String}

The environment of every program of a build: a Julia depot of its own (`JULIA_DEPOT_PATH`:
compiled caches, artifacts and scratch spaces; `JULIAUP_DEPOT_PATH` keeps the `julia`
launcher finding the user's installation), and uv, Nuitka and the fit structures cache
(`BAYSOL_CACHE`) inside `work`, so nothing is taken from a warm cache of the user.

# Returns
The variables, `name => value`.

# Exceptions
None.
"""
function cold_env(work::AbstractString)::Dict{String,String}
    juliaup = get(ENV, "JULIAUP_DEPOT_PATH") do
        first(Base.DEPOT_PATH)
    end
    env = Dict(
        "JULIA_DEPOT_PATH" => joinpath(work, "depot"),
        "JULIAUP_DEPOT_PATH" => juliaup,
        "UV_CACHE_DIR" => joinpath(work, "uv-cache"),
        "NUITKA_CACHE_DIR" => joinpath(work, "nuitka-cache"),
        "BAYSOL_CACHE" => joinpath(work, "fit-cache"),
    )
    # the compilers and linkers (juliac, Nuitka) target this macOS version at the least
    target = macos_deployment_target()
    target === nothing || (env["MACOSX_DEPLOYMENT_TARGET"] = target)
    return env
end

"The default `MACOSX_DEPLOYMENT_TARGET` of the macOS build."
const DEFAULT_MACOS_DEPLOYMENT_TARGET = "14.0"

"""
    macos_deployment_target(os = Platform.os()) -> Union{String,Nothing}

The `MACOSX_DEPLOYMENT_TARGET` of the build steps that compile or link: the variable of
that name if it is set (so it can be overridden), else
[`DEFAULT_MACOS_DEPLOYMENT_TARGET`](@ref); `nothing` off macOS.
"""
function macos_deployment_target(os::Symbol = Platform.os())::Union{String,Nothing}
    os === :macos || return nothing
    v = strip(get(ENV, "MACOSX_DEPLOYMENT_TARGET", ""))
    return isempty(v) ? DEFAULT_MACOS_DEPLOYMENT_TARGET : String(v)
end

"""
    looks_like_work(work) -> Bool

Whether `work` is a scratch folder of this tool: named `baysol-pkg-work*` and holding a
stage marker or the `logs` folder, so a folder of anything else is never removed.
"""
function looks_like_work(work::AbstractString)::Bool
    startswith(basename(rstrip(work, Platform.DIR_SEPARATORS)), "baysol-pkg-work") ||
        return false
    isdir(work) || return false
    return isdir(joinpath(work, "logs")) || any(s -> done(work, s), STAGES)
end

"""
The extended-length prefix of Windows (backslash, backslash, question
mark, backslash): it lifts the 260 character limit of a path.
"""
const LONG_PATH_PREFIX = "\\\\?\\"

"""
    rm_tree(path)

Removes the folder `path` with everything in it. On Windows a path of more than 260
characters cannot be removed by its plain name (`rm` then stops with "directory not
empty": the file inside is out of reach), and the MinGW-w64 artifact of the build's depot
has such paths (270 characters, measured); the extended-length prefix (`LONG_PATH_PREFIX`)
lifts the limit, so the folder is removed by its prefixed full name there.
"""
function rm_tree(path::AbstractString)
    p = String(path)
    if Platform.iswindows() && !startswith(p, LONG_PATH_PREFIX)
        p = LONG_PATH_PREFIX * abspath(p)
    end
    rm(p; recursive = true, force = true)
end

"""
    remove_caches(work) -> Int

Deletes the cold caches of `COLD_CACHES` below `work` (never anything else there).

# Returns
How many folders were removed.

# Exceptions
A `ToolError` when `work` is not a scratch folder of this tool.
"""
function remove_caches(work::AbstractString)::Int
    looks_like_work(work) || throw(ToolError("$WHO: refusing to clean $work", 1))
    n = 0
    for c in COLD_CACHES
        p = joinpath(work, c)
        isdir(p) || continue
        rm_tree(p)
        n += 1
    end
    return n
end

"""
    ensure_depot(work, julia)

Installs the packages of the projects the build's Julia programs use (the app, the unit
suite and the fitting tests) into the build's own depot, once (`depot.done`), so the
first program does not fail on an empty depot. Needs the network.

# Exceptions
A `ToolError` when an install fails.
"""
function ensure_depot(work::AbstractString, julia::AbstractString)
    done(work, "depot") && return nothing
    jobs = pkg_jobs()
    if jobs > 1
        projects = [
            rel => joinpath(Common.root(), split(rel, '/')...) for rel in
            ("tui/julia", "test", "test/fitting_tests")
        ]
        parallel_depot(julia, projects, jobs;
            peaks = earlier_peaks(joinpath(Common.root(), BUILD_LOG_DIR...))) ||
            throw(ToolError("$WHO: packages could not be installed", 1))
        finish(work, "depot")
        return nothing
    end
    for rel in ("tui/julia", "test", "test/fitting_tests")
        project = joinpath(Common.root(), split(rel, '/')...)
        step("julia packages $rel (cold depot)",
            () -> run_env(
                `$julia --startup-file=no --project=$project
                -e "using Pkg; Pkg.instantiate()"`,
                Dict{String,String}()); top = true) ||
            throw(ToolError("$WHO: packages of $rel could not be installed", 1))
    end
    finish(work, "depot")
    return nothing
end

"""
    remove_work(work)

Removes the scratch folder of a finished build. Only a folder that is named
`baysol-pkg-work*` and holds the tool's `pytools.done` or `bundle.done` marker is removed.
"""
function remove_work(work)
    startswith(basename(rstrip(work, Platform.DIR_SEPARATORS)), "baysol-pkg-work") ||
        throw(ToolError("$WHO: refusing to remove $work", 1))
    (done(work, "bundle") || done(work, "pytools")) ||
        throw(ToolError("$WHO: $work does not look like this tool's folder", 1))
    rm_tree(work)
end

# --- the program

"""
    preflight_programs(os = Platform.os()) -> Vector{String}

The programs the preflight wants on the PATH. A C compiler (`gcc`, which `juliac.jl` links
with) is one on Linux and macOS only: on Windows `juliac.jl` takes the `gcc.exe` of a
MinGW-w64 artifact it downloads into the Julia depot (the network is needed once per cold
depot), unless `JULIA_CC` names another compiler. `tar` reads the Node.js archive of
Linux and macOS only (the zip of Windows goes through 7-Zip).
"""
function preflight_programs(os::Symbol = Platform.os())
    os === :windows && return ["uv", "curl", "npm"]
    return ["uv", "curl", "tar", "gcc", "npm"]
end

"The preflight lines `(ok, what, detail)` for the options."
function preflight(archive)
    cs = Tuple{Bool,String,String}[]
    push!(cs, (!ispath(archive), "archive is new", archive))
    if Platform.islinux()
        info = parse_meminfo(read("/proc/meminfo", String))
        mib = (get(info, "MemTotal", 0) + get(info, "SwapTotal", 0)) ÷ 1024
        push!(
            cs,
            (mib >= 24_000, "RAM + swap >= 24 GiB (juliac peaks near 22 GiB)", "$mib MiB"),
        )
    else
        row = memory_preflight(
            Platform.os();
            ram_mib = Int(Sys.total_memory()) ÷ 1024^2,
            free_disk_mib = free_disk_mib(swap_volume()),
        )
        row === nothing || push!(cs, row)
    end
    for p in preflight_programs()
        w = Platform.which(p)
        push!(cs, (w !== nothing, "program $p", something(w, "not on PATH")))
    end
    # the strip tool is needed, not optional: a build of hours must not end unstripped
    strip = Platform.find_tool(STRIP_TOOL)
    push!(cs, (strip !== nothing, "program $STRIP_TOOL", something(strip, "not found")))
    push!(
        cs,
        (
            _icon_ready(icon_system(), joinpath(Common.root(), "icons")),
            "icon source",
            icon_system() === :macos ? "icons/$MAC_ICNS" : "icons/icon_NxN.png",
        ),
    )
    seven = find_7z()
    push!(cs, (seven !== nothing, "program 7-Zip", something(seven, "not found")))
    push!(
        cs,
        (isdir(joinpath(Common.root(), "node_modules")), "npm packages (node_modules)",
            "root of the checkout"),
    )
    return cs
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    isempty(argv) || argv[1] != "log" || return log_command(argv[2:end])
    isempty(argv) || argv[1] != "size" || return size_command(argv[2:end])
    a = split_args(WHO, ["--out", "--work", "--workload", "--stage"],
        ["--dry-run", "--keep-work", "--resume"], argv)
    isempty(a.specs) || fail(WHO, "unexpected argument $(first(a.specs))")
    opts = Dict(a.opts)
    archive = joinpath(abspath(get(opts, "--out", pwd())), this_archive())
    work = abspath(
        get(opts, "--work", joinpath(Platform.cache_dir(), "baysol-pkg-work")),
    )
    only = get(opts, "--stage", nothing)
    only === nothing || only in STAGES || fail(WHO, "unknown stage $only")
    cs = preflight(archive)
    for (ok, what, detail) in cs
        println(ok ? "ok  " : "FAIL", " ", rpad(what, 48), detail)
    end
    println("stages: ", join(STAGES, " > "), "   archive: ", archive, "   work: ", work)
    "--dry-run" in a.flags && return all(first, cs) ? 0 : 1
    all(first, cs) || return 1
    # the report and the archive go there; `--out` may not exist yet
    mkpath(dirname(archive))
    resume = "--resume" in a.flags || only !== nothing
    if !resume && ispath(work)
        looks_like_work(work) ||
            fail(WHO, "$work exists and is not this tool's folder (remove it yourself)")
        rm_tree(work)  # cold: nothing of an earlier build
    end
    mkpath(work)
    workload = get(opts, "--workload", nothing)
    REAL_OUT[] = stdout
    empty!(REPORT)
    empty!(STEP_LOGS)
    reset_machine_state()   # pkg-machine.jl (the daemon keeps the module between runs)
    LOG_DIR[] = mkpath(joinpath(work, "logs"))
    HISTORY[] = joinpath(work, "history.tsv")
    load_history()   # nothing on a cold build (the folder was emptied above)
    report = joinpath(dirname(archive), "baysol-pkg-report.txt")
    t_all = time()
    failed = false
    cold = cold_env(work)
    for (k, v) in cold
        k == "JULIAUP_DEPOT_PATH" || mkpath(v)
    end
    # every child program (and this process's own `withenv` users) sees the cold caches
    withenv(cold...) do
        try
            ensure_depot(work, find_julia())
        catch e
            e isa ToolError || rethrow()
            note("depot: $(e.message)"; terminal = true)
            failed = true
        end
        for s in STAGES
            failed && break
            only !== nothing && s != only && continue
            if done(work, s) && only === nothing && resume
                note(rpad(s, 10) * " skipped (done before)"; terminal = true)
                continue
            end
            ok = step("stage $s",
                () -> if s == "pytools"
                    stage_pytools(work)
                elseif s == "tui"
                    stage_tui(work)
                elseif s == "trace"
                    stage_trace(work)
                elseif s == "julia"
                    stage_julia(work, workload_folder(work, workload))
                else
                    stage_bundle(work)
                    true    # a `false` would count as a failed stage
                end; top = true)
            write_report(report, archive)
            ok || (failed = true; break)
        end
    end
    # the built program must start, from the finished bundle folder, before it is packed
    if !failed && (only === nothing || only == "bundle")
        step("smoke (baysol version)",
            () -> smoke_test(joinpath(work, "bundle", "baysol")); top = true) ||
            (failed = true)
        # the size of the bundle (for the build log), and the frozen tools after a reduction
        failed || size_steps(work) || (failed = true)
        # build paths (home folder, work folder, repository) left in the bundle
        failed ||
            step("build paths",
                () -> path_scan_step(joinpath(work, "bundle", "baysol"); work); top = true,
            ) ||
            (failed = true)
    end
    # a full run always ends with the archive, also when `--resume` found every stage done
    if !failed && only === nothing
        step("archive (7-Zip)", () -> make_archive(work, archive); top = true) ||
            (failed = true)
    end
    note("total      $(round((time() - t_all) / 60; digits = 1)) min"; terminal = true)
    write_report(report, archive)
    println("report: ", report)
    failed && return 1
    if only === nothing
        # the one record kept of a build (the step logs go with the scratch folder below)
        build_log = joinpath(
            Common.root(),
            BUILD_LOG_DIR...,
            replace(basename(archive),
                r"\.zip$" => ".LOG"),
        )
        try
            write_build_log(build_log, archive)
            println("build log: ", build_log)
        catch e
            println("build log not written: ", sprint(showerror, e))
        end
        # the archive is written: a folder that cannot be removed must not fail the build
        try
            remove_caches(work)  # always: the depot and the other caches are never kept
            "--keep-work" in a.flags || remove_work(work)
        catch e
            println("cleanup incomplete (remove $work yourself): ", sprint(showerror, e))
        end
        println("archive: ", archive)
    end
    return 0
end

include("pkg-size.jl")
include("pkg-log.jl")
include("pkg-machine.jl")

end
