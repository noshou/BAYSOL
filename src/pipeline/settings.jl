# SPDX-License-Identifier: LGPL-3.0-or-later

# The settings as the entry points take them: the checks of one value (`_checkedValue` and
# its helpers: the type, the limits of `SETTING_LIMITS`, the choices of `SETTING_CHOICES`, a
# colour that exists) and of the rules of `SETTING_RELATIONS` that tie settings together,
# the table `SETTING_KEYWORDS` of the keyword each setting is, and the functions that turn
# a settings `Dict` into those keywords. One invalid value stops the run with an
# `InvalidSettingsError` (and the same lines whether it came from a keyword or from a
# settings file). The Pipeline module reads no settings file: the file side
# (`settings.json`, `model-settings.json`, `loadSettings`) is in
# `tui/src/store/settings-file.jl`, and hands this side the `Dict` of values.

# The modules whose params.jl define settings.
const _SETTING_MODULES = (Inference, Geometry, Scattering, @__MODULE__)

const _COLOUR_SETTING = r"^PLOT_COLOUR_|^PLOT_TICK_COLOUR$"
const _FONT_SETTING = r"^PLOT_(TEXT|MATH)_FONT$"
const _MAX_FONT_NAME = 100

"The most characters a `:path` setting holds."
const _MAX_PATH_LENGTH = 4096

"""
The error `loadSettings` throws when `settings.json` cannot be read or holds an
invalid value, and that [`seedModel`](@ref), [`runModel`](@ref), [`results`](@ref) and
`runProject` throw for a keyword that stands for a setting (`mapNStarts`,
`shellSample`, ...) and is out of its limits: the same checks, the same lines.
`problems` has a line for each, naming the setting; `hint` is the sentence that ends the
message (what to do about it).

# Exceptions
This type is the exception; the fit that asked for the settings must not go on.
"""
struct InvalidSettingsError <: Exception
    problems::Vector{String}
    hint::String
end

# the hint for a settings file; a keyword of an entry point says so itself
const _SETTINGS_FILE_HINT =
    "Open the settings in the BAYSOL terminal interface: it resets an invalid " *
    "setting to its default."
const _SETTINGS_KEYWORD_HINT =
    "These values were passed as keywords; each is checked as the setting of the " *
    "same name in settings.json is."
InvalidSettingsError(problems::Vector{String}) =
    InvalidSettingsError(problems, _SETTINGS_FILE_HINT)

function Base.showerror(io::IO, e::InvalidSettingsError)
    n = length(e.problems)
    println(io, "InvalidSettingsError: the settings are not valid (", n, " problem",
        n == 1 ? "" : "s", "); nothing was started:")
    for p in e.problems
        println(io, "  - ", p)
    end
    print(io, e.hint)
end

# ---------------------------------------------------------------------------
#                            what a setting may hold
# ---------------------------------------------------------------------------

"The `SETTING_*` table `name` of every module, merged into one named tuple."
function _mergedTable(name::Symbol)
    tables = (getfield(m, name) for m in _SETTING_MODULES if isdefined(m, name))
    return reduce(merge, tables; init = (;))
end

"The names of all the settings (the `SETTING_NAMES` of every module)."
_settingNames() =
    Symbol[
        n for m in _SETTING_MODULES if isdefined(m, :SETTING_NAMES)
        for n in getfield(m, :SETTING_NAMES)
    ]

"The module whose params.jl defines the setting `name`."
function _settingOwner(name::Symbol)
    owners = [
        m for m in _SETTING_MODULES if isdefined(m, :SETTING_NAMES) &&
            name in getfield(m, :SETTING_NAMES)
    ]
    length(owners) == 1 || error("setting $name belongs to $(length(owners)) modules")
    return only(owners)
end

"The default of the setting `name`: the constant of its module."
_settingDefault(name::Symbol) = getfield(_settingOwner(name), name)

