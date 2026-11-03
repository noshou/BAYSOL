# SPDX-License-Identifier: LGPL-3.0-or-later

# The settings of the user: the application-wide `settings.edn` that the terminal interface
# keeps in the BAYSOL folder. `load_settings` reads it and checks every saved value before
# any code uses one: the type, the limits of `SETTING_LIMITS`, the choices of
# `SETTING_CHOICES`, a colour that exists, and the rules of `SETTING_RELATIONS` that tie
# settings together. A file that cannot be read, or one invalid value, stops the run with
# an `InvalidSettingsError` (and a warning for each problem), so an illegal setting never
# reaches the fit. The file is plain EDN, which has no reader in Julia, so a small one is
# here (`_parse_edn`): numbers, strings, keywords, `true`, `false`, `nil`, vectors, lists
# and maps, with `;` comments and commas as white space.

using Colors: Colors

# The modules whose Params.jl define settings.
const _SETTING_MODULES = (Inference, Geometry, Scattering, @__MODULE__)

const _COLOUR_SETTING = r"^PLOT_COLOUR_|^PLOT_TICK_COLOUR$"
const _FONT_SETTING = r"^PLOT_(TEXT|MATH)_FONT$"
const _MAX_FONT_NAME = 100
const _MAX_EDN_DEPTH = 64

"""
The error [`load_settings`](@ref) throws when `settings.edn` cannot be read or holds an
invalid value; `problems` has a line for each, naming the setting.

# Exceptions
This type is the exception; the fit that asked for the settings must not go on.
"""
struct InvalidSettingsError <: Exception
    problems::Vector{String}
end

function Base.showerror(io::IO, e::InvalidSettingsError)
    n = length(e.problems)
    println(io, "InvalidSettingsError: the settings are not valid (", n, " problem",
        n == 1 ? "" : "s", "); nothing was started:")
    for p in e.problems
        println(io, "  - ", p)
    end
    print(io, "Open the settings in the BAYSOL terminal interface: it resets an invalid ",
        "setting to its default.")
end

