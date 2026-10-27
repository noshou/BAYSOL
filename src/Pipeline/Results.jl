# SPDX-License-Identifier: LGPL-3.0-or-later

# results: the figures of a fit. The data of every figure is prepared once, without any
# plotting library (`_curve_data`, `_residual_data`, `_histogram_data`, `_comparison_data`),
# and three outputs are drawn from it: a terminal preview (UnicodePlots), a pgfplots `.tex`
# file per figure (PGFPlotsX; a LaTeX run turns it into a PDF/PNG/SVG, only on request) and
# the figures' tables, which Tables.jl writes (a workbook).

using PGFPlotsX: PGFPlotsX, @pgf
using UnicodePlots: UnicodePlots
using Colors: Colors

const PGF = PGFPlotsX

"""
A colour: anything `Colors.parse` reads (`:crimson`, `"crimson"`, `"#dc143c"`), or a
`(colour, opacity)` tuple such as `(:darkorange, 0.15)`.
"""
const ColorSpec = Union{AbstractString,Symbol,Tuple{Union{AbstractString,Symbol},Real}}

"""
    PlotStyle(; color_map, color_posterior, …)

The look of the figures of [`results`](@ref). Every field is a keyword argument, and
each defaults to the `PLOT_`-prefixed constant of [`Pipeline`](@ref BAYSOL.Pipeline) of the
same name (`PlotStyle().color_map` is `PLOT_COLOR_MAP`).

# Fields
- `color_map`, `color_posterior`, `color_data`, `color_errorbar`,
    `color_band`, `color_band_resid`, `color_hist`, `color_reference`:
    [`ColorSpec`](@ref BAYSOL.Pipeline.ColorSpec)s.
- `lw_map`, `lw_reference`, `lw_quantile`,
    `lw_quantile_resid`, `lw_zero_line`, `lw_errorbar`: line widths (pt).
- `markersize`, `whiskerwidth`: the data markers' radius and the error bars' whisker (pt).
- `hist_bins`: bins of each posterior histogram.
- `size_cm`: `(width, curve, residuals, hist)` of the figures (cm); `hist` is the
    `(width, height)` of one histogram figure.
- `ylim_log`, `ylim_lin_pad_frac`: the y-ranges of the I(q) and the residuals plots.
- `preview_size`: `(width, height)` of a terminal plot (characters, rows).
- `border_pt`: the padding the PDF page keeps round a figure (pt).
- `lw_axis`: the line width of the axis box (pt).
- `lw_tick`, `tick_length_cm`, `minor_ticks`, `tick_label_pad_pt`: the black axis
    ticks (line width in pt, major length in cm, the minor ticks between two major
    ones of a linear axis) and the gap between the y axis and its tick labels (pt).
- `xtick_angle`: the angle the x tick labels are turned by (degrees; 0 leaves them level).
- `tick_stub_pt`, `tick_elbow_pt`: each x tick leaves the axis straight for `tick_stub_pt`
    and then bends for `tick_elbow_pt` towards its slanted label (pt).
- `font`: the font of the LaTeX output: the name of any font LuaLaTeX can find (the text
    font; the math font stays Latin Modern Math), a `(text font, math font)` pair of
    `fontspec` names (the default is `PLOT_FONT`, TeX Gyre PagellaX with TeX Gyre Pagella
    Math), or `nothing` for the LaTeX default. [`font_available`](@ref) says whether a name
    is usable. A font needs `lualatex` or `xelatex`.
"""
Base.@kwdef struct PlotStyle
    color_map::ColorSpec = PLOT_COLOR_MAP
    color_posterior::ColorSpec = PLOT_COLOR_POSTERIOR
    color_data::ColorSpec = PLOT_COLOR_DATA
    color_errorbar::ColorSpec = PLOT_COLOR_ERRORBAR
    color_band::ColorSpec = PLOT_COLOR_BAND
    color_band_resid::ColorSpec = PLOT_COLOR_BAND_RESID
    color_hist::ColorSpec = PLOT_COLOR_HIST
    color_reference::ColorSpec = PLOT_COLOR_REFERENCE
    lw_map::Float64 = PLOT_LW_MAP
    lw_reference::Float64 = PLOT_LW_REFERENCE
    lw_quantile::Float64 = PLOT_LW_QUANTILE
    lw_quantile_resid::Float64 = PLOT_LW_QUANTILE_RESID
    lw_zero_line::Float64 = PLOT_LW_ZERO_LINE
    lw_errorbar::Float64 = PLOT_LW_ERRORBAR
    markersize::Float64 = PLOT_MARKERSIZE
    whiskerwidth::Float64 = PLOT_WHISKERWIDTH
    hist_bins::Int = PLOT_HIST_BINS
    size_cm::NamedTuple = PLOT_SIZE_CM
    ylim_log::Tuple{Float64,Float64} = PLOT_YLIM_LOG
    ylim_lin_pad_frac::Float64 = PLOT_YLIM_LIN_PAD_FRAC
    preview_size::NamedTuple = PLOT_PREVIEW_SIZE
    border_pt::Float64 = PLOT_BORDER_PT
    xtick_angle::Float64 = PLOT_XTICK_ANGLE
    lw_axis::Float64 = PLOT_LW_AXIS
    lw_tick::Float64 = PLOT_LW_TICK
    tick_length_cm::Float64 = PLOT_TICK_LENGTH_CM
    minor_ticks::Int = PLOT_MINOR_TICKS
    tick_label_pad_pt::Float64 = PLOT_TICK_LABEL_PAD_PT
    tick_stub_pt::Float64 = PLOT_TICK_STUB_PT
    tick_elbow_pt::Float64 = PLOT_TICK_ELBOW_PT
    font::Union{Nothing,String,Tuple{String,String}} = PLOT_FONT
end

"""
    Reference(name, q, I; q_max = Inf)

A curve to compare the fit with (the depositor's CRYSOL, FoXS, … fit), drawn with the
measured points and the MAP curve on a figure of its own. `name` labels it in the legend
and in the file name. Points with a non-finite or non-positive `q` or `I` (not drawable on
log axes) or with `q > q_max` are dropped.

# Returns
- The `Reference`.

# Exceptions
- `ArgumentError` if `q` and `I` differ in length or no point is left.
"""
struct Reference
    name::String
    q::Vector{Float64}
    I::Vector{Float64}
    function Reference(name::AbstractString, q::AbstractVector, I::AbstractVector;
        q_max::Real = Inf)
        length(q) == length(I) ||
            throw(ArgumentError("Reference $name: q and I differ in length"))
        keep = [
            isfinite(x) && isfinite(y) && x > 0 && y > 0 && x ≤ q_max
            for (x, y) in zip(q, I)
        ]
        any(keep) || throw(ArgumentError("Reference $name: no usable point"))
        return new(String(name), Float64.(q[keep]), Float64.(I[keep]))
    end
