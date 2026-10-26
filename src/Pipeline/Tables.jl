# SPDX-License-Identifier: LGPL-3.0-or-later

# The tables of a run, as the sheets of a workbook (`<name>.xlsx`) or as TSV files: the
# `_sheet` structure the summary and the figures build their tables with, the writers, the
# `draws` sheet. What goes into each table
# is decided where it is made (Summary.jl for the run's results, Results.jl for the figures'
# curves and histograms).

using XLSX: XLSX
using Printf: Printf

"""
A table of the numbers behind the figures: `name` (a sheet of the workbook),
the column names `header` and the columns `cols` (vectors of numbers,
strings or `missing`; a shorter one is padded with empty cells).
"""
_sheet(name, header, cols...) =
    (; name = String(name), header = String.(header), cols = collect(Any, cols))

"""
`names` as sheet names of a workbook: at most 31 characters (Excel's limit), none repeated
(a repeat gets `_2`, `_3`, …, within the limit).
"""
function _sheet_names(names)
    out = String[]
    for n in names
        base = String(first(n, 31))
        cand, k = base, 1
        while cand in out
            k += 1
            suffix = "_" * string(k)
            cand = String(first(base, 31 - length(suffix))) * suffix
        end
        push!(out, cand)
    end
    return out
end

"""
A cell of the workbook: a finite number rounded to `TABLE_SIGFIGS` significant figures
(nothing is rounded at 17 or more, which a `Float64` cannot carry), anything else as it is.
"""
function _cell end
_cell(x::AbstractFloat) =
    isfinite(x) && TABLE_SIGFIGS < 17 ? round(x; sigdigits = TABLE_SIGFIGS) : x
_cell(x::UInt64) = x > typemax(Int64) ? string(x) : x
_cell(x) = x

"""
Writes the table `sh` (made by `_sheet`) into the workbook sheet `sheet`, the header row
first; a column shorter than the longest is padded with empty cells.
"""
function _fill_sheet!(sheet, sh)
    n = maximum(length, sh.cols)
    cols = [Any[i ≤ length(c) ? _cell(c[i]) : missing for i in 1:n] for c in sh.cols]
    XLSX.writetable!(sheet, cols, sh.header)
    return nothing
end

"""
The sheets of the workbook written to `path`, in order: the first becomes the workbook's
first sheet. The file is written next to its final name and then renamed, so a crash
cannot leave half a workbook.

# Returns
- `path`.
"""
function _write_xlsx(path::AbstractString, sheets)
    mkpath(dirname(path))
    tmp = path * ".part"
    names = _sheet_names([sh.name for sh in sheets])
    XLSX.openxlsx(tmp; mode = "w") do xf
        for (k, sh) in enumerate(sheets)
            sheet = k == 1 ? xf[1] : XLSX.addsheet!(xf)
            XLSX.rename!(sheet, names[k])
            n = maximum(length, sh.cols)
            cols =
                [Any[i ≤ length(c) ? _cell(c[i]) : missing for i in 1:n] for c in sh.cols]
            XLSX.writetable!(sheet, cols, sh.header)
        end
    end
    mv(tmp, path; force = true)
    return String(path)
end

"""
Writes the sheets of a run to `dir/<name>.xlsx`.
The workbook path is recorded in `log.info` so that `print_summary` can name it.

Returns the path written.
"""
function _write_tables(dir, name, sheets, log)
    path = _write_xlsx(joinpath(dir, name * ".xlsx"), sheets)
    log === nothing || (log.info["workbook"] = abspath(path))
    return [path]
end

"""
The `draws` sheet: every draw of `fit` (divergent ones flagged), with its chain,
iteration, ξ, scale, background, c1 and reduced χ².
"""
function _draws_sheet(fit)
    cols = Any[Float64.(fit.chain), Float64.(fit.iteration),
        Float64.(getproperty.(fit.stats, :numerical_error))]
    names = ["chain", "iteration", "divergent"]
    for (i, (_, _, _, file)) in enumerate(PLOT_HIST_PARAMS)
        i ≤ 4 || break
        push!(cols, getindex.(fit.samples, i))
        push!(names, file)
    end
    append!(cols, (fit.scale, fit.bkgrnd_corr, fit.c1, fit.chisq_red))
    append!(names, ["scale", "bkgrnd_corr", "c1", "chisq_red"])
    return _sheet("draws", names, cols...)