"""
The kind of the setting `name` whose default is `v`: `:bool`, `:int`, `:float`,
`:colour`, `:font`, `:set` (some of the choices of `SETTING_CHOICES`),
`:tuple`, or one of the kinds of `SETTING_KINDS` that a default cannot tell
(`:optionalFloat`, `:optionalInt`, `:ranges`, `:strings`, `:colours`, `:markers`,
`:sizes`, `:path`).
"""
function settingKind(name::Symbol, v)
    haskey(_mergedTable(:SETTING_KINDS), name) &&
        return _mergedTable(:SETTING_KINDS)[name]
    haskey(_mergedTable(:SETTING_CHOICES), name) && return :set
    v isa Bool && return :bool
    v isa Integer && return :int
    v isa AbstractFloat && return :float
    v isa Symbol && occursin(_COLOUR_SETTING, String(name)) && return :colour
    v isa AbstractString && occursin(_FONT_SETTING, String(name)) && return :font
    v isa Union{Tuple,NamedTuple} && return :tuple
    return error("setting $name: no kind for a $(typeof(v))")
end

"Whether `x` is a colour a figure can use: a name or a code `colourRgb` reads."
function _isColour(x)
    x isa Union{AbstractString,Symbol} || return false
    return try
        colourRgb(x)
        true
    catch
        false
    end
end

_bad(msg::AbstractString) = throw(ArgumentError(msg))

_isWhole(x) = x isa Integer && !(x isa Bool) && typemin(Int) <= x <= typemax(Int)
_isNumber(x) = x isa Real && !(x isa Bool) && isfinite(x)

"One part of a tuple setting, shaped like the default part `d`; the part, or an error."
function _tuplePart(x, d)
    if d isa Integer
        _isWhole(x) || _bad("a part must be a whole number")
        return Int(x)
    elseif d isa Real
        _isNumber(x) || _bad("a part must be a finite number")
        return Float64(x)
    elseif d isa Symbol
        _isColour(x) || _bad("a part must be a colour")
        return Symbol(x)
    end
    return _bad("a part of this kind cannot be checked")
end

"The tuple setting value `v`, shaped like the default `default`; the value, or an error."
function _tupleValue(v, default)
    if default isa NamedTuple
        (v isa AbstractDict && Set(keys(v)) == Set(keys(default))) ||
            _bad("must have exactly $(join(keys(default), ", "))")
        return NamedTuple{keys(default)}(
            Tuple(_tuplePart(v[k], getfield(default, k)) for k in keys(default)))
    end
    (v isa AbstractVector && length(v) == length(default)) ||
        _bad("must have $(length(default)) parts")
    return Tuple(_tuplePart(x, d) for (x, d) in zip(v, default))
end

"A pair of q values `(low, high)` of a `:ranges` setting, or an error."
function _rangeValue(x)
    (x isa Union{Tuple,AbstractVector} && length(x) == 2) ||
        _bad("each range must be a pair (q_lo, q_hi)")
    all(_isNumber, x) || _bad("each range must be a pair of finite numbers")
    lo, hi = Float64(x[1]), Float64(x[2])
    (0 <= lo < hi) || _bad("each range needs 0 <= q_lo < q_hi, got ($lo, $hi)")
    return (lo, hi)
end

"A chain id of a `:strings` setting: one character that is not blank or a control."
function _chainId(x)
    x isa Char && (x = string(x))
    (x isa AbstractString && length(x) == 1 && !isspace(first(x)) && !iscntrl(first(x))) ||
        _bad("each chain must be one character, such as \"A\"")
    return String(x)
end

"""
A `(width, height)` pair of a `:sizes` setting, within `PLOT_TUI_SIZE_LIMITS`, or an error.
"""
function _sizeValue(x)
    (x isa Union{Tuple,AbstractVector} && length(x) == 2) ||
        _bad("each size must be a pair [width, height]")
    all(_isWhole, x) || _bad("each size must be a pair of whole numbers")
    w, h = Int(x[1]), Int(x[2])
    lo, hi = PLOT_TUI_SIZE_LIMITS.min, PLOT_TUI_SIZE_LIMITS.max
    (lo[1] <= w <= hi[1] && lo[2] <= h <= hi[2]) ||
        _bad(
            "each size needs a width of $(lo[1]) to $(hi[1]) and a height of " *
            "$(lo[2]) to $(hi[2]), got ($w, $h)",
        )
    return (w, h)
end