end

# ---------------------------------------------------------------------------
#                    The data of the figures (no plotting library)
# ---------------------------------------------------------------------------

"""
The MAP's reduced χ² on the measured points (the
report's `χ²` line), or `nothing` without a MAP.
"""
_chi2(result) = result[3] === nothing ? nothing : get(result[3][1], "chisq_red", nothing)

"""
A plot title with the reduced χ² after it:
`fit   χ² = 1.234` (nothing is added without one).
"""
_titled(title::AbstractString, chi2) =
    chi2 === nothing ? String(title) : string(title, "   χ² = ", @sprintf("%.4g", chi2))

"The non-divergent draws of `fit`, as a mask."
_ok_draws(fit) = .!getproperty.(fit.stats, :numerical_error)

"""
The I(q) figure's data: the measured points with positive intensity (the log axes cannot
show the others; the fit itself used every point), their error bars' ends (`err_lo`,
`err_hi`; a plain additive I ± σ interval is not symmetric on a log axis, so σ is propagated
into log space by the delta method and the interval is log-symmetric and always positive),
the quantile and bounds curves floored at half the smallest intensity (a model can graze 0
at the noise floor, which a log axis cannot show), the MAP curve (non-positive values as
NaN), and the y-range centred on the data.

`band`, `quant` and `map` are `nothing` when the run has no MAP/quantiles (all draws
diverged).
"""
function _curve_data(result, data, style::PlotStyle)
    _, _, map_result, quantile_result = result
    q, I, σ = data
    pos = I .> 0
    q, I, σ = q[pos], I[pos], σ[pos]
    isempty(I) && throw(ArgumentError("no positive intensity to plot"))
    floor_ = minimum(I) / 2
    log_I = log10.(I)
    # capped: a σ far above I overflows exp10 to Inf, which PGFPlotsX rejects; a bar
    # that long runs off any axis anyway
    log_σ = min.(σ ./ (I .* log(10)), 20.0)
    band = quant = mapc = nothing
    if quantile_result !== nothing
        _, curves = quantile_result
        b, qn = curves["bounds"], curves["quantiles"]
        band = (q = b[:, 1], lo = max.(b[:, 2], floor_), hi = max.(b[:, 3], floor_))
        quant = (q = qn[:, 1], lo = max.(qn[:, 2], floor_), hi = max.(qn[:, 3], floor_))
    end
    if map_result !== nothing
        mc = map_result[2]
        mapc = (q = mc[:, 1], I = map(v -> v > 0 ? v : NaN, mc[:, 2]))
    end
    lo, hi = extrema(I)
    return (;
        q, I, σ,
        err_lo = exp10.(log_I .- log_σ), err_hi = exp10.(log_I .+ log_σ),
        band, quant, map = mapc, chi2 = _chi2(result),
        ylim = (lo * style.ylim_log[1], hi * style.ylim_log[2]),
    )
end

"""
The residuals figure's data: data minus the MAP curve with its σ, and the bounds and
quantile curves minus the MAP curve. `nothing` when the run has no MAP curve.
"""
function _residual_data(result, data, style::PlotStyle)
    _, _, map_result, quantile_result = result
    map_result === nothing && return nothing
    q, I, σ = data
    I_map = map_result[2][:, 2]
    resid = I .- I_map
    band = quant = nothing
    if quantile_result !== nothing
        _, curves = quantile_result
        b, qn = curves["bounds"], curves["quantiles"]
        band = (q = b[:, 1], lo = b[:, 2] .- I_map, hi = b[:, 3] .- I_map)
        quant = (q = qn[:, 1], lo = qn[:, 2] .- I_map, hi = qn[:, 3] .- I_map)
    end
    lo, hi = extrema(resid)
    pad = style.ylim_lin_pad_frac * (hi - lo)
    return (; q, I, σ, I_map, resid, band, quant, chi2 = _chi2(result),
        ylim = (lo - pad, hi + pad))
end

"""
The posterior histograms' data, one entry per parameter of `PLOT_HIST_PARAMS`: the label,
the TeX label, the non-divergent draws, the MAP value (`nothing` without a MAP) and the bin
`edges` and `counts` (`style.hist_bins` equal-width bins over the draws' range).
"""
function _histogram_data(result, style::PlotStyle)
    fit, _, map_result, _ = result
    ok = _ok_draws(fit)
    samples = fit.samples[ok]
    map_params = map_result === nothing ? nothing : map_result[1]
    out = NamedTuple[]
    for (i, (label, tex, key, file)) in enumerate(PLOT_HIST_PARAMS)
        draws = if label == "c1"
            fit.c1[ok]
        elseif label == "scale"
            fit.scale[ok]
        elseif label == "bkgrnd_corr"
            fit.bkgrnd_corr[ok]
        else
            getindex.(samples, i)
        end
        isempty(draws) && continue
        lo, hi = extrema(draws)
        hi > lo || (hi = lo + max(abs(lo), 1.0) * 1e-9)    # a constant parameter
        edges = collect(range(lo, hi; length = style.hist_bins + 1))
        counts = zeros(Int, style.hist_bins)
        for x in draws
            counts[clamp(searchsortedlast(edges, x), 1, style.hist_bins)] += 1
        end
        push!(
            out,
            (;
                label, tex, file, draws, edges, counts,
                map_value = map_params === nothing ? nothing : map_params[key],
            ),
        )
    end
    return out
end

"""
A comparison figure's data: the positive measured points with their log-symmetric error
bars, the MAP curve and the `reference`'s curve.
"""
function _comparison_data(result, data, reference::Reference, style::PlotStyle)
    c = _curve_data(result, data, style)
    return (; c.q, c.I, c.σ, c.err_lo, c.err_hi, c.map, c.ylim, ref = reference)
end

# ---------------------------------------------------------------------------
#                                  Small helpers
# ---------------------------------------------------------------------------

"A file-name-safe version of `s` (letters, digits, `-` and `.` kept)."
_slug(s::AbstractString) = replace(String(s), r"[^A-Za-z0-9.\-]+" => "_")

"`s` with the characters LaTeX treats specially escaped, for a legend entry or label."
function _tex_escape(s::AbstractString)
    out = String(s)
    for (a, b) in ("_" => "\\_", "%" => "\\%", "&" => "\\&", "#" => "\\#", "\$" => "\\\$")
        out = replace(out, a => b)
    end
    return out
end

