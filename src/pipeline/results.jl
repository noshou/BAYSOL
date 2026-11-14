# SPDX-License-Identifier: LGPL-3.0-or-later

# results: the figures of a fit. The data of every figure is prepared once, without any
# plotting library (`_curveData`, `_residualData`, `_histogramData`, `_comparisonData`),
# and three outputs are drawn from it: a terminal preview (UnicodePlots), a pgfplots `.tex`
# file per figure (PGFPlotsX; a LaTeX run turns it into a PDF/PNG/SVG, only on request) and
# the figures' tables, which tables.jl writes (a workbook).

using PGFPlotsX: PGFPlotsX, @pgf
using UnicodePlots: UnicodePlots
using Colors: Colors

const PGF = PGFPlotsX

"""
A colour: a name of Colors.jl or a code (`:crimson`, `"crimson"`,
`"#dc143c"`, `"rgb(220, 20, 60)"`; see `colourRgb`), or a
`(colour, opacity)` tuple such as `(:darkorange, 0.15)`.
"""
const ColorSpec = Union{AbstractString,Symbol,Tuple{Union{AbstractString,Symbol},Real}}

"""
    PlotStyle(; colorMap, colorPosterior, …)

The look of the figures of [`results`](@ref). Every field is a keyword argument, and
each defaults to the `PLOT_`-prefixed constant of [`Pipeline`](@ref BAYSOL.Pipeline) of the
same name (`PlotStyle().colorMap` is `PLOT_COLOUR_MAP`).

# Fields
- `colorMap`, `colorPosterior`, `colorData`, `colorErrorbar`,
    `colorBand`, `colorBandResid`, `colorHist`, `colorReference`, `colorAxis`,
    `colorTick`:
    [`ColorSpec`](@ref BAYSOL.Pipeline.ColorSpec)s.
- `lwMap`, `lwReference`, `lwQuantile`,
    `lwQuantileResid`, `lwZeroLine`, `lwErrorbar`, `lwCompare`: line widths (pt).
- `colorsCompare`, `markersCompare`: for [`compareResults`](@ref), the colours of the
    fitted curves of the models and the markers of the reference curves, each a tuple of
    `Symbol`s (a colour name or `Symbol("#rrggbb")`; a marker of `PLOT_MARKER_NAMES`),
    assigned in order and cycled when there are more curves than entries.
- `markersize`, `whiskerwidth`: the data markers' radius and the error bars' whisker (pt).
- `histBins`: bins of each posterior histogram.
- `sizeCm`: `(width, height)` of every figure (cm), the same for all of them.
- `ylimLog`, `ylimLinPadFrac`: the y-ranges of the I(q) and the residuals plots.
- `previewSize`: `(width, height)` of a terminal plot (characters, rows).
- `borderPt`: the padding the PDF page keeps round a figure (pt).
- `lwAxis`: the line width of the axis box (pt); its colour is `colorAxis`.
- `lwTick`, `lwMinorTick`, `tickLengthCm`, `minorTicks`, `tickLabelPadPt`: the
    axis ticks, in `colorTick` (line widths of the major and the minor ticks in pt, major
    length in cm, the minor ticks between two major ones of a linear axis) and the gap
    between the y axis and its tick labels (pt).
- `xtickAngle`: the angle the x tick labels are turned by (degrees; 0 leaves them level).
- `xtickLabelPadPt`: the gap between the end of an x tick and its label (pt).
- `tickStubPt`, `tickElbowPt`: each x tick leaves the axis straight for `tickStubPt`
    and then bends for `tickElbowPt` towards its slanted label (pt).
- `font`: the font of the LaTeX output: the name of any font LuaLaTeX can find (the text
    font; the math font stays Latin Modern Math), a `(text font, math font)` pair of
    `fontspec` names (the default is `PLOT_FONT`, that is `PLOT_TEXT_FONT`, TeX Gyre
    PagellaX, with `PLOT_MATH_FONT`, TeX Gyre Pagella Math), or `nothing` for the LaTeX
    default. [`fontAvailable`](@ref) says whether a name is usable. A font needs
    `lualatex` or `xelatex`.
"""
Base.@kwdef struct PlotStyle
    colorMap::ColorSpec = PLOT_COLOUR_MAP
    colorPosterior::ColorSpec = PLOT_COLOUR_POSTERIOR
    colorData::ColorSpec = PLOT_COLOUR_DATA
    colorErrorbar::ColorSpec = PLOT_COLOUR_ERRORBAR
    colorBand::ColorSpec = PLOT_COLOUR_BAND
    colorBandResid::ColorSpec = PLOT_COLOUR_BAND_RESID
    colorHist::ColorSpec = PLOT_COLOUR_HIST
    colorReference::ColorSpec = PLOT_COLOUR_REFERENCE
    colorAxis::ColorSpec = PLOT_COLOUR_AXIS
    colorTick::ColorSpec = PLOT_TICK_COLOUR
    lwMap::Float64 = PLOT_LW_MAP
    lwReference::Float64 = PLOT_LW_REFERENCE
    lwQuantile::Float64 = PLOT_LW_QUANTILE
    lwQuantileResid::Float64 = PLOT_LW_QUANTILE_RESID
    lwZeroLine::Float64 = PLOT_LW_ZERO_LINE
    lwErrorbar::Float64 = PLOT_LW_ERRORBAR
    lwCompare::Float64 = PLOT_LW_COMPARE
    colorsCompare::Tuple{Vararg{Symbol}} = PLOT_COMPARE_COLOURS
    markersCompare::Tuple{Vararg{Symbol}} = PLOT_COMPARE_MARKERS
    markersize::Float64 = PLOT_MARKERSIZE
    whiskerwidth::Float64 = PLOT_WHISKERWIDTH
    histBins::Int = PLOT_HIST_BINS
    sizeCm::Tuple{Float64,Float64} = PLOT_WIDTH_HEIGHT_CM
    ylimLog::Tuple{Float64,Float64} = PLOT_YLIM_LOG
    ylimLinPadFrac::Float64 = PLOT_YLIM_LIN_PAD_FRAC
    previewSize::NamedTuple = PLOT_PREVIEW_SIZE
    borderPt::Float64 = PLOT_BORDER_PT
    xtickAngle::Float64 = PLOT_XTICK_ANGLE
    lwAxis::Float64 = PLOT_AXIS_LW
    lwTick::Float64 = PLOT_LW_MAJOR_TICK
    lwMinorTick::Float64 = PLOT_LW_MINOR_TICK
    tickLengthCm::Float64 = PLOT_TICK_LENGTH_CM
    minorTicks::Int = PLOT_LINMIN_TICKS
    tickLabelPadPt::Float64 = PLOT_YTICK_LABEL_PAD_PT
    xtickLabelPadPt::Float64 = PLOT_XTICK_LABEL_PAD_PT
    tickStubPt::Float64 = PLOT_XTICK_STUB_PT
    tickElbowPt::Float64 = PLOT_XTICK_ELBOW_PT
    font::Union{Nothing,String,Tuple{String,String}} = PLOT_FONT
end

