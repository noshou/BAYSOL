# SPDX-License-Identifier: LGPL-3.0-or-later

"""
The pipeline entry points: [`seed_model`](@ref) builds a [`Inference.Seed`](@ref) from a
structure, a measured curve and a buffer, [`run_model`](@ref) samples it and summarizes the
posterior, [`results`](@ref) draws the figures and writes the workbook of numbers, and
[`write_log`](@ref) writes the run log. `BAYSOL.seed_model`, `BAYSOL.run_model`,
`BAYSOL.results` and `BAYSOL.write_log` are these functions, re-exported by the
package root.
"""
module Pipeline

using Statistics: quantile, mean, var
using Printf: @sprintf
using StaticArrays: SVector
using ..PhysicalConstants: NS_PER_S
using ..Runtime: StageLog, tick, tock!, timed!, stage_seconds, with_gc_paused, tmap_blocks
using ..MolecularStructure: MolecularStructure
using ..Hydrogenator: Hydrogenator, Propka
using ..Geometry: sasa, PROBE_RADIUS, SHELL_N_TARGET
using ..Shannon: Shannon, SHANNON_REBIN
using ..Scattering: Scattering, B_LM_CHUNK, SHELL_THICKNESS
using ..BulkElectronDensity: Solute, DEFAULT_TEMPERATURE_C
using ..Inference: Inference, κ_δρ₁₂, κ_δρ₃, DEFAULT_TARGET_ACCEPT
using Distributions: Normal, cdf

"""
Half-width, in σ, of the default posterior interval of [`run_model`](@ref): the
"quantiles"/"bounds" entries are built from the empirical quantiles that bound the central
interval a Normal distribution would have at ±`DEFAULT_SIGMA` σ (2σ: the 2.28th and 97.72nd
percentiles). The quantiles are those of the draws, so the interval is no assumption of
a Normal posterior; the σ only says which percentiles. The run sheet records them.
"""
const DEFAULT_SIGMA = 2.0

"""
The largest `sigma` [`run_model`](@ref) accepts. Beyond 3σ (the 0.13th percentile) the
quantiles of a run's few thousand draws rest on a handful of draws.
"""
const MAX_SIGMA = 3.0

"""
Default warm-up of [`run_model`](@ref): NUTS iterations of step-size and mass-matrix
adaptation, discarded from the posterior.
"""
const DEFAULT_N_ADAPT = 300

"""
Default number of posterior draws of [`run_model`](@ref), after the `DEFAULT_N_ADAPT`
warm-up iterations.
"""
const DEFAULT_N_DRAWS = 700

"""
Default total number of NUTS iterations of [`run_model`](@ref), warm-up included:
`DEFAULT_N_ADAPT + DEFAULT_N_DRAWS`.
"""
const DEFAULT_N_SAMPLES = DEFAULT_N_ADAPT + DEFAULT_N_DRAWS

# ---------------------------------------------------------------------------
#                       Plot defaults (used by Results.jl)
# ---------------------------------------------------------------------------
#
# Every value below is the default of the field of [`PlotStyle`](@ref) of the same name
# (without the `PLOT_`). A colour is anything `Colors.parse` reads (a CSS/X11 name, a
# `"#rrggbb"` string), or a `(colour, opacity)` tuple.

"Colour of the MAP curve and of the MAP marker of the histograms."
const PLOT_COLOR_MAP = :crimson

"Colour of the posterior quantile curves."
const PLOT_COLOR_POSTERIOR = :darkorange

"Colour of the measured points."
const PLOT_COLOR_DATA = :gray20

"Colour of the measured points' error bars."
const PLOT_COLOR_ERRORBAR = (:gray40, 0.6)

"Colour of the posterior bounds band of the I(q) plot."
const PLOT_COLOR_BAND = (:darkorange, 0.15)

"Colour of the posterior bounds band of the residuals plot."
const PLOT_COLOR_BAND_RESID = (:darkorange, 0.35)

"Colour of the histogram bars."
const PLOT_COLOR_HIST = (:darkorange, 0.6)

