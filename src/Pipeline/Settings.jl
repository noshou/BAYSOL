# SPDX-License-Identifier: LGPL-3.0-or-later

# The settings as the entry points take them: the checks of one value (`_checked_value` and
# its helpers: the type, the limits of `SETTING_LIMITS`, the choices of `SETTING_CHOICES`, a
# colour that exists) and of the rules of `SETTING_RELATIONS` that tie settings together,
# the table `SETTING_KEYWORDS` of the keyword each setting is, and the functions that turn
# a settings `Dict` into those keywords. One invalid value stops the run with an
# `InvalidSettingsError` (and the same lines whether it came from a keyword or from a
# settings file). The Pipeline module reads no settings file: the file side
# (`settings.json`, `model-settings.json`, `load_settings`) is in
# `tui/src/store/settings-file.jl`, and hands this side the `Dict` of values.

# The modules whose Params.jl define settings.
const _SETTING_MODULES = (Inference, Geometry, Scattering, @__MODULE__)

const _COLOUR_SETTING = r"^PLOT_COLOUR_|^PLOT_TICK_COLOUR$"
const _FONT_SETTING = r"^PLOT_(TEXT|MATH)_FONT$"
const _MAX_FONT_NAME = 100

"The most characters a `:path` setting holds."
const _MAX_PATH_LENGTH = 4096

