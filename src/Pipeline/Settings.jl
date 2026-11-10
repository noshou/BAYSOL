# SPDX-License-Identifier: LGPL-3.0-or-later

# The settings of the user: the application-wide `settings.json` that the terminal interface
# keeps in the BAYSOL folder. `load_settings` reads it and checks every saved value before
# any code uses one: the type, the limits of `SETTING_LIMITS`, the choices of
# `SETTING_CHOICES`, a colour that exists, and the rules of `SETTING_RELATIONS` that tie
# settings together. A file that cannot be read, or one invalid value, stops the run with
# an `InvalidSettingsError` (and a warning for each problem), so an illegal setting never
# reaches the fit. The file is plain JSON (read with JSON3): a colour or a choice is a plain
# string, a tuple an array, the named tuple of the preview size an object.

using Colors: Colors
using JSON3: JSON3

# The modules whose Params.jl define settings.
const _SETTING_MODULES = (Inference, Geometry, Scattering, @__MODULE__)

const _COLOUR_SETTING = r"^PLOT_COLOUR_|^PLOT_TICK_COLOUR$"
const _FONT_SETTING = r"^PLOT_(TEXT|MATH)_FONT$"
const _MAX_FONT_NAME = 100

"The most characters a `:path` setting holds."
const _MAX_PATH_LENGTH = 4096

"""
The error [`load_settings`](@ref) throws when `settings.json` cannot be read or holds an
invalid value, and that [`seed_model`](@ref), [`run_model`](@ref), [`results`](@ref) and
[`run_project`](@ref) throw for a keyword that stands for a setting (`map_n_starts`,
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

"""
    settings_file() -> String

The path of the settings file of the user, `settings.json` in the BAYSOL folder: the folder
`BAYSOL_HOME` names if that is set to an absolute path, else `baysol` in the data folder
of the system (`%LOCALAPPDATA%` on Windows, `~/Library/Application Support` on macOS,
`\$XDG_DATA_HOME` or `~/.local/share` elsewhere), as the terminal interface keeps it.

# Returns
- The path; the file need not exist.

# Exceptions
- None.
"""
function settings_file()
    absolute(v) = !isempty(strip(v)) && isabspath(v)
    env(k) = get(ENV, k, "")
    root = if absolute(env("BAYSOL_HOME"))
        env("BAYSOL_HOME")
    else
        data = if Sys.iswindows()
            absolute(env("LOCALAPPDATA")) ? env("LOCALAPPDATA") :
            joinpath(homedir(), "AppData", "Local")
        elseif Sys.isapple()
            joinpath(homedir(), "Library", "Application Support")
        else
            absolute(env("XDG_DATA_HOME")) ? env("XDG_DATA_HOME") :
            joinpath(homedir(), ".local", "share")
        end
        joinpath(data, "baysol")
    end
    return joinpath(root, "settings.json")
end

# ---------------------------------------------------------------------------
#                              a reader of JSON files
# ---------------------------------------------------------------------------

# JSON3 gives lazy `JSON3.Object`/`JSON3.Array` views; the checks below want plain values:
# an object is a `Dict{Symbol,Any}`, an array a `Vector{Any}`, `null` is `nothing`, a number
# an `Int64` (or a `BigInt` beyond it) when written without a fraction or exponent, else
# a `Float64`.
_plain_json(x::AbstractDict) =
    Dict{Symbol,Any}(Symbol(k) => _plain_json(v) for (k, v) in x)
_plain_json(x::AbstractVector) = Any[_plain_json(v) for v in x]
_plain_json(x) = x

# The index just after the first JSON value in `text` (which starts at the first
# non-space), found by counting brackets and skipping strings: JSON3 stops reading after
# the first value and would let text that follows it pass unnoticed. A bare token (a number,
# `true`, `false`, `null`) ends at white space or a delimiter.
function _json_value_end(text::AbstractString)
    i = findfirst(!isspace, text)
    i === nothing && return 1
    c = text[i]
    if c == '{' || c == '[' || c == '"'
        depth = 0
        instr = false
        escaped = false
        for j in eachindex(text)
            j < i && continue
            ch = text[j]
            if instr
                if escaped
                    escaped = false
                elseif ch == '\\'
                    escaped = true
                elseif ch == '"'
                    instr = false
                    depth == 0 && return nextind(text, j)
                end
            elseif ch == '"'
                instr = true
            elseif ch == '{' || ch == '['
                depth += 1
            elseif ch == '}' || ch == ']'
                depth -= 1
                depth <= 0 && return nextind(text, j)
            end
        end
        return lastindex(text) + 1
    end
    j = something(findnext(c -> isspace(c) || c in ",]}", text, i), lastindex(text) + 1)
    return j
end

"""
    _read_json(text) -> Any

