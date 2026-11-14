# SPDX-License-Identifier: LGPL-3.0-or-later

# The run log: `<ID>.LOG` in the output folder of a run.

"""
A stage's name without what it carries in parentheses (`NUTS  (8k iters, 69.91k leapfrog)`)
or after a comma (`optima from the draws, 0 extra chains`), and that detail joined to the
stage's own note, with the brackets and parentheses that only set it off dropped.

# Returns
- `(stage, notes)`.
"""
function _stageAndNote(name::AbstractString, note::AbstractString)
    stage, detail = name, ""
    if (m = match(r"^(.*?)\s*\((.*)\)\s*$", name)) !== nothing
        stage, detail = m.captures
    elseif (i = findfirst(", ", name)) !== nothing
        stage, detail = name[1:(i.start-1)], name[(i.stop+1):end]
    end
    notes = join(filter(!isempty, strip.([detail, note])), "; ")
    return String(strip(stage)), replace(notes, r"[\[\]()]" => "")
end

"""
The timing table of a run: one row `(name, depth, secs, pct, jit, gc, note)` for the
wall clock (depth 0), then for each stage (a group row sums its depth-1 stages), then
`report write` and `unaccounted`; and the totals `gc` (the process's GC time), `fit`
(everything but the plotting) and `plot`. The wall clock runs from the start of the process
(the `startup`, Linux) through `seedModel` to now. `tReport` is the
[`tick`](@ref BAYSOL.Runtime.tick) taken when the table began, so `report write` is the time
spent writing before it.
"""
function _timingTable(log::StageLog, tReport)
    nowC = Base.cumulative_compile_time_ns()[1]
    nowG = Base.gc_time_ns()
    reportS = (time_ns() - tReport[1]) / NS_PER_S
    reportC = (nowC - tReport[2]) / NS_PER_S
    reportG = (nowG - tReport[3]) / NS_PER_S

    # the run (from `seedModel`) and the wall clock, which also counts the startup: the
    # process from its start to `seedModel` (Julia's startup, `using BAYSOL`, whatever was
    # compiled before). The compile and GC counters count from the start of the process.
    runS = (time_ns() - log.t0) / NS_PER_S
    runC = (nowC - log.compile0) / NS_PER_S
    runG = (nowG - log.gc0) / NS_PER_S
    startupC, startupG = log.compile0 / NS_PER_S, log.gc0 / NS_PER_S
    wall = log.startup + runS
    st, stC, stG = stageSeconds(log, :static)
    sp, spC, spG = stageSeconds(log, :sampling)
    pl, plC, plG = stageSeconds(log, :plot)

    # what no stage covers: the first call of `runModel`, `infer` and `writeLog`
    # compiles before their bodies (and so their stages) begin
    unacc = runS - st - sp - pl - reportS
    unaccC = runC - stC - spC - plC - reportC
    unaccG = runG - stG - spG - plG - reportG

    # one row per stage: its name, depth (the indentation), seconds, % of the wall clock
    # (`nothing` on plain stage lines), JIT and GC seconds and its note
    rows = NamedTuple[]

    add!(name, depth, secs, pct = nothing, jit = nothing, gc = nothing, note = "") =
        push!(rows, (; name, depth, secs, pct, jit, gc, note))
    add!("wall clock  (process start to end)", 0, wall, 100.0,
        nowC / NS_PER_S, nowG / NS_PER_S)
    add!(
        "startup",
        1,
        log.startup,
        nothing,
        startupC,
        startupG,
        "process start to seedModel",
    )
    for (group, label, tot, comp, gcs) in
        ((:static, "static build", st, stC, stG),
        (:sampling, "sampling", sp, spC, spG), (:plot, "plotting", pl, plC, plG))
        group === :plot && !any(s -> s.group === :plot, log.stages) && continue
        add!(label, 1, tot, 100 * tot / wall, comp, gcs)
        for stage in log.stages
            stage.group === group || continue
            add!(stage.name, stage.depth + 1, stage.seconds, nothing, stage.compile,
                stage.gc, stage.note)
        end
    end
    add!("report write", 1, reportS, nothing, reportC, reportG)
    add!("unaccounted", 1, unacc, nothing, max(unaccC, 0.0), max(unaccG, 0.0))
    return (; rows, gc = nowG / NS_PER_S, fit = wall - pl, plot = pl)
