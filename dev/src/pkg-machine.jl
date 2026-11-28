# SPDX-License-Identifier: LGPL-3.0-or-later

# The machine side of `bysl pkg`, kept apart from the stages: the memory guard of the
# systems whose swap is not a fixed size (macOS, Windows), the process probes of Windows,
# the scan for build paths in the bundle, the choice of the archiver, the timeouts and hang
# detector of the steps, and the opt-in parallel jobs. Every decision is a pure function of
# its inputs (so canned input tests it on any system); the few functions that ask the
# machine (`/proc`, `ps`, `powershell`, `diskstat`) are small and named for it. Only Linux
# (and macOS arm64 on a real Mac for the owner) has run this code; the macOS and Windows
# probes are written from the documented output of the tools and are untested on a real
# machine. Included into `PkgTool`.

# --- the disk-backed memory guard (macOS and Windows)

"""
Free space (MiB) of the volume that holds the swap files under which a build is stopped on
macOS and Windows, where the swap grows on demand on the system volume and is not a size
fixed up front (Linux: [`MIN_FREE_SWAP_MIB`](@ref)).
"""
const MIN_FREE_DISK_MIB = 4096

"""
RAM plus usable swap (MiB) the build needs: the juliac stage peaks near 22 GiB (10 GiB
resident, 14 GiB swapped on Linux). On macOS and Windows the usable swap is the free space
of the system volume above [`MIN_FREE_DISK_MIB`](@ref).
"""
const NEED_MEMORY_MIB = 24_000

"Whether the swap of `os` is made on demand on the disk (so the disk is what to watch)."
disk_backed_swap(os::Symbol = Platform.os()) = os === :macos || os === :windows

"""
    swap_volume(os = Platform.os(); env = ENV, isdir = Base.isdir) -> String

A path on the volume the swap files of `os` are made on: `/private/var/vm` on macOS
(`/` when it is not there), the system drive on Windows (`SystemDrive`, else `C:`), `/`
elsewhere.
"""
function swap_volume(os::Symbol = Platform.os(); env = ENV, isdir = Base.isdir)::String
    os === :macos && return isdir("/private/var/vm") ? "/private/var/vm" : "/"
    os === :windows && return string(get(env, "SystemDrive", "C:"), "\\")
    return "/"
end

"""
    free_disk_mib(path; stat = diskstat) -> Union{Int,Nothing}

The free space in MiB of the volume that holds `path` (the nearest folder that exists, when
`path` itself does not); `nothing` when the system does not say. `stat` is `diskstat`.
"""
function free_disk_mib(path::AbstractString; stat = diskstat)::Union{Int,Nothing}
    p = String(path)
    while !ispath(p) && dirname(p) != p
        p = dirname(p)
    end
    try
        return Int(stat(p).available) ÷ 1024^2
    catch
        return nothing
    end
end

"""
    memory_preflight(os; ram_mib, free_disk_mib, floor = MIN_FREE_DISK_MIB,
        need = NEED_MEMORY_MIB) -> Union{Tuple{Bool,String,String},Nothing}

The preflight row `(ok, what, detail)` for a system whose swap grows on the disk: RAM plus
the free disk space above `floor` must reach `need` MiB. `nothing` for Linux (its own
row, RAM + `SwapTotal`, stays in `preflight`). An unknown free disk passes with a detail
saying it was not checked: unknown is not a failure.
"""
function memory_preflight(
    os::Symbol;
    ram_mib::Integer,
    free_disk_mib::Union{Integer,Nothing},
    floor::Integer = MIN_FREE_DISK_MIB,
    need::Integer = NEED_MEMORY_MIB,
)::Union{Tuple{Bool,String,String},Nothing}
    disk_backed_swap(os) || return nothing
    what =
        "RAM + free disk >= $(need ÷ 1024) GiB (swap files grow on the system volume; " *
        "$floor MiB stay free)"
    free_disk_mib === nothing &&
        return (true, what, "$ram_mib MiB RAM, free disk unknown (not checked)")
    usable = max(free_disk_mib - floor, 0)
    return (
        ram_mib + usable >= need,
        what,
        "$ram_mib MiB RAM + $usable MiB of $free_disk_mib MiB free disk",
    )
end

"""
    guard_reason(os; swap_info = nothing, free_disk_mib = nothing,
        swap_floor = MIN_FREE_SWAP_MIB, disk_floor = MIN_FREE_DISK_MIB)
        -> Union{String,Nothing}

Why a running build is to be stopped, or `nothing`. Linux: the free swap of the
[`parse_meminfo`](@ref) result `swap_info` is under `swap_floor` MiB ([`swap_low`](@ref)).
macOS and Windows: the free disk space is under `disk_floor` MiB. A value that is not
given is not checked.
"""
function guard_reason(
    os::Symbol;
    swap_info = nothing,
    free_disk_mib::Union{Integer,Nothing} = nothing,
    swap_floor::Integer = MIN_FREE_SWAP_MIB,
    disk_floor::Integer = MIN_FREE_DISK_MIB,
)::Union{String,Nothing}
    if os === :linux
        swap_info !== nothing && swap_low(swap_info; floor = swap_floor) &&
            return "free swap under $swap_floor MiB"
    elseif disk_backed_swap(os)
        free_disk_mib !== nothing && free_disk_mib < disk_floor &&
            return "free disk under $disk_floor MiB (the swap files fill the system volume)"
    end
    return nothing
end

"The lowest free disk space (MiB) the guard has seen in this run, `nothing` before one."
const MIN_FREE_DISK_SEEN = Ref{Union{Int,Nothing}}(nothing)

