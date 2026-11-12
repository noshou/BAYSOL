# SPDX-License-Identifier: LGPL-3.0-or-later

# compare_results: ONE figure for a whole run, the measured curve with its error bars, the
# fitted (MAP) curve of every model and the reference curves, and the workbook of the same
# curves. As for `results`, the data of the figure is prepared once without any plotting
# library (`_compare_data`) and drawn three ways: a terminal plot (UnicodePlots), a pgfplots
# `.tex` (compiled only on request) and the `compare` workbook. The reader of the reference
# curves a project keeps in its `reference-fit/` folder is here too.

# ---------------------------------------------------------------------------
#                    reading the reference curves of a project
# ---------------------------------------------------------------------------

"""
The extensions a file of a project's `reference-fit/` folder may have (any case): a
reference curve is a text file of two or three numeric columns.
"""
const REFERENCE_EXTENSIONS = (".tsv", ".dat", ".txt")

"""
The reference curve in the text file `path`: two or three numeric columns (q, I and an
optional σ, which is read and not used), separated by white space, tabs, commas or
semicolons. Blank lines and everything from a `#` to the end of a line are skipped, and so
are text lines before the first row of numbers (a header). The curve is named by the file's
stem. `q_scale` multiplies q (0.1 turns nm⁻¹ into Å⁻¹).

# Returns
- The [`Reference`](@ref); points that cannot be drawn on log axes are dropped as it does.

# Exceptions
- `ArgumentError` naming the file (and the line) for a line that is not text of two or
    three numbers once the data has begun, a file without a numeric row, or one with no
    usable point.
- `SystemError` if the file cannot be read.
"""
function _read_reference(path::AbstractString; q_scale::Real = 1.0)
    file = basename(path)
    q, I = Float64[], Float64[]
    for (n, raw) in enumerate(eachline(path))
        line = strip(first(split(raw, '#'; limit = 2)))
        isempty(line) && continue
        cells = split(line, r"[\s,;]+"; keepempty = false)
        vals = tryparse.(Float64, cells)
        if any(isnothing, vals)
            isempty(q) && continue                  # a header before the first numbers
            throw(ArgumentError("$file line $n: a cell is not a number"))
        end
        length(vals) in (2, 3) ||
            throw(
                ArgumentError(
                    "$file line $n: expected 2 or 3 columns, found $(length(vals))",
                ),
            )
        push!(q, q_scale * vals[1])
        push!(I, vals[2])
    end
    isempty(q) && throw(ArgumentError("$file: no row of numbers"))
    try
        return Reference(splitext(file)[1], q, I)
    catch e
        e isa ArgumentError || rethrow()
        throw(ArgumentError("$file: " * e.msg))
    end
end

"""
The reference curves of the folder `folder` (a project's `reference-fit/`, or a run folder
with `prefix = "reference-fit-"`, which is then left off the names): every file whose name
starts with `prefix` and has one of the [`REFERENCE_EXTENSIONS`](@ref), in name order,
read by `_read_reference`. A stem that is taken (`a.tsv` and `a.dat`) gets `-2`, `-3`, …
so that every curve has its own name. A file that cannot be read is skipped and described in
the returned problems; it never stops the others.

# Returns
- `(references, problems)`: the curves, and one line of text for each file that was
    skipped, naming the file. A missing folder holds no curves and no problems.

# Exceptions
- None.
"""
function _read_references(
    folder::AbstractString; q_scale::Real = 1.0, prefix::AbstractString = "",
)
    refs = Reference[]
    problems = String[]
    isdir(folder) || return refs, problems
    used = Set{String}()
    for f in sort(readdir(folder))
        startswith(f, prefix) && lowercase(splitext(f)[2]) in REFERENCE_EXTENSIONS ||
            continue
        path = joinpath(folder, f)
        isfile(path) || continue
        try
            ref = _read_reference(path; q_scale)
            base = ref.name
            startswith(base, prefix) && (base = base[(length(prefix)+1):end])
            name, k = base, 1
            while name in used
                k += 1
                name = string(base, "-", k)
            end
            push!(used, name)
            push!(refs, Reference(name, ref.q, ref.I))
        catch e
            e isa InterruptException && rethrow()
            push!(
                problems,
                "reference $f was skipped: " *
                (e isa ArgumentError ? e.msg : sprint(showerror, e)),
            )
        end
    end
    return refs, problems
