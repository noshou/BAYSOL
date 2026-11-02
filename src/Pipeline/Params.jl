# SPDX-License-Identifier: LGPL-3.0-or-later

# The tunable constants of `Pipeline`: the posterior interval and the default run length of
# `run_model`, and the look of the figures of `results` (one size for all of them).
# Included by `Pipeline.jl`, so they live in the module.

"""
Half-width, in σ, of the default posterior interval of [`run_model`](@ref): the
"quantiles"/"bounds" entries are built from the empirical quantiles that bound the central
interval a Normal distribution would have at ±`VAL_SIGMA` σ (2σ: the 2.28th and 97.72nd
percentiles). The quantiles are those of the draws, so the interval is no assumption of
a Normal posterior; the σ only says which percentiles. The run sheet records them.
"""
const VAL_SIGMA = 2.0

"""
Default warm-up of [`run_model`](@ref): NUTS iterations of step-size and mass-matrix
adaptation, discarded from the posterior.
"""
const N_ADAPT = 300

"""
Default number of posterior draws of [`run_model`](@ref), after the `N_ADAPT`
warm-up iterations.
"""
const N_DRAWS = 700

"""
Significant figures of every number in the tables of [`results`](@ref): a workbook
cell is rounded to this many. The default, 17, is every
bit of a `Float64` (the number reads back exactly); lower it for shorter files or to drop
the noise in the last digits (15 is the most a `Float64` is guaranteed to carry).
"""
const TABLE_SIGFIGS = 17

"""
Default `tex` of [`results`](@ref): write each figure as a standalone pgfplots `.tex`
file in the output folder's `plots/` (LaTeX is not needed for this).
"""
const FIGURES_TEX = true

"""
Default `compile` of [`results`](@ref): run a LaTeX engine on the `.tex` figures (about a
second per figure; needs `lualatex`, `xelatex` or `pdflatex`, and poppler for PNG/SVG).
Off by default, and a failed run is a warning.
"""
const FIGURES_COMPILE = false

"""
Default `formats` of [`results`](@ref) when `compile` is on: the file types made from
each `.tex`, any of `:pdf`, `:png`, `:svg`.
"""
const FIGURES_FORMATS = (:pdf,)

# ---------------------------------------------------------------------------
#                       Plot defaults (used by Results.jl)
# ---------------------------------------------------------------------------
#
# Every value below is the default of the field of [`PlotStyle`](@ref) of the same name
# (without the `PLOT_`). A colour is anything `Colors.parse` reads (a CSS/X11 name, a
# `"#rrggbb"` string), or a `(colour, opacity)` tuple.

"Colour of the MAP curve and of the MAP marker of the histograms."
const PLOT_COLOUR_MAP = :crimson

"Colour of the posterior quantile curves."
const PLOT_COLOUR_POSTERIOR = :darkorange

"Colour of the measured points."
const PLOT_COLOUR_DATA = :gray20

"Colour of the measured points' error bars."
const PLOT_COLOUR_ERRORBAR = (:gray40, 0.6)

"Colour of the posterior bounds band of the I(q) plot."
const PLOT_COLOUR_BAND = (:darkorange, 0.15)

"Colour of the posterior bounds band of the residuals plot."
const PLOT_COLOUR_BAND_RESID = (:darkorange, 0.35)

"Colour of the histogram bars."
const PLOT_COLOUR_HIST = (:darkorange, 0.6)

"Colour of the reference curve (CRYSOL, FoXS, … ) on a comparison plot."
const PLOT_COLOUR_REFERENCE = :mediumturquoise

"Line width (pt) of the MAP curve and of the histograms' MAP marker."
const PLOT_LW_MAP = 1.2

"Line width (pt) of the reference curve."
const PLOT_LW_REFERENCE = 1.2

"Line width (pt) of the quantile curves of the I(q) plot."
const PLOT_LW_QUANTILE = 0.9

"Line width (pt) of the quantile curves of the residuals plot."
const PLOT_LW_QUANTILE_RESID = 1.4