"""
Throws an `ArgumentError` for a [`PlotStyle`](@ref) value that cannot be drawn: a
non-positive size, bin count or preview size, or a negative width, length or padding. A
poor but drawable choice is left to the user.
"""
function _checkStyle(s::PlotStyle)
    _need(all(>(0), s.sizeCm), "style.sizeCm must be positive")
    _need(s.histBins ≥ 1, "style.histBins must be at least 1")
    _need(s.minorTicks ≥ 0, "style.minorTicks must not be negative")
    _need(0 < s.ylimLog[1] < s.ylimLog[2], "style.ylimLog must be (lo, hi), 0 < lo < hi")
    _need(s.ylimLinPadFrac ≥ 0, "style.ylimLinPadFrac must not be negative")
    _need(
        get(s.previewSize, :width, 0) > 0 && get(s.previewSize, :height, 0) > 0,
        "style.previewSize must have a positive width and height",
    )
    _need(isfinite(s.xtickAngle), "style.xtickAngle must be finite")
    _need(
        !isempty(s.colorsCompare) && all(_isColour, s.colorsCompare),
        "style.colorsCompare must be a non-empty tuple of colours",
    )
    _need(
        !isempty(s.markersCompare) && all(in(PLOT_MARKER_NAMES), s.markersCompare),
        "style.markersCompare must be a non-empty tuple of markers of PLOT_MARKER_NAMES",
    )
    widths = (
        s.lwMap, s.lwReference, s.lwQuantile, s.lwQuantileResid, s.lwZeroLine,
        s.lwErrorbar, s.lwCompare, s.markersize, s.whiskerwidth, s.borderPt,
        s.lwAxis,
        s.lwTick, s.lwMinorTick, s.tickLengthCm, s.tickLabelPadPt,
        s.xtickLabelPadPt,
        s.tickStubPt, s.tickElbowPt,
    )
    _need(
        all(w -> isfinite(w) && w ≥ 0, widths),
        "style: widths, sizes and paddings must be finite and not negative",
    )
    return nothing
end

"""
    Reference(name, q, I; qMax = Inf)

A curve to compare the fit with (the depositor's CRYSOL, FoXS, … fit), drawn with the
measured points and the MAP curve on a figure of its own. `name` labels it in the legend
and in the file name. Points with a non-finite or non-positive `q` or `I` (not drawable on
log axes) or with `q > qMax` are dropped.

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
        qMax::Real = Inf)
        length(q) == length(I) ||
            throw(ArgumentError("Reference $name: q and I differ in length"))
        keep = [
            isfinite(x) && isfinite(y) && x > 0 && y > 0 && x ≤ qMax
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
_chi2(result) = result[3] === nothing ? nothing : get(result[3][1], "chisqRed", nothing)

"""
A plot title with the reduced χ² after it:
`fit   χ² = 1.234` (nothing is added without one).
"""
_titled(title::AbstractString, chi2) =
    chi2 === nothing ? String(title) : string(title, "   χ² = ", @sprintf("%.4g", chi2))

"The non-divergent draws of `fit`, as a mask."
_okDraws(fit) = .!getproperty.(fit.stats, :numerical_error)

"""
The I(q) figure's data: the measured points with positive intensity (the log axes cannot
show the others; the fit itself used every point), their error bars' ends (`errLo`,
`errHi`; a plain additive I ± σ interval is not symmetric on a log axis, so σ is propagated
into log space by the delta method and the interval is log-symmetric and always positive),
the quantile and bounds curves floored at half the smallest intensity (a model can graze 0
at the noise floor, which a log axis cannot show), the MAP curve (non-positive values as
NaN), and the y-range centred on the data.

`band`, `quant` and `map` are `nothing` when the run has no MAP/quantiles (all draws
diverged).
"""
function _curveData(result, data, style::PlotStyle)
    _, _, mapResult, quantileResult = result
    q, I, σ = data
    pos = I .> 0
    q, I, σ = q[pos], I[pos], σ[pos]
    isempty(I) && throw(ArgumentError("no positive intensity to plot"))
    floor_ = minimum(I) / 2
    logI = log10.(I)
    # capped: a σ far above I overflows exp10 to Inf, which PGFPlotsX rejects; a bar
    # that long runs off any axis anyway
    log_σ = min.(σ ./ (I .* log(10)), 20.0)
    band = quant = mapc = nothing
    if quantileResult !== nothing
        _, curves = quantileResult
        b, qn = curves["bounds"], curves["quantiles"]
        band = (q = b[:, 1], lo = max.(b[:, 2], floor_), hi = max.(b[:, 3], floor_))
        quant = (q = qn[:, 1], lo = max.(qn[:, 2], floor_), hi = max.(qn[:, 3], floor_))
    end
    if mapResult !== nothing
        mc = mapResult[2]
        mapc = (q = mc[:, 1], I = map(v -> v > 0 ? v : NaN, mc[:, 2]))
    end
    lo, hi = extrema(I)
    return (;
        q, I, σ,
        errLo = exp10.(logI .- log_σ), errHi = exp10.(logI .+ log_σ),
        band, quant, map = mapc, chi2 = _chi2(result),
        ylim = (lo * style.ylimLog[1], hi * style.ylimLog[2]),
    )
end

"""
The residuals figure's data: data minus the MAP curve with its σ, and the bounds and
quantile curves minus the MAP curve. `nothing` when the run has no MAP curve.
"""
function _residualData(result, data, style::PlotStyle)
    _, _, mapResult, quantileResult = result
    mapResult === nothing && return nothing
    q, I, σ = data
    iMap = mapResult[2][:, 2]
    resid = I .- iMap
    band = quant = nothing
    if quantileResult !== nothing
        _, curves = quantileResult
        b, qn = curves["bounds"], curves["quantiles"]
        band = (q = b[:, 1], lo = b[:, 2] .- iMap, hi = b[:, 3] .- iMap)
        quant = (q = qn[:, 1], lo = qn[:, 2] .- iMap, hi = qn[:, 3] .- iMap)
    end
    lo, hi = extrema(resid)
    pad = style.ylimLinPadFrac * (hi - lo)
    return (; q, I, σ, iMap, resid, band, quant, chi2 = _chi2(result),
        ylim = (lo - pad, hi + pad))
end

"""
The posterior histograms' data, one entry per parameter of `PLOT_HIST_PARAMS`: the label,
the TeX label, the non-divergent draws, the MAP value (`nothing` without a MAP) and the bin
`edges` and `counts` (`style.histBins` equal-width bins over the draws' range).
"""
function _histogramData(result, style::PlotStyle)
    fit, _, mapResult, _ = result
    ok = _okDraws(fit)
    samples = fit.samples[ok]
    mapParams = mapResult === nothing ? nothing : mapResult[1]
    out = NamedTuple[]
    for (i, (label, tex, key, file)) in enumerate(PLOT_HIST_PARAMS)
        draws = if label == "c1"
            fit.c1[ok]
        elseif label == "scale"
            fit.scale[ok]
        elseif label == "bkgrndCorr"
            fit.bkgrndCorr[ok]
        else
            getindex.(samples, i)
        end
        isempty(draws) && continue
        lo, hi = extrema(draws)
        hi > lo || (hi = lo + max(abs(lo), 1.0) * 1e-9)    # a constant parameter
        edges = collect(range(lo, hi; length = style.histBins + 1))
        counts = zeros(Int, style.histBins)
        for x in draws
            counts[clamp(searchsortedlast(edges, x), 1, style.histBins)] += 1
        end
        push!(
            out,
            (;
                label, tex, file, draws, edges, counts,
                mapValue = mapParams === nothing ? nothing : mapParams[key],
            ),
        )
    end
    return out
end

"""
A comparison figure's data: the positive measured points with their log-symmetric error
bars, the MAP curve with its χ², and the `reference`'s curve with its own χ²
(`refChi2`, text, or `nothing`).
"""
function _comparisonData(
    result, data, reference::Reference, style::PlotStyle; refChi2 = nothing,
)
    c = _curveData(result, data, style)
    return (; c.q, c.I, c.σ, c.errLo, c.errHi, c.map, c.ylim, c.chi2,
        ref = reference, refChi2)
end

# ---------------------------------------------------------------------------
#                                  Small helpers
# ---------------------------------------------------------------------------

"A file-name-safe version of `s` (letters, digits, `-` and `.` kept)."
_slug(s::AbstractString) = replace(String(s), r"[^A-Za-z0-9.\-]+" => "_")

"`s` with the characters LaTeX treats specially escaped, for a legend entry or label."
function _texEscape(s::AbstractString)
    out = String(s)
    for (a, b) in ("_" => "\\_", "%" => "\\%", "&" => "\\&", "#" => "\\#", "\$" => "\\\$")
        out = replace(out, a => b)
    end
    return out
end

"`(r, g, b, opacity)`, with the channels in 0:255, of a [`ColorSpec`](@ref)."
function _rgba(spec::ColorSpec)
    col, α = spec isa Tuple ? (spec[1], Float64(spec[2])) : (spec, 1.0)
    c = colourRgb(col)
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
const _TEX_COLOURS = (
    map = "bsmap", posterior = "bsposterior", data = "bsdata", errorbar = "bserrorbar",
    band = "bsband", bandResid = "bsbandresid", hist = "bshist",
    reference = "bsreference", axis = "bsaxis", tick = "bstick",
)

"""
`style` with its `font` replaced by `font`.
"""
_withFont(style::PlotStyle, font) = PlotStyle(;
    (k => getfield(style, k) for k in fieldnames(PlotStyle) if k !== :font)..., font)

"""
The `(text font, math font)` of a [`PlotStyle`](@ref)'s `font` (the math font `nothing`
when only a text font is given), or `nothing` for the LaTeX default.