"""
The value `v` of the setting `name`, in the type its default has; or an `ArgumentError`
saying what is wrong. The limits are checked here too.
"""
function _checkedValue(name::Symbol, v)
    default = _settingDefault(name)
    kind = settingKind(name, default)
    if kind === :optionalFloat || kind === :optionalInt
        v === nothing && return nothing        # "not given": no limit, automatic
    end
    out = if kind === :bool
        v isa Bool || _bad("must be true or false")
        v
    elseif kind === :int || kind === :optionalInt
        _isWhole(v) || _bad("must be a whole number" * (kind === :int ? "" : " or null"))
        Int(v)
    elseif kind === :float || kind === :optionalFloat
        _isNumber(v) ||
            _bad("must be a finite number" * (kind === :float ? "" : " or null"))
        Float64(v)
    elseif kind === :ranges
        (v isa Union{Tuple,AbstractVector}) || _bad("must be a list of (q_lo, q_hi) pairs")
        Tuple(_rangeValue(x) for x in v)
    elseif kind === :strings
        (v isa Union{Tuple,AbstractVector}) || _bad("must be a list of chain ids")
        ids = Tuple(_chainId(x) for x in v)
        allunique(ids) || _bad("must not repeat a chain")
        ids
    elseif kind === :colours
        (v isa Union{Tuple,AbstractVector} && !isempty(v)) ||
            _bad("must be a non-empty list of colours")
        all(_isColour, v) || _bad("must hold only colours (a name or a colour code)")
        Tuple(Symbol(x) for x in v)
    elseif kind === :markers
        names = String.(_mergedTable(:SETTING_CHOICES)[name])
        (v isa Union{Tuple,AbstractVector} && !isempty(v)) ||
            _bad("must be a non-empty list of markers")
        all(x -> (x isa AbstractString || x isa Symbol) && String(x) in names, v) ||
            _bad("must hold only markers of $(join(names, ", "))")
        Tuple(Symbol(x) for x in v)
    elseif kind === :sizes
        (v isa Union{Tuple,AbstractVector} && !isempty(v)) ||
            _bad("must be a non-empty list of [width, height] pairs")
        sizes = Tuple(_sizeValue(x) for x in v)
        all(k -> sizes[k][1] > sizes[k-1][1] && sizes[k][2] > sizes[k-1][2],
            2:length(sizes)) ||
            _bad("must grow in both width and height, each size above the one before")
        sizes
    elseif kind === :colour
        _isColour(v) || _bad("is not a colour")
        Symbol(v)
    elseif kind === :font
        (
            v isa AbstractString && !isempty(strip(v)) && length(v) <= _MAX_FONT_NAME &&
            !any(iscntrl, v)
        ) || _bad("must be a font name")
        String(v)
    elseif kind === :path
        (
            v isa AbstractString && length(v) <= _MAX_PATH_LENGTH && !any(iscntrl, v)
        ) || _bad("must be a path (text without control characters, or empty)")
        String(strip(v))
    elseif kind === :set
        choices = _mergedTable(:SETTING_CHOICES)[name]
        (
            v isa AbstractVector && !isempty(v) &&
            all(x -> x isa AbstractString && Symbol(x) in choices, v) &&
            allunique(v)
        ) || _bad("must be some of $(join(choices, ", ")), at least one")
        Tuple(c for c in choices if String(c) in v)
    else
        _tupleValue(v, default)
    end
    if kind in (:int, :float, :optionalInt, :optionalFloat)
        lim = get(_mergedTable(:SETTING_LIMITS), name, (;))
        for (k, words, ok) in ((:above, "above", >), (:below, "below", <),
            (:atLeast, "at least", >=), (:atMost, "at most", <=))
            haskey(lim, k) && !ok(out, lim[k]) && _bad("must be $words $(lim[k])")
        end
    end
    return out
end

"The rule `r` of `SETTING_RELATIONS` on the values `vals`: `nothing`, or what is wrong."
function _relationProblem(r, vals::AbstractDict{Symbol,Any})
    v = vals[r.setting]
    if r.rule === :inside
        b = vals[r.of]
        b[1] < v < b[2] || return "must lie strictly inside $(r.of) = $b"
    elseif r.rule === :withinWidth
        b = vals[r.of]
        0 < v <= b[2] - b[1] || return "must be above 0 and at most the width of $(r.of)"
    elseif r.rule === :ordered
        lower = get(r, :above, nothing)
        v[1] < v[2] || return "must have its first part below its second"
        lower === nothing || v[1] > lower || return "must have its first part above $lower"
    elseif r.rule === :allAbove
        all(>(r.bound), v isa NamedTuple ? values(v) : v) ||
            return "must have every part above $(r.bound)"
    elseif r.rule === :atMostSetting
        v <= vals[r.of] || return "must be at most $(r.of) = $(vals[r.of])"
    elseif r.rule === :belowSetting
        b = vals[r.of]
        v === nothing || b === nothing || v < b || return "must be below $(r.of) = $b"
    elseif r.rule === :opacity
        0 <= v[2] <= 1 || return "must have an opacity between 0 and 1"
    else
        error("unknown rule $(r.rule)")
    end
    return nothing