"""
The error `load_settings` throws when `settings.json` cannot be read or holds an
invalid value, and that [`seed_model`](@ref), [`run_model`](@ref), [`results`](@ref) and
`run_project` throw for a keyword that stands for a setting (`map_n_starts`,
`shell_sample`, ...) and is out of its limits: the same checks, the same lines.
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
function _merged_table(name::Symbol)
    tables = (getfield(m, name) for m in _SETTING_MODULES if isdefined(m, name))
    return reduce(merge, tables; init = (;))
end

"The names of all the settings (the `SETTING_NAMES` of every module)."
_setting_names() =
    Symbol[
        n for m in _SETTING_MODULES if isdefined(m, :SETTING_NAMES)
        for n in getfield(m, :SETTING_NAMES)
    ]

"The module whose Params.jl defines the setting `name`."
function _setting_owner(name::Symbol)
    owners = [
        m for m in _SETTING_MODULES if isdefined(m, :SETTING_NAMES) &&
            name in getfield(m, :SETTING_NAMES)
    ]
    length(owners) == 1 || error("setting $name belongs to $(length(owners)) modules")
    return only(owners)
end

"The default of the setting `name`: the constant of its module."
_setting_default(name::Symbol) = getfield(_setting_owner(name), name)

"""
The kind of the setting `name` whose default is `v`: `:bool`, `:int`, `:float`,
`:colour`, `:font`, `:set` (some of the choices of `SETTING_CHOICES`),
`:tuple`, or one of the kinds of `SETTING_KINDS` that a default cannot tell
(`:optional_float`, `:optional_int`, `:ranges`, `:strings`, `:colours`, `:markers`,
`:sizes`, `:path`).
"""
function setting_kind(name::Symbol, v)
    haskey(_merged_table(:SETTING_KINDS), name) &&
        return _merged_table(:SETTING_KINDS)[name]
    haskey(_merged_table(:SETTING_CHOICES), name) && return :set
    v isa Bool && return :bool
    v isa Integer && return :int
    v isa AbstractFloat && return :float
    v isa Symbol && occursin(_COLOUR_SETTING, String(name)) && return :colour
    v isa AbstractString && occursin(_FONT_SETTING, String(name)) && return :font
    v isa Union{Tuple,NamedTuple} && return :tuple
    return error("setting $name: no kind for a $(typeof(v))")
end

"Whether `x` is a colour a figure can use: a name or a code `colour_rgb` reads."
function _is_colour(x)
    x isa Union{AbstractString,Symbol} || return false
    return try
        colour_rgb(x)
        true
    catch
        false
    end
end

_bad(msg::AbstractString) = throw(ArgumentError(msg))

_is_whole(x) = x isa Integer && !(x isa Bool) && typemin(Int) <= x <= typemax(Int)
_is_number(x) = x isa Real && !(x isa Bool) && isfinite(x)

"One part of a tuple setting, shaped like the default part `d`; the part, or an error."
function _tuple_part(x, d)
    if d isa Integer
        _is_whole(x) || _bad("a part must be a whole number")
        return Int(x)
    elseif d isa Real
        _is_number(x) || _bad("a part must be a finite number")
        return Float64(x)
    elseif d isa Symbol
        _is_colour(x) || _bad("a part must be a colour")
        return Symbol(x)
    end
    return _bad("a part of this kind cannot be checked")
end

"The tuple setting value `v`, shaped like the default `default`; the value, or an error."
function _tuple_value(v, default)
    if default isa NamedTuple
        (v isa AbstractDict && Set(keys(v)) == Set(keys(default))) ||
            _bad("must have exactly $(join(keys(default), ", "))")
        return NamedTuple{keys(default)}(
            Tuple(_tuple_part(v[k], getfield(default, k)) for k in keys(default)))
    end
    (v isa AbstractVector && length(v) == length(default)) ||
        _bad("must have $(length(default)) parts")
    return Tuple(_tuple_part(x, d) for (x, d) in zip(v, default))
end

"A pair of q values `(low, high)` of a `:ranges` setting, or an error."
function _range_value(x)
    (x isa Union{Tuple,AbstractVector} && length(x) == 2) ||
        _bad("each range must be a pair (q_lo, q_hi)")
    all(_is_number, x) || _bad("each range must be a pair of finite numbers")
    lo, hi = Float64(x[1]), Float64(x[2])
    (0 <= lo < hi) || _bad("each range needs 0 <= q_lo < q_hi, got ($lo, $hi)")
    return (lo, hi)
end

"A chain id of a `:strings` setting: one character that is not blank or a control."
function _chain_id(x)
    x isa Char && (x = string(x))
    (x isa AbstractString && length(x) == 1 && !isspace(first(x)) && !iscntrl(first(x))) ||
        _bad("each chain must be one character, such as \"A\"")
    return String(x)
end

"""
A `(width, height)` pair of a `:sizes` setting, within `PLOT_TUI_SIZE_LIMITS`, or an error.
"""
function _size_value(x)
    (x isa Union{Tuple,AbstractVector} && length(x) == 2) ||
        _bad("each size must be a pair [width, height]")
    all(_is_whole, x) || _bad("each size must be a pair of whole numbers")
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
function _checked_value(name::Symbol, v)
    default = _setting_default(name)
    kind = setting_kind(name, default)
    if kind === :optional_float || kind === :optional_int
        v === nothing && return nothing        # "not given": no limit, automatic
    end
    out = if kind === :bool
        v isa Bool || _bad("must be true or false")
        v
    elseif kind === :int || kind === :optional_int
        _is_whole(v) || _bad("must be a whole number" * (kind === :int ? "" : " or null"))
        Int(v)
    elseif kind === :float || kind === :optional_float
        _is_number(v) ||
            _bad("must be a finite number" * (kind === :float ? "" : " or null"))
        Float64(v)
    elseif kind === :ranges
        (v isa Union{Tuple,AbstractVector}) || _bad("must be a list of (q_lo, q_hi) pairs")
        Tuple(_range_value(x) for x in v)
    elseif kind === :strings
        (v isa Union{Tuple,AbstractVector}) || _bad("must be a list of chain ids")
        ids = Tuple(_chain_id(x) for x in v)
        allunique(ids) || _bad("must not repeat a chain")
        ids
    elseif kind === :colours
        (v isa Union{Tuple,AbstractVector} && !isempty(v)) ||
            _bad("must be a non-empty list of colours")
        all(_is_colour, v) || _bad("must hold only colours (a name or a colour code)")
        Tuple(Symbol(x) for x in v)
    elseif kind === :markers
        names = String.(_merged_table(:SETTING_CHOICES)[name])
        (v isa Union{Tuple,AbstractVector} && !isempty(v)) ||
            _bad("must be a non-empty list of markers")
        all(x -> (x isa AbstractString || x isa Symbol) && String(x) in names, v) ||
            _bad("must hold only markers of $(join(names, ", "))")
        Tuple(Symbol(x) for x in v)
    elseif kind === :sizes
        (v isa Union{Tuple,AbstractVector} && !isempty(v)) ||
            _bad("must be a non-empty list of [width, height] pairs")
        sizes = Tuple(_size_value(x) for x in v)
        all(k -> sizes[k][1] > sizes[k-1][1] && sizes[k][2] > sizes[k-1][2],
            2:length(sizes)) ||
            _bad("must grow in both width and height, each size above the one before")
        sizes
    elseif kind === :colour
        _is_colour(v) || _bad("is not a colour")
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
        choices = _merged_table(:SETTING_CHOICES)[name]
        (
            v isa AbstractVector && !isempty(v) &&
            all(x -> x isa AbstractString && Symbol(x) in choices, v) &&
            allunique(v)
        ) || _bad("must be some of $(join(choices, ", ")), at least one")
        Tuple(c for c in choices if String(c) in v)
    else
        _tuple_value(v, default)
    end
    if kind in (:int, :float, :optional_int, :optional_float)
        lim = get(_merged_table(:SETTING_LIMITS), name, (;))
        for (k, words, ok) in ((:above, "above", >), (:below, "below", <),
            (:at_least, "at least", >=), (:at_most, "at most", <=))
            haskey(lim, k) && !ok(out, lim[k]) && _bad("must be $words $(lim[k])")
        end
    end
    return out
end

"The rule `r` of `SETTING_RELATIONS` on the values `vals`: `nothing`, or what is wrong."
function _relation_problem(r, vals::AbstractDict{Symbol,Any})
    v = vals[r.setting]
    if r.rule === :inside
        b = vals[r.of]
        b[1] < v < b[2] || return "must lie strictly inside $(r.of) = $b"
    elseif r.rule === :within_width
        b = vals[r.of]
        0 < v <= b[2] - b[1] || return "must be above 0 and at most the width of $(r.of)"
    elseif r.rule === :ordered
        lower = get(r, :above, nothing)
        v[1] < v[2] || return "must have its first part below its second"
        lower === nothing || v[1] > lower || return "must have its first part above $lower"
    elseif r.rule === :all_above
        all(>(r.bound), v isa NamedTuple ? values(v) : v) ||
            return "must have every part above $(r.bound)"
    elseif r.rule === :at_most_setting
        v <= vals[r.of] || return "must be at most $(r.of) = $(vals[r.of])"
    elseif r.rule === :below_setting
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
`load_settings` reports them. A rule whose settings are not all in `values` is skipped.
"""
function _relation_problems(values::AbstractDict{Symbol,Any})
    problems = String[]
    for r in _merged_relations()
        haskey(values, r.setting) && (!haskey(r, :of) || haskey(values, r.of)) || continue
        msg = _relation_problem(r, values)
        msg === nothing ||
            push!(problems, "$(r.setting) = $(repr(values[r.setting])): $msg")
    end
    return problems