end

"""
Seconds as the timing table prints them: two decimals, or, below 0.01 s, in
scientific notation with two significant figures (`3.0e-03`), so a stage that took
a few milliseconds is not shown as a block of zeros. Exactly 0 prints as `0`.
"""
_fmtSeconds(x::Real) =
    x == 0 ? "0" : abs(x) < 0.01 ? @sprintf("%.1e", x) : @sprintf("%.2f", x)

"""
The timing table of a run (see `_timingTable`) as lines of text, for a person to read:
a header, then a row for the wall clock and each stage, indented two spaces for each
level, with its seconds, its share of the wall clock, its JIT and GC seconds (every row
has all four) and its notes in a column of their own, short and on the same line (what
the stage's name carried in parentheses and its own note, without brackets, see
`_stageAndNote`). The last three lines are the process's GC time and the two halves
of the wall clock, `fit timing` (everything but the plotting) and `plot timing`.
"""
function _timingText(table)
    wall = table.rows[1].secs
    parts = [_stageAndNote(r.name, r.note) for r in table.rows]
    labels = ["  "^r.depth * first(p) for (r, p) in zip(table.rows, parts)]
    w = maximum(length, labels)
    lines = [
        @sprintf("%-*s %10s %9s %8s %8s  %s", w, "stage", "seconds", "% wall", "(JIT)",
            "(GC)", "notes"),
    ]
    for (r, p, label) in zip(table.rows, parts, labels)
        line = @sprintf("%-*s %10s %9.1f %8s %8s", w, label, _fmtSeconds(r.secs),
            100 * (r.secs / wall), @sprintf("(%.1f)", something(r.jit, 0.0)),
            @sprintf("(%.1f)", something(r.gc, 0.0)))
        push!(lines, isempty(last(p)) ? line : line * "  " * last(p))
    end
    push!(lines, "GC: " * _fmtSeconds(table.gc) * " s")
    push!(lines, "fit timing  = " * _fmtSeconds(table.fit) * " s")
    push!(lines, "plot timing = " * _fmtSeconds(table.plot) * " s")
    return lines
end

"A number as a log cell: an integer as it is, a float to 6 significant figures."
_logCell(x::Integer) = string(x)
_logCell(x::Real) = string(round(x; sigdigits = 6))
_logCell(x) = string(x)

"""
The version of BAYSOL as the log prints it, `v<version>-<release name>`
(`v0.3.0-wʋsg_n_yɩɩda`; just `v<version>` when [`RELEASE_NAME`](@ref) is
empty), the version of its `Project.toml`; `unknown` when that cannot be found.
"""
function _logVersion()
    v = pkgversion(@__MODULE__)
    v === nothing && return "unknown"
    return "v" * string(v) * (isempty(RELEASE_NAME) ? "" : "-" * RELEASE_NAME)
end

"""
The short git revision of the BAYSOL source tree, with `-dirty` when it has uncommitted
changes to tracked files, `unknown` when it is not a git checkout.
"""
function _logRevision()
    try
        dir = pkgdir(@__MODULE__)
        dir === nothing && return "unknown"
        rev = readchomp(pipeline(`git -C $dir rev-parse --short HEAD`; stderr = devnull))
        dirty = readchomp(
            pipeline(
                `git -C $dir status --porcelain --untracked-files=no`;
                stderr = devnull,
            ))
        return isempty(dirty) ? rev : rev * "-dirty"
    catch
        return "unknown"
    end
end

"""
The first stage of `log` whose name starts with `prefix` (its name and note), or `nothing`.
"""
function _logStage(log::StageLog, prefix::AbstractString)
    i = findfirst(s -> startswith(s.name, prefix), log.stages)
    return i === nothing ? nothing : log.stages[i]
end

