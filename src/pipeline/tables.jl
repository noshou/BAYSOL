# SPDX-License-Identifier: LGPL-3.0-or-later

# The tables of a run, as the sheets of a workbook (`<name>.xlsx`): the
# `_sheet` structure the summary and the figures build their tables with, the writers, the
# `draws` sheet. What goes into each table
# is decided where it is made (summary.jl for the run's results, results.jl for the figures'
# curves and histograms).

using XLSX: XLSX
using Printf: Printf

"""
A table of the numbers behind the figures: `name` (a sheet of the workbook),
the column names `header` and the columns `cols` (vectors of numbers,
strings or `missing`; a shorter one is padded with empty cells). With `frozen = true` the
header row stays in view when the sheet is scrolled.
"""
_sheet(name, header, cols...; frozen::Bool = false) =
    (; name = String(name), header = String.(header), cols = collect(Any, cols), frozen)

"""
`names` as sheet names of a workbook: at most 31 characters (Excel's limit), none repeated
(a repeat gets `_2`, `_3`, …, within the limit).
"""
function _sheetNames(names)
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
A cell of the workbook: a finite number rounded to `sigfigs` significant
figures (`TABLE_SIGFIGS` by default; nothing is rounded at 17 or more, which
a `Float64` cannot carry); a number that is not finite (a statistic that
could not be computed, `NaN`) is an empty cell, since a spreadsheet has no
`NaN` and would hold it as text. Anything else is as it is, but an integer a
`Float64` cannot hold exactly (2^53 or more: a seed a user gave) is text.
"""
function _cell end
_cell(x::AbstractFloat, sigfigs::Integer = TABLE_SIGFIGS) =
    !isfinite(x) ? missing : sigfigs < 17 ? round(x; sigdigits = sigfigs) : x
_cell(x::UInt64, ::Integer = TABLE_SIGFIGS) = x > UInt64(2)^53 ? string(x) : x
_cell(x, ::Integer = TABLE_SIGFIGS) = x

"""
Writes the table `sh` (made by `_sheet`) into the workbook sheet `sheet`, the header row
first; a column shorter than the longest is padded with empty cells.
"""
function _fillSheet!(sheet, sh, sigfigs::Integer = TABLE_SIGFIGS)
    n = maximum(length, sh.cols)
    cols =
        [Any[i ≤ length(c) ? _cell(c[i], sigfigs) : missing for i in 1:n] for c in sh.cols]
    XLSX.writetable!(sheet, cols, sh.header)
    return nothing
end

"""
The widest a column is made (characters); a column with longer text wraps it.
"""
const _MAX_COLUMN_WIDTH = 80

"""
Sets the width of each column of `sheet` to fit its header and its longest cell (up to
`_MAX_COLUMN_WIDTH`; a column with longer text wraps it, aligned to the top of its row) and
makes the header row bold. `cols` are the cells of each column, in the header's order.
"""
function _fitColumns!(sheet, header, cols)
    n = maximum(length, cols; init = 0)
    for (j, (h, c)) in enumerate(zip(header, cols))
        len = maximum(
            (ismissing(x) ? 0 : length(string(x)) for x in c); init = length(h))
        len = max(len, length(h)) + 2
        col = XLSX.encode_column_number(j)
        XLSX.setColumnWidth(sheet, col; width = clamp(len, 8, _MAX_COLUMN_WIDTH))
        len > _MAX_COLUMN_WIDTH && n > 0 &&
            XLSX.setAlignment(sheet, "$(col)2:$(col)$(n + 1)"; wrapText = true,
                vertical = "top")
    end
    XLSX.setFont(sheet, "A1:$(XLSX.encode_column_number(length(header)))1"; bold = true)
    return nothing
end

"""
The sheets of the workbook written to `path`, in order: the first becomes the workbook's
first sheet. The file is written next to its final name and then renamed, so a crash
cannot leave half a workbook.

# Returns
- `path`.
"""
function _writeXlsx(path::AbstractString, sheets; sigfigs::Integer = TABLE_SIGFIGS)
    mkpath(dirname(path))
    tmp = path * ".part"
    names = _sheetNames([sh.name for sh in sheets])
    XLSX.openxlsx(tmp; mode = "w") do xf
        for (k, sh) in enumerate(sheets)
            sheet = k == 1 ? xf[1] : XLSX.addsheet!(xf)
            XLSX.rename!(sheet, names[k])
            n = maximum(length, sh.cols)
            cols = [
                Any[i ≤ length(c) ? _cell(c[i], sigfigs) : missing for i in 1:n]
                for c in sh.cols
            ]
            XLSX.writetable!(sheet, cols, sh.header)
            _fitColumns!(sheet, sh.header, cols)
            get(sh, :frozen, false) && XLSX.freezePanes(sheet)
        end
    end
    mv(tmp, path; force = true)
    return String(path)
end

"""
Writes the sheets of a run to `dir/<name>.xlsx`.
The workbook path is recorded in `log.info` so that `printSummary` can name it.