end

"Every rule of `SETTING_RELATIONS`, of all the modules."
_merged_relations() =
    [
        r for m in _SETTING_MODULES if isdefined(m, :SETTING_RELATIONS)
        for r in getfield(m, :SETTING_RELATIONS)
    ]


# ---------------------------------------------------------------------------
#         the settings as keywords of the entry points (library use)
# ---------------------------------------------------------------------------

# A row of `SETTING_KEYWORDS`: the setting, the keyword that carries it, the entry point
# that takes the keyword and whether the keyword is checked by `_checked_keywords` (the
# checks of `load_settings`). The older keywords (`thickness`, `probe`, `κ_δρ₁₂`, ...)
# keep the checks and the error types they always had, so they are not `check`ed here.
_kw(setting, keyword, entry; check = false) = (; setting, keyword, entry, check)

# Entries: `:seed_model`, `:run_model` and `:results` take the keyword; `:run_model_args`
# are the two positional arguments of `run_model` (`n_samples = N_ADAPT + N_DRAWS`,
# `n_adapt`); `:run_project` is a keyword of `run_project` alone (a switch of the run, such
# as `plot_compare`); `:PlotStyle` is a field of `PlotStyle` (what `results` takes as
# `style`).
"""
`SETTING_KEYWORDS`: for each of the settings of `settings.json` the keyword (and entry
point) that carries it when a run is made from code, as `(setting, keyword, entry, check)`
rows. Every setting is here: `seed_model` takes the geometry, hydration-shell, prior and
c1 settings, the data (q range, error scale, excluded ranges) and the structure (chains,
model, hydrogens, `lMax`), `run_model` the sampler, MAP-search and output-interval
settings, `results` the table and figure settings (the plot look as a `style` built from
the `PlotStyle` fields named here). [`seed_keywords`](@ref), [`run_keywords`](@ref) and
[`results_keywords`](@ref) read it, and so does `run_project`. `entry` is `:seed_model`,
`:run_model`, `:results`, `:run_model_args` (the positional `n_samples`/`n_adapt` of
`run_model`), `:run_project` (a keyword of `run_project` alone: `plot_compare`) or
`:PlotStyle`; `check` says that the keyword is validated with the checks
of `load_settings` (the keywords that are new since the settings had no keyword).
"""
const SETTING_KEYWORDS = (
    # seed_model
    _kw(:SHELL_THICKNESS, :thickness, :seed_model),
    _kw(:PROBE_RADIUS, :probe, :seed_model),
    _kw(:κ_δρ₁₂, :κ_δρ₁₂, :seed_model),
    _kw(:κ_δρ₃, :κ_δρ₃, :seed_model),
    _kw(:PMV_FALLBACK_UNCERT, :pmv_fallback_uncert, :seed_model),
    _kw(:BOUNDS_δρ₁₂, :bounds_δρ₁₂, :seed_model; check = true),
    _kw(:MODE_δρ₁₂, :mode_δρ₁₂, :seed_model; check = true),
    _kw(:φ_max, :φ_max, :seed_model; check = true),
    _kw(:EXCL_VOL_CORR_BOUNDS, :excl_vol_corr_bounds, :seed_model; check = true),
    _kw(:EXCL_VOL_CORR_EPS, :excl_vol_corr_eps, :seed_model; check = true),
    _kw(:SHELL_AREA_PER_POINT, :shell_area_per_point, :seed_model; check = true),
    _kw(:SHELL_MIN_POINTS, :shell_min_points, :seed_model; check = true),
    _kw(:SHELL_SAMPLE, :shell_sample, :seed_model; check = true),
    _kw(:SASA_N_OCC, :sasa_n_occ, :seed_model; check = true),
    _kw(:BEAD_RAY_RANGE, :bead_ray_range, :seed_model; check = true),
    _kw(:BEAD_RAY_DIRS, :bead_ray_dirs, :seed_model; check = true),
    _kw(:Q_MIN, :q_min, :seed_model; check = true),
    _kw(:Q_MAX, :q_max, :seed_model; check = true),
    _kw(:SIGMA_SCALE, :sigma_scale, :seed_model; check = true),
    _kw(:EXCLUDE_Q, :exclude_q, :seed_model; check = true),
    _kw(:LMAX, :lMax, :seed_model),
    _kw(:CHAINS, :chains, :seed_model; check = true),
    _kw(:MODEL, :model, :seed_model; check = true),
    _kw(:ADD_HYDROGENS, :add_hydrogens, :seed_model),
    # run_model
    _kw(:VAL_SIGMA, :sigma, :run_model),
    _kw(:TARGET_ACCEPT, :δ, :run_model),
    _kw(:RNG_SEED, :rng_seed, :run_model),
    _kw(:N_CHAINS, :n_chains, :run_model),
    _kw(:RETRY_N_ADAPT, :retry_n_adapt, :run_model; check = true),
    _kw(:RETRY_N_DRAWS, :retry_n_draws, :run_model; check = true),
    _kw(:CHAIN_START_RADII, :chain_start_radii, :run_model; check = true),
    _kw(:OPTIMUM_CHAIN_CAP, :optimum_chain_cap, :run_model; check = true),
    _kw(:OPTIMUM_MIN_CHAINS, :optimum_min_chains, :run_model; check = true),
    _kw(:OPTIMUM_CHAIN_RADIUS, :optimum_chain_radius, :run_model; check = true),
    _kw(:OPTIMUM_CHAIN_FRACTION, :optimum_chain_fraction, :run_model; check = true),
    _kw(:MAP_MAX_ITER, :map_max_iter, :run_model; check = true),
    _kw(:MAP_N_STARTS, :map_n_starts, :run_model; check = true),
    _kw(:MAP_F_SUCCESSIVE, :map_f_successive, :run_model; check = true),
    _kw(:MAP_OPTIMA_KEPT, :map_optima_kept, :run_model; check = true),
    _kw(:MAP_JITTER_RADII, :map_jitter_radii, :run_model; check = true),
    _kw(:MAP_JITTER_DIRECTIONS, :map_jitter_directions, :run_model; check = true),
    _kw(:MAP_JITTER_MAX_OPTIMA, :map_jitter_max_optima, :run_model; check = true),
    _kw(:MAP_JITTER_WITHIN_NATS, :map_jitter_within_nats, :run_model; check = true),
    _kw(:BASIN_RESTART_NATS, :basin_restart_nats, :run_model; check = true),
    _kw(:HARVEST_COVER, :harvest_cover, :run_model; check = true),
    _kw(:HARVEST_DIVERGENT, :harvest_divergent, :run_model; check = true),
    _kw(:N_ADAPT, :n_adapt, :run_model_args),
    _kw(:N_DRAWS, :n_draws, :run_model_args),
    # results
    _kw(:TABLE_SIGFIGS, :table_sigfigs, :results; check = true),
    _kw(:FIGURES_TEX, :tex, :results),
    _kw(:FIGURES_COMPILE, :compile, :results),
    _kw(:FIGURES_FORMATS, :formats, :results),
    _kw(:PLOT_TUI_SIZES, :plot_tui_sizes, :results; check = true),
    _kw(:FIGURES_DIR, :plot_dir, :results; check = true),
    _kw(:FIGURES_COMPILER, :latex_compiler, :results; check = true),
    # run_project alone
    _kw(:PLOT_COMPARE, :plot_compare, :run_project),
    _kw(:TABLE_DIR, :table_dir, :run_project),
    # the fields of PlotStyle, the `style` of results
    _kw(:PLOT_COLOUR_MAP, :color_map, :PlotStyle),
    _kw(:PLOT_COLOUR_POSTERIOR, :color_posterior, :PlotStyle),
    _kw(:PLOT_COLOUR_DATA, :color_data, :PlotStyle),
    _kw(:PLOT_COLOUR_ERRORBAR, :color_errorbar, :PlotStyle),
    _kw(:PLOT_COLOUR_BAND, :color_band, :PlotStyle),
    _kw(:PLOT_COLOUR_BAND_RESID, :color_band_resid, :PlotStyle),
    _kw(:PLOT_COLOUR_HIST, :color_hist, :PlotStyle),
    _kw(:PLOT_COLOUR_REFERENCE, :color_reference, :PlotStyle),
    _kw(:PLOT_COLOUR_AXIS, :color_axis, :PlotStyle),
    _kw(:PLOT_TICK_COLOUR, :color_tick, :PlotStyle),
    _kw(:PLOT_LW_MAP, :lw_map, :PlotStyle),
    _kw(:PLOT_LW_REFERENCE, :lw_reference, :PlotStyle),
    _kw(:PLOT_LW_COMPARE, :lw_compare, :PlotStyle),
    _kw(:PLOT_COMPARE_COLOURS, :colors_compare, :PlotStyle),
    _kw(:PLOT_COMPARE_MARKERS, :markers_compare, :PlotStyle),
    _kw(:PLOT_LW_QUANTILE, :lw_quantile, :PlotStyle),
    _kw(:PLOT_LW_QUANTILE_RESID, :lw_quantile_resid, :PlotStyle),
    _kw(:PLOT_LW_ZERO_LINE, :lw_zero_line, :PlotStyle),
    _kw(:PLOT_LW_ERRORBAR, :lw_errorbar, :PlotStyle),
    _kw(:PLOT_MARKERSIZE, :markersize, :PlotStyle),
    _kw(:PLOT_WHISKERWIDTH, :whiskerwidth, :PlotStyle),
    _kw(:PLOT_HIST_BINS, :hist_bins, :PlotStyle),
    _kw(:PLOT_WIDTH_HEIGHT_CM, :size_cm, :PlotStyle),
    _kw(:PLOT_YLIM_LOG, :ylim_log, :PlotStyle),
    _kw(:PLOT_YLIM_LIN_PAD_FRAC, :ylim_lin_pad_frac, :PlotStyle),
    _kw(:PLOT_PREVIEW_SIZE, :preview_size, :PlotStyle),
    _kw(:PLOT_BORDER_PT, :border_pt, :PlotStyle),
    _kw(:PLOT_XTICK_ANGLE, :xtick_angle, :PlotStyle),
    _kw(:PLOT_AXIS_LW, :lw_axis, :PlotStyle),
    _kw(:PLOT_LW_MAJOR_TICK, :lw_tick, :PlotStyle),
    _kw(:PLOT_LW_MINOR_TICK, :lw_minor_tick, :PlotStyle),
    _kw(:PLOT_TICK_LENGTH_CM, :tick_length_cm, :PlotStyle),
    _kw(:PLOT_LINMIN_TICKS, :minor_ticks, :PlotStyle),
    _kw(:PLOT_YTICK_LABEL_PAD_PT, :tick_label_pad_pt, :PlotStyle),
    _kw(:PLOT_XTICK_LABEL_PAD_PT, :xtick_label_pad_pt, :PlotStyle),
    _kw(:PLOT_XTICK_STUB_PT, :tick_stub_pt, :PlotStyle),
    _kw(:PLOT_XTICK_ELBOW_PT, :tick_elbow_pt, :PlotStyle),
    _kw(:PLOT_TEXT_FONT, :font, :PlotStyle),
    _kw(:PLOT_MATH_FONT, :font, :PlotStyle),
)