"`(r, g, b, opacity)`, with the channels in 0:255, of a [`ColorSpec`](@ref)."
function _rgba(spec::ColorSpec)
    col, α = spec isa Tuple ? (spec[1], Float64(spec[2])) : (spec, 1.0)
    c = convert(Colors.RGB, Colors.parse(Colors.Colorant, String(col)))
    return (round(Int, 255 * Float64(Colors.red(c))),
        round(Int, 255 * Float64(Colors.green(c))),
        round(Int, 255 * Float64(Colors.blue(c))), α)
end

"The channels (0:255) of a [`ColorSpec`](@ref), for the terminal."
_rgb(spec::ColorSpec) = _rgba(spec)[1:3]

# ---------------------------------------------------------------------------
#                       The pgfplots/LaTeX figures (PGFPlotsX)
# ---------------------------------------------------------------------------

# The names of the colours defined in the preamble of every document.
const _TEX_COLORS = (
    map = "bsmap", posterior = "bsposterior", data = "bsdata", errorbar = "bserrorbar",
    band = "bsband", band_resid = "bsbandresid", hist = "bshist",
    reference = "bsreference",
)

"""
`style` with its `font` replaced by `font`.
"""
_with_font(style::PlotStyle, font) = PlotStyle(;
    (k => getfield(style, k) for k in fieldnames(PlotStyle) if k !== :font)..., font)

"""
The `(text font, math font)` of a [`PlotStyle`](@ref)'s `font` (the math font `nothing`
when only a text font is given), or `nothing` for the LaTeX default.

# Exceptions
- `ArgumentError` if `font` is none of `nothing`, a font name or a pair of font names.
"""
function _font_names(font)
    font === nothing && return nothing
    font isa AbstractString && return (String(font), nothing)
    font isa Tuple{<:AbstractString,<:AbstractString} && return String.(font)
    throw(
        ArgumentError(
            "font must be nothing, a font name or a (text font, math font) " *
            "pair of names, not $(repr(font))",
        ),
    )
end

"""
    font_available(name) -> Bool

Whether LuaLaTeX can use the font `name`, a `fontspec` name such as `"TeX Gyre Pagella"`
(upper and lower case and spaces do not matter). It asks `luaotfload-tool`, which comes
with TeX Live, without rebuilding the font database: a font installed since the database
was last built needs `luaotfload-tool --update` first.

# Returns
- `true` if the font is found, `false` if not.

# Exceptions
- `ErrorException` if `luaotfload-tool` is not on the `PATH` (no TeX Live), where nothing
    can be said about the font.
"""
function font_available(name::AbstractString)::Bool
    tool = Sys.which("luaotfload-tool")
    tool === nothing && error(
        "font_available needs luaotfload-tool, which comes with TeX Live; " *
        "none is on the PATH",
    )
    out = IOBuffer()
    run(
        pipeline(
            ignorestatus(`$tool --no-reload --find=$name`);
            stdout = out,
            stderr = out,
        ),
    )
    return occursin("found!", String(take!(out)))
end

"""
A standalone LaTeX document holding `axis`, with a border of `style.border_pt` round
it: the `fillbetween` library, the style's colours as `\\definecolor`s (the opacity of
a colour is applied where it is used, `_opacity`), and, if the style has a `font`, that
text and math font (`unicode-math`, so the document needs `lualatex` or `xelatex`).
"""
function _tex_document(axis, style::PlotStyle)
    td = PGF.TikzDocument(PGF.TikzPicture(axis))
    # the page is the figure plus a border; PGFPlotsX keeps its class options in a global
    filter!(o -> !startswith(o, "border="), PGF.CLASS_OPTIONS)
    push!(PGF.CLASS_OPTIONS, "border=$(style.border_pt)pt")
    PGF.push_preamble!(td, raw"\usepgfplotslibrary{fillbetween}")
    for (k, name) in pairs(_TEX_COLORS)
        r, g, b, _ = _rgba(getfield(style, Symbol(:color_, k)))
        PGF.push_preamble!(td, "\\definecolor{$name}{RGB}{$r,$g,$b}")
    end
    if (f = _font_names(style.font)) !== nothing
        PGF.push_preamble!(td, "\\usepackage{unicode-math}", "\\setmainfont{$(f[1])}")
        f[2] === nothing || PGF.push_preamble!(td, "\\setmathfont{$(f[2])}")
    end
    return td
end

"The opacity of a style colour, for `fill opacity` / `draw opacity`."
_opacity(spec::ColorSpec) = _rgba(spec)[4]

"Coordinates of `x`, `y`; a non-finite point breaks the line."
_coords(x, y; kw...) = PGF.Coordinates(x, y; kw...)

const _TEX_X = raw"$q$ (\AA$^{-1}$)"

"""
Round tick values (1, 2, 3, 5 × 10ᵏ; every integer multiple if that gives fewer than six)
in `[lo, hi]`, for a log axis whose range is less than a decade or two, where pgfplots'
own powers of ten would be one or two odd exponents.
"""
function _log_ticks(lo::Real, hi::Real)
    for ms in ((1, 2, 3, 5), 1:9)
        ticks = [
            m * 10.0^k for k in floor(Int, log10(lo)):ceil(Int, log10(hi)) for m in ms
            if lo ≤ m * 10.0^k ≤ hi
        ]
        length(ticks) ≥ 6 && return ticks
    end
    return [lo, hi]
end

"""
Round ticks and labels (see `_linear_ticks`) for an axis `width_cm` wide: as many as fit
without the labels running into each other, up to eight. A long label (`6.0×10⁻⁶`) gets
fewer ticks than a short one (`0.34`).
"""
function _fitting_ticks(lo::Real, hi::Real, width_cm::Real)
    ticks, labels = _linear_ticks(lo, hi, 8)
    for n in (8, 6, 5, 4, 3)
        ticks, labels = _linear_ticks(lo, hi, n)
        # a label takes about 0.18 cm a printed character (TeX markup does not print) and
        # needs a gap of about 0.3 cm
        sum(0.18 * _printed_length(l) + 0.3 for l in labels) ≤ 0.9 * width_cm && break
    end
    return ticks, labels
end

"""
About `n` round tick values (steps of 1, 2 or 5 × 10ᵏ) between `lo` and `hi`, and their
labels. The labels are as long as the step needs: `0.3405` for a step of 0.0005, `12` for a
step of 2, and `6×10⁻⁶` (as TeX) for values whose size is far from 1, so a parameter near
zero or in a narrow range is never printed as a column of identical numbers.

# Returns
- `(ticks, labels)`; both empty if the range is a single value.
"""
function _linear_ticks(lo::Real, hi::Real, n::Integer)
    hi > lo || return Float64[], String[]
    raw = (hi - lo) / n
    mag = 10.0^floor(Int, log10(raw))
    step = mag * (raw / mag ≤ 1.5 ? 1 : raw / mag ≤ 3.5 ? 2 : raw / mag ≤ 7.5 ? 5 : 10)
    ticks = [k * step for k in ceil(Int, lo/step):floor(Int, hi/step)]
    return ticks, _tick_labels(ticks, step)