end

"The font of a text sheet, and the width (characters) of its column."
const _TEXT_SHEET_FONT = "Courier New"
const _TEXT_SHEET_WIDTH = 100

"""
Adds the lines of `text` as the sheet `name` of the workbook that [`results`](@ref)
recorded in `log`, one line to a row of column A, in a monospace font and a column wide
enough for the longest line, so that a table laid out with spaces keeps its alignment. A
sheet of the same name is replaced; nothing happens without a recorded workbook.
"""
function _append_text_sheet(log::StageLog, name::AbstractString, text::AbstractString)
    path = get(log.info, "workbook", nothing)
    (path isa AbstractString && isfile(path)) || return nothing
    lines = split(rstrip(text), '\n')
    XLSX.openxlsx(path; mode = "rw") do xf
        XLSX.hassheet(xf, name) && XLSX.deletesheet!(xf, name)
        sheet = XLSX.addsheet!(xf, name)
        for (i, line) in enumerate(lines)
            sheet[i, 1] = String(line)
        end
        range = "A1:A$(length(lines))"
        XLSX.setFont(sheet, range; name = _TEXT_SHEET_FONT)
        XLSX.setColumnWidth(
            sheet,
            "A";
            width = 255,
        )
        XLSX.setAlignment(sheet, range; horizontal = "left", wrapText = false)
    end
    return nothing
end


"""
Writes the timing table of a [`run_model`](@ref) result as the `timings` sheet of the
workbook that [`results`](@ref) wrote for this run, in a monospace font so that its
columns line up as they do in a terminal. Call it after `results`, so the table lists
the plotting stages. A second call replaces the sheet.

The table lists the wall clock from the start of [`seed_model`](@ref) to the end of this
call, then each stage with its seconds, its share of the wall clock and its JIT compile
time, the `plotting` group when `results` ran, the garbage-collector time, and ends
with `fit timing` and `plot timing`, whose sum is the wall clock. See "The timing table"
in the Pipeline README for every line. The results themselves are the other sheets.

# Arguments
- `result`: a [`run_model`](@ref) return value, (fit, divergencerate, map, curve).

# Returns
- `nothing`.
"""
function write_timings(result)
    t_report = tick()
    log = result[1].timing
    log === nothing && return nothing
    _append_text_sheet(log, "timings", _timing_text(_timing_table(log, t_report)))
    return nothing
end

# ---------------------------------------------------------------------------
#                          The timing table
# ---------------------------------------------------------------------------

"""
Seconds as the timing table prints them: two decimals, or, below 0.01 s, in
scientific notation with two significant figures (`3.0e-03`), so a stage that took
a few milliseconds is not shown as a block of zeros. Exactly 0 prints as `0`.
"""
_fmt_seconds(x::Real) =
    x == 0 ? "0" : abs(x) < 0.01 ? @sprintf("%.1e", x) : @sprintf("%.2f", x)

"The width the lines of the timing table's notes are wrapped to."
const NOTE_WIDTH = 80

"""
The words of `note` ("" gives none) filled into lines of at most `width` characters; a word
longer than `width` stays whole on a line of its own.
"""
function _wrap_note(note::AbstractString, width::Integer)::Vector{String}
    lines = String[]
    cur = ""
    for word in split(note)
        if isempty(cur)
            cur = String(word)
        elseif length(cur) + 1 + length(word) <= width
            cur *= " " * word
        else
            push!(lines, cur)
            cur = String(word)
        end
    end
    isempty(cur) || push!(lines, cur)
    return lines
end