"The rows of [`SETTING_KEYWORDS`](@ref) of the entry point `entry`."
_keyword_rows(entry::Symbol) = filter(r -> r.entry === entry, SETTING_KEYWORDS)

"A keyword value as `_checked_value` reads it: a tuple or vector as a vector of its parts."
_setting_input(v) = v
_setting_input(v::Union{Tuple,AbstractVector}) =
    Any[x isa Symbol ? String(x) : x for x in v]

"""
The keywords of `entry` (`:seed_model`, `:run_model` or `:results`) in `kw`, a
`NamedTuple` of the values a caller passed for the checked keywords of that entry
point, each checked as `load_settings` checks the setting of the same name: its type,
limits and, for the settings that depend on each other (`MODE_δρ₁₂` inside
`BOUNDS_δρ₁₂`, `SASA_N_OCC` at most `SHELL_SAMPLE`, ...), the rules of
`SETTING_RELATIONS`.

# Returns
- `kw` with every value in the type of the setting's default (an `Int`, a `Float64`, a
    `Tuple`).

# Exceptions
- [`InvalidSettingsError`](@ref), with a line `SETTING = value: what is wrong` for each
    problem, the lines `load_settings` reports.
"""
function _checked_keywords(entry::Symbol, kw::NamedTuple)
    setting_of = Dict(r.keyword => r.setting for r in _keyword_rows(entry) if r.check)
    vals = Dict{Symbol,Any}()
    problems = String[]
    for (k, v) in pairs(kw)
        name = setting_of[k]
        try
            vals[name] = _checked_value(name, _setting_input(v))
        catch e
            e isa ArgumentError || rethrow()
            push!(problems, "$name = $(repr(v)): $(e.msg)")
        end
    end
    isempty(problems) && append!(problems, _relation_problems(vals))
    isempty(problems) || throw(InvalidSettingsError(problems, _SETTINGS_KEYWORD_HINT))
    return NamedTuple{keys(kw)}(Tuple(vals[setting_of[k]] for k in keys(kw)))