"""
    settings_file() -> String

The path of the settings file of the user, `settings.edn` in the BAYSOL folder: the folder
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
    return joinpath(root, "settings.edn")
end

# ---------------------------------------------------------------------------
#                                an EDN reader
# ---------------------------------------------------------------------------

mutable struct _Edn
    s::String
    i::Int
    depth::Int
end

_edn_fail(r::_Edn, msg) = throw(
    ArgumentError(
        string("line ",
            1 + count(==('\n'), SubString(r.s, 1, max(0, prevind(r.s, r.i)))),
            ": ", msg)),
)

_peek(r::_Edn) = r.i > ncodeunits(r.s) ? nothing : r.s[r.i]
_advance!(r::_Edn) = (r.i = nextind(r.s, r.i); nothing)

function _skip!(r::_Edn)
    while (c = _peek(r)) !== nothing
        if c == ';'
            while (d = _peek(r)) !== nothing && d != '\n'
                _advance!(r)
            end
        elseif isspace(c) || c == ','
            _advance!(r)
        else
            break
        end
    end
end

_ends_token(c) = c === nothing || isspace(c) || c in ",{}[]()\";"

function _token!(r::_Edn)
    start = r.i
    while !_ends_token(_peek(r))
        _advance!(r)
    end
    return SubString(r.s, start, prevind(r.s, r.i))
end

function _string!(r::_Edn)
    _advance!(r)                                    # the opening quote
    io = IOBuffer()
    while true
        c = _peek(r)
        c === nothing && _edn_fail(r, "a string is not closed")
        _advance!(r)
        c == '"' && return String(take!(io))
        if c == '\\'
            e = _peek(r)
            e === nothing && _edn_fail(r, "a string is not closed")
            _advance!(r)
            if e == 'u'
                digits = IOBuffer()
                j = r.i
                n = 0
                while n < 4 && j <= ncodeunits(r.s)
                    print(digits, r.s[j])
                    j = nextind(r.s, j)
                    n += 1
                end
                code = n == 4 ? tryparse(UInt32, String(take!(digits)); base = 16) : nothing
                (code === nothing || !isvalid(Char, code)) &&
                    _edn_fail(r, "a bad \\u escape in a string")
                print(io, Char(code))
                r.i = j
            else
                mapped = get(
                    Dict('"' => '"', '\\' => '\\', 'n' => '\n', 't' => '\t',
                        'r' => '\r', 'b' => '\b', 'f' => '\f'), e, nothing)
                mapped === nothing && _edn_fail(r, "a bad escape \\$e in a string")
                print(io, mapped)
            end
        else
            print(io, c)
        end
    end
end

function _atom!(r::_Edn)
    tok = _token!(r)
    isempty(tok) && _edn_fail(r, "an unexpected character")
    tok == "true" && return true
    tok == "false" && return false
    tok == "nil" && return nothing
    if occursin(r"^[+-]?\d+$", tok)
        n = tryparse(Int64, tok)
        n === nothing && _edn_fail(r, "the integer $tok is too large")
        return n
    end
    if occursin(r"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$", tok)
        x = tryparse(Float64, tok)
        x === nothing && _edn_fail(r, "the number $tok is out of range")
        return x
    end
    return _edn_fail(r, "an unexpected token `$tok`")
end

function _collection!(r::_Edn, close::Char)
    r.depth += 1
    r.depth > _MAX_EDN_DEPTH && _edn_fail(r, "nested too deeply")
    _advance!(r)                                    # the opening bracket
    items = Any[]
    while true
        _skip!(r)
        c = _peek(r)
        c === nothing && _edn_fail(r, "a `$close` is missing")
        if c == close
            _advance!(r)
            break
        end
        c in "}])" && _edn_fail(r, "an unexpected `$c`")
        push!(items, _value!(r))
    end
    r.depth -= 1
    return items
end

function _value!(r::_Edn)
    _skip!(r)
    c = _peek(r)
    c === nothing && _edn_fail(r, "a value is missing")
    if c == '{'
        items = _collection!(r, '}')
        isodd(length(items)) && _edn_fail(r, "a map has a key without a value")
        d = Dict{Any,Any}()
        for k in 1:2:length(items)
            haskey(d, items[k]) && _edn_fail(r, "a map has the key $(repr(items[k])) twice")
            d[items[k]] = items[k+1]
        end
        return d
    elseif c == '['
        return _collection!(r, ']')
    elseif c == '('
        return _collection!(r, ')')
    elseif c == '"'
        return _string!(r)
    elseif c == ':'
        _advance!(r)
        tok = _token!(r)
        isempty(tok) && _edn_fail(r, "a keyword has no name")
        return Symbol(tok)
    elseif c in "}])"
        return _edn_fail(r, "an unexpected `$c`")
    end
    return _atom!(r)
end

"""
The value in the EDN `text`: maps are `Dict{Any,Any}`, vectors and lists `Vector{Any}`,
keywords `Symbol`s, `nil` is `nothing`.

# Exceptions
- `ArgumentError` naming the line, if `text` is not exactly one EDN value.
"""
function _parse_edn(text::AbstractString)
    r = _Edn(String(text), 1, 0)
    v = _value!(r)
    _skip!(r)
    _peek(r) === nothing || _edn_fail(r, "something follows the value")
    return v
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
The kind of the setting `name` whose default is `v`: `:bool`, `:int`, `:float`, `:colour`,
`:font`, `:set` (some of the choices of `SETTING_CHOICES`) or `:tuple`.
"""
function setting_kind(name::Symbol, v)
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
    x isa Symbol && return haskey(Colors.color_names, String(x))
    x isa AbstractString && return occursin(r"^#[0-9a-fA-F]{6}$", x)
    return false
end

_bad(msg::AbstractString) = throw(ArgumentError(msg))

_is_whole(x) = x isa Integer && !(x isa Bool)
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
        return x
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