end

# ---------------------------------------------------------------------------
#                       the data of the comparison figure
# ---------------------------------------------------------------------------

"""
The UnicodePlots marker that stands for each marker name of `PLOT_MARKER_NAMES` in the
terminal plot (the closest mark UnicodePlots has; the `.tex` uses the pgfplots mark of the
same name).
"""
const _TERMINAL_MARKERS = Dict{Symbol,Symbol}(
    :o => :circle, Symbol("*") => :circle, :square => :rect, Symbol("square*") => :rect,
    :triangle => :utriangle, Symbol("triangle*") => :utriangle, :diamond => :diamond,
    Symbol("diamond*") => :diamond, :pentagon => :pentagon,
    Symbol("pentagon*") => :pentagon, :star => :star5, :x => :x, Symbol("+") => :+,
    :asterisk => :star6, :oplus => :cross, :otimes => :xcross,
)

"""
About how many marks a reference curve carries in the `.tex` figure (`mark repeat` thins
the marks of a dense curve to this many) and, thinned the same way, in the terminal plot.
Not a setting: it keeps the marks of a curve of hundreds of points from fusing into a band.
"""
const _COMPARE_MARKS = 14

"The size (pt) of the marks of the reference curves of the `.tex` figure."
const _COMPARE_MARK_SIZE_PT = 1.6

"The entry `k` of `list`, counting from 1 and starting again at the first after the last."
_assigned(list, k::Integer) = list[mod1(k, length(list))]

"""
The values `y` at `x` interpolated linearly onto the points `q`; `missing` for a `q`
outside the range of `x` and when fewer than two finite points are given. Used to put
the curves of the models and references onto the measured q of the `compare` sheet.
"""
function _interp_onto(q::AbstractVector, x::AbstractVector, y::AbstractVector)
    out = Vector{Union{Missing,Float64}}(missing, length(q))
    ok = [isfinite(a) && isfinite(b) for (a, b) in zip(x, y)]
    count(ok) < 2 && return out
    order = sortperm(x[ok])
    xs, ys = x[ok][order], y[ok][order]
    for (i, v) in enumerate(q)
        xs[1] ≤ v ≤ xs[end] || continue
        j = searchsortedlast(xs, v)
        out[i] =
            j == length(xs) ? ys[end] :
            ys[j] + (ys[j+1] - ys[j]) * (v - xs[j]) / (xs[j+1] - xs[j])
    end
    return out
end

"""
The data of the comparison figure, prepared once for all three outputs. `fits` are the
results of [`run_model`](@ref) (each with a MAP curve), `names` their names, `data` the
measured curve `(q, I, σ)` and `refs` the [`Reference`](@ref)s.

The measured points are as `_curve_data` makes them (positive intensities, log-symmetric
error bars, the y-range centred on them). Each model has its name, its colour (the `k`-th
of `style.colors_compare`, cycling), the TeX name of that colour, its MAP curve on its own
q grid (`map`, non-positive values NaN for the log axes; `map_raw` as it is, for the
workbook), its reduced χ² and, with a single model only, its bounds band (several bands
over each other are not readable). Each reference has its marker (the `k`-th of
`style.markers_compare`, cycling).
"""
function _compare_data(fits, names, data, refs, style::PlotStyle)
    base = _curve_data((nothing, nothing, nothing, nothing), data, style)
    floor_ = minimum(base.I) / 2
    models = map(enumerate(fits)) do (k, r)
        mc = r[3][2]
        band = nothing
        if length(fits) == 1 && r[4] !== nothing
            b = r[4][2]["bounds"]
            band = (q = b[:, 1], lo = max.(b[:, 2], floor_), hi = max.(b[:, 3], floor_))
        end
        return (;
            name = String(names[k]), color = _assigned(style.colors_compare, k),
            tex = "bscompare$k", chi2 = _chi2(r),
            map = (q = mc[:, 1], I = map(v -> v > 0 ? v : NaN, mc[:, 2])),
            map_raw = (q = mc[:, 1], I = mc[:, 2]), band,
        )
    end
    references = [
        (; ref, marker = _assigned(style.markers_compare, k)) for
        (k, ref) in enumerate(refs)
    ]
    return (;
        base.q, base.I, base.σ, base.err_lo, base.err_hi, base.ylim, raw = data, models,
        refs = references,
    )