end

"""
    seed_keywords(settings) -> NamedTuple

The keywords of [`seed_model`](@ref) that a setting stands for, from `settings` (what
`load_settings` returns): `thickness` (`SHELL_THICKNESS`), `probe` (`PROBE_RADIUS`),
`κ_δρ₁₂`, `κ_δρ₃`, `pmv_fallback_uncert` (`PMV_FALLBACK_UNCERT`), `bounds_δρ₁₂`,
`mode_δρ₁₂`, `φ_max`, `excl_vol_corr_bounds` (`EXCL_VOL_CORR_BOUNDS`), `excl_vol_corr_eps`,
`shell_area_per_point`, `shell_min_points`, `shell_sample`, `sasa_n_occ`, `bead_ray_range`,
`bead_ray_dirs`, `q_min`, `q_max`, `sigma_scale`, `exclude_q`, `lMax` (`LMAX`), `chains`,
`model` and `add_hydrogens` (the lower-case name of the setting where none is given). Pass
it on with `seed_model(...; seed_keywords(settings)...)`. The sampler settings are
[`run_keywords`](@ref), the output and plot settings [`results_keywords`](@ref); every
setting is a keyword of one of the three, and `settings.json` is one way, not the only one,
to supply them.

# Returns
- A `NamedTuple` of the 24 keywords.

# Exceptions
- `KeyError` if `settings` lacks one of the settings (a `Dict` from `load_settings` has
  them all).
"""
seed_keywords(settings::AbstractDict) = _keywords(settings, :seed_model)