Returns the path written.
"""
function _writeTables(dir, name, sheets, log; sigfigs::Integer = TABLE_SIGFIGS)
    path = _writeXlsx(joinpath(dir, name * ".xlsx"), sheets; sigfigs = sigfigs)
    log === nothing || (log.info["workbook"] = abspath(path))
    return [path]
end

"""
The `draws` sheet: one tidy table, a row for each posterior draw of `fit`, in the
order the chains are stored, with a frozen header row. The columns, with units in the
header text: `chain` and `draw` (1-based, within the chain); the sampled parameters
`rhoE` (e⁻/Å³) and `deltaRho1..3` (units of `UNIT_OF_δρ` e⁻/Å³); the quantities
derived from each draw that the result already holds, `scale`, `bkgrndCorr`,
`exclVolCorr` (c1: profiled, or the sampled fifth coordinate when its profile had a
kink) and `chi2FitGrid` (the reduced χ² on the fitted grid); and the sampler's flags
of the draw: `logDensity`, `divergent` (1 for a divergent transition), `treeDepth`,
`nSteps`, `stepSize` and `acceptanceRate`. A flag the sampler's statistics do not
carry has no column. Nothing is recomputed: every column is read off `fit`.
"""
function _drawsSheet(fit)
    n = length(fit.samples)
    # the position of each draw within its chain (the chains are stored one after another)
    seen = Dict{Int,Int}()
    draw = [seen[c] = get(seen, c, 0) + 1 for c in fit.chain]
    cols = Any[fit.chain, draw]
    names = ["chain", "draw"]
    for (i, (_, _, _, file)) in enumerate(PLOT_HIST_PARAMS)
        i ≤ 4 || break
        push!(cols, getindex.(fit.samples, i))
        push!(names, i == 1 ? "rhoE (e-/A^3)" : "$file ($(UNIT_OF_δρ) e-/A^3)")
    end
    append!(cols, (fit.scale, fit.bkgrndCorr, fit.c1, fit.chisqRed))
    append!(
        names,
        ["scale", "bkgrndCorr (a.u.)", "exclVolCorr (c1)", "chi2FitGrid"],
    )
    # the sampler's flags, each only if the statistics carry it
    function stat(key)
        all(s -> hasproperty(s, key), fit.stats) || return nothing
        return getproperty.(fit.stats, key)
    end
    for (key, label) in (
        (:log_density, "logDensity"), (:numerical_error, "divergent"),
        (:tree_depth, "treeDepth"), (:n_steps, "nSteps"),
        (:step_size, "stepSize"), (:acceptance_rate, "acceptanceRate"),
    )
        v = stat(key)
        v === nothing && continue
        push!(cols, key === :numerical_error ? Int.(v) : v)
        push!(names, label)
    end
    all(c -> length(c) == n, cols) || error("the draws of the fit differ in length")
    return _sheet("draws", names, cols...; frozen = true)
end

"""
The `divergences` sheet: one row for each divergent transition of the run, of every attempt
(the base run, a retry, a ladder rung, the sampled-c1 restart), in the order the attempts
recorded them, with a frozen header row. The columns: `attempt` (as in the statistics log's
`attempts` table), `chain`, `draw` (the iteration within the chain, 1-based) and `phase`
(`warm-up` or `sampling`); the first four sampled parameters `rhoE (e-/A^3)` and
`deltaRho1..3` (units of `UNIT_OF_δρ` e⁻/Å³) at the divergent draw; `logDensity` and
`logDensityFromChainMedian` (log π less the median log π of the chain's sampling draws);
and the sampler's `nSteps` (leapfrog steps) and `treeDepth` of the transition. The sheet is
written even when no transition diverged (the header row alone): its absence would not say
that nothing diverged. Nothing is capped. The rows are the sampler's own per-draw records
(`Inference.statDivergences`); the statistics log does not list them.

# Arguments
- `rows`: the `NamedTuple`s of `Inference.statDivergences`.

# Returns
- The sheet made by `_sheet`.

# Exceptions
- None.
"""
function _divergencesSheet(rows)
    pcol(i) = Float64[r.xi[i] for r in rows]
    return _sheet("divergences",
        ["attempt", "chain", "draw", "phase", "rhoE (e-/A^3)",
            "deltaRho1 ($(UNIT_OF_δρ) e-/A^3)", "deltaRho2 ($(UNIT_OF_δρ) e-/A^3)",
            "deltaRho3 ($(UNIT_OF_δρ) e-/A^3)", "logDensity",
            "logDensityFromChainMedian", "nSteps", "treeDepth"],
        Int[r.attempt for r in rows], Int[r.chain for r in rows],
        Int[r.draw for r in rows], String[r.phase for r in rows],
        pcol(1), pcol(2), pcol(3), pcol(4), Float64[r.logπ for r in rows],
        Float64[r.dLogπ for r in rows], Int[r.steps for r in rows],
        Int[r.depth for r in rows]; frozen = true)
end

"""
The workbook of a run that failed after some of its transitions diverged: the sheets that
are honest after a failure, the `run` sheet (`status`, `errorType` and `error` rows, the
columns of the run sheet of a successful run, the values text) and the `divergences` sheet
([`_divergencesSheet`](@ref)). Nothing else exists to write (no draws were pooled). A run
that failed without a divergent transition writes no workbook: nothing would be in it that
the run log does not say.

# Arguments
- `path`: the workbook (`<folder>/res_<run>.xlsx`, `res.xlsx` for the folder's own run).
- `err`: the error that ended the run; `log`: the run's stage log (`nothing`: no workbook).

# Returns
- The path of the workbook, or `nothing` if there is nothing to write.

# Exceptions
- Whatever the workbook write throws (the caller records it as `workbookError` and goes on
    with the original error).
"""
function _writeFailedWorkbook(path::AbstractString, err, log::Union{Nothing,StageLog})
    log === nothing && return nothing
    rows = Inference.statDivergences(Inference.statBuffer(log))
    isempty(rows) && return nothing
    msg = replace(first(sprint(showerror, err), _LOG_ERROR_MAX), r"[\r\n\t]+" => " ")
    run = _sheet("run", ["section", "name", "value", "unit"],
        fill("run", 4), ["status", "errorType", "error", "divergentTransitions"],
        Any["failed", string(typeof(err)), msg, length(rows)], fill(missing, 4))
    sheets = [run, _divergencesSheet(rows)]
    log.info["workbook"] = abspath(_writeXlsx(path, sheets))
    return String(path)
end