end
"""
The problems of the rules of `SETTING_RELATIONS` on `values`, one line each, in the form
`loadSettings` reports them. A rule whose settings are not all in `values` is skipped.
"""
function _relationProblems(values::AbstractDict{Symbol,Any})
    problems = String[]
    for r in _mergedRelations()
        haskey(values, r.setting) && (!haskey(r, :of) || haskey(values, r.of)) || continue
        msg = _relationProblem(r, values)
        msg === nothing ||
            push!(problems, "$(r.setting) = $(repr(values[r.setting])): $msg")
    end
    return problems
end

"Every rule of `SETTING_RELATIONS`, of all the modules."
_mergedRelations() =
    [
        r for m in _SETTING_MODULES if isdefined(m, :SETTING_RELATIONS)
        for r in getfield(m, :SETTING_RELATIONS)
    ]


# ---------------------------------------------------------------------------
#         the settings as keywords of the entry points (library use)
# ---------------------------------------------------------------------------

# A row of `SETTING_KEYWORDS`: the setting, the keyword that carries it, the entry point
# that takes the keyword and whether the keyword is checked by `_checkedKeywords` (the
# checks of `loadSettings`). The older keywords (`thickness`, `probe`, `κ_δρ₁₂`, ...)
# keep the checks and the error types they always had, so they are not `check`ed here.
_kw(setting, keyword, entry; check = false) = (; setting, keyword, entry, check)