"""
    run_keywords(settings) -> NamedTuple

The keywords of [`run_model`](@ref) that a setting stands for, from `settings`: `sigma`
(`VAL_SIGMA`), `δ` (`TARGET_ACCEPT`), `rng_seed`, `n_chains`, `retry_n_adapt`,
`retry_n_draws`, `chain_start_radii`, `optimum_chain_cap`, `optimum_min_chains`,
`optimum_chain_radius`, `optimum_chain_fraction`, `map_max_iter`, `map_n_starts`,
`map_f_successive`, `map_optima_kept`, `map_jitter_radii`, `map_jitter_directions`,
`map_jitter_max_optima`, `map_jitter_within_nats`, `basin_restart_nats`, `harvest_cover`
and `harvest_divergent`. Pass it on with `run_model(seed, run_arguments(settings)...;
run_keywords(settings)...)`.

# Returns
- A `NamedTuple` of the 22 keywords.

# Exceptions
- `KeyError` if `settings` lacks one of the settings.
"""
run_keywords(settings::AbstractDict) = _keywords(settings, :run_model)

"""
    run_arguments(settings) -> NamedTuple

The two positional arguments of [`run_model`](@ref) that settings stand for:
`(n_samples = N_ADAPT + N_DRAWS, n_adapt = N_ADAPT)`. Pass them with
`run_model(seed, run_arguments(settings)...; run_keywords(settings)...)`.

# Returns
- `(n_samples, n_adapt)`, both `Int`.

# Exceptions
- `KeyError` if `settings` lacks `N_ADAPT` or `N_DRAWS`.
"""
run_arguments(settings::AbstractDict) =
    (n_samples = settings[:N_ADAPT] + settings[:N_DRAWS], n_adapt = settings[:N_ADAPT])