"Line width (pt) of the zero line of the residuals plot."
const PLOT_LW_ZERO_LINE = 0.8

"Radius (pt) of the data markers."
const PLOT_MARKERSIZE = 0.55

"Line width (pt) of the error bars."
const PLOT_LW_ERRORBAR = 0.3

"Length (pt) of an error bar's whisker."
const PLOT_WHISKERWIDTH = 1.5

"Bins of each posterior histogram."
const PLOT_HIST_BINS = 40

"""
`(width, height)` in cm of every figure: the I(q) plots, the residuals plot, the comparison
plot and each posterior histogram all have exactly this size. 16 cm is the text width of
an A4 page with 25 mm margins and of a US Letter page with 1 in margins (16.5 cm), so a
figure fits either at full width; the height is 3:2.
"""
const PLOT_WIDTH_HEIGHT_CM = (16.0, 11.0)

"""
The I(q) plots' y-range is the data's range scaled by these factors (the plot is
centred on the data, not on however far the error bars or the band extend).
"""
const PLOT_YLIM_LOG = (0.7, 1.3)

"The residuals plot's y-padding, as a fraction of the residuals' range."
const PLOT_YLIM_LIN_PAD_FRAC = 0.3

"Width (characters) and height (rows) of a terminal plot."
const PLOT_PREVIEW_SIZE = (width = 70, height = 18)

"""
The text font of the figures: a `fontspec` name, TeX Gyre PagellaX (the TeX Live package
`newpx`). Any font that LuaLaTeX can find does; [`font_available`](@ref) says whether it
can find one, and `bb fonts` does the same from the shell.
"""
const PLOT_TEXT_FONT = "TeX Gyre PagellaX"

"""
The math font of the figures: a `fontspec` name, TeX Gyre Pagella Math (the TeX Live
package `tex-gyre-math`), the companion of [`PLOT_TEXT_FONT`](@ref).
"""
const PLOT_MATH_FONT = "TeX Gyre Pagella Math"

"""
The default `font` of [`PlotStyle`](@ref): the `(text font, math font)` pair
`(PLOT_TEXT_FONT, PLOT_MATH_FONT)`.
"""
const PLOT_FONT = (PLOT_TEXT_FONT, PLOT_MATH_FONT)

"""
The angle (degrees, counter-clockwise) the x tick labels of every figure are turned by,
so that long labels (`0.3405`, `6×10⁻⁶`) do not run into each other: they end at their tick
and slope up to the left. `0` leaves them horizontal.
"""
const PLOT_XTICK_ANGLE = 45.0

"The line width (pt) of the major axis ticks."
const PLOT_LW_MAJOR_TICK = 0.8

"The line width (pt) of the minor axis ticks."
const PLOT_LW_MINOR_TICK = 0.8

"""
The colour of the axis ticks, major and minor, and of the stubs that carry the x tick
labels; a [`ColorSpec`](@ref BAYSOL.Pipeline.ColorSpec) like the other colours.
"""
const PLOT_TICK_COLOUR = :black

"The line width (pt) of the axis lines (the box round each figure)."
const PLOT_AXIS_LW = 1.2

"The colour of the axis lines (the box round each figure)."
const PLOT_COLOUR_AXIS = :black

"""
The length (cm) of a major tick; a minor tick is half as long. The ticks point inward and
are drawn on all four sides of the axis.
"""
const PLOT_TICK_LENGTH_CM = 0.22

"""
The number of minor ticks between two major ones of a linear axis (a log axis has its own).
"""
const PLOT_LINMIN_TICKS = 4

"The gap (pt) between the y axis and its tick labels."
const PLOT_YTICK_LABEL_PAD_PT = 4.0

"""
The gap (pt) between the end of an x tick (its bent leader) and its label; the label's
`inner sep`.
"""
const PLOT_XTICK_LABEL_PAD_PT = 2.0