"""
The timing table, written last. The wall clock runs from the
creation of `log` (the start of [`seed_model`](@ref)) to now, i.e. to the end of
the table. `t_report` is the [`tick`](@ref BAYSOL.Runtime.tick) taken when
[`write_timings`](@ref) began, so the `report write` line is the time spent in
[`write_timings`](@ref) before the table. Nothing is written when `log` is `nothing`.

The `plotting` group is the stages [`results`](@ref) recorded (it prints only
when there are some). The last two lines split the wall clock in two, `fit timing`
(everything but the plotting: [`seed_model`](@ref), [`run_model`](@ref) and the
table) and `plot timing` (the `plotting` group), so the wall clock is their sum.

Stages print in the order they were recorded, indented two spaces per depth, with
the group lines (static build, sampling) summing their depth-1 stages. The label
column is as wide as the longest stage name so the seconds column always lines up; a
stage's note (`[cache hit]`) is wrapped to [`NOTE_WIDTH`](@ref) columns on lines of its own
under it, so no line is wider than the table.
"""
function _timing_table(log::StageLog, t_report)
    report_s = (time_ns() - t_report[1]) / NS_PER_S
    report_c = (Base.cumulative_compile_time_ns()[1] - t_report[2]) / NS_PER_S
    total_c = (Base.cumulative_compile_time_ns()[1] - log.compile0) / NS_PER_S
    wall = (time_ns() - log.t0) / NS_PER_S
    st, st_c, st_g = stage_seconds(log, :static)
    sp, sp_c, sp_g = stage_seconds(log, :sampling)
    pl, pl_c, pl_g = stage_seconds(log, :plot)
    unacc = wall - st - sp - pl - report_s
    # compile time not inside any stage: the first call of run_model, infer and
    # write_timings compiles before their bodies (and so their stages) begin
    unacc_c = total_c - st_c - sp_c - pl_c - report_c

    # one row per stage: its name, depth (the indentation), seconds, % of the wall clock
    # and JIT seconds (the last two `nothing` on plain stage lines) and its note
    rows = NamedTuple[]
    add!(name, depth, secs, pct = nothing, jit = nothing, note = "") =
        push!(rows, (; name, depth, secs, pct, jit, note))
    add!("wall clock  (seed_model → end of timings)", 0, wall, 100.0, total_c)
    for (group, label, tot, comp) in
        ((:static, "static build", st, st_c), (:sampling, "sampling", sp, sp_c),
        (:plot, "plotting", pl, pl_c))
        group === :plot && !any(s -> s.group === :plot, log.stages) && continue
        add!(label, 1, tot, 100 * tot / wall, comp)
        for stage in log.stages
            stage.group === group || continue
            add!(stage.name, stage.depth + 1, stage.seconds, nothing, nothing, stage.note)
        end
    end
    add!("report write", 1, report_s)
    add!("unaccounted", 1, unacc, nothing, max(unacc_c, 0.0))
    return (; rows, gc = st_g + sp_g + pl_g, fit = wall - pl, plot = pl)
end

"""
The text of a timing table made by `_timing_table`: the label column is as wide as the
longest indented stage name; a note is wrapped under its stage, and the GC line and the two
halves of the wall clock (everything but the plotting, and the plotting) come last.
"""
function _timing_text(table)
    io = IOBuffer()
    labels = ["  "^r.depth * r.name for r in table.rows]
    w = maximum(length, labels)
    @printf(io, "%-*s %10s %9s %8s\n", w, "stage", "seconds", "% wall", "(JIT)")
    for (r, label) in zip(table.rows, labels)
        @printf(io, "%-*s %10s", w, label, _fmt_seconds(r.secs))
        r.pct === nothing || @printf(io, " %9.1f", r.pct)
        r.jit === nothing || @printf(io, " %8s", @sprintf("(%.1f)", r.jit))
        println(io)
        indent = "  "^(r.depth + 1)
        for l in _wrap_note(r.note, NOTE_WIDTH - length(indent))
            println(io, indent * l)
        end
    end
    @printf(io, "GC: %s s\n", _fmt_seconds(table.gc))
    @printf(io, "fit timing  = %s s\n", _fmt_seconds(table.fit))
    @printf(io, "plot timing = %s s\n", _fmt_seconds(table.plot))
    return String(take!(io))
end

"""
Writes the timing table of `log` to `io`, as `write_timings` does; nothing when `log` is
`nothing`.
"""
function _write_timing(io::IO, log::Union{Nothing,StageLog}, t_report)
    log === nothing && return nothing
    print(io, _timing_text(_timing_table(log, t_report)))
    return nothing
end
