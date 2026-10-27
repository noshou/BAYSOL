# SPDX-License-Identifier: LGPL-3.0-or-later

# The tables of a run, as the sheets of a workbook (`<name>.xlsx`): the
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
(nothing is rounded at 17 or more, which a `Float64` cannot carry); a number that is
not finite (a statistic that could not be computed, `NaN`) is an empty cell, since a
spreadsheet has no `NaN` and would hold it as text. Anything else is as it is, but an
integer a `Float64` cannot hold exactly (2^53 or more: a seed a user gave) is text.
"""
function _cell end
_cell(x::AbstractFloat) =
    !isfinite(x) ? missing : TABLE_SIGFIGS < 17 ? round(x; sigdigits = TABLE_SIGFIGS) : x
_cell(x::UInt64) = x > UInt64(2)^53 ? string(x) : x
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
The widest a column is made (characters); a column with longer text wraps it.
"""
const _MAX_COLUMN_WIDTH = 80

"""
Sets the width of each column of `sheet` to fit its header and its longest cell (up to
`_MAX_COLUMN_WIDTH`; a column with longer text wraps it, aligned to the top of its row) and
makes the header row bold. `cols` are the cells of each column, in the header's order.
"""
function _fit_columns!(sheet, header, cols)
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
            _fit_columns!(sheet, sh.header, cols)
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
