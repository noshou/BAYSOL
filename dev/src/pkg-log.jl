# SPDX-License-Identifier: LGPL-3.0-or-later

# `bysl pkg log`: reads the build logs `bysl pkg` leaves in `dev/build-logs/` and prints
# each as a short block (what was built, on what, how long each stage took and how much
# memory it peaked at), plus one comparison row per build when there are several. Only the
# LOG is read, never the work folder, and its format is written by `write_build_log`.
# Included into `PkgTool`.

"""
One row of the `--- stages ---` table of a build log: a stage or a step of one.

- `name`: the step name (`stage julia`, `archive (7-Zip)`, `juliac`, ...).
- `top`: whether it is a stage (not indented in the log), `false` for a step inside one.
- `ok`: `true` for `ok`, `false` for `FAIL`.
- `seconds`: its wall time.
- `ram`, `swap`: the peaks in MiB, `nothing` when the row has none.
"""
struct StageRow
    name::String
    top::Bool
    ok::Bool
    seconds::Float64
    ram::Union{Int,Nothing}
    swap::Union{Int,Nothing}
end

"""
The parts of a build log that [`format_build_log`](@ref) shows.

- `rows`: the `key<TAB>value` rows above the first `---` line and in the `--- machine ---`
  block, by key.
- `stages`: the [`StageRow`](@ref)s.
- `skipped`: the stages the build found done before (`--resume`).
- `total`: the `total` line in minutes, `nothing` without one.
"""
struct BuildLog
    rows::Dict{String,String}
    stages::Vector{StageRow}
    skipped::Vector{String}
    total::Union{Float64,Nothing}
end

const STAGE_ROW =
    r"^(\s*)(\S.*?)\s+(ok|FAIL)\s+([0-9.]+) s(?:\s+peak RAM (\d+) MiB, swap (\d+) MiB)?\s*$"
const SKIPPED_ROW = r"^(\w+)\s+skipped \(done before\)"
const TOTAL_ROW = r"^total\s+([0-9.]+) min"

"""
    parse_build_log(text) -> BuildLog

Reads the text of a build log. Lines it does not know are left out, so an older or newer
log still reads.

# Returns
The [`BuildLog`](@ref).

# Exceptions
None.
"""
function parse_build_log(text::AbstractString)::BuildLog
    rows = Dict{String,String}()
    stages = StageRow[]
    skipped = String[]
    total = nothing
    section = ""    # the name between `--- ` and ` ---`, "" before the first one
    for line in split(text, '\n')
        m = match(r"^--- (.*?) ---$", line)
        if m !== nothing
            section = m[1]
        elseif section == "stages"
            if (s = match(STAGE_ROW, line)) !== nothing
                peaks =
                    s[5] === nothing ? (nothing, nothing) :
                    (parse(Int, s[5]), parse(Int, s[6]))
                push!(
                    stages,
                    StageRow(s[2], isempty(s[1]), s[3] == "ok",
                        parse(Float64, s[4]), peaks...),
                )
            elseif (s = match(SKIPPED_ROW, line)) !== nothing
                push!(skipped, s[1])
            elseif (s = match(TOTAL_ROW, line)) !== nothing
                total = parse(Float64, s[1])
            end
        elseif section in ("", "machine") && occursin('\t', line)
            key, value = split(line, '\t'; limit = 2)
            rows[strip(key)] = strip(value)
        end
    end
    return BuildLog(rows, stages, skipped, total)
end

"A duration of `s` seconds: seconds under two minutes, else minutes."
duration_text(s::Real) = s < 120 ? "$(round(Int, s)) s" : "$(round(s / 60; digits = 1)) min"

"A size of `mib` MiB: MiB under one GiB, else GiB; `-` for `nothing`."
function size_text(mib::Union{Real,Nothing})
    mib === nothing && return "-"
    return mib < 1024 ? "$(round(Int, mib)) MiB" : "$(round(mib / 1024; digits = 1)) GiB"
end

# the number in a `ram`/`swap` row (`15624 MiB`), or `nothing`
function _rowMib(b::BuildLog, key)
    m = match(r"^(\d+) MiB", get(b.rows, key, ""))
    return m === nothing ? nothing : parse(Int, m[1])
end

# the highest peak of the top-level stages, `nothing` without peaks
function _peak(b::BuildLog, field::Symbol)
    v = [getfield(s, field) for s in b.stages if s.top && getfield(s, field) !== nothing]
    return isempty(v) ? nothing : maximum(v)
end

# the first word of the revision, version and system rows in one head line
_head(b::BuildLog) = join(
    filter(
        !isempty,
        [
            "baysol " * get(b.rows, "version", "?"),
            split(get(b.rows, "system", "?"), ',')[1],
            get(b.rows, "revision", "?"),
            get(b.rows, "datetime", "?"),
        ],
    ), "   ")