# Entries: `:seedModel`, `:runModel` and `:results` take the keyword; `:runModelArgs`
# are the two positional arguments of `runModel` (`nSamples = N_ADAPT + N_DRAWS`,
# `nAdapt`); `:runProject` is a keyword of `runProject` alone (a switch of the run, such
# as `plotCompare`); `:PlotStyle` is a field of `PlotStyle` (what `results` takes as
# `style`).
"""
`SETTING_KEYWORDS`: for each of the settings of `settings.json` the keyword (and entry
point) that carries it when a run is made from code, as `(setting, keyword, entry, check)`
rows. Every setting is here: `seedModel` takes the geometry, hydration-shell, prior and
c1 settings, the data (q range, error scale, excluded ranges) and the structure (chains,
model, hydrogens, `lMax`), `runModel` the sampler, MAP-search and output-interval
settings, `results` the table and figure settings (the plot look as a `style` built from
the `PlotStyle` fields named here). [`seedKeywords`](@ref), [`runKeywords`](@ref) and
[`resultsKeywords`](@ref) read it, and so does `runProject`. `entry` is `:seedModel`,
`:runModel`, `:results`, `:runModelArgs` (the positional `nSamples`/`nAdapt` of
`runModel`), `:runProject` (a keyword of `runProject` alone: `plotCompare`) or
`:PlotStyle`; `check` says that the keyword is validated with the checks
of `loadSettings` (the keywords that are new since the settings had no keyword).
"""
const SETTING_KEYWORDS = (
    # seedModel
    _kw(:SHELL_THICKNESS, :thickness, :seedModel),
    _kw(:PROBE_RADIUS, :probe, :seedModel),
    _kw(:κ_δρ₁₂, :κ_δρ₁₂, :seedModel),
    _kw(:κ_δρ₃, :κ_δρ₃, :seedModel),
    _kw(:PMV_FALLBACK_UNCERT, :pmvFallbackUncert, :seedModel),
    _kw(:BOUNDS_δρ₁₂, :bounds_δρ₁₂, :seedModel; check = true),
    _kw(:MODE_δρ₁₂, :mode_δρ₁₂, :seedModel; check = true),
    _kw(:φ_max, :φ_max, :seedModel; check = true),
    _kw(:EXCL_VOL_CORR_BOUNDS, :exclVolCorrBounds, :seedModel; check = true),
    _kw(:EXCL_VOL_CORR_EPS, :exclVolCorrEps, :seedModel; check = true),
    _kw(:SHELL_AREA_PER_POINT, :shellAreaPerPoint, :seedModel; check = true),
    _kw(:SHELL_MIN_POINTS, :shellMinPoints, :seedModel; check = true),
    _kw(:SHELL_SAMPLE, :shellSample, :seedModel; check = true),
    _kw(:SASA_N_OCC, :sasaNOcc, :seedModel; check = true),
    _kw(:BEAD_RAY_RANGE, :beadRayRange, :seedModel; check = true),
    _kw(:BEAD_RAY_DIRS, :beadRayDirs, :seedModel; check = true),
    _kw(:Q_MIN, :qMin, :seedModel; check = true),
    _kw(:Q_MAX, :qMax, :seedModel; check = true),
    _kw(:SIGMA_SCALE, :sigmaScale, :seedModel; check = true),
    _kw(:EXCLUDE_Q, :excludeQ, :seedModel; check = true),
    _kw(:LMAX, :lMax, :seedModel),
    _kw(:CHAINS, :chains, :seedModel; check = true),
    _kw(:MODEL, :model, :seedModel; check = true),
    _kw(:ADD_HYDROGENS, :addHydrogens, :seedModel),
    # runModel
    _kw(:VAL_SIGMA, :sigma, :runModel),
    _kw(:TARGET_ACCEPT, :δ, :runModel),
    _kw(:RNG_SEED, :rngSeed, :runModel),
    _kw(:N_CHAINS, :nChains, :runModel),
    _kw(:RETRY_N_ADAPT, :retryNAdapt, :runModel; check = true),
    _kw(:RETRY_N_DRAWS, :retryNDraws, :runModel; check = true),
    _kw(:CHAIN_START_RADII, :chainStartRadii, :runModel; check = true),
    _kw(:OPTIMUM_CHAIN_CAP, :optimumChainCap, :runModel; check = true),
    _kw(:OPTIMUM_MIN_CHAINS, :optimumMinChains, :runModel; check = true),
    _kw(:OPTIMUM_CHAIN_RADIUS, :optimumChainRadius, :runModel; check = true),
    _kw(:OPTIMUM_CHAIN_FRACTION, :optimumChainFraction, :runModel; check = true),
    _kw(:MAP_MAX_ITER, :mapMaxIter, :runModel; check = true),
    _kw(:MAP_N_STARTS, :mapNStarts, :runModel; check = true),
    _kw(:MAP_F_SUCCESSIVE, :mapFSuccessive, :runModel; check = true),
    _kw(:MAP_OPTIMA_KEPT, :mapOptimaKept, :runModel; check = true),
    _kw(:MAP_JITTER_RADII, :mapJitterRadii, :runModel; check = true),
    _kw(:MAP_JITTER_DIRECTIONS, :mapJitterDirections, :runModel; check = true),
    _kw(:MAP_JITTER_MAX_OPTIMA, :mapJitterMaxOptima, :runModel; check = true),
    _kw(:MAP_JITTER_WITHIN_NATS, :mapJitterWithinNats, :runModel; check = true),
    _kw(:BASIN_RESTART_NATS, :basinRestartNats, :runModel; check = true),
    _kw(:HARVEST_COVER, :harvestCover, :runModel; check = true),
    _kw(:HARVEST_DIVERGENT, :harvestDivergent, :runModel; check = true),
    _kw(:N_ADAPT, :nAdapt, :runModelArgs),
    _kw(:N_DRAWS, :nDraws, :runModelArgs),
    # results
    _kw(:TABLE_SIGFIGS, :tableSigfigs, :results; check = true),
    _kw(:FIGURES_TEX, :tex, :results),
    _kw(:FIGURES_COMPILE, :compile, :results),
    _kw(:FIGURES_FORMATS, :formats, :results),
    _kw(:PLOT_TUI_SIZES, :plotTuiSizes, :results; check = true),
    _kw(:FIGURES_DIR, :plotDir, :results; check = true),
    _kw(:FIGURES_COMPILER, :latexCompiler, :results; check = true),
    # runProject alone
    _kw(:PLOT_COMPARE, :plotCompare, :runProject),
    _kw(:TABLE_DIR, :tableDir, :runProject),
    # the fields of PlotStyle, the `style` of results
    _kw(:PLOT_COLOUR_MAP, :colorMap, :PlotStyle),
    _kw(:PLOT_COLOUR_POSTERIOR, :colorPosterior, :PlotStyle),
    _kw(:PLOT_COLOUR_DATA, :colorData, :PlotStyle),
    _kw(:PLOT_COLOUR_ERRORBAR, :colorErrorbar, :PlotStyle),
    _kw(:PLOT_COLOUR_BAND, :colorBand, :PlotStyle),
    _kw(:PLOT_COLOUR_BAND_RESID, :colorBandResid, :PlotStyle),
    _kw(:PLOT_COLOUR_HIST, :colorHist, :PlotStyle),
    _kw(:PLOT_COLOUR_REFERENCE, :colorReference, :PlotStyle),
    _kw(:PLOT_COLOUR_AXIS, :colorAxis, :PlotStyle),
    _kw(:PLOT_TICK_COLOUR, :colorTick, :PlotStyle),
    _kw(:PLOT_LW_MAP, :lwMap, :PlotStyle),
    _kw(:PLOT_LW_REFERENCE, :lwReference, :PlotStyle),
    _kw(:PLOT_LW_COMPARE, :lwCompare, :PlotStyle),
    _kw(:PLOT_COMPARE_COLOURS, :colorsCompare, :PlotStyle),
    _kw(:PLOT_COMPARE_MARKERS, :markersCompare, :PlotStyle),
    _kw(:PLOT_LW_QUANTILE, :lwQuantile, :PlotStyle),
    _kw(:PLOT_LW_QUANTILE_RESID, :lwQuantileResid, :PlotStyle),
    _kw(:PLOT_LW_ZERO_LINE, :lwZeroLine, :PlotStyle),
    _kw(:PLOT_LW_ERRORBAR, :lwErrorbar, :PlotStyle),
    _kw(:PLOT_MARKERSIZE, :markersize, :PlotStyle),
    _kw(:PLOT_WHISKERWIDTH, :whiskerwidth, :PlotStyle),
    _kw(:PLOT_HIST_BINS, :histBins, :PlotStyle),
    _kw(:PLOT_WIDTH_HEIGHT_CM, :sizeCm, :PlotStyle),
    _kw(:PLOT_YLIM_LOG, :ylimLog, :PlotStyle),
    _kw(:PLOT_YLIM_LIN_PAD_FRAC, :ylimLinPadFrac, :PlotStyle),
    _kw(:PLOT_PREVIEW_SIZE, :previewSize, :PlotStyle),
    _kw(:PLOT_BORDER_PT, :borderPt, :PlotStyle),
    _kw(:PLOT_XTICK_ANGLE, :xtickAngle, :PlotStyle),
    _kw(:PLOT_AXIS_LW, :lwAxis, :PlotStyle),
    _kw(:PLOT_LW_MAJOR_TICK, :lwTick, :PlotStyle),
    _kw(:PLOT_LW_MINOR_TICK, :lwMinorTick, :PlotStyle),
    _kw(:PLOT_TICK_LENGTH_CM, :tickLengthCm, :PlotStyle),
    _kw(:PLOT_LINMIN_TICKS, :minorTicks, :PlotStyle),
    _kw(:PLOT_YTICK_LABEL_PAD_PT, :tickLabelPadPt, :PlotStyle),
    _kw(:PLOT_XTICK_LABEL_PAD_PT, :xtickLabelPadPt, :PlotStyle),
    _kw(:PLOT_XTICK_STUB_PT, :tickStubPt, :PlotStyle),
    _kw(:PLOT_XTICK_ELBOW_PT, :tickElbowPt, :PlotStyle),
    _kw(:PLOT_TEXT_FONT, :font, :PlotStyle),
    _kw(:PLOT_MATH_FONT, :font, :PlotStyle),
)