"""
    results_keywords(settings) -> NamedTuple

The keywords of [`results`](@ref) that settings stand for: `table_sigfigs`
(`TABLE_SIGFIGS`), `tex` (`FIGURES_TEX`), `compile` (`FIGURES_COMPILE`),
`formats` (`FIGURES_FORMATS`), `plot_dir` (`FIGURES_DIR`), `latex_compiler`
(`FIGURES_COMPILER`), `plot_tui_sizes` (`PLOT_TUI_SIZES`) and
`style`, the [`PlotStyle`](@ref) the `PLOT_*` settings describe (each is
the field of the same meaning; the font is the pair `PLOT_TEXT_FONT`,
`PLOT_MATH_FONT`). With the default settings `style` is `PlotStyle()`.

# Returns
- A `NamedTuple` of the eight keywords.

# Exceptions
- `KeyError` if `settings` lacks one of the settings.
"""
function results_keywords(settings::AbstractDict)
    return merge(_keywords(settings, :results), (; style = _plot_style(settings)))
end

"""
The keywords of the rows of `entry` (not `PlotStyle` or `run_model_args`), from `settings`.
"""
function _keywords(settings::AbstractDict, entry::Symbol)
    rows = _keyword_rows(entry)
    return NamedTuple{Tuple(r.keyword for r in rows)}(
        Tuple(settings[r.setting] for r in rows))