# Exceptions
- `ArgumentError` if `font` is none of `nothing`, a font name or a pair of font names.
"""
function _fontNames(font)
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
    fontAvailable(name) -> Bool

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
function fontAvailable(name::AbstractString)::Bool
    tool = Sys.which("luaotfload-tool")
    tool === nothing && error(
        "fontAvailable needs luaotfload-tool, which comes with TeX Live; " *
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
A standalone LaTeX document holding `axis`, with a border of `style.borderPt` round
it: the `fillbetween` library, the style's colours as `\\definecolor`s (the opacity of
a colour is applied where it is used, `_opacity`), and, if the style has a `font`, that
text and math font (`unicode-math`, so the document needs `lualatex` or `xelatex`).
"""
function _texDocument(axis, style::PlotStyle)
    td = PGF.TikzDocument(PGF.TikzPicture(axis))
    # the page is the figure plus a border; PGFPlotsX keeps its class options in a global
    filter!(o -> !startswith(o, "border="), PGF.CLASS_OPTIONS)
    push!(PGF.CLASS_OPTIONS, "border=$(style.borderPt)pt")
    PGF.push_preamble!(td, raw"\usepgfplotslibrary{fillbetween}")
    for (k, name) in pairs(_TEX_COLOURS)
        r, g, b, _ = _rgba(getfield(style, Symbol(:color, uppercasefirst(string(k)))))
        PGF.push_preamble!(td, "\\definecolor{$name}{RGB}{$r,$g,$b}")
    end
    if (f = _fontNames(style.font)) !== nothing
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
function _logTicks(lo::Real, hi::Real)
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
Round ticks and labels (see `_linearTicks`) for an axis `widthCm` wide: as many as fit
without the labels running into each other, up to eight. A long label (`6.0×10⁻⁶`) gets
fewer ticks than a short one (`0.34`).
"""
function _fittingTicks(lo::Real, hi::Real, widthCm::Real)
    ticks, labels = _linearTicks(lo, hi, 8)
    for n in (8, 6, 5, 4, 3)
        ticks, labels = _linearTicks(lo, hi, n)
        # a label takes about 0.18 cm a printed character (TeX markup does not print) and
        # needs a gap of about 0.3 cm
        sum(0.18 * _printedLength(l) + 0.3 for l in labels) ≤ 0.9 * widthCm && break
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
function _linearTicks(lo::Real, hi::Real, n::Integer)
    hi > lo || return Float64[], String[]
    raw = (hi - lo) / n
    mag = 10.0^floor(Int, log10(raw))
    step = mag * (raw / mag ≤ 1.5 ? 1 : raw / mag ≤ 3.5 ? 2 : raw / mag ≤ 7.5 ? 5 : 10)
    ticks = [k * step for k in ceil(Int, lo/step):floor(Int, hi/step)]
    return ticks, _tickLabels(ticks, step)
end

"""
The TeX labels of `ticks`, whose spacing is `step` (see `_linearTicks`): all with the same
number of decimals, and, when the values are far from 1 (below 10⁻³ or above 10⁵), all with
the exponent of the largest, as `0.6×10⁻⁵, 0.8×10⁻⁵, 1.0×10⁻⁵`, so that the labels of one
axis are comparable at a glance.
"""
function _tickLabels(ticks, step::Real)
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
box in `style.colorAxis` and ticks in `style.colorTick` (`style.lwTick` wide, the minor
ones `style.lwMinorTick`) on all four sides, pointing
inward, major and minor (`style.minorTicks` between two major ones of a linear
axis; a log axis keeps its own) and the y tick labels `style.tickLabelPadPt`
away from the axis. The x tick labels are drawn by `_xtickLeaders!`.
"""
function _styleTicks!(opts, style::PlotStyle; log::Bool = false)
    opts["axis line style"] = "{$(_TEX_COLOURS.axis), line width=$(style.lwAxis)pt}"
    opts["tick align"] = "inside"
    opts["xtick pos"] = "both"
    opts["ytick pos"] = "both"
    opts["tick style"] = "{$(_TEX_COLOURS.tick), line width=$(style.lwTick)pt}"
    opts["minor tick style"] = "{$(_TEX_COLOURS.tick), line width=$(style.lwMinorTick)pt}"
    opts["major tick length"] = "$(style.tickLengthCm)cm"
    opts["minor tick length"] = "$(style.tickLengthCm / 2)cm"
    if !log
        opts["minor x tick num"] = style.minorTicks
        opts["minor y tick num"] = style.minorTicks
    end
    opts["yticklabel style"] = "xshift=-$(style.tickLabelPadPt)pt"
    return opts