"The rows of [`SETTING_KEYWORDS`](@ref) of the entry point `entry`."
_keywordRows(entry::Symbol) = filter(r -> r.entry === entry, SETTING_KEYWORDS)

"A keyword value as `_checkedValue` reads it: a tuple or vector as a vector of its parts."
_settingInput(v) = v
_settingInput(v::Union{Tuple,AbstractVector}) =
    Any[x isa Symbol ? String(x) : x for x in v]

"""
The keywords of `entry` (`:seedModel`, `:runModel` or `:results`) in `kw`, a
`NamedTuple` of the values a caller passed for the checked keywords of that entry
point, each checked as `loadSettings` checks the setting of the same name: its type,
limits and, for the settings that depend on each other (`MODE_δρ₁₂` inside
`BOUNDS_δρ₁₂`, `SASA_N_OCC` at most `SHELL_SAMPLE`, ...), the rules of
`SETTING_RELATIONS`.

# Returns
- `kw` with every value in the type of the setting's default (an `Int`, a `Float64`, a
    `Tuple`).

# Exceptions
- [`InvalidSettingsError`](@ref), with a line `SETTING = value: what is wrong` for each
    problem, the lines `loadSettings` reports.
"""
function _checkedKeywords(entry::Symbol, kw::NamedTuple)
    settingOf = Dict(r.keyword => r.setting for r in _keywordRows(entry) if r.check)
    vals = Dict{Symbol,Any}()
    problems = String[]
    for (k, v) in pairs(kw)
        name = settingOf[k]
        try
            vals[name] = _checkedValue(name, _settingInput(v))
        catch e
            e isa ArgumentError || rethrow()
            push!(problems, "$name = $(repr(v)): $(e.msg)")
        end
    end
    isempty(problems) && append!(problems, _relationProblems(vals))
    isempty(problems) || throw(InvalidSettingsError(problems, _SETTINGS_KEYWORD_HINT))
    return NamedTuple{keys(kw)}(Tuple(vals[settingOf[k]] for k in keys(kw)))