end

# ---------------------------------------------------------------------------
#                                the .tex figure
# ---------------------------------------------------------------------------

"The bounds band of a single model: two invisible curves and the fill between them."
function _compare_band(m, style::PlotStyle)
    m.band === nothing && return Any[]
    lo, hi = "bscmplo", "bscmphi"
    return Any[
        @pgf(
            PGF.Plot({name_path = lo, draw = "none", forget_plot},
                _coords(m.band.q, m.band.lo))
        ),
        @pgf(
            PGF.Plot({name_path = hi, draw = "none", forget_plot},
                _coords(m.band.q, m.band.hi))
        ),
        @pgf(
            PGF.Plot(
                {fill = m.tex, fill_opacity = _opacity(style.color_band), draw = "none"},
                "fill between [of=$lo and $hi]")
        ),
        _legend("bounds"),
    ]
end

"""
The pgfplots axis of the comparison figure: the bounds band (one model only), the measured
points with their error bars, each reference as a dashed line in the reference colour
carrying its marker, and the MAP curve of each model in its own colour, on top.
"""
function _compare_axis(c, style::PlotStyle)
    plots = Any[]
    for m in c.models
        append!(plots, _compare_band(m, style))
    end
    append!(plots, _data_plots(c, style))
    for (k, r) in enumerate(c.refs)
        rep = max(1, length(r.ref.q) ÷ _COMPARE_MARKS)
        phase = clamp(1 + round(Int, (k - 1) * rep / length(c.refs)), 1, rep)
        push!(
            plots,
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLOURS.reference, dashed,
                        line_width = "$(style.lw_reference)pt", mark = String(r.marker),
                        mark_size = "$(_COMPARE_MARK_SIZE_PT)pt", mark_repeat = rep,
                        mark_phase = phase, mark_options = "solid"},
                    _coords(r.ref.q, r.ref.I))
            ),
            _legend(r.ref.name),
        )
    end
    for m in c.models
        push!(
            plots,
            @pgf(
                PGF.Plot(
                    {color = m.tex, line_width = "$(style.lw_compare)pt", mark = "none"},
                    _coords(m.map.q, m.map.I))
            ),
            _legend(m.name * " (MAP)"),
        )
    end
    return _axis(
        _axis_options(style; ylabel = raw"$I(q)$", height = style.size_cm[2],
            log = true, ylim = c.ylim, xlim = _xlim(c.q)),
        plots, style)
end

"""
The standalone document of the comparison figure: the figure's document
([`_tex_document`](@ref)) with the colour of each model defined in its preamble.
"""
function _compare_document(c, style::PlotStyle)
    td = _tex_document(_compare_axis(c, style), style)
    for m in c.models
        r, g, b, _ = _rgba(m.color)
        PGF.push_preamble!(td, "\\definecolor{$(m.tex)}{RGB}{$r,$g,$b}")
    end
    return td
end

# ---------------------------------------------------------------------------
#                              the terminal plot
# ---------------------------------------------------------------------------

"""
The comparison plot in the terminal: the data, each reference (a thin line of its marker)
and each model's MAP curve in its colour, as log₁₀ q against log₁₀ I(q). The bounds band
is in the `.tex` only. References share one colour, so the terminal tells them apart by
their marker.
"""
function _preview_compare(c, style::PlotStyle)
    lg = log10
    p = UnicodePlots.scatterplot(lg.(c.q), lg.(c.I); name = "data",
        color = _rgb(style.color_posterior), xlabel = "log₁₀ q   (q in Å⁻¹)",
        ylabel = "log₁₀ I(q)", title = "comparison", _term_kw(style)...)
    for r in c.refs
        idx = unique(round.(Int, range(1, length(r.ref.q); length = _COMPARE_MARKS)))
        UnicodePlots.scatterplot!(p, lg.(r.ref.q[idx]), lg.(r.ref.I[idx]);
            name = r.ref.name, color = _rgb(style.color_reference),
            marker = _TERMINAL_MARKERS[r.marker])
    end
    for m in c.models
        ok = .!isnan.(m.map.I)
        label =
            m.chi2 === nothing ? m.name :
            string(m.name, "   χ² = ",
                @sprintf("%.4g", m.chi2))
        UnicodePlots.lineplot!(p, lg.(m.map.q[ok]), lg.(m.map.I[ok]); name = label,
            color = _rgb(m.color))
    end
    return p