"""
    format_build_log(b; steps = false) -> Vector{String}

The lines of the short view of one build: the head (version, system, revision, date),
the host (cpu, threads, RAM, swap), the tools, and a table of the stages with their time and
peak memory. `steps` adds the steps inside each stage; the stages the build skipped are
named; a failed stage is marked `FAIL`.

# Returns
The lines.

# Exceptions
None.
"""
function format_build_log(b::BuildLog; steps::Bool = false)::Vector{String}
    out = String[_head(b)]
    ram, swap = _rowMib(b, "ram"), _rowMib(b, "swap")
    push!(
        out,
        "host   " * join(
            filter(
                !isempty,
                [
                    get(b.rows, "cpu", "?"),
                    "$(get(b.rows, "threads", "?")) threads",
                    "RAM " * size_text(ram),
                    "swap " * size_text(swap),
                ],
            ), ", "),
    )
    push!(
        out,
        "tools  julia " * get(b.rows, "julia", "?") * ", node " *
        get(b.rows, "node", "?") * ", python " * get(b.rows, "python", "?"),
    )
    push!(out, "")
    push!(
        out,
        rpad("stage", 18) * lpad("time", 10) * lpad("peak RAM", 12) *
        lpad("peak swap", 12),
    )
    for s in b.stages
        s.top || steps || continue
        name = (s.top ? "" : "  ") * replace(s.name, r"^stage " => "")
        push!(
            out,
            rpad(name * (s.ok ? "" : " FAIL"), 18) * lpad(duration_text(s.seconds), 10) *
            lpad(size_text(s.ram), 12) * lpad(size_text(s.swap), 12),
        )
    end
    isempty(b.skipped) || push!(out, "skipped (done before): " * join(b.skipped, ", "))
    b.total === nothing || push!(out, "total  " * duration_text(b.total * 60))
    return out
end

"""
    format_build_summary(logs) -> Vector{String}

One row per build (`name => BuildLog`): version, system, total time and the highest peak
RAM and swap over its stages, to compare builds on different machines.

# Returns
The lines.

# Exceptions
None.
"""
function format_build_summary(logs::AbstractVector{<:Pair{String,BuildLog}})::Vector{String}
    out = [
        rpad("build", 34) * lpad("total", 10) * lpad("peak RAM", 12) *
        lpad("peak swap", 12) * "  result",
    ]
    for (name, b) in logs
        failed = any(s -> s.top && !s.ok, b.stages)
        push!(
            out,
            rpad(replace(name, r"\.LOG$" => ""), 34) *
            lpad(b.total === nothing ? "-" : duration_text(b.total * 60), 10) *
            lpad(size_text(_peak(b, :ram)), 12) * lpad(size_text(_peak(b, :swap)), 12) *
            "  " * (failed ? "FAIL" : "ok"),
        )
    end
    return out
end

"""
    build_log_files(dir, names) -> Vector{String}

The `.LOG` files of `dir`, sorted; with `names`, only those whose file name contains one of
them (case-insensitive).

# Returns
The paths.

# Exceptions
None.
"""
function build_log_files(dir::AbstractString, names)::Vector{String}
    isdir(dir) || return String[]
    files = sort(filter(f -> endswith(f, ".LOG"), readdir(dir)))
    isempty(names) ||
        (files = filter(f -> any(n -> occursin(lowercase(n), lowercase(f)), names), files))
    return joinpath.(dir, files)
end

"""
    log_command(argv) -> Int

`bysl pkg log [NAME...] [--steps]`: prints the short view of the build logs of
`dev/build-logs/` (those whose file name contains a NAME, or all), and a comparison table
when there is more than one.

# Returns
The exit status.

# Exceptions
`ToolError` (through `fail`) when no log matches.
"""
function log_command(argv::Vector{String})::Int
    a = split_args(WHO, String[], ["--steps"], argv)
    dir = joinpath(Common.root(), BUILD_LOG_DIR...)
    files = build_log_files(dir, a.specs)
    isempty(files) && fail(
        WHO,
        "no build log in $dir" *
        (isempty(a.specs) ? "" : " matches " * join(a.specs, ", ")),
    )
    logs = [basename(f) => parse_build_log(read(f, String)) for f in files]
    for (i, (_, b)) in enumerate(logs)
        i > 1 && println()
        foreach(println, format_build_log(b; steps = "--steps" in a.flags))
    end
    if length(logs) > 1
        println()
        foreach(println, format_build_summary(logs))
    end
    return 0
end