The value in the JSON `text`, as plain Julia values (see `_plain_json`).

# Returns
- A `Dict{Symbol,Any}`, `Vector{Any}`, `String`, number, `Bool` or `nothing`.

# Exceptions
- `ArgumentError` saying what is wrong, if `text` is not exactly one JSON value.
"""
function _read_json(text::AbstractString)
    stop = _json_value_end(text)
    all(isspace, SubString(text, min(stop, lastindex(text) + 1))) ||
        throw(ArgumentError("not valid JSON: something follows the value"))
    first_char = something(findfirst(!isspace, text), 1)
    if first_char <= lastindex(text) && !(text[first_char] in "{[\"")
        # a bare token: JSON3 would read a prefix of `1.2.3`
        tok = strip(SubString(text, first_char, prevind(text, stop)))
        occursin(r"^(true|false|null|-?\d+(\.\d+)?([eE][+-]?\d+)?)$", tok) ||
            throw(ArgumentError("not valid JSON: unexpected token `$tok`"))
    end
    try
        return _plain_json(JSON3.read(text))
    catch e
        e isa InterruptException && rethrow()
        throw(ArgumentError("not valid JSON: " * first(split(sprint(showerror, e), '\n'))))
    end
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

"Whether `x` is a colour a figure can use: a name of Colors.jl, or `#rrggbb`."
function _is_colour(x)
    x isa Symbol && return _is_colour(String(x))
    x isa AbstractString || return false
    return haskey(Colors.color_names, String(x)) || occursin(r"^#[0-9a-fA-F]{6}$", x)
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
        all(_is_colour, v) || _bad("must hold only colours (a name or #rrggbb)")
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
    load_settings(path = settings_file()) -> Dict{Symbol,Any}

The value of every setting: the one saved in the settings file `path` (as the terminal
interface writes it) or the default, in the type the default has (an `Int`, a `Float64`,
a `Tuple` and so on). A missing file gives the defaults. Every saved value is checked
before it is used: its type, the limits and the choices of the setting, a colour that
exists, and the rules that tie settings together. Names that are no setting are ignored.

# Returns
- A `Dict` from setting name (a `Symbol`) to its value.

# Exceptions
- `InvalidSettingsError` if the file cannot be read or holds an invalid value; a warning
  is printed for each problem first. The run that wanted the settings must stop: an
  invalid setting is reset to its default by the terminal interface.
"""
function load_settings(path::AbstractString = settings_file())
    saved = nothing
    if isfile(path)
        saved = try
            _read_json(read(path, String))
        catch e
            e isa InterruptException && rethrow()
            msg =
                "$path cannot be read: " *
                (e isa ArgumentError ? e.msg : sprint(showerror, e))
            @warn msg
            throw(InvalidSettingsError([msg]))
        end
        saved = Some(saved)
    end
    values, problems = _settings_from(saved, path)
    for p in problems
        @warn "invalid setting: $p"
    end
    isempty(problems) || throw(InvalidSettingsError(problems))
    return values