end

"""
The [`PlotStyle`](@ref) the plot settings in `settings` (what `load_settings`
returns) describe: each `PLOT_*` setting is the field of the same meaning (the rows of
`SETTING_KEYWORDS` of the entry `:PlotStyle`), and the font is the pair `PLOT_TEXT_FONT`,
`PLOT_MATH_FONT`. With the default settings it is `PlotStyle()`.
"""
function _plot_style(settings::AbstractDict)
    fields = Dict{Symbol,Any}(
        r.keyword => settings[r.setting] for r in _keyword_rows(:PlotStyle) if
        r.keyword !== :font
    )
    fields[:font] = (settings[:PLOT_TEXT_FONT], settings[:PLOT_MATH_FONT])
    return PlotStyle(; fields...)
end

"Whether the setting `name` may hold `nothing` (no limit, automatic)."
_is_nullable(name::Symbol) =
    setting_kind(name, _setting_default(name)) in (:optional_float, :optional_int)

"""
Overrides, in `settings` (a `Dict` from `load_settings`), the settings that the
keywords in `given` carry: `given` is a `NamedTuple` of keyword => value from
`run_project`, where `nothing` means "take the setting" and so does `:settings`. A setting
that may be `nothing` (`Q_MIN`, `Q_MAX`, `LMAX`: no limit, automatic) is cleared with a
`nothing` given for it, and only `:settings` takes the saved one. The function works on any
`NamedTuple` of keywords, so overrides of one model can be applied the same way to a copy of
`settings`. Every given value is checked as
`load_settings` checks its setting, and the rules between settings are checked on the
result; `settings` is changed only if all pass.

# Exceptions
- [`InvalidSettingsError`](@ref) with a line for each problem.
- `KeyError` for a keyword of `given` that no setting stands for.
"""
function _apply_keywords!(settings::AbstractDict{Symbol,Any}, given::NamedTuple)
    setting_of = Dict(
        r.keyword => r.setting for r in SETTING_KEYWORDS if r.entry !== :PlotStyle
    )
    changed = Dict{Symbol,Any}()
    problems = String[]
    for (k, v) in pairs(given)
        v === :settings && continue
        name = setting_of[k]
        # `nothing` takes the saved value, except for a setting that may be `nothing`
        v === nothing && !_is_nullable(name) && continue
        try
            changed[name] = _checked_value(name, _setting_input(v))
        catch e
            e isa ArgumentError || rethrow()
            push!(problems, "$name = $(repr(v)): $(e.msg)")
        end
    end
    isempty(problems) && append!(problems, _relation_problems(merge(settings, changed)))
    isempty(problems) || throw(InvalidSettingsError(problems, _SETTINGS_KEYWORD_HINT))
    merge!(settings, changed)
    return settings
end