end

"""
How many characters a tick label prints: the TeX markup (`\\times`, `^`, `{}`, `\$`) does
not print.
"""
_printedLength(l) = count(c -> !(c in "\$\\{}^"), replace(l, "\\times" => "×"))

"""
The labels of the ticks of a log axis (`0.02`, `0.5`, `1`): rounded, so that `3 * 0.1` does
not print as `0.30000000000000004`.
"""
function _logLabels(ticks)
    return [
        "\$" * replace(string(round(t; sigdigits = 3)), r"\.0$" => "") * "\$" for
        t in ticks
    ]
end

"""
The x tick labels of an axis whose options are `opts`, drawn as TikZ so that each can hang
on a bent tick: the tick leaves the axis straight (`style.tickStubPt`), bends for
`style.tickElbowPt` in the direction of the slanted label (`style.xtickAngle`) and ends
in the label, which reads up to the right. pgfplots' own labels are switched off, and the
axis title is moved down below the longest label. With an angle of 0 the tick stays
straight and the label sits level below it.

# Returns
- The TikZ commands to put in the axis, as strings; none if the axis has no x ticks or no
    `ymin` to start them from.
"""
function _xtickLeaders!(opts, style::PlotStyle)
    (haskey(opts, "xtick") && haskey(opts, "ymin")) || return String[]
    ticks = split(string(opts["xtick"]), ',')
    labels = if haskey(opts, "xticklabels")
        split(string(opts["xticklabels"]), ',')
    else
        _logLabels(parse.(Float64, ticks))
    end
    opts["xticklabels"] = "{}"
    # the commands lie outside the axis box: clip each plot on its own, not everything
    opts["clip mode"] = "individual"
    a, ymin = style.xtickAngle, opts["ymin"]
    stub, elbow = style.tickStubPt, style.tickElbowPt
    leg = iszero(a) ? "" : " -- ++(-$(elbow * cosd(a))pt,-$(elbow * sind(a))pt)"
    node = iszero(a) ? "anchor=north" : "anchor=east, rotate=$a"
    cmds = [
        "\\draw[$(_TEX_COLOURS.tick), line width=$(style.lwTick)pt] " *
        "(axis cs:$x,$ymin) -- ++(0pt,-$(stub)pt)$leg " *
        "node[$node, inner sep=$(style.xtickLabelPadPt)pt, text=black] {$l};" for
        (x, l) in zip(ticks, labels)
    ]
    # the title goes below the longest label: its stub, elbow and slope, and its height
    widthCm = 0.18 * maximum(_printedLength, labels)
    dropCm = (stub + elbow * sind(a)) / 28.45 + widthCm * sind(a) + 0.45
    opts["xlabel style"] = "yshift=-$(round(dropCm; digits = 2))cm"
    return cmds
end

"""
A pgfplots axis with `opts` and `plots`, and the x tick labels drawn by
`_xtickLeaders!` after them.
"""
function _axis(opts, plots, style::PlotStyle)
    leaders = _xtickLeaders!(opts, style)
    return PGF.Axis(opts, plots..., leaders...)
end

"Puts `ticks` and their `labels` into the options of an axis, on its `ax` (\"x\") axis."
function _setTicks!(opts, ax::AbstractString, ticks, labels)
    length(ticks) < 2 && return opts
    opts[ax*"tick"] = join(ticks, ",")
    opts[ax*"ticklabels"] = join(labels, ",")
    opts["scaled ticks"] = "false"
    return opts
end

"The common options of an I(q) axis (log-log) or a linear axis."
function _axisOptions(style::PlotStyle; ylabel, height, log::Bool, ylim = nothing,
    xlim = nothing, legendPos = "south west")
    opts = @pgf {
        xlabel = _TEX_X,
        ylabel = ylabel,
        width = "$(style.sizeCm[1])cm",
        height = "$(height)cm",
        legend_pos = legendPos,
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
            opts["xtick"] = join(_logTicks(xlim...), ",")
        end
    elseif xlim !== nothing
        _setTicks!(opts, "x", _linearTicks(xlim..., 8)...)
    end
    if ylim !== nothing
        opts["ymin"] = ylim[1]
        opts["ymax"] = ylim[2]
    end
    return _styleTicks!(opts, style; log)
end

"The x-range of a log axis: exactly the data's, with no margin either side."
_xlim(q) = (minimum(q), maximum(q))

"A `\\addlegendentry` for the plot just before it."
_legend(text) = PGF.LegendEntry(_texEscape(text))

"The quantile/bounds curves of an axis: the band, then the two dotted curves."
function _bandPlots(band, quant, style::PlotStyle; lw, bandColor, bandOpacity)
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
                    {fill = _TEX_COLOURS[bandColor], fill_opacity = bandOpacity,
                        draw = "none"}, raw"fill between [of=bslo and bshi]")
            ),
            _legend("bounds"))
    end
    if quant !== nothing
        push!(plots,
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLOURS.posterior, densely_dotted,
                        line_width = "$(lw)pt", mark = "none"}, _coords(quant.q, quant.lo))
            ),
            _legend("quantiles"),
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLOURS.posterior, densely_dotted,
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
function _errorbarOptions(style::PlotStyle)
    return @pgf {
        forget_plot, draw = "none", mark = "none",
        "error bars/y dir" => "both", "error bars/y explicit",
        "error bars/error mark" => "-",
        "error bars/error bar style" => string(
            "color=", _TEX_COLOURS.errorbar, ", draw opacity=",
            _opacity(style.colorErrorbar),
            ", line width=", style.lwErrorbar, "pt"),
        "error bars/error mark options" => _whisker(style),
    }
end

"The measured points with their error bars (log-symmetric ends)."
function _dataPlots(c, style::PlotStyle)
    return Any[
        PGF.Plot(
            _errorbarOptions(style),
            _coords(c.q, c.I; yerrorplus = c.errHi .- c.I, yerrorminus = c.I .- c.errLo)),
        @pgf(
            PGF.Plot(
                {only_marks, mark = "*", mark_size = "$(style.markersize)pt",
                    color = _TEX_COLOURS.data}, _coords(c.q, c.I))
        ),
        _legend("data"),
    ]
end

"The MAP curve."
function _mapPlot(c, style::PlotStyle, label)
    c.map === nothing && return Any[]
    return Any[
        @pgf(
            PGF.Plot(
                {color = _TEX_COLOURS.map, line_width = "$(style.lwMap)pt",
                    mark = "none"}, _coords(c.map.q, c.map.I))
        ),
        _legend(label),
    ]
end

"The fit figure: data, quantile band and curves, MAP curve."
function _fitAxis(c, style::PlotStyle)
    plots = vcat(
        _bandPlots(c.band, c.quant, style; lw = style.lwQuantile,
            bandColor = :band, bandOpacity = _opacity(style.colorBand)),
        _dataPlots(c, style),
        _mapPlot(c, style, "MAP"),
    )
    return _axis(
        _axisOptions(style; ylabel = raw"$I(q)$", height = style.sizeCm[2],
            log = true, ylim = c.ylim, xlim = _xlim(c.q)),
        plots, style)