"""
The length (pt) of the straight stub that carries an x tick out of the axis, and of the
elbow (pt) that then bends towards the slanted label; see `PLOT_XTICK_ANGLE`.
"""
const PLOT_XTICK_STUB_PT = 4.0

const PLOT_XTICK_ELBOW_PT = 6.0

"""
The padding (pt) the PDF page keeps round a figure. Without it the page is cropped to the
figure's bounding box and the edge of a label or a tick at the right or the top is cut off.
"""
const PLOT_BORDER_PT = 8.0

# Sanity limits: positive, inside their range, and never a zero where the code divides.
@assert(isfinite(VAL_SIGMA) && VAL_SIGMA > 0, "VAL_SIGMA must be a finite number above 0")
@assert(N_ADAPT ≥ 1 && N_DRAWS ≥ 1, "N_ADAPT and N_DRAWS must be at least 1")
@assert(1 ≤ TABLE_SIGFIGS ≤ 17, "TABLE_SIGFIGS must be between 1 and 17")
@assert(
    all(f -> f in (:pdf, :png, :svg), FIGURES_FORMATS),
    "FIGURES_FORMATS may hold :pdf, :png and :svg"
)
@assert(
    all(>(0), PLOT_WIDTH_HEIGHT_CM) && PLOT_HIST_BINS ≥ 1 && PLOT_LINMIN_TICKS ≥ 1 &&
    PLOT_PREVIEW_SIZE.width > 0 && PLOT_PREVIEW_SIZE.height > 0,
    "the figure size, preview size, histogram bins and tick count must be positive"
)

"""
The limits of each setting above that has one, read by the terminal interface when a
user edits a value (`dev/harvest_defaults.jl` copies them to `default_settings.edn`). Each
limit is `above` or `below` (strict) or `at_least` or `at_most` (inclusive). They follow
`results`' check of a `PlotStyle`: widths, sizes and paddings are not negative. The
settings that are tuples are left out.
"""
const SETTING_LIMITS = (
    N_ADAPT = (at_least = 1,),
    N_DRAWS = (at_least = 1,),
    TABLE_SIGFIGS = (at_least = 1, at_most = 17),
    VAL_SIGMA = (above = 0,),
    PLOT_HIST_BINS = (at_least = 1,),
    PLOT_LINMIN_TICKS = (at_least = 0,),
    PLOT_YLIM_LIN_PAD_FRAC = (at_least = 0,),
    PLOT_LW_MAP = (at_least = 0,),
    PLOT_LW_REFERENCE = (at_least = 0,),
    PLOT_LW_QUANTILE = (at_least = 0,),
    PLOT_LW_QUANTILE_RESID = (at_least = 0,),
    PLOT_LW_ZERO_LINE = (at_least = 0,),
    PLOT_MARKERSIZE = (at_least = 0,),
    PLOT_LW_ERRORBAR = (at_least = 0,),
    PLOT_WHISKERWIDTH = (at_least = 0,),
    PLOT_AXIS_LW = (at_least = 0,),
    PLOT_BORDER_PT = (at_least = 0,),
    PLOT_TICK_LENGTH_CM = (at_least = 0,),
    PLOT_LW_MAJOR_TICK = (at_least = 0,),
    PLOT_LW_MINOR_TICK = (at_least = 0,),
    PLOT_XTICK_STUB_PT = (at_least = 0,),
    PLOT_XTICK_ELBOW_PT = (at_least = 0,),
    PLOT_XTICK_LABEL_PAD_PT = (at_least = 0,),
    PLOT_YTICK_LABEL_PAD_PT = (at_least = 0,),
)

"""
The settings above that hold some of a few fixed choices (any subset, in this order),
read by the terminal interface, which shows them as tabs to switch on and off
(`dev/harvest_defaults.jl` copies them to `default_settings.edn`).
"""
const SETTING_CHOICES = (FIGURES_FORMATS = (:pdf, :png, :svg),)