end

"""
The TeX labels of `ticks`, whose spacing is `step` (see `_linear_ticks`): all with the same
number of decimals, and, when the values are far from 1 (below 10⁻³ or above 10⁵), all with
the exponent of the largest, as `0.6×10⁻⁵, 0.8×10⁻⁵, 1.0×10⁻⁵`, so that the labels of one
axis are comparable at a glance.
"""
function _tick_labels(ticks, step::Real)
    isempty(ticks) && return String[]
    nonzero = filter(!iszero, ticks)
    emax = isempty(nonzero) ? 0 : floor(Int, log10(maximum(abs, nonzero)))
    estep = floor(Int, log10(step))
    # `d` decimals, zeros included, so that the labels of an axis line up (`0.30, 0.32`)
    function plain(v, d)
        d ≤ 0 && return string(round(Int, v))
        str = string(round(v; digits = d))
        i = findfirst('.', str)
        return i === nothing ? str * "." * "0"^d : str * "0"^(d - (length(str) - i))
    end
    if -3 ≤ emax ≤ 5
        return ["\$" * plain(t, -estep) * "\$" for t in ticks]
    end
    return [
        t == 0 ? "\$0\$" :
        "\$" * plain(t / 10.0^emax, emax - estep) * "\\times10^{" * string(emax) * "}\$"
        for t in ticks
    ]
end

"""
The look of the axis lines and ticks of an axis, in its options `opts`: a bold
black box and black ticks of `style.lw_tick` on all four sides, pointing
inward, major and minor (`style.minor_ticks` between two major ones of a linear
axis; a log axis keeps its own) and the y tick labels `style.tick_label_pad_pt`
away from the axis. The x tick labels are drawn by `_xtick_leaders!`.
"""
function _style_ticks!(opts, style::PlotStyle; log::Bool = false)
    opts["axis line style"] = "{black, line width=$(style.lw_axis)pt}"
    opts["tick align"] = "inside"
    opts["xtick pos"] = "both"
    opts["ytick pos"] = "both"
    opts["tick style"] = "{black, line width=$(style.lw_tick)pt}"
    opts["major tick length"] = "$(style.tick_length_cm)cm"
    opts["minor tick length"] = "$(style.tick_length_cm / 2)cm"
    if !log
        opts["minor x tick num"] = style.minor_ticks
        opts["minor y tick num"] = style.minor_ticks
    end
    opts["yticklabel style"] = "xshift=-$(style.tick_label_pad_pt)pt"
    return opts
end

"""
How many characters a tick label prints: the TeX markup (`\\times`, `^`, `{}`, `\$`) does
not print.
"""
_printed_length(l) = count(c -> !(c in "\$\\{}^"), replace(l, "\\times" => "×"))

"""
The labels of the ticks of a log axis (`0.02`, `0.5`, `1`): rounded, so that `3 * 0.1` does
not print as `0.30000000000000004`.
"""
function _log_labels(ticks)
    return [
        "\$" * replace(string(round(t; sigdigits = 3)), r"\.0$" => "") * "\$" for
        t in ticks
    ]
end

"""
The x tick labels of an axis whose options are `opts`, drawn as TikZ so that each can hang
on a bent tick: the tick leaves the axis straight (`style.tick_stub_pt`), bends for
`style.tick_elbow_pt` in the direction of the slanted label (`style.xtick_angle`) and ends
in the label, which reads up to the right. pgfplots' own labels are switched off, and the
axis title is moved down below the longest label. With an angle of 0 the tick stays
straight and the label sits level below it.

# Returns
- The TikZ commands to put in the axis, as strings; none if the axis has no x ticks or no
    `ymin` to start them from.
"""
function _xtick_leaders!(opts, style::PlotStyle)
    (haskey(opts, "xtick") && haskey(opts, "ymin")) || return String[]
    ticks = split(string(opts["xtick"]), ',')
    labels = if haskey(opts, "xticklabels")
        split(string(opts["xticklabels"]), ',')
    else
        _log_labels(parse.(Float64, ticks))
    end
    opts["xticklabels"] = "{}"
    # the commands lie outside the axis box: clip each plot on its own, not everything
    opts["clip mode"] = "individual"
    a, ymin = style.xtick_angle, opts["ymin"]
    stub, elbow = style.tick_stub_pt, style.tick_elbow_pt
    leg = iszero(a) ? "" : " -- ++(-$(elbow * cosd(a))pt,-$(elbow * sind(a))pt)"
    node = iszero(a) ? "anchor=north" : "anchor=east, rotate=$a"
    cmds = [
        "\\draw[black, line width=$(style.lw_tick)pt] (axis cs:$x,$ymin) -- " *
        "++(0pt,-$(stub)pt)$leg node[$node, inner sep=2pt, text=black] {$l};" for
        (x, l) in zip(ticks, labels)
    ]
    # the title goes below the longest label: its stub, elbow and slope, and its height
    width_cm = 0.18 * maximum(_printed_length, labels)
    drop_cm = (stub + elbow * sind(a)) / 28.45 + width_cm * sind(a) + 0.45
    opts["xlabel style"] = "yshift=-$(round(drop_cm; digits = 2))cm"
    return cmds
end

"""
A pgfplots axis with `opts` and `plots`, and the x tick labels drawn by
`_xtick_leaders!` after them.
"""
function _axis(opts, plots, style::PlotStyle)
    leaders = _xtick_leaders!(opts, style)
    return PGF.Axis(opts, plots..., leaders...)
end

"Puts `ticks` and their `labels` into the options of an axis, on its `ax` (\"x\") axis."
function _set_ticks!(opts, ax::AbstractString, ticks, labels)
    length(ticks) < 2 && return opts
    opts[ax*"tick"] = join(ticks, ",")
    opts[ax*"ticklabels"] = join(labels, ",")
    opts["scaled ticks"] = "false"
    return opts
end