end

# ---------------------------------------------------------------------------
#                                 the workbook
# ---------------------------------------------------------------------------

"""
The table of `<name>_compare.tsv`, as `(header, columns)`: `q (A^-1)`,
`I_measured (a.u.)` and `sigma (a.u.)` of the measured curve as given, then a column
`fit_<model> (a.u.)` for each model (its MAP curve) and `ref_<name> (a.u.)` for each
reference, each interpolated linearly onto the measured q (empty outside the curve's own
range; a curve on the measured q is exactly as it is).
"""
function _compare_table(c)
    q, I, σ = c.raw
    header = ["q (A^-1)", "I_measured (a.u.)", "sigma (a.u.)"]
    cols = Any[q, I, σ]
    for m in c.models
        push!(header, "fit_$(m.name) (a.u.)")
        push!(cols, _interp_onto(q, m.map_raw.q, m.map_raw.I))
    end
    for r in c.refs
        push!(header, "ref_$(r.ref.name) (a.u.)")
        push!(cols, _interp_onto(q, r.ref.q, r.ref.I))
    end
    return header, cols
end

"""
Writes the comparison table `(header, cols)` as a tab-separated text file (a header line,
then a row for each point of the measured curve; an empty cell where a curve does not reach;
numbers rounded to `sigfigs` significant figures as the workbooks are). The file is written
next to its final name and then renamed.

# Returns
- `path`.
"""
function _write_tsv(path::AbstractString, header, cols; sigfigs::Integer = TABLE_SIGFIGS)
    mkpath(dirname(path))
    tmp = path * ".part"
    n = maximum(length, cols; init = 0)
    open(tmp, "w") do io
        println(io, join(header, '\t'))
        for i in 1:n
            cells = map(cols) do c
                x = i <= length(c) ? _cell(c[i], sigfigs) : missing
                ismissing(x) ? "" : string(x)
            end
            println(io, join(cells, '\t'))
        end
    end
    mv(tmp, path; force = true)
    return String(path)
end

# ---------------------------------------------------------------------------
#                              compare_results
# ---------------------------------------------------------------------------

