# SPDX-License-Identifier: LGPL-3.0-or-later

# The run log: `<ID>.LOG` in the output folder of a run.

"""
A stage's name without what it carries in parentheses (`NUTS  (8k iters, 69.91k leapfrog)`)
or after a comma (`optima from the draws, 0 extra chains`), and that detail joined to the
stage's own note, with the brackets and parentheses that only set it off dropped.

# Returns
- `(stage, notes)`.
"""
function _stage_and_note(name::AbstractString, note::AbstractString)
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
(the `startup`, Linux) through `seed_model` to now. `t_report` is the
[`tick`](@ref BAYSOL.Runtime.tick) taken when the table began, so `report write` is the time
spent writing before it.
"""
function _timing_table(log::StageLog, t_report)
    now_c = Base.cumulative_compile_time_ns()[1]
    now_g = Base.gc_time_ns()
    report_s = (time_ns() - t_report[1]) / NS_PER_S
    report_c = (now_c - t_report[2]) / NS_PER_S
    report_g = (now_g - t_report[3]) / NS_PER_S

    # the run (from `seed_model`) and the wall clock, which also counts the startup: the
    # process from its start to `seed_model` (Julia's startup, `using BAYSOL`, whatever was
    # compiled before). The compile and GC counters count from the start of the process.
    run_s = (time_ns() - log.t0) / NS_PER_S
    run_c = (now_c - log.compile0) / NS_PER_S
    run_g = (now_g - log.gc0) / NS_PER_S
    startup_c, startup_g = log.compile0 / NS_PER_S, log.gc0 / NS_PER_S
    wall = log.startup + run_s
    st, st_c, st_g = stage_seconds(log, :static)
    sp, sp_c, sp_g = stage_seconds(log, :sampling)
    pl, pl_c, pl_g = stage_seconds(log, :plot)

    # what no stage covers: the first call of `run_model`, `infer` and `write_log`
    # compiles before their bodies (and so their stages) begin
    unacc = run_s - st - sp - pl - report_s
    unacc_c = run_c - st_c - sp_c - pl_c - report_c
    unacc_g = run_g - st_g - sp_g - pl_g - report_g

    # one row per stage: its name, depth (the indentation), seconds, % of the wall clock
    # (`nothing` on plain stage lines), JIT and GC seconds and its note
    rows = NamedTuple[]

    add!(name, depth, secs, pct = nothing, jit = nothing, gc = nothing, note = "") =
        push!(rows, (; name, depth, secs, pct, jit, gc, note))
    add!("wall clock  (process start to end)", 0, wall, 100.0,
        now_c / NS_PER_S, now_g / NS_PER_S)
    add!(
        "startup",
        1,
        log.startup,
        nothing,
        startup_c,
        startup_g,
        "process start to seed_model",
    )
    for (group, label, tot, comp, gcs) in
        ((:static, "static build", st, st_c, st_g),
        (:sampling, "sampling", sp, sp_c, sp_g), (:plot, "plotting", pl, pl_c, pl_g))
        group === :plot && !any(s -> s.group === :plot, log.stages) && continue
        add!(label, 1, tot, 100 * tot / wall, comp, gcs)
        for stage in log.stages
            stage.group === group || continue
            add!(stage.name, stage.depth + 1, stage.seconds, nothing, stage.compile,
                stage.gc, stage.note)
        end
    end
    add!("report write", 1, report_s, nothing, report_c, report_g)
    add!("unaccounted", 1, unacc, nothing, max(unacc_c, 0.0), max(unacc_g, 0.0))
    return (; rows, gc = now_g / NS_PER_S, fit = wall - pl, plot = pl)
end

"""
Seconds as the timing table prints them: two decimals, or, below 0.01 s, in
scientific notation with two significant figures (`3.0e-03`), so a stage that took
a few milliseconds is not shown as a block of zeros. Exactly 0 prints as `0`.
"""
_fmt_seconds(x::Real) =
    x == 0 ? "0" : abs(x) < 0.01 ? @sprintf("%.1e", x) : @sprintf("%.2f", x)

"""
The timing table of a run (see `_timing_table`) as lines of text, for a person to read:
a header, then a row for the wall clock and each stage, indented two spaces for each
level, with its seconds, its share of the wall clock, its JIT and GC seconds (every row
has all four) and its notes in a column of their own, short and on the same line (what
the stage's name carried in parentheses and its own note, without brackets, see
`_stage_and_note`). The last three lines are the process's GC time and the two halves
of the wall clock, `fit timing` (everything but the plotting) and `plot timing`.
"""
function _timing_text(table)
    wall = table.rows[1].secs
    parts = [_stage_and_note(r.name, r.note) for r in table.rows]
    labels = ["  "^r.depth * first(p) for (r, p) in zip(table.rows, parts)]
    w = maximum(length, labels)
    lines = [
        @sprintf("%-*s %10s %9s %8s %8s  %s", w, "stage", "seconds", "% wall", "(JIT)",
            "(GC)", "notes"),
    ]
    for (r, p, label) in zip(table.rows, parts, labels)
        line = @sprintf("%-*s %10s %9.1f %8s %8s", w, label, _fmt_seconds(r.secs),
            100 * (r.secs / wall), @sprintf("(%.1f)", something(r.jit, 0.0)),
            @sprintf("(%.1f)", something(r.gc, 0.0)))
        push!(lines, isempty(last(p)) ? line : line * "  " * last(p))
    end
    push!(lines, "GC: " * _fmt_seconds(table.gc) * " s")
    push!(lines, "fit timing  = " * _fmt_seconds(table.fit) * " s")
    push!(lines, "plot timing = " * _fmt_seconds(table.plot) * " s")
    return lines
end

"A number as a log cell: an integer as it is, a float to 6 significant figures."
_log_cell(x::Integer) = string(x)
_log_cell(x::Real) = string(round(x; sigdigits = 6))
_log_cell(x) = string(x)

"""
The version of BAYSOL as the log prints it, `v<version>-<release name>`
(`v0.3.0-wʋsg_n_yɩɩda`; just `v<version>` when [`RELEASE_NAME`](@ref) is
empty), the version of its `Project.toml`; `unknown` when that cannot be found.
"""
function _log_version()
    v = pkgversion(@__MODULE__)
    v === nothing && return "unknown"
    return "v" * string(v) * (isempty(RELEASE_NAME) ? "" : "-" * RELEASE_NAME)
end

"""
The short git revision of the BAYSOL source tree, with `-dirty` when it has uncommitted
changes to tracked files, `unknown` when it is not a git checkout.
"""
function _log_revision()
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
function _log_stage(log::StageLog, prefix::AbstractString)
    i = findfirst(s -> startswith(s.name, prefix), log.stages)
    return i === nothing ? nothing : log.stages[i]
end

"A count with a `k` or `M` suffix (`69.91k`) as a number."
function _log_count(tok::AbstractString)
    scale = endswith(tok, "k") ? 1e3 : endswith(tok, "M") ? 1e6 : 1.0
    return round(Int, parse(Float64, rstrip(tok, ['k', 'M'])) * scale)
end

"""
The rows of the setup, fit and sampler sections of a run's log (`[name, value]` pairs).