"The common options of an I(q) axis (log-log) or a linear axis."
function _axis_options(style::PlotStyle; ylabel, height, log::Bool, ylim = nothing,
    xlim = nothing, legend_pos = "south west")
    opts = @pgf {
        xlabel = _TEX_X,
        ylabel = ylabel,
        width = "$(style.size_cm.width)cm",
        height = "$(height)cm",
        legend_pos = legend_pos,
        legend_style = "draw=none, fill=none, font=\\footnotesize",
        legend_cell_align = "left",
    }
    if log
        opts["xmode"] = "log"
        opts["ymode"] = "log"
        opts["log ticks with fixed point"] = nothing
        if xlim !== nothing
            opts["xmin"] = xlim[1]
            opts["xmax"] = xlim[2]
            opts["xtick"] = join(_log_ticks(xlim...), ",")
        end
    elseif xlim !== nothing
        _set_ticks!(opts, "x", _linear_ticks(xlim..., 8)...)
    end
    if ylim !== nothing
        opts["ymin"] = ylim[1]
        opts["ymax"] = ylim[2]
    end
    return _style_ticks!(opts, style; log)
end

"The x-range of a log axis: exactly the data's, with no margin either side."
_xlim(q) = (minimum(q), maximum(q))

"A `\\addlegendentry` for the plot just before it."
_legend(text) = PGF.LegendEntry(_tex_escape(text))

"The quantile/bounds curves of an axis: the band, then the two dotted curves."
function _band_plots(band, quant, style::PlotStyle; lw, band_color, band_opacity)
    plots = Any[]
    if band !== nothing
        push!(plots,
            @pgf(
                PGF.Plot({name_path = "bslo", draw = "none", forget_plot},
                    _coords(band.q, band.lo))
            ),
            @pgf(
                PGF.Plot({name_path = "bshi", draw = "none", forget_plot},
                    _coords(band.q, band.hi))
            ),
            @pgf(
                PGF.Plot(
                    {fill = _TEX_COLORS[band_color], fill_opacity = band_opacity,
                        draw = "none"}, raw"fill between [of=bslo and bshi]")
            ),
            _legend("bounds"))
    end
    if quant !== nothing
        push!(plots,
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLORS.posterior, densely_dotted,
                        line_width = "$(lw)pt", mark = "none"}, _coords(quant.q, quant.lo))
            ),
            _legend("quantiles"),
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLORS.posterior, densely_dotted,
                        line_width = "$(lw)pt", mark = "none", forget_plot},
                    _coords(quant.q, quant.hi))
            ))
    end
    return plots
end

"The `error mark options` of an error bar: the whisker, a short bar across it."
_whisker(style::PlotStyle) = "rotate=90, mark size=$(style.whiskerwidth)pt"

"""
The options of the plot that carries the error bars. The plot itself is invisible
(`draw = none, mark = none`, and not `only marks`, which leaves a pale default-sized marker
on every point that fuses into a band when there are hundreds of them); the bars are drawn
by their own style, thin and translucent.
"""
function _errorbar_options(style::PlotStyle)
    return @pgf {
        forget_plot, draw = "none", mark = "none",
        "error bars/y dir" => "both", "error bars/y explicit",
        "error bars/error mark" => "-",
        "error bars/error bar style" => string(
            "color=", _TEX_COLORS.errorbar, ", draw opacity=",
            _opacity(style.color_errorbar),
            ", line width=", style.lw_errorbar, "pt"),
        "error bars/error mark options" => _whisker(style),
    }
end

"The measured points with their error bars (log-symmetric ends)."
function _data_plots(c, style::PlotStyle)
    return Any[
        PGF.Plot(
            _errorbar_options(style),
            _coords(c.q, c.I; yerrorplus = c.err_hi .- c.I, yerrorminus = c.I .- c.err_lo)),
        @pgf(
            PGF.Plot(
                {only_marks, mark = "*", mark_size = "$(style.markersize)pt",
                    color = _TEX_COLORS.data}, _coords(c.q, c.I))
        ),
        _legend("data"),
    ]
end

"The MAP curve."
function _map_plot(c, style::PlotStyle, label)
    c.map === nothing && return Any[]
    return Any[
        @pgf(
            PGF.Plot(
                {color = _TEX_COLORS.map, line_width = "$(style.lw_map)pt",
                    mark = "none"}, _coords(c.map.q, c.map.I))
        ),
        _legend(label),
    ]
end

"The fit figure: data, quantile band and curves, MAP curve."
function _fit_axis(c, style::PlotStyle)
    plots = vcat(
        _band_plots(c.band, c.quant, style; lw = style.lw_quantile,
            band_color = :band, band_opacity = _opacity(style.color_band)),
        _data_plots(c, style),
        _map_plot(c, style, "MAP"),
    )
    return _axis(
        _axis_options(style; ylabel = raw"$I(q)$", height = style.size_cm.curve,
            log = true, ylim = c.ylim, xlim = _xlim(c.q)),
        plots, style)
end

"The residuals figure."
function _residual_axis(r, style::PlotStyle)
    plots = vcat(
        _band_plots(r.band, r.quant, style; lw = style.lw_quantile_resid,
            band_color = :band_resid, band_opacity = _opacity(style.color_band_resid)),
        Any[
            PGF.Plot(_errorbar_options(style), _coords(r.q, r.resid; yerror = r.σ)),
            @pgf(
                PGF.Plot(
                    {only_marks, mark = "*", mark_size = "$(style.markersize)pt",
                        color = _TEX_COLORS.data}, _coords(r.q, r.resid))
            ),
            _legend("data - MAP"),
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLORS.map, line_width = "$(style.lw_zero_line)pt",
                        mark = "none", forget_plot},
                    _coords([minimum(r.q), maximum(r.q)], [0.0, 0.0]))
            ),
        ],
    )
    opts = _axis_options(style; ylabel = raw"$I(q) - I_{\mathrm{MAP}}(q)$",
        height = style.size_cm.residuals, log = false, ylim = r.ylim,
        xlim = extrema(r.q), legend_pos = "north east")
    return _axis(opts, plots, style)
end

"""
`v` as TeX math to `sigfigs` significant figures: `-5.49`, and
`6.2\\times10^{-6}` for a value far from 1 (below 10⁻³ or from 10⁵).
"""
function _tex_number(v::Real; sigfigs::Integer = 4)
    v == 0 && return "0"
    e = floor(Int, log10(abs(v)))
    -3 ≤ e ≤ 4 && return string(round(v; sigdigits = sigfigs))
    return string(round(v / 10.0^e; sigdigits = sigfigs)) * "\\times10^{" * string(e) * "}"
end

"""
The middle of the tallest bin of the histogram `h`: where the draws are most often found,
the mode of the sampled values to within a bin.
"""
function _hist_mode(h)
    k = argmax(h.counts)
    return (h.edges[k] + h.edges[k+1]) / 2
end