"""
The rules that tie settings above together, or that a tuple setting must obey, which a set
of values must obey as a whole; each is a `(rule, setting, ...)` and is read by the
terminal interface and by [`load_settings`](@ref BAYSOL.Pipeline.load_settings).
`:all_above`: every number of `setting` is above `bound`; `:ordered`: the pair `setting`
has its first number below its second, and above `above` if there is one; `:opacity`:
`setting` is a `(colour, opacity)` pair whose opacity is in 0 to 1.
"""
const SETTING_RELATIONS = (
    (rule = :all_above, setting = :PLOT_WIDTH_HEIGHT_CM, bound = 0),
    (rule = :all_above, setting = :PLOT_PREVIEW_SIZE, bound = 0),
    (rule = :ordered, setting = :PLOT_YLIM_LOG, above = 0),
    (rule = :opacity, setting = :PLOT_COLOUR_ERRORBAR),
    (rule = :opacity, setting = :PLOT_COLOUR_BAND),
    (rule = :opacity, setting = :PLOT_COLOUR_BAND_RESID),
    (rule = :opacity, setting = :PLOT_COLOUR_HIST),
)

"""
The constants above that are settings, the ones a user may change: the terminal interface
shows each on a page of its own, and [`load_settings`](@ref BAYSOL.Pipeline.load_settings)
accepts a saved value for these and for no other name.
"""
const SETTING_NAMES = (
    :N_ADAPT, :N_DRAWS, :TABLE_SIGFIGS, :VAL_SIGMA, :FIGURES_TEX, :FIGURES_COMPILE,
    :FIGURES_FORMATS, :PLOT_COLOUR_MAP, :PLOT_COLOUR_POSTERIOR, :PLOT_COLOUR_DATA,
    :PLOT_COLOUR_ERRORBAR, :PLOT_COLOUR_REFERENCE, :PLOT_COLOUR_BAND,
    :PLOT_COLOUR_BAND_RESID, :PLOT_COLOUR_HIST, :PLOT_COLOUR_AXIS, :PLOT_LW_MAP,
    :PLOT_LW_REFERENCE, :PLOT_LW_QUANTILE, :PLOT_LW_QUANTILE_RESID,
    :PLOT_LW_ZERO_LINE, :PLOT_MARKERSIZE, :PLOT_LW_ERRORBAR, :PLOT_WHISKERWIDTH,
    :PLOT_AXIS_LW, :PLOT_WIDTH_HEIGHT_CM, :PLOT_PREVIEW_SIZE, :PLOT_TEXT_FONT,
    :PLOT_MATH_FONT, :PLOT_HIST_BINS, :PLOT_YLIM_LOG, :PLOT_YLIM_LIN_PAD_FRAC,
    :PLOT_BORDER_PT, :PLOT_TICK_LENGTH_CM, :PLOT_LINMIN_TICKS, :PLOT_LW_MAJOR_TICK,
    :PLOT_LW_MINOR_TICK, :PLOT_TICK_COLOUR, :PLOT_XTICK_ANGLE, :PLOT_XTICK_STUB_PT,
    :PLOT_XTICK_ELBOW_PT, :PLOT_XTICK_LABEL_PAD_PT, :PLOT_YTICK_LABEL_PAD_PT,
)

"""
The name of each part of the tuple settings above, in order, which the terminal interface
shows beside the part when a user edits it. A setting that is a tuple has exactly one name
for each of its parts (a named tuple's parts are named by its keys, in their order).
"""
const SETTING_PARTS = (
    PLOT_WIDTH_HEIGHT_CM = ("width", "height"),
    PLOT_PREVIEW_SIZE = ("width", "height"),
    PLOT_YLIM_LOG = ("lower", "upper"),
    PLOT_COLOUR_ERRORBAR = ("colour", "opacity"),
    PLOT_COLOUR_BAND = ("colour", "opacity"),
    PLOT_COLOUR_BAND_RESID = ("colour", "opacity"),
    PLOT_COLOUR_HIST = ("colour", "opacity"),
)