"A count with a `k` or `M` suffix (`69.91k`) as a number."
function _logCount(tok::AbstractString)
    scale = endswith(tok, "k") ? 1e3 : endswith(tok, "M") ? 1e6 : 1.0
    return round(Int, parse(Float64, rstrip(tok, ['k', 'M'])) * scale)
end

"""
The rows of the setup, fit and sampler sections of a run's log (`[name, value]` pairs).

# Returns
- `Vector{Vector{String}}`.
"""
function _logStats(result)
    fit, divergenceRate, mapResult, _ = result
    log = fit.timing
    info = log.info
    mapParams = mapResult === nothing ? nothing : first(mapResult)
    keys_, vals = _runRows(fit, divergenceRate, mapParams, info)
    run = Dict(zip(keys_, vals))
    rows = Vector{Vector{String}}()
    # a number that is not finite (a statistic that could not be computed) is not recorded
    add!(k, v) = v isa Real && !isfinite(v) || push!(rows, [k, _logCell(v)])
    adopt!(k, from = k) = haskey(run, from) && add!(k, run[from])

    # what the stage notes say: the kind of structure, the caches, the downloads
    cls = _logStage(log, "classify")
    kind = cls === nothing ? nothing : match(r"(protein|nucleic|mixed)", cls.note)
    kind === nothing || add!("structure", kind.captures[1])
    pq = _logStage(log, "pdb2pqr")
    pq === nothing ||
        add!("pdb2pqrCache", occursin("cache miss", pq.note) ? "miss" : "hit")
    cmp = _logStage(log, "components")
    dl = cmp === nothing ? nothing : match(r"(\d+) download", cmp.note)
    dl === nothing || add!("compDwnld", dl.captures[1])

    # the conditions the run was given, next to the atoms and the model
    for (k, from) in (
        ("temperatureC", "temperatureC"), ("ph", "ph"), ("sigmaPh", "sigmaPh"),
        ("energyEv", "energyEv"),
    )
        haskey(info, from) && add!(k, info[from])
    end
    # the data and structure choices that differ from the defaults (see `seedModel`)
    for k in (
        "qMin", "qMax", "sigmaScale", "excludeQ", "nQInput", "nQCropped",
        "nQExcluded", "structureModel", "structureChains", "addHydrogens",
        "lmaxPinned",
    )
        haskey(info, k) && add!(k, info[k])
    end
    # the settings this model was given that differ from the project's (`runProject`
    # with a `model-settings.json`): one row each, `override<Setting>`
    for k in sort!([k for k in keys(info) if startswith(k, "override")])
        add!(k, info[k])
    end

    for k in
        (
        "nAtoms", "lmax", "dmax", "nQRaw", "nQ", "nSamples", "nAdapt", "rngSeed",
        "pmvFallbackUncert",
    )
        adopt!(k)
    end
    if mapParams !== nothing
        for k in _REPORT_KEYS
            k == "logDensity" && continue
            haskey(mapParams, k) &&
                add!(k == "exclVolCorr" ? "c1" : _REPORT_LABELS[k], mapParams[k])
        end
        for k in _PRIOR_KEYS
            haskey(mapParams, "z" * uppercasefirst(k)) &&
                add!(
                    "z" * uppercasefirst(_REPORT_LABELS[k]),
                    mapParams["z"*uppercasefirst(k)],
                )
        end
        adopt!("c1Sat", "exclVolSat")
        adopt!("cavityFrac")
    end
    add!("divergenceRate", divergenceRate)
    add!("nDivergent", count(s -> s.numerical_error, fit.stats))
    for k in ("rhatMax", "essMin", "essTailMin", "ebfmi", "meanAccept",
        "treeDepthAvg", "treeDepthMax", "meanNSteps", "iterations", "chainsPooled",
        "chainsRun", "modes", "optima", "rewhitenedNats", "retryFirstRhat",
        "retryKept",
    )
        adopt!(k)
    end
    haskey(run, "modes") || add!("modes", 1)
    d = fit.diagnostics
    if length(d.modeWeight) > 1
        add!("modeShareMax", maximum(d.modeWeight))
        add!("modeShareMin", minimum(d.modeWeight))
    end
    nuts = _logStage(log, "NUTS ")
    m =
        nuts === nothing ? nothing :
        match(r"([\d.]+[kM]?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step", nuts.name)
    if m !== nothing
        add!("leapfrog", _logCount(m.captures[2]))
        add!("msStep", m.captures[3])
    end
    mp = _logStage(log, "MAP search")
    m = mp === nothing ? nothing : match(r"(\d+)/(\d+) starts, (\d+) modes?", mp.name)
    if m !== nothing
        add!("mapStartsOk", m.captures[1])
        add!("mapStartsTot", m.captures[2])
        add!("mapModes", m.captures[3])
    end
    return rows