"""
The skewness of the histogram `h` (the third standardized moment of its bin middles,
weighted by the counts): positive for a long right tail, negative for a long left one.
"""
function _hist_skew(h)
    mid = (h.edges[1:(end-1)] .+ h.edges[2:end]) ./ 2
    w = h.counts ./ sum(h.counts)
    m = sum(w .* mid)
    s2 = sum(w .* (mid .- m) .^ 2)
    return s2 > 0 ? sum(w .* (mid .- m) .^ 3) / s2^1.5 : 0.0
end

"""
One posterior histogram, a figure of its own, with
its MAP value and its mode μ marked and in a legend.
"""
function _histogram_axis(h, style::PlotStyle)
    pw, ph = style.size_cm.hist
    ymax = 1.08 * maximum(h.counts)
    # the legend (MAP and μ) goes in the top corner over the long tail, where the bars are
    # low: the right for a right tail (or none), the left for a left tail
    corner = _hist_skew(h) ≥ 0 ? "north east" : "north west"
    opts = @pgf {
        xlabel = h.tex, ylabel = "count", ymin = 0, ymax = ymax,
        width = "$(pw)cm", height = "$(ph)cm",
        legend_pos = corner,
        legend_style = "draw=black, fill=white, font=\\footnotesize, inner sep=3pt",
        legend_cell_align = "left",
    }
    _set_ticks!(opts, "x", _fitting_ticks(first(h.edges), last(h.edges), pw)...)
    _style_ticks!(opts, style)
    plots = Any[
        @pgf(
        PGF.Plot(
            {ybar_interval, fill = _TEX_COLORS.hist,
                fill_opacity = _opacity(style.color_hist), draw = _TEX_COLORS.hist,
                draw_opacity = 1, forget_plot},
            _coords(h.edges, vcat(h.counts, h.counts[end])))
    ),
    ]
    mode = _hist_mode(h)
    # digits enough to tell a bin from its neighbour: a narrow posterior (ρₑ) needs more
    # than 4 significant figures to show MAP and μ apart
    bw = h.edges[2] - h.edges[1]
    top = max(abs(mode), abs(something(h.map_value, 0.0)))
    sig = max(4, ceil(Int, log10(top / bw)) + 1)
    # the legend: the MAP value (the solid line) and μ, the most sampled part of the
    # histogram (the middle of its tallest bin; the dotted line), each with its value
    if h.map_value !== nothing
        push!(plots,
            @pgf(
                PGF.Plot(
                    {
                        color = _TEX_COLORS.map,
                        line_width = "$(style.lw_map)pt",
                        mark = "none",
                    },
                    _coords([h.map_value, h.map_value], [0, ymax]))
            ),
            PGF.LegendEntry(
                "\$\\mathrm{MAP} = " * _tex_number(h.map_value; sigfigs = sig) * "\$",
            ))
    end
    push!(plots,
        @pgf(
            PGF.Plot(
                {
                    color = _TEX_COLORS.data,
                    line_width = "$(style.lw_map)pt",
                    dotted,
                    mark = "none",
                },
                _coords([mode, mode], [0, ymax]))
        ),
        PGF.LegendEntry("\$\\mu = " * _tex_number(mode; sigfigs = sig) * "\$"))
    return _axis(opts, plots, style)
end

"The comparison figure: data, reference curve, MAP curve."
function _comparison_axis(c, style::PlotStyle)
    ref = c.ref
    plots = vcat(
        _data_plots(c, style),
        Any[
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLORS.reference, dashed,
                        line_width = "$(style.lw_reference)pt", mark = "none"},
                    _coords(ref.q, ref.I))
            ),
            _legend(ref.name),
        ],
        _map_plot(c, style, "BAYSOL MAP"),
    )
    return _axis(
        _axis_options(style; ylabel = raw"$I(q)$", height = style.size_cm.curve,
            log = true, ylim = c.ylim, xlim = _xlim(c.q)),
        plots, style)
end

"""
Write `td`, the LaTeX document of a figure, as `<stem>.tex`.

# Returns
- The path.
"""
function _write_tex(td, stem::AbstractString)
    mkpath(dirname(stem))
    PGF.save(stem * ".tex", td)
    return stem * ".tex"
end

"""
The `PGFPlotsX.save` keywords that pick the LaTeX engine: with a font, `lualatex` or else
`xelatex` (the fonts are `fontspec` fonts, which `pdflatex` cannot load); without one,
nothing, and PGFPlotsX uses the first engine it finds.

# Exceptions
- `ErrorException` if there is a font and neither engine is installed, or LuaLaTeX cannot
    find the font.
"""
function _engine_kwargs(font)
    names = _font_names(font)
    names === nothing && return (;)
    if Sys.which("lualatex") !== nothing
        if Sys.which("luaotfload-tool") !== nothing
            for n in names
                n === nothing || font_available(n) ||
                    error(
                        "the font \"$n\" is not available to LuaLaTeX (`bb fonts \"$n\"` " *
                        "checks a name, `bb fonts --list` lists them; " *
                        "font = nothing uses the LaTeX default)",
                    )
            end
        end
        return (; latex_engine = PGF.LUALATEX)
    end
    Sys.which("xelatex") !== nothing && return (; latex_engine = PGF.XELATEX)
    error(
        "a font needs lualatex or xelatex, and neither is installed " *
        "(use font = nothing for the LaTeX default font)",
    )
end

"""
Run LaTeX on `td` for each of `formats` (`:pdf`, `:png`, `:svg`), writing `<stem>.<format>`
(with `font`, as the engine of [`_engine_kwargs`](@ref) that can load it).
A failed run (no engine installed, a LaTeX error) is a warning, not an error: the other
outputs stay and the run goes on.

# Returns
- The paths written.
"""
function _compile_tex(td, stem::AbstractString, formats, font = nothing)
    mkpath(dirname(stem))
    written = String[]
    for fmt in formats
        path = string(stem, ".", fmt)
        try
            PGF.save(path, td; _engine_kwargs(font)...)
            push!(written, path)
        catch e
            @warn "LaTeX did not produce $path" exception = e
        end
    end
    return written
end

# ---------------------------------------------------------------------------
#                        The terminal preview (UnicodePlots)
# ---------------------------------------------------------------------------

"The `UnicodePlots` keywords every terminal plot shares."
_term_kw(style::PlotStyle) = (
    width = style.preview_size.width, height = style.preview_size.height,
    border = :corners, grid = false,
)