"""
    compare_results(fits, data; names, references, dir, name, style, font, preview, io,
        tex, compile, formats, table_sigfigs, plot_tui_sizes, tui_dir) -> Vector{String}

The combined comparison of a run, ONE figure for the results of several models of the
same measured curve: the measured points with their error bars, the fitted (MAP) curve of
every model, in the colours of `style.colors_compare` (the first model takes the first
colour, and so on, cycling), and every [`Reference`](@ref) (the depositor's fit, CRYSOL,
FoXS, … ) as a dashed line in the reference colour carrying the marker of
`style.markers_compare` that its place in `references` gives it (cycling). With a single
model the posterior bounds band of the single-model figure is drawn too; with several the
bands would hide each other and are left out. Log axes, as the other I(q) figures.
`run_project` calls it after the last model of a run when the setting
`PLOT_COMPARE` is on, into the run's `compare/` folder.

Three outputs come out of it, as from [`results`](@ref): the figure in the terminal
(printed to `io`, `preview = true`), the pgfplots `<name>_compare.tex` in `dir/plots/`
(`tex = true`; LaTeX is run only with `compile = true`, to the `formats`, and a failed run
is a warning), and the table `dir/<name>_compare.tsv` of the same curves, always written,
tab-separated (it compresses, unlike a workbook): `q`, the measured `I` and `sigma`, then a
column for the fit of each model and one for each reference, each interpolated onto the
measured q: empty where a curve does not reach, exact where it is on that grid. The
figure's colours, markers and line styles are the settings' (`PLOT_COMPARE_*`).

# Arguments
- `fits`: the results of [`run_model`](@ref), one per model, of the SAME measured curve. A
    result without a MAP curve (every draw diverged) has nothing to draw: it is skipped
    with a warning.
- `data`: the measured curve `(q, I, σ)` (q in Å⁻¹) that every fit was made from; the
    figure shows these points, not each model's own binned curve.
- `names`: the model names, `model1`, `model2`, … by default; they label the legend and
    the columns, and must differ.
- `references`: [`Reference`](@ref)s, a vector or a single one.
- `dir`, `name`: the output folder (created if missing) and the first part of the file
    names (`<name>_compare`).
- `style`, `font`: a [`PlotStyle`](@ref) and the font, as for [`results`](@ref).
- `preview`, `io`, `tex`, `compile`, `formats`: as for [`results`](@ref).
- `table_sigfigs`: significant figures of every number of the workbook (17 writes every
    bit of a `Float64`; at least 1).
- `plot_tui_sizes`, `tui_dir`: as for [`results`](@ref): with a `tui_dir` the terminal
    plot is also drawn at each size of `plot_tui_sizes` and written there as
    `plots_<width>x<height>.txt`.

# Returns
- The paths of the files written: the `.tex`, what was compiled from it, the workbook and
    the terminal plots of `tui_dir`.

# Exceptions
- `ArgumentError` if `fits` is empty or none has a MAP curve, `names` has another length
    than `fits` or repeats a name, `data` has no positive intensity or its three vectors
    differ in length, the `style` holds a value that cannot be drawn, `formats` holds
    anything but `:pdf`, `:png` and `:svg`, or `font` is not `nothing`, a font name or a
    pair of names.
- [`InvalidSettingsError`](@ref) if `table_sigfigs` is not a whole number of at least 1 or
    `plot_tui_sizes` is not a valid `PLOT_TUI_SIZES`.
"""
function compare_results(
    fits::AbstractVector, data::Tuple;
    names::AbstractVector{<:AbstractString} = ["model$k" for k in eachindex(fits)],
    references::Union{Reference,AbstractVector{Reference}} = Reference[],
    dir::AbstractString = pwd(),
    name::AbstractString = "res",
    style::PlotStyle = PlotStyle(),
    font = style.font,
    preview::Bool = true,
    io::IO = stdout,
    tex::Bool = FIGURES_TEX,
    compile::Bool = FIGURES_COMPILE,
    formats = FIGURES_FORMATS,
    table_sigfigs::Integer = TABLE_SIGFIGS,
    plot_tui_sizes = PLOT_TUI_SIZES,
    tui_dir::Union{Nothing,AbstractString} = nothing,
)::Vector{String}
    q, I, σ = data
    _check_style(style)
    checked = _checked_keywords(:results, (; table_sigfigs, plot_tui_sizes))
    table_sigfigs, plot_tui_sizes = checked.table_sigfigs, checked.plot_tui_sizes
    _need(
        all(f -> f in (:pdf, :png, :svg), formats),
        "formats may hold :pdf, :png and :svg",
    )
    length(q) == length(I) == length(σ) ||
        throw(ArgumentError("data: q, I and σ must have the same length"))
    _need(!isempty(fits), "compare_results needs at least one fit")
    _need(length(names) == length(fits), "names must have one name for each fit")
    _need(allunique(names), "the model names must differ")
    refs = references isa Reference ? [references] : collect(references)
    _font_names(font)                               # a bad font is an error before any work
    style = font == style.font ? style : _with_font(style, font)
    has_map = [r[3] !== nothing for r in fits]
    for k in findall(!, has_map)
        @warn "compare_results: model $(names[k]) has no MAP curve and is left out"
    end
    _need(any(has_map), "no fit has a MAP curve to draw")
    c = _compare_data(fits[has_map], names[has_map], data, refs, style)
    mkpath(dir)
    written = String[]
    stem = joinpath(dir, PLOT_SUBDIR, name * "_compare")
    preview && (println(io, _preview_compare(c, style)); println(io))
    td = nothing
    if tex || compile
        td = _compare_document(c, style)
        tex && push!(written, _write_tex(td, stem))
    end
    compile && append!(written, _compile_tex(td, stem, formats, style.font))
    table = joinpath(dir, name * "_compare.tsv")
    push!(written, _write_tsv(table, _compare_table(c)...; sigfigs = table_sigfigs))
    if tui_dir !== nothing
        texts = map(plot_tui_sizes) do (W, H)
            buf = IOBuffer()
            text = _text_of_size(W, H) do w, h, bins
                sprint(print, _preview_compare(c, _terminal_style(style, w, h, bins)))
            end
            println(buf, text)
            println(buf)
            buf
        end
        append!(written, _write_tui_texts(tui_dir, plot_tui_sizes, texts))
    end
    return written
end