end

"The residuals figure."
function _residualAxis(r, style::PlotStyle)
    plots = vcat(
        _bandPlots(r.band, r.quant, style; lw = style.lwQuantileResid,
            bandColor = :bandResid, bandOpacity = _opacity(style.colorBandResid)),
        Any[
            PGF.Plot(_errorbarOptions(style), _coords(r.q, r.resid; yerror = r.σ)),
            @pgf(
                PGF.Plot(
                    {only_marks, mark = "*", mark_size = "$(style.markersize)pt",
                        color = _TEX_COLOURS.data}, _coords(r.q, r.resid))
            ),
            _legend("data - MAP"),
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLOURS.map, line_width = "$(style.lwZeroLine)pt",
                        mark = "none", forget_plot},
                    _coords([minimum(r.q), maximum(r.q)], [0.0, 0.0]))
            ),
        ],
    )
    opts = _axisOptions(style; ylabel = raw"$I(q) - I_{\mathrm{MAP}}(q)$",
        height = style.sizeCm[2], log = false, ylim = r.ylim,
        xlim = extrema(r.q), legendPos = "north east")
    return _axis(opts, plots, style)
end

"""
`v` as TeX math to `sigfigs` significant figures: `-5.49`, and
`6.2\\times10^{-6}` for a value far from 1 (below 10⁻³ or from 10⁵).
"""
function _texNumber(v::Real; sigfigs::Integer = 4)
    v == 0 && return "0"
    e = floor(Int, log10(abs(v)))
    -3 ≤ e ≤ 4 && return string(round(v; sigdigits = sigfigs))
    return string(round(v / 10.0^e; sigdigits = sigfigs)) * "\\times10^{" * string(e) * "}"
end

"""
The middle of the tallest bin of the histogram `h`: where the draws are most often found,
the mode of the sampled values to within a bin.
"""
function _histMode(h)
    k = argmax(h.counts)
    return (h.edges[k] + h.edges[k+1]) / 2
end

"""
The skewness of the histogram `h` (the third standardized moment of its bin middles,
weighted by the counts): positive for a long right tail, negative for a long left one.
"""
function _histSkew(h)
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
function _histogramAxis(h, style::PlotStyle)
    pw, ph = style.sizeCm
    ymax = 1.08 * maximum(h.counts)
    # the legend (MAP and μ) goes in the top corner over the long tail, where the bars are
    # low: the right for a right tail (or none), the left for a left tail
    corner = _histSkew(h) ≥ 0 ? "north east" : "north west"
    opts = @pgf {
        xlabel = h.tex, ylabel = "count", ymin = 0, ymax = ymax,
        width = "$(pw)cm", height = "$(ph)cm",
        legend_pos = corner,
        legend_style = "draw=black, fill=white, font=\\footnotesize, inner sep=3pt",
        legend_cell_align = "left",
    }
    _setTicks!(opts, "x", _fittingTicks(first(h.edges), last(h.edges), pw)...)
    _styleTicks!(opts, style)
    plots = Any[
        @pgf(
        PGF.Plot(
            {ybar_interval, fill = _TEX_COLOURS.hist,
                fill_opacity = _opacity(style.colorHist), draw = _TEX_COLOURS.hist,
                draw_opacity = 1, forget_plot},
            _coords(h.edges, vcat(h.counts, h.counts[end])))
    ),
    ]
    mode = _histMode(h)
    # digits enough to tell a bin from its neighbour: a narrow posterior (ρₑ) needs more
    # than 4 significant figures to show MAP and μ apart
    bw = h.edges[2] - h.edges[1]
    top = max(abs(mode), abs(something(h.mapValue, 0.0)))
    sig = max(4, ceil(Int, log10(top / bw)) + 1)
    # the legend: the MAP value (the solid line) and μ, the most sampled part of the
    # histogram (the middle of its tallest bin; the dotted line), each with its value
    if h.mapValue !== nothing
        push!(plots,
            @pgf(
                PGF.Plot(
                    {
                        color = _TEX_COLOURS.map,
                        line_width = "$(style.lwMap)pt",
                        mark = "none",
                    },
                    _coords([h.mapValue, h.mapValue], [0, ymax]))
            ),
            PGF.LegendEntry(
                "\$\\mathrm{MAP} = " * _texNumber(h.mapValue; sigfigs = sig) * "\$",
            ))
    end
    push!(plots,
        @pgf(
            PGF.Plot(
                {
                    color = _TEX_COLOURS.data,
                    line_width = "$(style.lwMap)pt",
                    dotted,
                    mark = "none",
                },
                _coords([mode, mode], [0, ymax]))
        ),
        PGF.LegendEntry("\$\\mu = " * _texNumber(mode; sigfigs = sig) * "\$"))
    return _axis(opts, plots, style)
end

"The comparison figure: data, reference curve, MAP curve."
function _comparisonAxis(c, style::PlotStyle)
    ref = c.ref
    plots = vcat(
        _dataPlots(c, style),
        Any[
            @pgf(
                PGF.Plot(
                    {color = _TEX_COLOURS.reference, dashed,
                        line_width = "$(style.lwReference)pt", mark = "none"},
                    _coords(ref.q, ref.I))
            ),
            _legend(
                c.refChi2 === nothing ? ref.name :
                string(ref.name, "  (", c.refChi2, ")"),
            ),
        ],
        _mapPlot(
            c, style,
            c.chi2 === nothing ? "BAYSOL MAP" :
            string("BAYSOL MAP  χ² = ", @sprintf("%.4g", c.chi2)),
        ),
    )
    return _axis(
        _axisOptions(style; ylabel = raw"$I(q)$", height = style.sizeCm[2],
            log = true, ylim = c.ylim, xlim = _xlim(c.q)),
        plots, style)
end

"""
Write `td`, the LaTeX document of a figure, as `<stem>.tex`.

# Returns
- The path.
"""
function _writeTex(td, stem::AbstractString)
    mkpath(dirname(stem))
    PGF.save(stem * ".tex", td)
    return stem * ".tex"
end

"""
The `PGFPlotsX` engine of each LaTeX compiler a `latexCompiler` path may name (by its file
name without the extension).
"""
const _LATEX_ENGINES = (
    lualatex = PGF.LUALATEX, xelatex = PGF.XELATEX, pdflatex = PGF.PDFLATEX,
)