end

"""
The values of all the settings given what the settings file holds, `saved` (already read
and wrapped in a `Some`, so that a file holding `null` is not mistaken for no file;
`nothing` for no file), and the problems found: `(values, problems)`. A value that is
invalid is left at its default in `values` and named in `problems`.
"""
function _settings_from(saved, path::AbstractString)
    names = _setting_names()
    values = Dict{Symbol,Any}(n => _setting_default(n) for n in names)
    problems = String[]
    content = saved === nothing ? nothing : something(saved)
    if saved === nothing
    elseif !(content isa AbstractDict)
        push!(problems, "$path must hold an object of the screens")
    else
        present, found = _saved_values(content)
        merge!(values, present)
        append!(problems, found)
    end
    isempty(problems) && append!(problems, _relation_problems(values))
    return values, problems
end

"""
The settings a settings table holds, `(present, problems)`: `content` is the object of
screens (`{screen: {NAME: {"value": ...}}}`, what `settings.json` and one model of
`model-settings.json` hold). `present` has each setting NAME that is saved with a value,
checked, and `problems` a line for each value that is not valid or entry that is not an
object. Names that are no setting are ignored.

# Returns
- `(present, problems)`: a `Dict` from setting name to its checked value, and the lines.

# Exceptions
- None: what is wrong is in `problems`.
"""
function _saved_values(content::AbstractDict)
    names = _setting_names()
    present = Dict{Symbol,Any}()
    problems = String[]
    for (screen, entries) in content
        if !(entries isa AbstractDict)
            push!(problems, "screen $screen is not an object of settings")
            continue
        end
        for (name, entry) in entries
            Symbol(name) in names || continue
            sym = Symbol(name)
            if !(entry isa AbstractDict)
                push!(problems, "$name: its entry is not an object")
            elseif haskey(entry, :value)
                try
                    present[sym] = _checked_value(sym, entry[:value])
                catch e
                    e isa ArgumentError || rethrow()
                    push!(problems, "$name = $(repr(entry[:value])): $(e.msg)")
                end
            end
        end
    end
    return present, problems
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
    seed_keywords(settings = load_settings()) -> NamedTuple

The keywords of [`seed_model`](@ref) that a setting stands for, from `settings` (what
[`load_settings`](@ref) returns): `thickness` (`SHELL_THICKNESS`), `probe` (`PROBE_RADIUS`),
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
seed_keywords(settings::AbstractDict = load_settings()) = _keywords(settings, :seed_model)

"""
    run_keywords(settings = load_settings()) -> NamedTuple

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
run_keywords(settings::AbstractDict = load_settings()) = _keywords(settings, :run_model)

"""
    run_arguments(settings = load_settings()) -> NamedTuple

The two positional arguments of [`run_model`](@ref) that settings stand for:
`(n_samples = N_ADAPT + N_DRAWS, n_adapt = N_ADAPT)`. Pass them with
`run_model(seed, run_arguments(settings)...; run_keywords(settings)...)`.

# Returns
- `(n_samples, n_adapt)`, both `Int`.