# Returns
- `Vector{Vector{String}}`.
"""
function _log_stats(result)
    fit, divergence_rate, map_result, _ = result
    log = fit.timing
    info = log.info
    map_params = map_result === nothing ? nothing : first(map_result)
    keys_, vals = _run_rows(fit, divergence_rate, map_params, info)
    run = Dict(zip(keys_, vals))
    rows = Vector{Vector{String}}()
    # a number that is not finite (a statistic that could not be computed) is not recorded
    add!(k, v) = v isa Real && !isfinite(v) || push!(rows, [k, _log_cell(v)])
    adopt!(k, from = k) = haskey(run, from) && add!(k, run[from])

    # what the stage notes say: the kind of structure, the caches, the downloads
    cls = _log_stage(log, "classify")
    kind = cls === nothing ? nothing : match(r"(protein|nucleic|mixed)", cls.note)
    kind === nothing || add!("structure", kind.captures[1])
    pq = _log_stage(log, "pdb2pqr")
    pq === nothing ||
        add!("pdb2pqr_cache", occursin("cache miss", pq.note) ? "miss" : "hit")
    cmp = _log_stage(log, "components")
    dl = cmp === nothing ? nothing : match(r"(\d+) download", cmp.note)
    dl === nothing || add!("components_download", dl.captures[1])

    for k in
        ("n_atoms", "lmax", "dmax", "n_q_raw", "n_q", "n_samples", "n_adapt", "rng_seed")
        adopt!(k)
    end
    if map_params !== nothing
        for k in _REPORT_KEYS
            k == "log_density" && continue
            haskey(map_params, k) &&
                add!(k == "excl_vol_corr" ? "c1" : _REPORT_LABELS[k], map_params[k])
        end
        for k in _PRIOR_KEYS
            haskey(map_params, "z_" * k) &&
                add!("z_" * _REPORT_LABELS[k], map_params["z_"*k])
        end
        adopt!("c1_sat", "excl_vol_sat")
        adopt!("cavity_frac")
    end
    add!("divergence_rate", divergence_rate)
    add!("n_divergent", count(s -> s.numerical_error, fit.stats))
    for k in ("rhat_max", "ess_min", "ess_tail_min", "ebfmi", "mean_accept",
        "tree_depth_avg", "tree_depth_max", "mean_n_steps", "iterations", "chains_pooled",
        "chains_run", "modes", "optima", "rewhitened_nats", "retry_first_rhat",
        "retry_kept",
    )
        adopt!(k)
    end
    haskey(run, "modes") || add!("modes", 1)
    d = fit.diagnostics
    if length(d.mode_weight) > 1
        add!("mode_share_max", maximum(d.mode_weight))
        add!("mode_share_min", minimum(d.mode_weight))
    end
    nuts = _log_stage(log, "NUTS ")
    m =
        nuts === nothing ? nothing :
        match(r"([\d.]+[kM]?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step", nuts.name)
    if m !== nothing
        add!("leapfrog", _log_count(m.captures[2]))
        add!("ms_step", m.captures[3])
    end
    mp = _log_stage(log, "MAP search")
    m = mp === nothing ? nothing : match(r"(\d+)/(\d+) starts, (\d+) modes?", mp.name)
    if m !== nothing
        add!("map_starts_ok", m.captures[1])
        add!("map_starts_total", m.captures[2])
        add!("map_modes", m.captures[3])
    end
    return rows
end

"""
The machine the run was made on, as the last rows of its section (`[name, value]` pairs):
the system, the processor and its clock, the cores, the Julia threads, the memory, and the
load and the free memory when the run started (a busy machine spoils a timing).
"""
function _log_machine(log::StageLog)
    cpu = first(Sys.cpu_info())
    gib(x) = _log_cell(round(x / 2^30; digits = 1))
    rows = [["machine.os", string(Sys.KERNEL, " ", Sys.MACHINE)],
        ["machine.cpu", cpu.model == "unknown" ? Sys.CPU_NAME : strip(cpu.model)],
        ["machine.cpu_mhz", string(cpu.speed)],
        ["machine.cpus", string(Sys.CPU_THREADS)],
        ["machine.threads", string(Threads.nthreads())],
        ["machine.memory_gib", gib(Sys.total_memory())]]
    haskey(log.info, "load_start") &&
        push!(rows, ["machine.load_start", _log_cell(log.info["load_start"])])
    haskey(log.info, "free_memory_start") &&
        push!(rows, ["machine.free_gib_start", gib(log.info["free_memory_start"])])
    return rows
end

"""
The stamp of a write of the log: the day, the time (24 hours) and 
the offset from UTC (ex: `27-10-2026 14:09:33 +0200`).
"""
_log_stamp() = Libc.strftime("%d-%m-%Y %H:%M:%S %z", time())

"""
Lays out `rows` (each a vector of cells) as lines of tab-separated cells that line up in any
viewer: a cell that has another after it is padded with spaces to the width of its column,
a multiple of 8 that leaves room for the widest cell, and followed by one tab. At a tab
width of 2, 4 or 8 the next cell starts in the same column on every line, and a line still
splits on its tabs (the cells keep their padding, which a reader trims).
"""
function _tab_lines(rows)
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
function _update_log(path::AbstractString, title::AbstractString, lines)
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
        println(io, "datetime\t", _log_stamp())      # of this write, once for the file
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
    write_log(result; ref_chi2 = nothing, path = nothing, name = nothing)

Writes the log of a [`run_model`](@ref) result: what is worth tracking from one run to the
next, in the section of the run in the file `<folder>.LOG` of the output folder of the
workbook that [`results`](@ref) wrote (the section is named after the run, `fit3` for
`res_fit3.xlsx`, the folder for `res.xlsx`; a folder with several runs has one section for
each, and a second call replaces the run's own section). The lines are flat, tab-aligned
`name  value` rows, then the timing table and the machine:

- the run: the BAYSOL revision (`-dirty` if tracked files have uncommitted changes),
  the Julia version, the BAYSOL version with its release name (`v0.3.0-wʋsg_n_yɩɩda`), the
  reference χ² (`ref_chi2`) if known, the kind of structure and its
  caches, the atoms, the model and the data, the sampler's settings and the seed;
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

[`results`](@ref) writes the log when it is given `run_log = true` (off by default; the
fitting tests set it); call `write_log` yourself otherwise, or again after `results` to
include what came between. A folder's logs are tracked in git, which is why it is small.

# Arguments
- `result`: a `run_model` return value.
- `ref_chi2`: the reference χ², the depositor's with its method
    (`"CRYSOL 1.37"`), printed in the run's section as the `ref_chi2` row.
- `path`, `name`: the log file and the section's title instead of the ones the workbook
    gives.

# Returns
- The path of the log, `nothing` without a log
    of the run's stages (or a workbook or a path).

# Exceptions
- `SystemError` if the file cannot be written.
"""
function write_log(result; ref_chi2 = nothing, path = nothing, name = nothing)
    t_report = tick()
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
    meta = [["revision", _log_revision()], ["julia", string(VERSION)],
        ["baysol", _log_version()]]
    ref_chi2 === nothing || push!(meta, ["ref_chi2", string(ref_chi2)])
    lines = vcat(
        _tab_lines(vcat(meta, _log_stats(result))),
        ["", "--- timing ---"], _timing_text(_timing_table(log, t_report)),
        ["", "--- machine ---"], _tab_lines(_log_machine(log)),
    )
    _update_log(path, name, lines)
    log.info["log"] = abspath(path)
    return String(path)
end