"""
The `PGFPlotsX.save` keywords that pick the LaTeX engine. With a `compiler` (the path of
`lualatex`, `xelatex` or `pdflatex`) that one, and nothing else (a path that is set is
never replaced by another compiler); without one, as for a font: with a font, `lualatex`
or else `xelatex` (the fonts are `fontspec` fonts, which `pdflatex` cannot load); without
a font, nothing, and PGFPlotsX uses the first engine it finds.

# Exceptions
- `ErrorException` if `compiler` is not a file or not named for one of the three engines,
    or a font is given and the compiler is `pdflatex`; if there is a font and no compiler
    and neither `lualatex` nor `xelatex` is installed, or LuaLaTeX cannot find the font.
"""
function _engineKwargs(font, compiler::AbstractString = "")
    names = _fontNames(font)
    if !isempty(compiler)
        isfile(compiler) || error("the LaTeX compiler $compiler is not a file")
        key = Symbol(lowercase(first(splitext(basename(compiler)))))
        haskey(_LATEX_ENGINES, key) ||
            error("the LaTeX compiler must be lualatex, xelatex or pdflatex, got $compiler")
        names !== nothing && key === :pdflatex &&
            error("a font needs lualatex or xelatex, not $compiler")
        return (; latex_engine = _LATEX_ENGINES[key])
    end
    names === nothing && return (;)
    if Sys.which("lualatex") !== nothing
        if Sys.which("luaotfload-tool") !== nothing
            for n in names
                n === nothing || fontAvailable(n) ||
                    error(
                        "the font \"$n\" is not available to LuaLaTeX " *
                        "(`bysl plots fonts \"$n\"` checks a name, " *
                        "`bysl plots fonts --list` lists them; " *
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
(with `font` and `compiler`, as the engine of [`_engineKwargs`](@ref) that can load it).
A failed run (no engine installed, a LaTeX error) is a warning, not an error: the other
outputs stay and the run goes on.

# Returns
- The paths written.
"""
function _compileTex(td, stem::AbstractString, formats, font = nothing, compiler = "")
    mkpath(dirname(stem))
    written = String[]
    # the compiler's own folder first on the PATH, so PGFPlotsX runs that one
    pathEnv =
        isempty(compiler) ? ENV["PATH"] :
        string(dirname(abspath(compiler)), Sys.iswindows() ? ';' : ':', ENV["PATH"])
    for fmt in formats
        path = string(stem, ".", fmt)
        try
            withenv("PATH" => pathEnv) do
                PGF.save(path, td; _engineKwargs(font, compiler)...)
            end
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
_termKw(style::PlotStyle) = (
    width = style.previewSize.width, height = style.previewSize.height,
    border = :corners, grid = false,
)

"""
The I(q) plot in the terminal: the MAP curve alone. The data points would fill a plot of a
few dozen terminal cells with dots over the curve and make it unreadable, so the data are
in the residuals plot, the `.tex` and the workbook; a fit without a MAP curve shows the
data instead. Both axes are log10 of the values and are labelled that way (the terminal
axes print plain numbers, where a log axis would print exponents such as `10³⸱⁸⁷⁹¹³`).
The bounds band and the reference curves are in the `.tex`, not here.
"""
function _previewFit(c, style::PlotStyle)
    lg = log10
    kw = (xlabel = "log₁₀ q   (q in Å⁻¹)", ylabel = "log₁₀ I(q)",
        title = _titled("fit", c.chi2), _termKw(style)...)
    if c.map === nothing
        return UnicodePlots.scatterplot(lg.(c.q), lg.(c.I); name = "data",
            color = _rgb(style.colorPosterior), kw...)
    end
    ok = .!isnan.(c.map.I)
    return UnicodePlots.lineplot(lg.(c.map.q[ok]), lg.(c.map.I[ok]); name = "MAP",
        color = _rgb(style.colorMap), kw...)
end

"""
The residuals plot in the terminal. The y-range is that of the 2 %–98 % quantiles of the
residuals, padded, so that a few wild points (the lowest q of a curve) do not flatten the
rest; the title says how many are outside it.
"""
function _previewResiduals(r, style::PlotStyle)
    lo, hi = quantile(r.resid, (0.02, 0.98))
    pad = 0.25 * max(hi - lo, eps())
    lo, hi = lo - pad, hi + pad
    out = count(x -> !(lo ≤ x ≤ hi), r.resid)
    p = UnicodePlots.scatterplot(r.q, r.resid; name = "data - MAP",
        color = _rgb(style.colorPosterior), xlabel = "q (Å⁻¹)",
        ylabel = "I(q) - I_MAP(q)",
        title = _titled(out == 0 ? "residuals" : "residuals ($out off the plot)", r.chi2),
        ylim = (lo, hi), _termKw(style)...)
    UnicodePlots.hline!(p, 0.0; color = _rgb(style.colorMap))
    return p
end

"One posterior histogram in the terminal (orange); the MAP value is in the title."
function _previewHistogram(h, style::PlotStyle)
    title =
        h.mapValue === nothing ? h.label :
        string(h.label, "   (MAP ", @sprintf("%.6g", h.mapValue), ")")
    return UnicodePlots.histogram(h.draws; nbins = style.histBins, title = title,
        xlabel = h.label, color = _rgb(style.colorHist), width = style.previewSize.width,
        border = :corners)
end

# ---------------------------------------------------------------------------
#               the terminal plots at several sizes (`PLOT_TUI_SIZES`)
# ---------------------------------------------------------------------------

"""
`style` for a terminal plot with the plot area `w` wide and `h` rows tall, and `bins`
bins when it is a histogram (which has no height of its own: its height is its bin count).

# Returns
- A [`PlotStyle`](@ref) like `style` with the preview size and the bin count changed.

# Exceptions
- None.
"""
function _terminalStyle(style::PlotStyle, w::Integer, h::Integer, bins::Integer = h)
    fields = (k => getfield(style, k) for k in fieldnames(PlotStyle))
    return PlotStyle(;
        fields..., previewSize = (width = w, height = h),
        histBins = min(style.histBins, bins),
    )
end

"The width, in terminal cells, of the widest line of `text` (U+2800 and boxes are 1)."
_textWidth(text::AbstractString) = maximum(textwidth, split(text, '\n'); init = 0)

# The rows a terminal plot has above and below its plot area (the title, the two borders,
# the tick labels and the label of the x axis); a size's plots are at most this and its
# `height` tall.
const _TERMINAL_EXTRA_ROWS = 5

"A string with the terminal's colour codes removed (the plain text of `plots.txt`)."
_plainText(s::AbstractString) = replace(s, r"\e\[[0-9;?]*[ -/]*[@-~]" => "")

"""
The text of a terminal plot that is `width` columns wide as a whole (labels, ticks and
legend included) and has a plot area of `height` rows. `render(w, h, bins)` draws the plot
with the area `w` wide, `h` rows tall and, for a histogram, `bins` bins. The labels and the
legend add a width of their own, so the area's width is corrected until the widest line is
`width` (a title or a legend wider than that cannot be cut: then the narrowest drawing
found is the result, which a caller can read off the text). A histogram's bin count is only
a suggestion (the edges are rounded to nice numbers, so a bimodal sample gets more bins), so
it is lowered until the plot is at most `height` plus the rows round the area. The colour
codes are taken out.

# Returns
- The plain text of the plot, lines joined by a newline.

# Exceptions
- None.
"""
function _textOfSize(render, width::Integer, height::Integer)
    text = ""
    for bins in height:-1:2
        w = width
        best, bestWidth = "", typemax(Int)
        for _ in 1:4
            text = _plainText(render(max(w, 10), height, bins))
            m = _textWidth(text)
            if (m <= width && (bestWidth > width || m > bestWidth)) ||
               (bestWidth > width && m < bestWidth)
                best, bestWidth = text, m
            end
            m == width && break
            w = max(w + width - m, 10)
        end
        text = best
        count('\n', strip(text)) + 1 <= height + _TERMINAL_EXTRA_ROWS && break
    end
    return text
end

"""
Writes the texts `texts` (one `IOBuffer` per size of `sizes`) as `plots_<W>x<H>.txt` into
`dir` (made if missing), and returns the paths. A size whose text is empty (no terminal
plot was drawn) is not written.

# Returns
- The paths of the files written.

# Exceptions
- `SystemError` if a file cannot be written.
"""
function _writeTuiTexts(dir::AbstractString, sizes, texts)
    mkpath(dir)
    paths = String[]
    for ((W, H), buf) in zip(sizes, texts)
        text = String(take!(buf))
        isempty(text) && continue
        path = joinpath(dir, "plots_$(W)x$(H).txt")
        write(path, text)
        push!(paths, path)
    end
    return paths
end

# ---------------------------------------------------------------------------
#                                 results
# ---------------------------------------------------------------------------

"""

The figures of a fit run by [`runModel`](@ref), and the numbers behind them. Three figures
are made, each from the same prepared data:

- the **fit**: the measured points with their error bars, the posterior bounds band and
    quantile curves, and the MAP curve, on log axes (`<name>`);
- the **residuals**: data minus MAP with the band and quantile curves minus MAP
    (`<name>_residuals`);
- the **histograms** of the non-divergent draws of ρₑ, δρ₁, δρ₂, δρ₃, scale, background and
    c1, each its own figure with the MAP value marked (`<name>_hist_rhoE`,
    `<name>_hist_deltaRho1`, …, `<name>_hist_c1`);

and one **comparison** figure per entry of `references` (data, reference curve, MAP curve;
`<name>_comparison`, or `<name>_comparison_<reference name>` when there are several). The
models of one run, with all the references, on ONE figure are [`compareResults`](@ref).

The files are laid out under `dir`: the `.tex` figures (and what is compiled from them) in
`dir/plots/`, and the numbers as one workbook `dir/<name>.xlsx`; the run's log (timings
and what is worth tracking), which [`writeLog`](@ref) writes when `runLog = true`, is
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
    `formFactorLog`. The sheets:
    - `run`: `section | name | value | unit | meaning`, the run's settings and statistics:
        model sizes, sampler settings, the Shannon binning, the
        sampler's diagnostics and the chains' convergence;
    - `map`: `parameter | value`, the MAP value of each parameter;
    - `quantiles_<interval>`: `parameter | quantileLo | quantileHi | boundLo | boundHi`,
        the posterior quantile pair of each parameter and the extreme draws inside it;
    - `stdevFromPrior`: `parameter | zMap | zQuantileLo | zQuantileHi`, how far the
        MAP value and the quantile pair of the four prior-carrying parameters lie from the
        prior mean, in prior standard deviations (θ-space);
    - `modes` and `optima`: only when the posterior has more than one mode or optimum;
    - `formFactorLog`: only when `formFactorLog` is given or the seed has one;
    - `data` (`q | I | sigma`, the fitted curve), `model` (`q | I_map | quantileLo |
        quantileHi | boundLo | boundHi`), `residuals` (`q | I | sigma | I_map |
        residual`), one `hist_<parameter>` (`binLo | binHi | count`) for each histogram,
        `draws` (one tidy table, a row for each draw, header frozen and units in the
        header text: `chain`, `draw` within the chain, the four sampled parameters,
        `scale`, `bkgrndCorr`, `exclVolCorr`, `chi2FitGrid`, and the sampler's flags
        `logDensity`, `divergent`, `treeDepth`, `nSteps`, `stepSize` and
        `acceptanceRate`, each only if the statistics carry it) and one
        `ref_<name>` (`q | I`) for each reference curve.
    The README of `src/pipeline/` explains every row of `run`.