"Colour of the reference curve (CRYSOL, FoXS, … ) on a comparison plot."
const PLOT_COLOR_REFERENCE = :mediumturquoise

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
Width of the figures (cm), height of the I(q) plots, height of the residuals plot, and
the width and height of one histogram figure.
"""
const PLOT_SIZE_CM = (width = 12.0, curve = 8.5, residuals = 6.8, hist = (10.0, 6.5))

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
The default `font` of [`PlotStyle`](@ref): a `(text font, math font)` pair of `fontspec`
names, TeX Gyre PagellaX with the TeX Gyre Pagella Math font (the TeX Live packages `newpx`
and `tex-gyre-math`). `font` takes any other font that LuaLaTeX can find, and
[`font_available`](@ref) says whether it can find one; `bb fonts` does the same from the
shell.
"""
const PLOT_FONT = ("TeX Gyre PagellaX", "TeX Gyre Pagella Math")

"""
The subfolders of the output folder of [`results`](@ref): the `.tex` figures, and what
is compiled from them, go into `PLOT_SUBDIR`. The workbook stays in the output folder
itself.
"""
const PLOT_SUBDIR = "plots"

"""
Significant figures of every number in the tables of [`results`](@ref): a workbook
cell is rounded to this many. The default, 17, is every
bit of a `Float64` (the number reads back exactly); lower it for shorter files or to drop
the noise in the last digits (15 is the most a `Float64` is guaranteed to carry).
"""
const TABLE_SIGFIGS = 17

"""
The angle (degrees, counter-clockwise) the x tick labels of every figure are turned by,
so that long labels (`0.3405`, `6×10⁻⁶`) do not run into each other: they end at their tick
and slope up to the left. `0` leaves them horizontal.
"""
const PLOT_XTICK_ANGLE = 45.0

"""
The line width (pt) of the axis ticks, major and minor, which are black so that they show
against the plot.
"""
const PLOT_LW_TICK = 0.8

"""
The line width (pt) of the axis lines (the box round each figure), black.
"""
const PLOT_LW_AXIS = 1.2

"""
The length (cm) of a major tick; a minor tick is half as long. The ticks point inward and
are drawn on all four sides of the axis.
"""
const PLOT_TICK_LENGTH_CM = 0.22

"""
The number of minor ticks between two major ones of a linear axis (a log axis has its own).
"""
const PLOT_MINOR_TICKS = 4

"""
The gap (pt) between the y axis and its tick labels.
"""
const PLOT_TICK_LABEL_PAD_PT = 4.0

"""
The length (pt) of the straight stub that carries an x tick out of the axis, and of the
elbow (pt) that then bends towards the slanted label; see `PLOT_XTICK_ANGLE`.
"""
const PLOT_TICK_STUB_PT = 4.0
const PLOT_TICK_ELBOW_PT = 6.0

# The release name is the `release_name` key of Project.toml, next to `version` (which must
# stay plain semver: `0.3.0-name` would be a pre-release, and a name may have non-ASCII
# letters). It is read when the package is precompiled; a change of Project.toml
# precompiles it again.
const _PROJECT_TOML = normpath(joinpath(@__DIR__, "..", "..", "Project.toml"))
include_dependency(_PROJECT_TOML)

"""
The name of the release the version in `Project.toml` belongs to (the message of its git
tag, `wʋsg_n_yɩɩda` for v0.3.0): the `release_name` key of `Project.toml`, `""` if it has
none. Change it together with `version`: the run log prints both, as `v0.3.0-wʋsg_n_yɩɩda`.
"""
const RELEASE_NAME = String(get(Base.parsed_toml(_PROJECT_TOML), "release_name", ""))

"""
The padding (pt) the PDF page keeps round a figure. Without it the page is cropped to the
figure's bounding box and the edge of a label or a tick at the right or the top is cut off.
"""
const PLOT_BORDER_PT = 8.0

"""
(label, TeX label, key, file name) of each posterior histogram, each its own figure
(`<name>_hist_<file name>.tex`). The first four are the sampled
`ξ = (ρₑ, δρ₁, δρ₂, δρ₃)` in sample order (the histogram code indexes the draws by
position); scale, background and c1 are per-draw profiled quantities. The key names the
MAP value in the `MAPParams`.
"""
const PLOT_HIST_PARAMS = [
    ("ρₑ", raw"$\rho_e$", "slvnt_e_dns", "rho_e"),
    ("δρ₁", raw"$\delta\rho_1$", "delta_rho_1", "delta_rho_1"),
    ("δρ₂", raw"$\delta\rho_2$", "delta_rho_2", "delta_rho_2"),
    ("δρ₃", raw"$\delta\rho_3$", "delta_rho_3", "delta_rho_3"),
    ("scale", "scale", "scale", "scale"),
    ("bkgrnd_corr", raw"bkgrnd\_corr", "bkgrnd_corr", "bkgrnd_corr"),
    ("c1", raw"$c_1$", "excl_vol_corr", "c1"),
]