"""
The value `v` of the setting `name`, in the type its default has; or an `ArgumentError`
saying what is wrong. The limits are checked here too.
"""
function _checked_value(name::Symbol, v)
    default = _setting_default(name)
    kind = setting_kind(name, default)
    out = if kind === :bool
        v isa Bool || _bad("must be true or false")
        v
    elseif kind === :int
        _is_whole(v) || _bad("must be a whole number")
        Int(v)
    elseif kind === :float
        _is_number(v) || _bad("must be a finite number")
        Float64(v)
    elseif kind === :colour
        _is_colour(v) || _bad("is not a colour")
        v
    elseif kind === :font
        (
            v isa AbstractString && !isempty(strip(v)) && length(v) <= _MAX_FONT_NAME &&
            !any(iscntrl, v)
        ) || _bad("must be a font name")
        String(v)
    elseif kind === :set
        choices = _merged_table(:SETTING_CHOICES)[name]
        (
            v isa AbstractVector && !isempty(v) &&
            all(x -> x isa Symbol && x in choices, v) &&
            allunique(v)
        ) || _bad("must be some of $(join(choices, ", ")), at least one")
        Tuple(c for c in choices if c in v)
    else
        _tuple_value(v, default)
    end
    if kind === :int || kind === :float
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
            _parse_edn(read(path, String))
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
and wrapped in a `Some`, so that a file holding `nil` is not mistaken for no file; `nothing`
for no file), and the problems found: `(values, problems)`. A value that is
invalid is left at its default in `values` and named in `problems`.
"""
function _settings_from(saved, path::AbstractString)
    names = _setting_names()
    values = Dict{Symbol,Any}(n => _setting_default(n) for n in names)
    problems = String[]
    content = saved === nothing ? nothing : something(saved)
    if saved === nothing
    elseif !(content isa AbstractDict)
        push!(problems, "$path must hold a map of the screens")
    else
        for (screen, entries) in content
            if !(entries isa AbstractDict)
                push!(problems, "screen $screen is not a map of settings")
                continue
            end
            for (name, entry) in entries
                (name isa AbstractString && Symbol(name) in names) || continue
                sym = Symbol(name)
                if !(entry isa AbstractDict)
                    push!(problems, "$name: its entry is not a map")
                elseif haskey(entry, :value)
                    try
                        values[sym] = _checked_value(sym, entry[:value])
                    catch e
                        e isa ArgumentError || rethrow()
                        push!(problems, "$name = $(repr(entry[:value])): $(e.msg)")
                    end
                end
            end
        end
    end
    if isempty(problems)
        for r in _merged_relations()
            msg = _relation_problem(r, values)
            msg === nothing ||
                push!(problems, "$(r.setting) = $(repr(values[r.setting])): $msg")
        end
    end
    return values, problems
end

"Every rule of `SETTING_RELATIONS`, of all the modules."
_merged_relations() =
    [
        r for m in _SETTING_MODULES if isdefined(m, :SETTING_RELATIONS)
        for r in getfield(m, :SETTING_RELATIONS)
    ]

# ---------------------------------------------------------------------------
#             the settings that `seed_model` takes as keywords
# ---------------------------------------------------------------------------

# The settings whose name is a keyword of `seed_model`: (setting, keyword).
const _SEED_SETTINGS = (
    (:SHELL_THICKNESS, :thickness),
    (:PROBE_RADIUS, :probe),
    (:κ_δρ₁₂, :κ_δρ₁₂),
    (:κ_δρ₃, :κ_δρ₃),
    (:PMV_FALLBACK_UNCERT, :pmv_fallback_uncert),
)

"""
    seed_keywords(settings = load_settings()) -> NamedTuple

The keywords of [`seed_model`](@ref) that a setting stands for, from `settings` (what
[`load_settings`](@ref) returns): `thickness` (`SHELL_THICKNESS`), `probe`
(`PROBE_RADIUS`), `κ_δρ₁₂`, `κ_δρ₃` and `pmv_fallback_uncert` (`PMV_FALLBACK_UNCERT`).
Pass it on with `seed_model(...; seed_keywords(settings)...)`. The sampler, output and
plot settings feed other functions and are not here.

# Returns
- A `NamedTuple` of the five keywords.

# Exceptions
- `KeyError` if `settings` lacks one of the settings (a `Dict` from `load_settings` has
  them all).
"""
seed_keywords(settings::AbstractDict = load_settings()) =
    NamedTuple{Tuple(last.(_SEED_SETTINGS))}(
        Tuple(settings[first(p)] for p in _SEED_SETTINGS))