The time of each figure (its data, preview, `.tex` and LaTeX run), of the summary tables
and of writing the workbook is recorded in the run's timing log as stages of the `plot`
group, so the log's timings list them; with `runLog` it calls [`writeLog`](@ref) last.

# Arguments
- `result`: what `runModel` returned.
- `data`: the curve the fit saw, `(q, I, σ)`, which is `seed.shannon.q`, `.I`, `.σ`; or the
    `seed` itself.
- `dir`, `name`: the output folder (created if missing, with its `plots/`
    subfolder as it is needed) and the first part of the file names.
- `references`: [`Reference`](@ref)s, a vector or a single one.
- `style`: a [`PlotStyle`](@ref).
- `font`: the font of the LaTeX figures, `style.font` unless given: the name of any font
    LuaLaTeX can find (the text font), a `(text font, math font)` pair, or `nothing` for the
    LaTeX default (which `pdflatex` also compiles). The default is TeX Gyre PagellaX with
    TeX Gyre Pagella Math, and [`fontAvailable`](@ref) checks a name. A font needs
    `lualatex` or `xelatex` to compile; the terminal plots and the data do not depend on it.
- `preview`, `io`: whether to print the terminal plots, and where.
- `tex`, `compile`, `formats`: as above.
- `runLog`: also write the run's section of the folder's run log ([`writeLog`](@ref)),
    `false` by default; the fitting tests set it. The log is then in the files returned.
- `refChi2`: the reference χ², the depositor's with its method (`"CRYSOL 1.37"`), which
    the log prints in the run's section as the `refChi2` row (only with `runLog`), and
    the legend of each comparison figure prints beside the reference curve.
- `formFactorLog`, `nAtoms`: the seed's `seed.fw.formFactorLog` and `seed.fw.nAtoms`
    for the `formFactorLog` and `run` sheets; given by themselves when `data` is a
    `Seed`.
- `tableSigfigs::Integer = TABLE_SIGFIGS`: significant figures of every number of the
    workbook (17 writes every bit of a `Float64`; at least 1).
- `plotTuiSizes = PLOT_TUI_SIZES`, `tuiDir = nothing`: with a `tuiDir` the terminal
    plots are also drawn at each of the sizes `plotTuiSizes` (the setting
    `PLOT_TUI_SIZES`: `(width, height)` pairs, the width of the whole plot in columns and
    the height of its area in rows) and written into that folder as
    `plots_<width>x<height>.txt`, in the layout of `io` (so a viewer can pick the largest
    that fits its window); `runProject` does it in `:tui` mode. Without `tuiDir` the
    sizes are checked and nothing is written.
- `plotDir::AbstractString = FIGURES_DIR`: with a path (not `""`), the `.tex` figures are
    also copied into that folder (made if missing; a file of the same name is
    replaced). `runProject` gives each model its own
    `<plot folder>/<project>/<run>/<model>`.
- `latexCompiler::AbstractString = FIGURES_COMPILER`: the path of the compiler `compile`
    runs, `lualatex`, `xelatex` or `pdflatex`, named by its file; `""` looks for
    `lualatex`, then `xelatex`, on the `PATH`. A compiler that is set is the only one tried.

# Returns
- The paths of the files written (the copies in `plotDir` are not listed).

# Exceptions
- `ArgumentError` if the `style` holds a value that cannot be drawn (a non-positive size
    or bin count, a negative width), `formats` holds anything but `:pdf`, `:png` and `:svg`,
    or `data` has no positive intensity, its three vectors differ in length,
    or `font` is not `nothing`, a font name or a pair of names.