"""
The I(q) plot in the terminal: the data (orange) and the MAP curve. Both axes are log10 of
the values and are labelled that way (the terminal axes print plain numbers, where a log
axis would print exponents such as `10³⸱⁸⁷⁹¹³`). The bounds band and the reference curves
are in the `.tex`, not here.
"""
function _preview_fit(c, style::PlotStyle)
    lg = log10
    p = UnicodePlots.scatterplot(lg.(c.q), lg.(c.I); name = "data",
        color = _rgb(style.color_posterior), xlabel = "log₁₀ q   (q in Å⁻¹)",
        ylabel = "log₁₀ I(q)", title = _titled("fit", c.chi2), _term_kw(style)...)
    if c.map !== nothing
        ok = .!isnan.(c.map.I)
        UnicodePlots.lineplot!(p, lg.(c.map.q[ok]), lg.(c.map.I[ok]); name = "MAP",
            color = _rgb(style.color_map))
    end
    return p
end

"""
The residuals plot in the terminal. The y-range is that of the 2 %–98 % quantiles of the
residuals, padded, so that a few wild points (the lowest q of a curve) do not flatten the
rest; the title says how many are outside it.
"""
function _preview_residuals(r, style::PlotStyle)
    lo, hi = quantile(r.resid, (0.02, 0.98))
    pad = 0.25 * max(hi - lo, eps())
    lo, hi = lo - pad, hi + pad
    out = count(x -> !(lo ≤ x ≤ hi), r.resid)
    p = UnicodePlots.scatterplot(r.q, r.resid; name = "data - MAP",
        color = _rgb(style.color_posterior), xlabel = "q (Å⁻¹)",
        ylabel = "I(q) - I_MAP(q)",
        title = _titled(out == 0 ? "residuals" : "residuals ($out off the plot)", r.chi2),
        ylim = (lo, hi), _term_kw(style)...)
    UnicodePlots.hline!(p, 0.0; color = _rgb(style.color_map))
    return p
end

"One posterior histogram in the terminal (orange); the MAP value is in the title."
function _preview_histogram(h, style::PlotStyle)
    title =
        h.map_value === nothing ? h.label :
        string(h.label, "   (MAP ", @sprintf("%.6g", h.map_value), ")")
    return UnicodePlots.histogram(h.draws; nbins = style.hist_bins, title = title,
        xlabel = h.label, color = _rgb(style.color_hist), width = style.preview_size.width,
        border = :corners)
end

# ---------------------------------------------------------------------------
#                                 results
# ---------------------------------------------------------------------------