end

"""
    seedKeywords(settings) -> NamedTuple

The keywords of [`seedModel`](@ref) that a setting stands for, from `settings` (what
`loadSettings` returns): `thickness` (`SHELL_THICKNESS`), `probe` (`PROBE_RADIUS`),
`κ_δρ₁₂`, `κ_δρ₃`, `pmvFallbackUncert` (`PMV_FALLBACK_UNCERT`), `bounds_δρ₁₂`,
`mode_δρ₁₂`, `φ_max`, `exclVolCorrBounds` (`EXCL_VOL_CORR_BOUNDS`), `exclVolCorrEps`,
`shellAreaPerPoint`, `shellMinPoints`, `shellSample`, `sasaNOcc`, `beadRayRange`,
`beadRayDirs`, `qMin`, `qMax`, `sigmaScale`, `excludeQ`, `lMax` (`LMAX`), `chains`,
`model` and `addHydrogens` (the lower-case name of the setting where none is given). Pass
it on with `seedModel(...; seedKeywords(settings)...)`. The sampler settings are
[`runKeywords`](@ref), the output and plot settings [`resultsKeywords`](@ref); every
setting is a keyword of one of the three, and `settings.json` is one way, not the only one,
to supply them.

# Returns
- A `NamedTuple` of the 24 keywords.

# Exceptions
- `KeyError` if `settings` lacks one of the settings (a `Dict` from `loadSettings` has
  them all).
"""
seedKeywords(settings::AbstractDict) = _keywords(settings, :seedModel)

"""
    runKeywords(settings) -> NamedTuple

The keywords of [`runModel`](@ref) that a setting stands for, from `settings`: `sigma`
(`VAL_SIGMA`), `δ` (`TARGET_ACCEPT`), `rngSeed`, `nChains`, `retryNAdapt`,
`retryNDraws`, `chainStartRadii`, `optimumChainCap`, `optimumMinChains`,
`optimumChainRadius`, `optimumChainFraction`, `mapMaxIter`, `mapNStarts`,
`mapFSuccessive`, `mapOptimaKept`, `mapJitterRadii`, `mapJitterDirections`,
`mapJitterMaxOptima`, `mapJitterWithinNats`, `basinRestartNats`, `harvestCover`
and `harvestDivergent`. Pass it on with `runModel(seed, runArguments(settings)...;
runKeywords(settings)...)`.

# Returns
- A `NamedTuple` of the 22 keywords.

# Exceptions
- `KeyError` if `settings` lacks one of the settings.
"""
runKeywords(settings::AbstractDict) = _keywords(settings, :runModel)

"""
    runArguments(settings) -> NamedTuple

The two positional arguments of [`runModel`](@ref) that settings stand for:
`(nSamples = N_ADAPT + N_DRAWS, nAdapt = N_ADAPT)`. Pass them with
`runModel(seed, runArguments(settings)...; runKeywords(settings)...)`.

# Returns
- `(nSamples, nAdapt)`, both `Int`.

# Exceptions
- `KeyError` if `settings` lacks `N_ADAPT` or `N_DRAWS`.
"""
runArguments(settings::AbstractDict) =
    (nSamples = settings[:N_ADAPT] + settings[:N_DRAWS], nAdapt = settings[:N_ADAPT])