end

"""
The machine the run was made on, as the last rows of its section (`[name, value]` pairs):
the system, the processor and its clock, the cores, the Julia threads, the memory, and the
load and the free memory when the run started (a busy machine spoils a timing).
"""
function _logMachine(log::StageLog)
    cpu = first(Sys.cpu_info())
    gib(x) = _logCell(round(x / 2^30; digits = 1))
    rows = [["machine.os", string(Sys.KERNEL, " ", Sys.MACHINE)],
        ["machine.cpu", cpu.model == "unknown" ? Sys.CPU_NAME : strip(cpu.model)],
        ["machine.cpu_mhz", string(cpu.speed)],
        ["machine.cpus", string(Sys.CPU_THREADS)],
        ["machine.threads", string(Threads.nthreads())],
        ["machine.memory_gib", gib(Sys.total_memory())]]
    haskey(log.info, "loadStart") &&
        push!(rows, ["machine.loadStart", _logCell(log.info["loadStart"])])
    haskey(log.info, "freeMemoryStart") &&
        push!(rows, ["machine.free_gib_start", gib(log.info["freeMemoryStart"])])
    return rows
end

"""
The stamp of a write of the log: the day, the time (24 hours) and 
the offset from UTC (ex: `27-10-2026 14:09:33 +0200`).
"""
_logStamp() = Libc.strftime("%d-%m-%Y %H:%M:%S %z", time())

"""
Lays out `rows` (each a vector of cells) as lines of tab-separated cells that line up in any
viewer: a cell that has another after it is padded with spaces to the width of its column,
a multiple of 8 that leaves room for the widest cell, and followed by one tab. At a tab
width of 2, 4 or 8 the next cell starts in the same column on every line, and a line still
splits on its tabs (the cells keep their padding, which a reader trims).
"""
function _tabLines(rows)
    ncol = maximum(length, rows; init = 0)
    stop(w) = 8 * cld(w + 1, 8)
    # only a cell that has another after it is padded, so a column is as wide as those
    widths = [
        stop(maximum(length(r[j]) for r in rows if length(r) > j; init = 0)) for
        j in 1:ncol
    ]
    return [
        join((j < length(r) ? rpad(c, widths[j]) : c for (j, c) in enumerate(r)), "\t") for
        r in rows
    ]
end

"""
Replaces the section `title` of the log file `path` with `lines` (or adds it at the end),
keeping the others as they are, and stamps the file with the time of the write on its first
line. The file is written next to its final name and then renamed.
"""
function _updateLog(path::AbstractString, title::AbstractString, lines)
    sections = Pair{String,Vector{String}}[]
    if isfile(path)
        for l in eachline(path)
            m = match(r"^=== (.*) ===$", l)
            if m !== nothing
                push!(sections, String(m.captures[1]) => String[])
            elseif !isempty(sections)
                push!(last(sections).second, l)
            end
        end
    end
    i = findfirst(p -> p.first == title, sections)
    i === nothing ? push!(sections, String(title) => collect(lines)) :
    (sections[i] = String(title) => collect(lines))
    mkpath(dirname(abspath(path)))
    tmp = path * ".part"
    open(tmp, "w") do io
        println(io, "datetime\t", _logStamp())      # of this write, once for the file
        for (name, body) in sections
            println(io)
            println(io, "=== ", name, " ===")
            while !isempty(body) && isempty(strip(last(body)))
                pop!(body)                    # the blank lines that separate sections
            end
            foreach(l -> println(io, l), body)
        end
    end
    mv(tmp, path; force = true)
    return String(path)