# Exceptions
- `KeyError` if `settings` lacks `N_ADAPT` or `N_DRAWS`.
"""
run_arguments(settings::AbstractDict = load_settings()) =
    (n_samples = settings[:N_ADAPT] + settings[:N_DRAWS], n_adapt = settings[:N_ADAPT])

"""
    results_keywords(settings = load_settings()) -> NamedTuple

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
function results_keywords(settings::AbstractDict = load_settings())
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
The [`PlotStyle`](@ref) the plot settings in `settings` (what [`load_settings`](@ref)
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
Overrides, in `settings` (a `Dict` from [`load_settings`](@ref)), the settings that the
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


# ---------------------------------------------------------------------------
#     the settings of one model (`model-settings.json`, the `model_settings` keyword)
# ---------------------------------------------------------------------------

"The file of a project folder that gives some settings per model."
const MODEL_SETTINGS_FILE = "model-settings.json"

"""
The settings that belong to the whole run and may NOT differ from model to model: the
table and figure settings (`TABLE_SIGFIGS`, `FIGURES_TEX`, `FIGURES_COMPILE`,
`FIGURES_FORMATS`, `FIGURES_DIR`, `FIGURES_COMPILER`) and every `PLOT_*` setting (the look
of the figures, the terminal plot sizes, the comparison and its colours, markers and line
width), which are drawn once for the run or the same for every model. Every other
setting is per fit (the data selection, the structure, the model, shell, bead and prior
settings, the sampler) and can be given for one model. A test checks this list against
the kinds of `SETTING_KEYWORDS`, so a new setting has to be classified.
"""
const RUN_LEVEL_SETTINGS = (
    :TABLE_SIGFIGS, :FIGURES_TEX, :FIGURES_COMPILE, :FIGURES_FORMATS, :FIGURES_DIR,
    :FIGURES_COMPILER,
)

"Whether the setting `name` is one of the whole run (`RUN_LEVEL_SETTINGS`, or a `PLOT_*`)."
_is_run_level(name::Symbol) =
    name in RUN_LEVEL_SETTINGS || startswith(String(name), "PLOT_")

const _MODEL_SETTINGS_HINT =
    "model-settings.json holds, for each model (its file name without the extension), " *
    "settings in the shape of settings.json; settings of the whole run " *
    "(table, figure and PLOT_* settings) belong in settings.json."

# One line for the problem of a setting of the whole run in the table of a model.
_run_level_problem(
    who::AbstractString,
    name::Symbol,
) = "$who: $name is a setting of the whole run, not of one model"

"""
The per-model settings file `path` (see [`run_project`](@ref)): `{"<model>": {<sheet>:
{<NAME>: {"value": ...}}}}`, the shape of `settings.json` for each model. Every value is
checked as `load_settings` checks it, and a setting of the whole run (`RUN_LEVEL_SETTINGS`,
the `PLOT_*` settings) is refused. Names that are no setting are ignored, as in
`settings.json`.

# Returns
- A `Dict` from model name to the `Dict` of the settings it gives (name => checked value).

# Exceptions
- [`InvalidSettingsError`](@ref) if the file cannot be read or is not an object of
    objects, a value is invalid or a setting of the whole run is given; a line for each
    problem, naming the file and the model (a warning is printed for each first).
"""
function _read_model_settings(path::AbstractString)
    label = basename(path)
    content = try
        _read_json(read(path, String))
    catch e
        e isa InterruptException && rethrow()
        msg =
            "$path cannot be read: " * (e isa ArgumentError ? e.msg : sprint(showerror, e))
        @warn msg
        throw(InvalidSettingsError([msg], _MODEL_SETTINGS_HINT))
    end
    problems = String[]
    out = Dict{String,Dict{Symbol,Any}}()
    if !(content isa AbstractDict)
        push!(
            problems,
            "$label must hold an object with a table of settings for each model",
        )
    else
        for (model, table) in content
            who = "$label, model $model"
            if !(table isa AbstractDict)
                push!(problems, "$who: must be an object of settings screens")
                continue
            end
            # a setting of the whole run is refused whatever its value is
            names = Set(_setting_names())
            refused = Symbol[]
            kept = Dict{Symbol,Any}()
            for (screen, entries) in table
                entries isa AbstractDict || (kept[screen] = entries; continue)
                kept[screen] = Dict{Symbol,Any}(
                    k => v for (k, v) in entries if
                    !(
                        Symbol(k) in names && _is_run_level(Symbol(k)) &&
                        v isa AbstractDict && haskey(v, :value)
                    ) ||
                        (push!(refused, Symbol(k)); false)
                )
            end
            for name in sort!(refused)
                push!(problems, _run_level_problem(who, name))
            end
            present, found = _saved_values(kept)
            append!(problems, ["$who: $p" for p in found])
            out[String(model)] = present
        end
    end
    for p in problems
        @warn "invalid setting: $p"
    end
    isempty(problems) || throw(InvalidSettingsError(problems, _MODEL_SETTINGS_HINT))
    return out
end

"""
The `model_settings` keyword of [`run_project`](@ref) as the raw overrides it carries:
`models` is an `AbstractDict` or `NamedTuple` from a model name to an `AbstractDict` or
`NamedTuple` of keywords (`q_min`, `n_chains`, ... the names of the keywords of the
entry points), or `nothing`. Nothing is checked but the shape and the names.

# Returns
- A `Dict` from model name to the `Dict` of setting name => the value given.

# Exceptions
- `ArgumentError` if the shape is wrong or a name is the keyword of no setting.
"""
function _model_keyword_table(models)
    models === nothing && return Dict{String,Dict{Symbol,Any}}()
    models isa Union{AbstractDict,NamedTuple} ||
        _bad(
            "model_settings must be a Dict or NamedTuple from a model name to its settings",
        )
    setting_of = Dict(r.keyword => r.setting for r in SETTING_KEYWORDS)
    out = Dict{String,Dict{Symbol,Any}}()
    for (model, table) in pairs(models)
        table isa Union{AbstractDict,NamedTuple} ||
            _bad(
                "model_settings: the settings of model $model must be a Dict or NamedTuple",
            )
        d = Dict{Symbol,Any}()
        for (k, v) in pairs(table)
            haskey(setting_of, Symbol(k)) ||
                _bad("model_settings: model $model: `$k` is the keyword of no setting")
            d[setting_of[Symbol(k)]] = v
        end
        out[String(model)] = d
    end
    return out
end

"""
The overrides of `_model_keyword_table` checked as `load_settings` checks the settings
(`nothing` clears a setting that may be `nothing` and is skipped for the others, as for the
other keywords of `run_project`), with a setting of the whole run refused.

# Returns
- A `Dict` from model name to the `Dict` of setting name => checked value.

# Exceptions
- [`InvalidSettingsError`](@ref), with a line for each problem naming the model.
"""
function _check_model_keywords(raw::AbstractDict{String,Dict{Symbol,Any}})
    out = Dict{String,Dict{Symbol,Any}}()
    problems = String[]
    for model in sort!(collect(keys(raw)))
        who = "model_settings, model $model"
        d = Dict{Symbol,Any}()
        for name in sort!(collect(keys(raw[model])))
            v = raw[model][name]
            if _is_run_level(name)
                push!(problems, _run_level_problem(who, name))
                continue
            end
            v === :settings && continue
            v === nothing && !_is_nullable(name) && continue
            try
                d[name] = _checked_value(name, _setting_input(v))
            catch e
                e isa ArgumentError || rethrow()
                push!(problems, "$who: $name = $(repr(v)): $(e.msg)")
            end
        end
        out[model] = d
    end
    isempty(problems) || throw(InvalidSettingsError(problems, _SETTINGS_KEYWORD_HINT))
    return out
end

"""
The settings of one model: `base` (the project's, a `Dict` from `load_settings` with the
keywords of `run_project` applied) with the checked `overrides` on top.

# Returns
- A new `Dict`; `base` is not changed.

# Exceptions
- [`InvalidSettingsError`](@ref) if the rules between settings (`Q_MIN` below `Q_MAX`, ...)
    fail on the result, a line for each, naming the model `label`.
"""
function _model_settings(base::AbstractDict{Symbol,Any}, overrides::AbstractDict, label)
    s = merge(base, overrides)
    problems = ["$label: $p" for p in _relation_problems(s)]
    isempty(problems) || throw(InvalidSettingsError(problems, _MODEL_SETTINGS_HINT))
    return s
end