"""
    resultsKeywords(settings) -> NamedTuple

The keywords of [`results`](@ref) that settings stand for: `tableSigfigs`
(`TABLE_SIGFIGS`), `tex` (`FIGURES_TEX`), `compile` (`FIGURES_COMPILE`),
`formats` (`FIGURES_FORMATS`), `plotDir` (`FIGURES_DIR`), `latexCompiler`
(`FIGURES_COMPILER`), `plotTuiSizes` (`PLOT_TUI_SIZES`) and
`style`, the [`PlotStyle`](@ref) the `PLOT_*` settings describe (each is
the field of the same meaning; the font is the pair `PLOT_TEXT_FONT`,
`PLOT_MATH_FONT`). With the default settings `style` is `PlotStyle()`.

# Returns
- A `NamedTuple` of the eight keywords.

# Exceptions
- `KeyError` if `settings` lacks one of the settings.
"""
function resultsKeywords(settings::AbstractDict)
    return merge(_keywords(settings, :results), (; style = _plotStyle(settings)))
end

"""
The keywords of the rows of `entry` (not `PlotStyle` or `runModelArgs`), from `settings`.
"""
function _keywords(settings::AbstractDict, entry::Symbol)
    rows = _keywordRows(entry)
    return NamedTuple{Tuple(r.keyword for r in rows)}(
        Tuple(settings[r.setting] for r in rows))
end

"""
The [`PlotStyle`](@ref) the plot settings in `settings` (what `loadSettings`
returns) describe: each `PLOT_*` setting is the field of the same meaning (the rows of
`SETTING_KEYWORDS` of the entry `:PlotStyle`), and the font is the pair `PLOT_TEXT_FONT`,
`PLOT_MATH_FONT`. With the default settings it is `PlotStyle()`.
"""
function _plotStyle(settings::AbstractDict)
    fields = Dict{Symbol,Any}(
        r.keyword => settings[r.setting] for r in _keywordRows(:PlotStyle) if
        r.keyword !== :font
    )
    fields[:font] = (settings[:PLOT_TEXT_FONT], settings[:PLOT_MATH_FONT])
    return PlotStyle(; fields...)
end

"Whether the setting `name` may hold `nothing` (no limit, automatic)."
_isNullable(name::Symbol) =
    settingKind(name, _settingDefault(name)) in (:optionalFloat, :optionalInt)

"""
Overrides, in `settings` (a `Dict` from `loadSettings`), the settings that the
keywords in `given` carry: `given` is a `NamedTuple` of keyword => value from
`runProject`, where `nothing` means "take the setting" and so does `:settings`. A setting
that may be `nothing` (`Q_MIN`, `Q_MAX`, `LMAX`: no limit, automatic) is cleared with a
`nothing` given for it, and only `:settings` takes the saved one. The function works on any
`NamedTuple` of keywords, so overrides of one model can be applied the same way to a copy of
`settings`. Every given value is checked as
`loadSettings` checks its setting, and the rules between settings are checked on the
result; `settings` is changed only if all pass.

# Exceptions
- [`InvalidSettingsError`](@ref) with a line for each problem.
- `KeyError` for a keyword of `given` that no setting stands for.
"""
function _applyKeywords!(settings::AbstractDict{Symbol,Any}, given::NamedTuple)
    settingOf = Dict(
        r.keyword => r.setting for r in SETTING_KEYWORDS if r.entry !== :PlotStyle
    )
    changed = Dict{Symbol,Any}()
    problems = String[]
    for (k, v) in pairs(given)
        v === :settings && continue
        name = settingOf[k]
        # `nothing` takes the saved value, except for a setting that may be `nothing`
        v === nothing && !_isNullable(name) && continue
        try
            changed[name] = _checkedValue(name, _settingInput(v))
        catch e
            e isa ArgumentError || rethrow()
            push!(problems, "$name = $(repr(v)): $(e.msg)")
        end
    end
    isempty(problems) && append!(problems, _relationProblems(merge(settings, changed)))
    isempty(problems) || throw(InvalidSettingsError(problems, _SETTINGS_KEYWORD_HINT))
    merge!(settings, changed)
    return settings
end