"""

The figures of a fit run by [`run_model`](@ref), and the numbers behind them. Three figures
are made, each from the same prepared data:

- the **fit**: the measured points with their error bars, the posterior bounds band and
    quantile curves, and the MAP curve, on log axes (`<name>`);
- the **residuals**: data minus MAP with the band and quantile curves minus MAP
    (`<name>_residuals`);
- the **histograms** of the non-divergent draws of ρₑ, δρ₁, δρ₂, δρ₃, scale, background and
    c1, each its own figure with the MAP value marked (`<name>_hist_rho_e`,
    `<name>_hist_delta_rho_1`, …, `<name>_hist_c1`);

and one **comparison** figure per entry of `references` (data, reference curve, MAP curve;
`<name>_comparison`, or `<name>_comparison_<reference name>` when there are several).

The files are laid out under `dir`: the `.tex` figures (and what is compiled from them) in
`dir/plots/`, and the numbers as one workbook `dir/<name>.xlsx`; the run's log (timings
and what is worth tracking), which [`write_log`](@ref) writes when `run_log = true`, is
the section of `name` in `dir/<folder name>.LOG`. `name` is the first part of every file
name, so several runs can share a folder. Three kinds of output come out of each figure:

- a **terminal preview** printed to `io` (`preview = true`), made with UnicodePlots, which
    needs nothing installed;
- a **pgfplots `.tex`** file (`tex = true`), a standalone document that needs no LaTeX to
    write. The default does *not* run LaTeX (it takes about a second per figure); with
    `compile = true` each document is also compiled to the `formats` (`:pdf`, `:png`,
    `:svg`; this needs a LaTeX engine, and poppler's `pdftocairo`/`pdftoppm` for
    `:png`/`:svg`). A failed run is a warning and the `.tex` stays;
- the **numbers**, always written, as one workbook. Sheet and
    column names are plain ASCII, and every value is a number (a statistic that could not be
    computed is an empty cell) except the labels in the first column and the text of
    `form_factor_log`. The sheets:
    - `run`: `section | name | value | unit | meaning`, the run's settings and statistics:
        model sizes, sampler settings, the Shannon binning, the
        sampler's diagnostics and the chains' convergence;
    - `map`: `parameter | value`, the MAP value of each parameter;
    - `quantiles_<interval>`: `parameter | quantile_lo | quantile_hi | bound_lo | bound_hi`,
        the posterior quantile pair of each parameter and the extreme draws inside it;
    - `stdev_from_prior`: `parameter | z_map | z_quantile_lo | z_quantile_hi`, how far the
        MAP value and the quantile pair of the four prior-carrying parameters lie from the
        prior mean, in prior standard deviations (θ-space);
    - `modes` and `optima`: only when the posterior has more than one mode or optimum;
    - `form_factor_log`: only when `form_factor_log` is given or the seed has one;
    - `data` (`q | I | sigma`, the fitted curve), `model` (`q | I_map | quantile_lo |
        quantile_hi | bound_lo | bound_hi`), `residuals` (`q | I | sigma | I_map |
        residual`), one `hist_<parameter>` (`bin_lo | bin_hi | count`) for each histogram,
        `draws` (every draw with its `chain`, `iteration`, `divergent` flag, the four
        sampled parameters, `scale`, `bkgrnd_corr`, `c1` and `chisq_red`) and one
        `ref_<name>` (`q | I`) for each reference curve.
    The README of `src/Pipeline/` explains every row of `run`.

The time of each figure (its data, preview, `.tex` and LaTeX run), of the summary tables
and of writing the workbook is recorded in the run's timing log as stages of the `plot`
group, so the log's timings list them; with `run_log` it calls [`write_log`](@ref) last.

# Arguments
- `result`: what `run_model` returned.
- `data`: the curve the fit saw, `(q, I, σ)`, which is `seed.shannon.q`, `.I`, `.σ`; or the
    `seed` itself.
- `dir`, `name`: the output folder (created if missing, with its `plots/`
    subfolder as it is needed) and the first part of the file names.
- `references`: [`Reference`](@ref)s, a vector or a single one.
- `style`: a [`PlotStyle`](@ref).
- `font`: the font of the LaTeX figures, `style.font` unless given: the name of any font
    LuaLaTeX can find (the text font), a `(text font, math font)` pair, or `nothing` for the
    LaTeX default (which `pdflatex` also compiles). The default is TeX Gyre PagellaX with
    TeX Gyre Pagella Math, and [`font_available`](@ref) checks a name. A font needs
    `lualatex` or `xelatex` to compile; the terminal plots and the data do not depend on it.
- `preview`, `io`: whether to print the terminal plots, and where.
- `tex`, `compile`, `formats`: as above.
- `quantile_label`: the name of the quantiles sheet's interval (`quantiles_<label>`);
    `nothing` takes the one `run_model` used (`2sigma`, `5-95`, …).
- `run_log`: also write the run's section of the folder's run log ([`write_log`](@ref)),
    `false` by default; the fitting tests set it. The log is then in the files returned.
- `ref_chi2`: the reference χ², the depositor's with its method (`"CRYSOL 1.37"`), which
    the log prints in the run's section as the `ref_chi2` row (only with `run_log`).
- `form_factor_log`, `n_atoms`: the seed's `seed.fw.form_factor_log` and `seed.fw.n_atoms`
    for the `form_factor_log` and `run` sheets; given by themselves when `data` is a
    `Seed`.

# Returns
- The paths of the files written.

# Exceptions
- `ArgumentError` if `data` has no positive intensity, its three vectors differ in length,
    or `font` is not `nothing`, a font name or a pair of names.
"""
function results(
    result, data::Tuple;
    dir::AbstractString = pwd(),
    name::AbstractString = "res",
    references::Union{Reference,AbstractVector{Reference}} = Reference[],
    style::PlotStyle = PlotStyle(),
    font = style.font,
    preview::Bool = true,
    io::IO = stdout,
    tex::Bool = true,
    compile::Bool = false,
    formats = (:pdf,),
    quantile_label::Union{Nothing,AbstractString} = nothing,
    run_log::Bool = false,
    ref_chi2::Union{Nothing,AbstractString} = nothing,
    form_factor_log = nothing,
    n_atoms = nothing,
)::Vector{String}
    q, I, σ = data
    length(q) == length(I) == length(σ) ||
        throw(ArgumentError("data: q, I and σ must have the same length"))
    refs = references isa Reference ? [references] : collect(references)
    _font_names(font)                               # a bad font is an error before any work
    style = font == style.font ? style : _with_font(style, font)
    mkpath(dir)
    tex_base = joinpath(dir, PLOT_SUBDIR, name)     # .tex and what is compiled from it
    log = result[1].timing
    written = String[]
    sheets = Any[]                                  # the tables, as the workbook's sheets

    # a figure's stage: its data, then each output as a child stage. `axis_of(d)` is the
    # figure's pgfplots axis, which the `.tex` and the LaTeX run share; `preview_of(d)` is
    # what is printed and `sheets_of(d)` returns the figure's tables (`_sheet`s)
    function figure(label, build, suffix, axis_of, preview_of, sheets_of)
        timed!(log, :plot, 1, label) do
            d = timed!(build, log, :plot, 2, "data")
            if preview && preview_of !== nothing
                timed!(log, :plot, 2, "preview") do
                    println(io, preview_of(d))
                    println(io)
                end
            end
            td = nothing
            if tex || compile
                timed!(log, :plot, 2, "tex") do
                    td = _tex_document(axis_of(d), style)
                    tex && push!(written, _write_tex(td, tex_base * suffix))
                end
            end
            if compile
                timed!(log, :plot, 2, "latex") do
                    append!(
                        written,
                        _compile_tex(td, tex_base * suffix, formats, style.font),
                    )
                end
            end
            sheets_of === nothing || append!(sheets, sheets_of(d))
        end
    end

    # the tables that are not a figure's: the run, the MAP, the quantiles, ...
    timed!(log, :plot, 1, "summary data") do
        append!(
            sheets,
            _summary_sheets(
                result;
                quantile_label,
                form_factor_log,
                n_atoms,
            ),
        )
    end
    figure(
        "fit",
        () -> _curve_data(result, data, style),
        "",
        c -> _fit_axis(c, style),
        c -> _preview_fit(c, style),
        c -> begin
            out = [_sheet("data", ["q", "I", "sigma"], q, I, σ)]
            c.map === nothing || push!(
                out,
                _sheet(
                    "model",
                    ["q", "I_map", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"],
                    c.map.q, c.map.I,
                    c.quant === nothing ? Float64[] : c.quant.lo,
                    c.quant === nothing ? Float64[] : c.quant.hi,
                    c.band === nothing ? Float64[] : c.band.lo,
                    c.band === nothing ? Float64[] : c.band.hi,
                ),
            )
            out
        end,
    )

    if (r = _residual_data(result, data, style)) !== nothing
        figure(
            "residuals",
            () -> r,
            "_residuals",
            r -> _residual_axis(r, style),
            r -> _preview_residuals(r, style),
            r -> [
                _sheet(
                    "residuals",
                    ["q", "I", "sigma", "I_map", "residual"],
                    r.q,
                    r.I,
                    r.σ,
                    r.I_map,
                    r.resid,
                ),
            ],
        )
    end

    # the bin counts of every histogram and all the draws, 
    # then one figure per histogram
    hists = timed!(log, :plot, 1, "histogram data") do
        hs = _histogram_data(result, style)
        for h in hs
            push!(
                sheets,
                _sheet(
                    "hist_" * h.file,
                    ["bin_lo", "bin_hi", "count"],
                    h.edges[1:(end-1)],
                    h.edges[2:end],
                    h.counts,
                ),
            )
        end
        push!(sheets, _draws_sheet(result[1]))
        hs
    end
    for h in hists
        figure(
            "histogram " * h.file,
            () -> h,
            "_hist_" * h.file,
            h -> _histogram_axis(h, style),
            h -> _preview_histogram(h, style),
            nothing,
        )
    end

    for ref in refs
        suffix = length(refs) == 1 ? "_comparison" : "_comparison_" * _slug(ref.name)
        figure(
            "comparison " * ref.name,
            () -> _comparison_data(result, data, ref, style),
            suffix,
            c -> _comparison_axis(c, style),
            nothing,
            c -> [
                _sheet(
                    "ref_" * _slug(ref.name),
                    ["q", "I"],
                    ref.q, ref.I,
                ),
            ],
        )
    end

    timed!(log, :plot, 1, "data files") do
        append!(written, _write_tables(dir, name, sheets, log))
    end

    any(endswith(".tex"), written) &&
        (log.info["plots"] = abspath(joinpath(dir, PLOT_SUBDIR))) # print_summary names it  

    if run_log
        logfile = write_log(result; ref_chi2)
        logfile === nothing || push!(written, logfile)
    end

    return written
end

results(result, seed::Inference.Seed; kwargs...) = results(
    result,
    (seed.shannon.q, seed.shannon.I, seed.shannon.σ);
    form_factor_log = seed.fw.form_factor_log,
    n_atoms = seed.fw.n_atoms,
    kwargs...,
)