- [`InvalidSettingsError`](@ref) if `tableSigfigs` is not a whole number of at least 1
    (the check of `loadSettings` for `TABLE_SIGFIGS`), `plotTuiSizes` is not
    a valid `PLOT_TUI_SIZES`, or `plotDir` or `latexCompiler` is not a path (text
    without control characters).
- `SystemError` if the plot folder cannot be made or written.
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
    tex::Bool = FIGURES_TEX,
    compile::Bool = FIGURES_COMPILE,
    formats = FIGURES_FORMATS,
    runLog::Bool = false,
    refChi2::Union{Nothing,AbstractString} = nothing,
    formFactorLog = nothing,
    nAtoms = nothing,
    tableSigfigs::Integer = TABLE_SIGFIGS,
    plotTuiSizes = PLOT_TUI_SIZES,
    tuiDir::Union{Nothing,AbstractString} = nothing,
    plotDir::AbstractString = FIGURES_DIR,
    latexCompiler::AbstractString = FIGURES_COMPILER,
)::Vector{String}
    q, I, σ = data
    _checkStyle(style)
    checked = _checkedKeywords(
        :results, (; tableSigfigs, plotTuiSizes, plotDir, latexCompiler),
    )
    tableSigfigs, plotTuiSizes = checked.tableSigfigs, checked.plotTuiSizes
    plotDir, latexCompiler = checked.plotDir, checked.latexCompiler
    _need(
        all(f -> f in (:pdf, :png, :svg), formats),
        "formats may hold :pdf, :png and :svg",
    )
    length(q) == length(I) == length(σ) ||
        throw(ArgumentError("data: q, I and σ must have the same length"))
    refs = references isa Reference ? [references] : collect(references)
    _fontNames(font)                               # a bad font is an error before any work
    style = font == style.font ? style : _withFont(style, font)
    mkpath(dir)
    texBase = joinpath(dir, PLOT_SUBDIR, name)     # .tex and what is compiled from it
    log = result[1].timing
    written = String[]
    sheets = Any[]                                  # the tables, as the workbook's sheets
    # the terminal plots at the other sizes, one text for each (`tuiDir` only)
    tuiTexts = [IOBuffer() for _ in plotTuiSizes]

    # a figure's stage: its data, then each output as a child stage. `axisOf(d)` is the
    # figure's pgfplots axis, which the `.tex` and the LaTeX run share; `previewOf(d)` is
    # what is printed and `sheetsOf(d)` returns the figure's tables (`_sheet`s)
    function figure(label, build, suffix, axisOf, previewOf, sheetsOf)
        timed!(log, :plot, 1, label) do
            d = timed!(build, log, :plot, 2, "data")
            if preview && previewOf !== nothing
                timed!(log, :plot, 2, "preview") do
                    println(io, previewOf(d, style))
                    println(io)
                end
            end
            if tuiDir !== nothing && previewOf !== nothing
                timed!(log, :plot, 2, "terminal sizes") do
                    for (buf, (W, H)) in zip(tuiTexts, plotTuiSizes)
                        text = _textOfSize(W, H) do w, h, bins
                            sprint(
                                print,
                                previewOf(d, _terminalStyle(style, w, h, bins)),
                            )
                        end
                        println(buf, text)
                        println(buf)
                    end
                end
            end
            td = nothing
            if tex || compile
                timed!(log, :plot, 2, "tex") do
                    td = _texDocument(axisOf(d), style)
                    tex && push!(written, _writeTex(td, texBase * suffix))
                end
            end
            if compile
                timed!(log, :plot, 2, "latex") do
                    append!(
                        written,
                        _compileTex(
                            td, texBase * suffix, formats, style.font, latexCompiler,
                        ),
                    )
                end
            end
            sheetsOf === nothing || append!(sheets, sheetsOf(d))
        end
    end

    # the tables that are not a figure's: the run, the MAP, the quantiles, ...
    timed!(log, :plot, 1, "summary data") do
        append!(
            sheets,
            _summarySheets(
                result;
                formFactorLog,
                nAtoms,
            ),
        )
    end
    figure(
        "fit",
        () -> _curveData(result, data, style),
        "",
        c -> _fitAxis(c, style),
        (c, st) -> _previewFit(c, st),
        c -> begin
            out = [_sheet("data", ["q", "I", "sigma"], q, I, σ)]
            c.map === nothing || push!(
                out,
                _sheet(
                    "model",
                    ["q", "I_map", "quantileLo", "quantileHi", "boundLo", "boundHi"],
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

    if (r = _residualData(result, data, style)) !== nothing
        figure(
            "residuals",
            () -> r,
            "_residuals",
            r -> _residualAxis(r, style),
            (r, st) -> _previewResiduals(r, st),
            r -> [
                _sheet(
                    "residuals",
                    ["q", "I", "sigma", "I_map", "residual"],
                    r.q,
                    r.I,
                    r.σ,
                    r.iMap,
                    r.resid,
                ),
            ],
        )
    end

    # the bin counts of every histogram and all the draws, 
    # then one figure per histogram
    hists = timed!(log, :plot, 1, "histogram data") do
        hs = _histogramData(result, style)
        for h in hs
            push!(
                sheets,
                _sheet(
                    "hist_" * h.file,
                    ["binLo", "binHi", "count"],
                    h.edges[1:(end-1)],
                    h.edges[2:end],
                    h.counts,
                ),
            )
        end
        push!(sheets, _drawsSheet(result[1]))
        hs
    end
    for h in hists
        figure(
            "histogram " * h.file,
            () -> h,
            "_hist_" * h.file,
            h -> _histogramAxis(h, style),
            (h, st) -> _previewHistogram(h, st),
            nothing,
        )
    end

    for ref in refs
        suffix = length(refs) == 1 ? "_comparison" : "_comparison_" * _slug(ref.name)
        figure(
            "comparison " * ref.name,
            () -> _comparisonData(result, data, ref, style; refChi2),
            suffix,
            c -> _comparisonAxis(c, style),
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
        append!(written, _writeTables(dir, name, sheets, log; sigfigs = tableSigfigs))
        tuiDir === nothing || append!(
            written, _writeTuiTexts(tuiDir, plotTuiSizes, tuiTexts),
        )
    end

    if !isempty(plotDir)       # the `.tex` figures are also put in the plot folder
        mkpath(plotDir)
        for f in written
            endswith(f, ".tex") && cp(f, joinpath(plotDir, basename(f)); force = true)
        end
    end

    any(endswith(".tex"), written) &&
        (log.info["plots"] = abspath(joinpath(dir, PLOT_SUBDIR))) # printSummary names it

    if runLog
        logfile = writeLog(result; refChi2)
        logfile === nothing || push!(written, logfile)
    end

    return written
end

results(result, seed::Inference.Seed; kwargs...) = results(
    result,
    (seed.shannon.q, seed.shannon.I, seed.shannon.σ);
    formFactorLog = seed.fw.formFactorLog,
    nAtoms = seed.fw.nAtoms,
    kwargs...,
)
