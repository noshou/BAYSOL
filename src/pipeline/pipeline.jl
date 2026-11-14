# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Main entrypoint for BAYSOL.
"""
module Pipeline

using Statistics: quantile, mean, var
using Printf: @sprintf
using StaticArrays: SVector
using ..PhysicalConstants: NS_PER_S, UNIT_OF_δρ
using ..Runtime: StageLog, tick, tock!, timed!, stageSeconds, withGcPaused, tmapBlocks
using ..MolecularStructure: MolecularStructure
using ..Hydrogenator: Hydrogenator, Propka
using ..Geometry: Geometry, sasa, PROBE_RADIUS
using ..Shannon: Shannon, SHANNON_REBIN
using ..Scattering: Scattering, B_LM_CHUNK, SHELL_THICKNESS
using ..BulkElectronDensity: Solute, DEFAULT_TEMPERATURE_C
using ..Inference: Inference, κ_δρ₁₂, κ_δρ₃, PMV_FALLBACK_UNCERT, TARGET_ACCEPT
using Distributions: Normal, cdf

include("params.jl")

"""
The subfolder of the output folder of [`results`](@ref) that the `.tex` figures, and what
is compiled from them, go into. The workbook and the run log stay in the output folder
itself. Not a setting: `bysl plots render` and the TUI look for the figures here.
"""
const PLOT_SUBDIR = "plots"

"""
The smallest and the largest size, `(width, height)`, a pair of
[`PLOT_TUI_SIZES`](@ref) may have: below the smallest a text plot has no room for its
axes, above the largest it is a wall of text. A guardrail of the setting, not a setting.
"""
const PLOT_TUI_SIZE_LIMITS = (min = (24, 3), max = (400, 100))

"""
Throws an `ArgumentError` with `message` unless `condition` holds: the check behind the
positive and range limits of the entry points' inputs.
"""
_need(condition::Bool, message::AbstractString) = condition || throw(ArgumentError(message))

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
(label, TeX label, key, file name) of each posterior histogram, each its own figure
(`<name>_hist_<file name>.tex`). The first four are the sampled
`ξ = (ρₑ, δρ₁, δρ₂, δρ₃)` in sample order (the histogram code indexes the draws by
position); scale, background and c1 are per-draw profiled quantities. The key names the
MAP value in the `MAPParams`.
"""
const PLOT_HIST_PARAMS = [
    ("ρₑ", raw"$\rhoE$", "slvntEDns", "rhoE"),
    ("δρ₁", raw"$\delta\rho_1$", "deltaRho1", "deltaRho1"),
    ("δρ₂", raw"$\delta\rho_2$", "deltaRho2", "deltaRho2"),
    ("δρ₃", raw"$\delta\rho_3$", "deltaRho3", "deltaRho3"),
    ("scale", "scale", "scale", "scale"),
    ("bkgrndCorr", raw"bkgrnd\_corr", "bkgrndCorr", "bkgrndCorr"),
    ("c1", raw"$c1Factor$", "exclVolCorr", "c1"),
]

"""
    MAPParams = Dict{String, Float64}

Parameter values at the single MAP (maximum a posteriori, i.e.
highest-log-density non-divergent) draw found by [`runModel`](@ref), keyed
by name:

-   `logDensity`: the MAP draw's log-posterior density.
-   `slvntEDns`, `deltaRho1`, `deltaRho2`, `deltaRho3`: the shell
    parameters at that draw (see [`Inference.Seed`](@ref) for the ξ ordering this
    is read off of).
-   `cavityShellFrac`: fraction of the hydration-shell volume carried by
    cavity beads (from the Gram matrix at the lowest q). When it is ~0, δρ₃ has
    essentially no likelihood and its posterior is just its prior.
-   `scale`, `bkgrndcorr`: the WLS-fit detector scale/background at that draw.
-   `chisqred`: the WLS fit's reduced χ² at that draw.
-   `zSlvntEDns`, `zDeltaRho1`, `zDeltaRho2`,
    `zDeltaRho3`: how many prior standard deviations (θ-space) the
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

# Summary constants (used by summary.jl).

"""
Order the physical/derived parameters are listed
in the workbook's `map` and `quantiles` sheets.
"""
const _REPORT_KEYS = [
    "logDensity", "slvntEDns", "deltaRho1", "deltaRho2",
    "deltaRho3", "scale", "bkgrndCorr", "exclVolCorr", "chisqRed",
]

"The 4 physical parameters that carry a prior."
const _PRIOR_KEYS = [
    "slvntEDns", "deltaRho1", "deltaRho2", "deltaRho3",
]

"The names of the parameters in the workbook's sheets (plain ASCII)."
const _REPORT_LABELS = Dict{String,String}(
    "logDensity"  => "logDensity",
    "slvntEDns"   => "rhoE",
    "deltaRho1"   => "deltaRho1",
    "deltaRho2"   => "deltaRho2",
    "deltaRho3"   => "deltaRho3",
    "scale"       => "scale",
    "bkgrndCorr"  => "bkgrndCorr",
    "exclVolCorr" => "exclVolCorr",
    "chisqRed"    => "chi2",
)

include("colour-notation.jl")
include("settings.jl")
include("seed-model.jl")
include("run-model.jl")
include("tables.jl")
include("log.jl")
include("results.jl")
include("compare.jl")
include("summary.jl")

export seedModel,
    runModel, printSummary, writeLog,
    results, compareResults, PlotStyle, Reference, fontAvailable, InvalidSettingsError,
    seedKeywords, runKeywords, runArguments, resultsKeywords
public MAPParams, MAPResult, QuantileBounds, QuantileParams, QuantileCurves, QuantileResult

end # module