end

"""
    writeLog(result; refChi2 = nothing, path = nothing, name = nothing)

Writes the log of a [`runModel`](@ref) result: what is worth tracking from one run to the
next, in the section of the run in the file `<folder>.LOG` of the output folder of the
workbook that [`results`](@ref) wrote (the section is named after the run, `fit3` for
`res_fit3.xlsx`, the folder for `res.xlsx`; a folder with several runs has one section for
each, and a second call replaces the run's own section). The lines are flat, tab-aligned
`name  value` rows, then the timing table and the machine:

- the run: the BAYSOL revision (`-dirty` if tracked files have uncommitted changes),
  the Julia version, the BAYSOL version with its release name (`v0.3.0-wʋsg_n_yɩɩda`), the
  reference χ² (`refChi2`) if known, the kind of structure and its
  caches, the conditions (`temperatureC`, `ph`, `sigmaPh`, `energyEv`: what `seedModel`
  was given), the data and structure choices that differ from the defaults (`qMin`,
  `qMax`, `sigmaScale`, `excludeQ`, the points before and after, `structureModel`,
  `structureChains`, `addHydrogens`, `lmaxPinned`), the atoms, the model and the data,
  the sampler's settings and the seed;
- the fit: the reduced χ² on the measured points, the MAP of the parameters and their
  z-scores from the prior, the cavity fraction;
- the sampler's health: divergences, R̂, effective sample sizes, E-BFMI, acceptance, tree
  depth, leapfrog steps, the chains, modes and optima, a retry or a re-whitening;
- `--- timing ---`: the timing table as the reports showed it, for a person to read: the
  stages indented by level with their seconds, share of the wall clock, JIT and GC and a
  `notes` column (short, on the same line, no brackets), then the process's GC and the fit
  and plot timings;
- `--- machine ---`, last: the system, the processor and its clock, the cores and Julia
  threads, the memory, and the load and the free memory when the run started.

The first line of the file, `datetime`, stamps the last write (day, 24-hour
time, offset from UTC). The cells of a row are padded with spaces to a
multiple of 8 and followed by one tab, so they line up at any tab width.

[`results`](@ref) writes the log when it is given `runLog = true` (off by default; the
fitting tests set it); call `writeLog` yourself otherwise, or again after `results` to
include what came between. A folder's logs are tracked in git, which is why it is small.

# Arguments
- `result`: a `runModel` return value.
- `refChi2`: the reference χ², the depositor's with its method
    (`"CRYSOL 1.37"`), printed in the run's section as the `refChi2` row.
- `path`, `name`: the log file and the section's title instead of the ones the workbook
    gives.

# Returns
- The path of the log, `nothing` without a log
    of the run's stages (or a workbook or a path).

# Exceptions
- `SystemError` if the file cannot be written.
"""
function writeLog(result; refChi2 = nothing, path = nothing, name = nothing)
    tReport = tick()
    log = result[1].timing
    log === nothing && return nothing
    wb = get(log.info, "workbook", nothing)
    if path === nothing
        wb isa AbstractString || return nothing
        dir = dirname(wb)
        path = joinpath(dir, basename(abspath(dir)) * ".LOG")
    end
    if name === nothing
        stem = wb isa AbstractString ? replace(basename(wb), r"\.xlsx$" => "") : "res"
        name =
            stem == "res" ? basename(abspath(dirname(path))) : replace(stem, r"^res_" => "")
    end
    meta = [["revision", _logRevision()], ["julia", string(VERSION)],
        ["baysol", _logVersion()]]
    refChi2 === nothing || push!(meta, ["refChi2", string(refChi2)])
    lines = vcat(
        _tabLines(vcat(meta, _logStats(result))),
        ["", "--- timing ---"], _timingText(_timingTable(log, tReport)),
        ["", "--- machine ---"], _tabLines(_logMachine(log)),
    )
    _updateLog(path, name, lines)
    log.info["log"] = abspath(path)
    return String(path)
end