"""
    MAPParams = Dict{String, Float64}

Parameter values at the single MAP (maximum a posteriori, i.e.
highest-log-density non-divergent) draw found by [`run_model`](@ref), keyed
by name:

-   `log_density`: the MAP draw's log-posterior density.
-   `slvnt_e_dns`, `delta_rho_1`, `delta_rho_2`, `delta_rho_3`: the shell
    parameters at that draw (see [`Inference.Seed`](@ref) for the ξ ordering this
    is read off of).
-   `cavity_shell_frac`: fraction of the hydration-shell volume carried by
    cavity beads (from the Gram matrix at the lowest q). When it is ~0, δρ₃ has
    essentially no likelihood and its posterior is just its prior.
-   `scale`, `bkgrndcorr`: the WLS-fit detector scale/background at that draw.
-   `chisqred`: the WLS fit's reduced χ² at that draw.
-   `z_slvnt_e_dns`, `z_delta_rho_1`, `z_delta_rho_2`,
    `z_delta_rho_3`: how many prior standard deviations (θ-space) the
    corresponding physical parameter's MAP value sits from its prior mean.
"""
const MAPParams = Dict{String,Float64}

"""
    MAPResult = Tuple{MAPParams, Matrix{Float64}}

(params, curve) at the MAP draw.
"""
const MAPResult = Tuple{MAPParams,Matrix{Float64}}

"""
    QuantileBounds = Dict{String, Tuple{Float64, Float64}}

One parameter's quantiles/bounds/z triple (all (lo, hi) tuples):
quantiles is the raw empirical (q1, q2) quantile pair; bounds is the
extrema of exactly the draws that fall within [lo, hi], so it can differ
slightly from quantiles itself (it's the tightest interval that actually
contains data on both ends).
"""
const QuantileBounds = Dict{String,Tuple{Float64,Float64}}

"""
    QuantileParams = Dict{String, QuantileBounds}

One [`QuantileBounds`](@ref) per parameter, over the same names as
[`MAPParams`](@ref) (plus "logdensity", minus none).
"""
const QuantileParams = Dict{String,QuantileBounds}

"""
    QuantileCurves = Dict{String, Matrix{Float64}}

"quantiles"/"bounds" predicted-curve envelopes, each a (Q, 3) matrix
whose columns are (q, Ilo(q), Ihi(q)).
"""
const QuantileCurves = Dict{String,Matrix{Float64}}

"""
    QuantileResult = Tuple{QuantileParams, QuantileCurves}

(params, curve), the quantile-filtered counterpart of [`MAPResult`](@ref).
"""
const QuantileResult = Tuple{QuantileParams,QuantileCurves}

# Summary constants (used by Summary.jl).

"""
Order the physical/derived parameters are listed
in the workbook's `map` and `quantiles` sheets.
"""
const _REPORT_KEYS = [
    "log_density", "slvnt_e_dns", "delta_rho_1", "delta_rho_2",
    "delta_rho_3", "scale", "bkgrnd_corr", "excl_vol_corr", "chisq_red",
]

"The 4 physical parameters that carry a prior."
const _PRIOR_KEYS = [
    "slvnt_e_dns", "delta_rho_1", "delta_rho_2", "delta_rho_3",
]

"The names of the parameters in the workbook's sheets (plain ASCII)."
const _REPORT_LABELS = Dict{String,String}(
    "log_density"   => "log_density",
    "slvnt_e_dns"   => "rho_e",
    "delta_rho_1"   => "delta_rho_1",
    "delta_rho_2"   => "delta_rho_2",
    "delta_rho_3"   => "delta_rho_3",
    "scale"         => "scale",
    "bkgrnd_corr"   => "bkgrnd_corr",
    "excl_vol_corr" => "excl_vol_corr",
    "chisq_red"     => "chi2",
)

include("SeedModel.jl")
include("RunModel.jl")
include("Tables.jl")
include("Log.jl")
include("Results.jl")
include("Summary.jl")

export seed_model, run_model, print_summary, write_log
results, PlotStyle, Reference, font_available
public MAPParams, MAPResult, QuantileBounds, QuantileParams, QuantileCurves, QuantileResult

end # module