"Records `mib` in [`MIN_FREE_DISK_SEEN`](@ref) when it is a new low."
function note_free_disk(mib::Union{Integer,Nothing})::Nothing
    mib === nothing && return nothing
    cur = MIN_FREE_DISK_SEEN[]
    (cur === nothing || mib < cur) && (MIN_FREE_DISK_SEEN[] = Int(mib))
    return nothing
end

"""
    current_guard_reason(os = Platform.os()) -> Union{String,Nothing}

[`guard_reason`](@ref) for the machine as it is now: Linux reads `/proc/meminfo`, macOS and
Windows the free disk space of [`swap_volume`](@ref) (also noted for the report).
"""
function current_guard_reason(os::Symbol = Platform.os())::Union{String,Nothing}
    if os === :linux
        return guard_reason(os; swap_info = parse_meminfo(read("/proc/meminfo", String)))
    elseif disk_backed_swap(os)
        free = free_disk_mib(swap_volume(os))
        note_free_disk(free)
        return guard_reason(os; free_disk_mib = free)
    end
    return nothing
end

"""
    parse_swapusage(text) -> Union{NTuple{3,Int},Nothing}

`(total, used, free)` in MiB from the text `sysctl vm.swapusage` prints on macOS
(`vm.swapusage: total = 2048.00M  used = 1024.25M  free = 1023.75M  (encrypted)`);
`nothing` for a text that does not have them.
"""
function parse_swapusage(text::AbstractString)::Union{NTuple{3,Int},Nothing}
    m = match(
        r"total\s*=\s*([\d.]+)([MGK])\s+used\s*=\s*([\d.]+)([MGK])" *
        r"\s+free\s*=\s*([\d.]+)([MGK])",
        text,
    )
    m === nothing && return nothing
    mib(v, u) = round(Int, parse(Float64, v) * (u == "G" ? 1024 : u == "K" ? 1 / 1024 : 1))
    return (mib(m[1], m[2]), mib(m[3], m[4]), mib(m[5], m[6]))
end

"""
    parse_memory_pressure(text) -> Union{Int,Nothing}

The `System-wide memory free percentage` of the text `memory_pressure` prints on macOS;
`nothing` when it is not there.
"""
function parse_memory_pressure(text::AbstractString)::Union{Int,Nothing}
    m = match(r"System-wide memory free percentage:\s*(\d+)\s*%", text)
    return m === nothing ? nothing : parse(Int, m[1])
end

# --- process probes (Windows, and the kill by PID)

"""
    parse_windows_processes(csv) -> NamedTuple

The processes of the CSV text `Get-CimInstance Win32_Process | Select-Object ProcessId,
ParentProcessId, WorkingSetSize | ConvertTo-Csv -NoTypeInformation` prints: `parents`
(`pid => parent pid`) and `rss` (`pid => working set in MiB`). A line that is not three
quoted numbers (the header, a blank) is left out; an empty working set counts as 0.
"""
function parse_windows_processes(csv::AbstractString)
    parents = Dict{Int,Int}()
    rss = Dict{Int,Int}()
    for line in split(csv, r"\r?\n")
        f = split(strip(line), ',')
        length(f) == 3 || continue
        v = [tryparse(Int, strip(x, [' ', '"'])) for x in f]
        (v[1] === nothing || v[2] === nothing) && continue
        parents[v[1]] = v[2]
        rss[v[1]] = (v[3] === nothing ? 0 : v[3]) ÷ 1024^2
    end
    return (; parents, rss)
end

"The PowerShell command text of [`windows_process_csv`](@ref)."
const WINDOWS_PROCESS_QUERY =
    "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId," *
    "WorkingSetSize | ConvertTo-Csv -NoTypeInformation"

"""
    windows_process_csv(; powershell = Platform.find_tool("powershell", "pwsh"))
        -> Union{String,Nothing}

The text [`parse_windows_processes`](@ref) reads, from PowerShell; `nothing` when there is
none or it fails (Windows has no `/proc`, and `wmic` is gone from Windows 11).
"""
function windows_process_csv(;
    powershell = Platform.find_tool("powershell", "pwsh"),
)::Union{String,Nothing}
    powershell === nothing && return nothing
    try
        return read(
            `$powershell -NoProfile -NonInteractive -Command $WINDOWS_PROCESS_QUERY`,
            String,
        )
    catch
        return nothing
    end
end

"""
    windows_tree_memory(root = getpid(); csv = windows_process_csv)
        -> Tuple{Union{Int,Nothing},Nothing}

`(RSS in MiB, nothing)` of the children of `root` on Windows: the working sets of every
process below it. The swap is `nothing` (a commit charge is not swapped-out memory). The RSS
is `nothing`, never 0, when the probe gives no text, so the report says `unknown`.
"""
function windows_tree_memory(root::Integer = getpid(); csv = windows_process_csv)
    text = csv()
    text === nothing && return (nothing, nothing)
    p = parse_windows_processes(text)
    isempty(p.parents) && return (nothing, nothing)
    kids = descendants(p.parents, root; include_root = false)
    return (sum((get(p.rss, k, 0) for k in kids); init = 0), nothing)
end

"""
    parse_ps_cputime(text) -> Union{Float64,Nothing}

The seconds in a `ps` CPU time (`MM:SS.ss`, `H:MM:SS`, `D-HH:MM:SS`); `nothing` for text
in another shape.
"""
function parse_ps_cputime(text::AbstractString)::Union{Float64,Nothing}
    m = match(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$", strip(text))
    m === nothing && return nothing
    d = m[1] === nothing ? 0 : parse(Int, m[1])
    h = m[2] === nothing ? 0 : parse(Int, m[2])
    return ((d * 24 + h) * 60 + parse(Int, m[3])) * 60 + parse(Float64, m[4])
end

"""
    parse_ps_table(text) -> NamedTuple

The processes of `ps -axo pid=,ppid=,cputime=` (macOS): `parents` and `cpu` (`pid =>
seconds`, the lines whose time [`parse_ps_cputime`](@ref) reads).
"""
function parse_ps_table(text::AbstractString)
    parents = Dict{Int,Int}()
    cpu = Dict{Int,Float64}()
    for line in split(text, '\n')
        f = split(line)
        length(f) == 3 || continue
        pid, ppid = tryparse(Int, f[1]), tryparse(Int, f[2])
        (pid === nothing || ppid === nothing) && continue
        parents[pid] = ppid
        t = parse_ps_cputime(f[3])
        t === nothing || (cpu[pid] = t)
    end
    return (; parents, cpu)
end

"The clock ticks per second of `/proc/<pid>/stat` times (`sysconf(_SC_CLK_TCK)`, 100)."
linux_clock_ticks() = begin
    n = try
        ccall(:sysconf, Clong, (Cint,), 2)
    catch
        100
    end
    n > 0 ? Int(n) : 100
end

"""
    process_table(os = Platform.os()) -> NamedTuple

`(parents, cpu)` of every process: `pid => parent pid` and `pid => CPU seconds so far`
(`cpu` is empty where the system gives none: Windows). Linux reads `/proc`, macOS `ps`,
Windows [`windows_process_csv`](@ref). Unreadable processes are left out; a probe that
fails gives empty tables.
"""
function process_table(os::Symbol = Platform.os())
    parents = Dict{Int,Int}()
    cpu = Dict{Int,Float64}()
    try
        if os === :linux
            tick = linux_clock_ticks()
            for d in readdir("/proc")
                all(isdigit, d) || continue
                try
                    m = match(r"^\d+ \(.*\) \S (\d+) (?:\S+ ){10}(\d+) (\d+)"s,
                        read("/proc/$d/stat", String))
                    m === nothing && continue
                    pid = parse(Int, d)
                    parents[pid] = parse(Int, m[1])
                    cpu[pid] = (parse(Int, m[2]) + parse(Int, m[3])) / tick
                catch
                end
            end
        elseif os === :windows
            text = windows_process_csv()
            text === nothing || (parents = parse_windows_processes(text).parents)
        else
            t = parse_ps_table(read(`ps -axo pid=,ppid=,cputime=`, String))
            parents, cpu = t.parents, t.cpu
        end
    catch
    end
    return (; parents, cpu)
end

"""
    tree_cpu_seconds(root; table = process_table(), include_root = true)
        -> Union{Float64,Nothing}

The CPU seconds used so far by `root` and the processes below it; `nothing` when the
system gives no CPU time (Windows) or none of them is in the table. The hang detector
only needs it to grow, so the figure of a process that ended drops out of the sum.
"""
function tree_cpu_seconds(
    root::Integer;
    table = process_table(),
    include_root::Bool = true,
)::Union{Float64,Nothing}
    isempty(table.cpu) && return nothing
    pids = descendants(table.parents, root; include_root)
    found = [table.cpu[p] for p in pids if haskey(table.cpu, p)]
    return isempty(found) ? nothing : sum(found)
end

"""
    kill_pid(pid; os = Platform.os())

Ends the process `pid` at once: `SIGKILL` on Linux and macOS, `taskkill /F` on Windows.
Never an error (the process may be gone). Always by PID, never by name.
"""
function kill_pid(pid::Integer; os::Symbol = Platform.os())::Nothing
    try
        if os === :windows
            Base.run(
                pipeline(ignorestatus(`taskkill /PID $pid /F`); stdout = devnull,
                    stderr = devnull),
            )
        else
            ccall(:kill, Cint, (Cint, Cint), pid, 9)
        end
    catch
    end
    return nothing
end

"""
    kill_tree(root; include_root = true, table = process_table(), killer = kill_pid)
        -> Vector{Int}

Ends `root` (unless `include_root` is false) and every process below it, deepest first, by
PID (never `pkill -f`, which also matches the calling shell). `killer` is called with each
PID.

# Returns
The PIDs it was called with.
"""
function kill_tree(
    root::Integer;
    include_root::Bool = true,
    table = process_table(),
    killer = kill_pid,
)::Vector{Int}
    pids = reverse(descendants(table.parents, root; include_root))
    foreach(killer, pids)
    return pids
end

# --- timeouts and the hang detector

"Minutes after which one fit of the trace stage is ended (`BAYSOL_PKG_FIT_TIMEOUT_MIN`)."
const FIT_TIMEOUT_MIN = 480

"""
Minutes after which one other step of the trace
stage is ended (`BAYSOL_PKG_STEP_TIMEOUT_MIN`).
"""
const STEP_TIMEOUT_MIN = 360

"""
Minutes without output and without CPU time after which a step is ended as hung
(`BAYSOL_PKG_HANG_MIN`). The hang seen under Rosetta 2 sat at 0% CPU for hours.
"""
const HANG_MIN = 30

"""
CPU seconds the tree of a step has to gain to count as working (see [`hang_update!`](@ref)).
"""
const HANG_CPU_MIN_S = 1.0

"Seconds between two looks of the watchdog."
const WATCH_PERIOD_S = 30

"""
    minutes_setting(name, default; env = ENV) -> Float64

The minutes in the environment variable `name` (`0` turns the limit off), `default` when it
is not set.

# Exceptions
A `ToolError` for a value that is not a number of at least 0.
"""
function minutes_setting(name::AbstractString, default::Real; env = ENV)::Float64
    haskey(env, name) || return Float64(default)
    v = tryparse(Float64, strip(env[name]))
    (v === nothing || v < 0 || !isfinite(v)) &&
        throw(ToolError("$WHO: $name=$(env[name]) is not a number of minutes (0 = off)", 1))
    return v
end

fit_timeout_min(; env = ENV) =
    minutes_setting("BAYSOL_PKG_FIT_TIMEOUT_MIN", FIT_TIMEOUT_MIN; env)
step_timeout_min(; env = ENV) =
    minutes_setting("BAYSOL_PKG_STEP_TIMEOUT_MIN", STEP_TIMEOUT_MIN; env)
hang_min(; env = ENV) = minutes_setting("BAYSOL_PKG_HANG_MIN", HANG_MIN; env)

"""
The state of the hang detector: a step is hung when for `window` seconds its log did not
grow and its process tree did not gain [`HANG_CPU_MIN_S`](@ref) of CPU time.
"""
mutable struct HangState
    window::Float64
    last_active::Float64
    cpu::Union{Float64,Nothing}
    size::Int
end

HangState(window::Real, t::Real) = HangState(Float64(window), Float64(t), nothing, 0)

"""
    hang_update!(h, t, cpu, size; cpu_min = HANG_CPU_MIN_S) -> Bool

Feeds one look (time `t`, tree CPU seconds `cpu` or `nothing`, log size `size`) to `h`;
true when the step has been idle for the whole window. A CPU figure that is `nothing`
(the system gives none) never reports a hang: without it a quiet step cannot be told from
a busy one that prints nothing. A CPU sum that fell (a process ended) counts as activity.
"""
function hang_update!(
    h::HangState,
    t::Real,
    cpu::Union{Real,Nothing},
    size::Integer;
    cpu_min::Real = HANG_CPU_MIN_S,
)::Bool
    active = size > h.size
    if cpu === nothing
        active = true   # unknown: never a hang
    elseif h.cpu === nothing || cpu < h.cpu || cpu - h.cpu >= cpu_min
        active = true
    end
    h.size = Int(size)
    if active
        h.last_active = Float64(t)
        h.cpu = cpu === nothing ? nothing : Float64(cpu)
        return false
    end
    return t - h.last_active >= h.window
end

"""
    watch_verdict(elapsed_s, limit_min, hung, hang_minutes) -> String

The reason a step is to be ended, or `""`: `timeout after N min` when `limit_min` (> 0) is
used up, else `hang: no output and no CPU for N min` when `hung`.
"""
function watch_verdict(elapsed_s::Real, limit_min::Real, hung::Bool, hang_minutes::Real)
    limit_min > 0 && elapsed_s >= limit_min * 60 &&
        return "timeout after $(round(limit_min; digits = 1)) min"
    hung && return "hang: no output and no CPU for $(round(hang_minutes; digits = 1)) min"
    return ""
end

"The `(step, reason)` of the steps the watchdog ended in this run, for the build log."
const WATCHDOG_KILLS = Tuple{String,String}[]

"The log file of the step that started last (the one a running program writes to)."
current_log() = isempty(STEP_LOGS) ? "" : last(STEP_LOGS).second

"The name of the step that started last."
current_step() = isempty(STEP_LOGS) ? "" : first(last(STEP_LOGS))

"""
    watched(f; name, limit_min, hang_minutes, root = getpid(), include_root = false,
        period = WATCH_PERIOD_S, ...) -> Any

Calls `f()` while a watcher looks every `period` seconds at the processes below
`root`: past `limit_min` minutes, or after `hang_minutes` without growth of the step
log and without CPU time ([`HangState`](@ref)), it ends them by PID
([`kill_tree`](@ref)), adds a `timeout:` line to the report and a row to
[`WATCHDOG_KILLS`](@ref). The killed programs exit with an error, so `f` returns
false (a failed step or fit, which `--resume` runs again); if `f` returns anything
else after a kill, `false` is returned. A limit of 0 is off, both off runs `f` alone.

The keywords `log`, `tree_cpu`, `killer`, `clock` and `sleeper` are the system's calls,
replaced by fakes in the tests.
"""
function watched(
    f;
    name::AbstractString,
    limit_min::Real,
    hang_minutes::Real,
    root::Integer = getpid(),
    include_root::Bool = false,
    period::Real = WATCH_PERIOD_S,
    log = current_log,
    tree_cpu = r -> tree_cpu_seconds(r; include_root),
    killer = r -> kill_tree(r; include_root),
    clock = time,
    sleeper = sleep_unless,
)
    (limit_min <= 0 && hang_minutes <= 0) && return f()
    running = Ref(true)
    reason = Ref("")
    t0 = clock()
    state = HangState(hang_minutes * 60, t0)
    watcher = @async while running[]
        sleeper(running, period)
        running[] || break
        t = clock()
        path = log()
        size = isfile(path) ? filesize(path) : 0
        hung = hang_minutes > 0 && hang_update!(state, t, tree_cpu(root), size)
        why = watch_verdict(t - t0, limit_min, hung, hang_minutes)
        if !isempty(why)
            reason[] = why
            killed = killer(root)
            push!(WATCHDOG_KILLS, (String(name), why))
            note("  timeout: $name: $why; ended $(length(killed)) process(es)";
                terminal = true)
            break
        end
    end
    value = try
        f()
    finally
        running[] = false
        wait(watcher)
    end
    isempty(reason[]) || return false
    return value
end

# --- build paths in the bundle

"The values of `BAYSOL_PATH_SCAN`: what a build does when the bundle holds build paths."
const PATH_SCAN_MODES = ("warn", "fail", "off")

"""
    path_scan_mode(; env = ENV) -> String

`BAYSOL_PATH_SCAN`: `warn` (default: a report line and the `buildPathStrings` LOG row),
`fail` (the build stops) or `off` (not scanned).

# Exceptions
A `ToolError` for any other value.
"""
function path_scan_mode(; env = ENV)::String
    mode = get(env, "BAYSOL_PATH_SCAN", "warn")
    mode in PATH_SCAN_MODES && return mode
    throw(
        ToolError(
            "$WHO: BAYSOL_PATH_SCAN=$mode is not one of " *
            join(PATH_SCAN_MODES, ", "), 1),
    )
end

"""
    path_needles(paths; wide = false) -> Vector{Pair{String,Vector{UInt8}}}

The byte strings to look for, for each folder of `paths` (the home folder, the work
folder, the repository): the path as written and with its other separator style (`/`,
`\\`), as `label => bytes`; with `wide` also as UTF-16LE (how a Windows executable may hold
a string), labelled `<path> (utf-16)`. A path that is empty, or shorter than 5 characters,
is left out, and so is every path that starts with another one of the list (the repository
below the home folder is already counted by the home folder, so a hit is counted once).
"""
function path_needles(paths; wide::Bool = false)
    given =
        unique(filter(p -> length(p) >= 5, [rstrip(String(p), ['/', '\\']) for p in paths]))
    keep = filter(p -> !any(q -> q != p && startswith(p, q), given), given)
    out = Pair{String,Vector{UInt8}}[]
    for p in keep
        for v in unique([p, replace(p, '\\' => '/'), replace(p, '/' => '\\')])
            push!(out, v => Vector{UInt8}(codeunits(v)))
            wide && push!(
                out,
                "$v (utf-16)" =>
                    reinterpret(UInt8, transcode(UInt16, String(v))) |> collect,
            )
        end
    end
    return out
end

"""
    find_bytes(needle, buf, from) -> Union{UnitRange{Int},Nothing}

The first place at or after `from` where the bytes `needle` occur in `buf`. It finds the
first byte with `findnext` (a `memchr` for bytes) and compares the rest there, which is
much faster on a binary than the generic search for a vector.
"""
function find_bytes(
    needle::AbstractVector{UInt8},
    buf::AbstractVector{UInt8},
    from::Integer,
)
    n = length(needle)
    n == 0 && return nothing
    b0 = needle[1]
    i = Int(from)
    last_start = length(buf) - n + 1
    while (i = something(findnext(==(b0), buf, i), 0)) != 0 && i <= last_start
        all(k -> @inbounds(buf[i+k-1] == needle[k]), 2:n) && return i:(i+n-1)
        i += 1
    end
    return nothing
end

"""
    scan_file(path, needles; chunk = 16 * 2^20) -> Vector{Int}

How many times each of `needles` (byte vectors) occurs in the file `path`, read in chunks
(a sysimage is hundreds of MiB) with an overlap so a match across two chunks counts once.
Read only.
"""
function scan_file(path::AbstractString, needles; chunk::Integer = 16 * 2^20)::Vector{Int}
    counts = zeros(Int, length(needles))
    isempty(needles) && return counts
    keep = maximum(length, needles) - 1
    carry = UInt8[]
    open(path, "r") do io
        while !eof(io)
            fresh = read(io, chunk)
            buf = isempty(carry) ? fresh : vcat(carry, fresh)
            for (i, n) in enumerate(needles)
                from = 1
                while (r = find_bytes(n, buf, from)) !== nothing
                    # a match that ends inside the carry was counted with the last chunk
                    last(r) > length(carry) && (counts[i] += 1)
                    from = last(r) + 1
                end
            end
            carry = buf[max(1, end-keep+1):end]
        end
    end
    return counts
end

"""
    scan_paths(dir, needles; chunk = 16 * 2^20, top = 10) -> NamedTuple

Counts the occurrences of the `label => bytes` `needles` ([`path_needles`](@ref)) in every
file below `dir` (binary and text, symbolic links not followed). Read only; the bundle is
never changed.

# Returns
`(total, counts, files, scanned)`: the sum, `label => count` for the needles that occur,
the `top` files with most hits as `relative path => hits`, and the number of files read.
"""
function scan_paths(
    dir::AbstractString,
    needles;
    chunk::Integer = 16 * 2^20,
    top::Integer = 10,
)
    bytes = [last(n) for n in needles]
    labels = [first(n) for n in needles]
    counts = zeros(Int, length(needles))
    hits = Pair{String,Int}[]
    scanned = 0
    for (d, _, fs) in walkdir(dir), f in fs
        p = joinpath(d, f)
        (islink(p) || !isfile(p)) && continue
        c = try
            scan_file(p, bytes; chunk)
        catch
            continue
        end
        scanned += 1
        counts .+= c
        sum(c) > 0 && push!(hits, relpath(p, dir) => sum(c))
    end
    sort!(hits; by = last, rev = true)
    return (
        total = sum(counts),
        counts = Dict(labels[i] => counts[i] for i in eachindex(labels) if counts[i] > 0),
        files = first(hits, top),
        scanned,
    )
end

"""
    path_scan_decision(total, mode) -> Tuple{Symbol,String}

`(:ok | :warn | :fail, text)` for `total` build-path strings found under `mode`
([`path_scan_mode`](@ref)): none is ok, some are a warning except under `fail`, `off`
is always ok.
"""
function path_scan_decision(total::Integer, mode::AbstractString)
    mode == "off" && return (:ok, "not scanned (BAYSOL_PATH_SCAN=off)")
    total == 0 && return (:ok, "no build path in the bundle")
    text =
        "$total strings with a build path (home, work folder or repository) " *
        "in the bundle"
    return (mode == "fail" ? :fail : :warn, text)
end

"The number of build-path strings the last scan found (`nothing`: not scanned)."
const PATH_SCAN_TOTAL = Ref{Union{Int,Nothing}}(nothing)

"""
    path_scan_step(bundle; env = ENV, home = homedir(), work, root = Common.root()) -> Bool

The build step after the bundle is made: scans the folder `bundle` for the home folder,
the work folder and the repository path ([`scan_paths`](@ref)), notes the result in the
report (the three files with most hits too) and in [`PATH_SCAN_TOTAL`](@ref) for the
`buildPathStrings` LOG row.

# Returns
True unless the mode is `fail` and a path was found.
"""
function path_scan_step(
    bundle::AbstractString;
    env = ENV,
    home::AbstractString = homedir(),
    work::AbstractString,
    root::AbstractString = Common.root(),
)::Bool
    mode = path_scan_mode(; env)
    PATH_SCAN_TOTAL[] = nothing
    mode == "off" && return true
    r = scan_paths(bundle, path_needles([home, work, root]; wide = Platform.iswindows()))
    PATH_SCAN_TOTAL[] = r.total
    status, text = path_scan_decision(r.total, mode)
    note("  build paths: $text ($(r.scanned) files read)"; terminal = status !== :ok)
    for (f, n) in first(r.files, 3)
        note("      $n x $f")
    end
    return status !== :fail
end

"""
    juliac_debug_args(; env = ENV) -> Vector{String}

`--debug-info=N` for the Julia that runs `juliac.jl`, from `BAYSOL_JULIAC_DEBUG_INFO`
(`0`, `1` or `2`; unset: `0`, which leaves out the line tables; `1` is the stock
level). `juliac.jl` starts the compile process with `Base.julia_cmd()`, which repeats
the debug level of the Julia that runs it (checked: a Julia started with `-g0` gives
`-g0` there, one without gives `-g1`), so the level reaches the compile with no
change of `juliac.jl`. `0` leaves out the debug-info line tables of the LLVM code
(source file names of every method that is compiled in); see the README of `dev/`
("Build paths in the binary") for what it does not remove.

# Exceptions
A `ToolError` for any other value.
"""
function juliac_debug_args(; env = ENV)::Vector{String}
    v = get(env, "BAYSOL_JULIAC_DEBUG_INFO", "")
    isempty(v) && return ["--debug-info=0"]
    v in ("0", "1", "2") && return ["--debug-info=$v"]
    throw(ToolError("$WHO: BAYSOL_JULIAC_DEBUG_INFO=$v is not 0, 1 or 2", 1))
end

# --- the archiver

"The 7-Zip programs looked for on the PATH, in this order."
const SEVEN_ZIP_NAMES = ("7zz", "7z", "7za")

"""
    seven_zip_works(path) -> Bool

Whether the program `path` starts and says it is 7-Zip when run without arguments (it
prints its usage; the exit status does not matter). A program that cannot be spawned (no
execute bit, a x86_64 program that the machine cannot run, a missing library) is false.
"""
function seven_zip_works(path::AbstractString)::Bool
    try
        text = read(pipeline(ignorestatus(`$path`); stderr = devnull), String)
        return occursin(r"7-Zip|p7zip|7zz|7za", text)
    catch
        return false
    end
end

"""
    archiver_candidates(; bundled, which = Platform.which, os = Platform.os())
        -> Vector{String}

The 7-Zip programs to try, in order: [`SEVEN_ZIP_NAMES`](@ref) on the PATH, then `bundled`
(the `7za` of the npm package `7zip-bin`, `nothing` when there is none).
"""
function archiver_candidates(;
    bundled::Union{AbstractString,Nothing},
    which = Platform.which,
    os::Symbol = Platform.os(),
)::Vector{String}
    found = String[]
    for n in SEVEN_ZIP_NAMES
        p = which(n)
        p === nothing || push!(found, String(p))
    end
    bundled === nothing || push!(found, String(bundled))
    return unique(found)
end

"""
    pick_archiver(candidates; probe = seven_zip_works) -> Union{String,Nothing}

The first of `candidates` for which `probe(path)` is true; `nothing` when none is.
"""
function pick_archiver(candidates; probe = seven_zip_works)::Union{String,Nothing}
    for c in candidates
        probe(c) && return String(c)
    end
    return nothing
end

"""
    fallback_archiver(os = Platform.os(); which = Platform.which)
        -> Union{NamedTuple,Nothing}

What packs the final zip when no 7-Zip starts, macOS only: `ditto` (`ditto -c -k`, which
Apple ships with the system), else `zip`. `(kind, path)`, or `nothing` elsewhere or when
neither is there. It cannot unpack the `.7z` of the reference fits, so a 7-Zip is still
needed by the stages before the archive.
"""
function fallback_archiver(os::Symbol = Platform.os(); which = Platform.which)
    os === :macos || return nothing
    for kind in (:ditto, :zip)
        p = which(string(kind))
        p === nothing || return (; kind, path = String(p))
    end
    return nothing
end

"""
    fallback_archive_command(fb, archive, bundle_root) -> Tuple{Cmd,String}

`(command, directory)` that packs the folder `bundle_root` (`<work>/bundle/baysol`) into
`archive` with its name at the top, as the 7-Zip command does: `ditto -c -k --keepParent`
or `zip -r -9 -y` (symbolic links kept) run in the parent of `bundle_root`.
"""
function fallback_archive_command(fb, archive::AbstractString, bundle_root::AbstractString)
    top = basename(rstrip(bundle_root, ['/', '\\']))
    parent = dirname(rstrip(bundle_root, ['/', '\\']))
    p = fb.path
    fb.kind === :ditto && return (`$p -c -k --keepParent $top $archive`, parent)
    return (`$p -r -9 -y $archive $top`, parent)
end

"The 7-Zip [`find_7z`](@ref) chose and kept for the run."
const ARCHIVER_PATH = Ref{Union{String,Nothing}}(nothing)

"""
What the build uses to pack and unpack (`archiver` LOG row), `nothing` before it is chosen.
"""
const ARCHIVER = Ref{Union{String,Nothing}}(nothing)

# --- the log rows of this file

"""
    machine_log_rows() -> Vector{Pair{String,String}}

The rows of this file for the build log: `archiver`, `buildPathStrings`, `minFreeDisk`
(macOS and Windows), `timeouts` (the steps the watchdog ended) and `juliacDebugInfo`. A row
without a value is left out, except `buildPathStrings`, which says `not scanned`.
"""
function machine_log_rows()::Vector{Pair{String,String}}
    rows = Pair{String,String}[]
    ARCHIVER[] === nothing || push!(rows, "archiver" => ARCHIVER[])
    push!(
        rows,
        "buildPathStrings" =>
            (PATH_SCAN_TOTAL[] === nothing ? "not scanned" : string(PATH_SCAN_TOTAL[])),
    )
    MIN_FREE_DISK_SEEN[] === nothing ||
        push!(rows, "minFreeDisk" => "$(MIN_FREE_DISK_SEEN[]) MiB")
    isempty(WATCHDOG_KILLS) ||
        push!(rows, "timeouts" => join(("$n ($r)" for (n, r) in WATCHDOG_KILLS), "; "))
    push!(rows, "juliacDebugInfo" => something(
        let a = juliac_debug_args()
            isempty(a) ? nothing : a[1]
        end, "stock"))
    return rows
end

# --- parallel jobs (opt-in)

"The default of `BAYSOL_PKG_JOBS`: one job at a time, as the build always ran."
const PKG_JOBS = 1

"Memory (MiB) kept free when a job is admitted, for the system and the driver."
const JOB_RESERVE_MIB = 2048

"The peak (MiB) assumed for a job no earlier build log has a figure for."
const JOB_DEFAULT_PEAK_MIB = 4096

"""
    pkg_jobs(; env = ENV, cores = logical_cores()) -> Int

`BAYSOL_PKG_JOBS`: how many independent jobs may run at once (default [`PKG_JOBS`](@ref),
1 = one at a time); never more than `cores`.

# Exceptions
A `ToolError` for a value that is not a positive integer.
"""
function pkg_jobs(; env = ENV, cores::Integer = logical_cores())::Int
    haskey(env, "BAYSOL_PKG_JOBS") || return PKG_JOBS
    n = tryparse(Int, strip(env["BAYSOL_PKG_JOBS"]))
    (n === nothing || n < 1) &&
        throw(
            ToolError(
                "$WHO: BAYSOL_PKG_JOBS=$(env["BAYSOL_PKG_JOBS"]) is not a " *
                "positive integer", 1),
        )
    return min(n, max(cores, 1))
end

"""
    fits_memory(peak, running, free_ram_mib, backing_mib; reserve = JOB_RESERVE_MIB) -> Bool

Whether a job of `peak` MiB may start while the jobs in `running` (their summed peaks)
run: the peaks, with `reserve`, must fit into the free RAM plus `backing_mib` (free swap
on Linux, the free disk above the floor on macOS and Windows).
"""
fits_memory(peak, running, free_ram_mib, backing_mib; reserve = JOB_RESERVE_MIB) =
    running + peak + reserve <= free_ram_mib + backing_mib

"""
    known_peaks(logs::AbstractVector{<:AbstractString}) -> Dict{String,Int}

The highest `peak RAM` (MiB) of each step name over the build logs (the text of each),
read with [`parse_build_log`](@ref): what the earlier builds measured for a step.
"""
function known_peaks(logs)::Dict{String,Int}
    peaks = Dict{String,Int}()
    for text in logs
        for s in parse_build_log(text).stages
            s.ram === nothing || (peaks[s.name] = max(get(peaks, s.name, 0), s.ram))
        end
    end
    return peaks
end

"""
    current_backing_mib(os = Platform.os()) -> Int

The memory a job may spill into: the free swap on Linux, the free disk above
[`MIN_FREE_DISK_MIB`](@ref) on macOS and Windows; 0 when unknown (so a job waits).
"""
function current_backing_mib(os::Symbol = Platform.os())::Int
    if os === :linux
        return get(parse_meminfo(read("/proc/meminfo", String)), "SwapFree", 0) ÷ 1024
    end
    free = free_disk_mib(swap_volume(os))
    return free === nothing ? 0 : max(free - MIN_FREE_DISK_MIB, 0)
end

"""
One job of [`run_jobs`](@ref): its `name`, the `peak` MiB it is expected to need, and `run`
(a function without arguments returning true when the job passed).
"""
struct Job
    name::String
    peak::Int
    run::Function
end

"""
    run_jobs(jobs, slots; admit = (peak, running) -> true, first_alone = false,
        poll = 0.2) -> Vector{Bool}

Runs the `jobs` with at most `slots` at once and returns whether each passed, in the order
of `jobs`. With `slots <= 1` they run one after the other in the calling task, in order:
exactly the old behaviour. Otherwise jobs START in the order of the list, each as soon as a
slot is free and `admit(peak, running)` (`running`: the summed peaks of the jobs running)
agrees; a job is always admitted when none is running, so the run finishes whatever the
memory says (it degrades to sequential). With `first_alone` the first job completes before
any other starts (to warm a cache they share). Jobs finish in any order; a job that throws
counts as failed. The caller prints the results afterwards, in order.
"""
function run_jobs(
    jobs::AbstractVector{Job},
    slots::Integer;
    admit = (peak, running) -> true,
    first_alone::Bool = false,
    poll::Real = 0.2,
)::Vector{Bool}
    results = fill(false, length(jobs))
    safe(j) =
        try
            j.run() === true
        catch
            false
        end
    if slots <= 1
        for (i, j) in enumerate(jobs)
            results[i] = safe(j)
        end
        return results
    end
    running = Dict{Int,Task}()
    next = 1
    while next <= length(jobs) || !isempty(running)
        for (i, t) in collect(running)
            istaskdone(t) && delete!(running, i)
        end
        while next <= length(jobs) && length(running) < slots
            held = sum((jobs[i].peak for i in keys(running)); init = 0)
            alone =
                first_alone && next == 1 ||
                (first_alone && !isempty(running) && 1 in keys(running))
            (isempty(running) || (!alone && admit(jobs[next].peak, held))) || break
            i = next
            running[i] = @async(results[i] = safe(jobs[i]))
            next += 1
            first_alone && i == 1 && break
        end
        isempty(running) || sleep(poll)
    end
    return results
end

"The Julia code of a cold-depot install."
const INSTANTIATE = "using Pkg; Pkg.instantiate()"

"""
    instantiate_jobs(julia, projects, work, run_cmd) -> Vector{Job}

One [`Job`](@ref) per project folder of `projects` (`rel => path`) that runs
`Pkg.instantiate()` in it with `julia` and writes the output to the step log
`<name>.log` of the step "julia packages <rel> (cold depot)". `run_cmd(cmd, log)` runs a
command into a file and returns true on status 0 (replaced in the tests). The peak of each
job is `peaks[name]` when an earlier build log knew it, else [`JOB_DEFAULT_PEAK_MIB`](@ref).
"""
function instantiate_jobs(
    julia::AbstractString,
    projects,
    peaks::AbstractDict,
    run_cmd,
)::Vector{Job}
    return [
        Job(
            "julia packages $rel (cold depot)",
            get(peaks, "julia packages $rel (cold depot)", JOB_DEFAULT_PEAK_MIB),
            () -> run_cmd(
                `$julia --startup-file=no --project=$path -e $INSTANTIATE`,
                step_log("julia packages $rel (cold depot)"),
            ),
        ) for (rel, path) in projects
    ]
end

"""
    parallel_depot(julia, projects, jobs; peaks, admit, run_cmd) -> Bool

The cold-depot installs of `projects` with up to `jobs` at once ([`run_jobs`](@ref), the
first one ALONE so it makes the registry and the shared packages that the others then find
in the depot: Pkg locks the depot, but two cold clones of the same registry are not
worth the risk). The jobs write their own logs; the report lines follow in order once all
are done (the step logs of `step` redirect the whole process, so `step` cannot run
twice at once). Julia precompilation is NOT done twice: `Pkg.instantiate` of the cold
depot precompiles, and every job precompiles only its own project.

# Returns
True when every install passed.
"""
function parallel_depot(
    julia::AbstractString,
    projects,
    jobs::Integer;
    peaks::AbstractDict = Dict{String,Int}(),
    admit = (peak, running) ->
        fits_memory(peak, running, free_memory_mib(), current_backing_mib()),
    run_cmd = (cmd, log) -> success(
        Base.run(pipeline(ignorestatus(cmd); stdout = log, stderr = log)),
    ),
)::Bool
    js = instantiate_jobs(julia, projects, peaks, run_cmd)
    t0 = time()
    results = run_jobs(js, jobs; admit, first_alone = true)
    for (j, ok) in zip(js, results)
        push!(STEP_LOGS, j.name => step_log(j.name))
        note(
            string(rpad(j.name, 10), ok ? " ok    " : " FAIL  ",
                lpad(round(time() - t0; digits = 1), 8), " s (parallel, jobs=$jobs)");
            terminal = true)
    end
    return all(results)
end

"The free RAM in MiB (`Sys.free_memory`)."
free_memory_mib() = Int(Sys.free_memory()) ÷ 1024^2

"""
    earlier_peaks(dir) -> Dict{String,Int}

[`known_peaks`](@ref) over the `*.LOG` files of the folder `dir` (the tracked build logs);
empty when there is none.
"""
function earlier_peaks(dir::AbstractString)::Dict{String,Int}
    isdir(dir) || return Dict{String,Int}()
    return known_peaks(
        read(f, String) for f in readdir(dir; join = true) if endswith(f, ".LOG")
    )
end

"""
    reset_machine_state()

Clears what a run of this file remembers (the chosen archiver, the scan total, the lowest
free disk, the watchdog's kills), because the dev daemon keeps the module between runs.
"""
function reset_machine_state()::Nothing
    ARCHIVER_PATH[] = nothing
    ARCHIVER[] = nothing
    PATH_SCAN_TOTAL[] = nothing
    MIN_FREE_DISK_SEEN[] = nothing
    empty!(WATCHDOG_KILLS)
    return nothing
end
