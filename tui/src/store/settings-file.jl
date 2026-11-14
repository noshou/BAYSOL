# SPDX-License-Identifier: LGPL-3.0-or-later

# The file side of the settings of the user: the application-wide `settings.json` that the
# terminal interface keeps in the BAYSOL folder, and `model-settings.json` of a project.
# `loadSettings` reads the file and checks every saved value before any code uses one,
# with the checks of the keyword side (`BAYSOL.Pipeline._checkedValue`, the rules of
# `SETTING_RELATIONS`); one invalid value stops the run with an `InvalidSettingsError`.
# The file is plain JSON (read with JSON3): a colour or a choice is a plain string, a
# tuple an array, the named tuple of the preview size an object. The Pipeline module
# itself reads no settings file; this file is part of the module `BAYSOLRun`
# (`run-project.jl`), whose twin on the TypeScript side is `settings-store.ts`.

"""
    settingsFile() -> String

The path of the settings file of the user, `settings.json` in the BAYSOL folder: the folder
`BAYSOL_HOME` names if that is set to an absolute path, else `baysol` in the data folder
of the system (`%LOCALAPPDATA%` on Windows, `~/Library/Application Support` on macOS,
`\$XDG_DATA_HOME` or `~/.local/share` elsewhere), as the terminal interface keeps it.

# Returns
- The path; the file need not exist.

# Exceptions
- None.
"""
function settingsFile()
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
_plainJson(x::AbstractDict) =
    Dict{Symbol,Any}(Symbol(k) => _plainJson(v) for (k, v) in x)
_plainJson(x::AbstractVector) = Any[_plainJson(v) for v in x]
_plainJson(x) = x

# The index just after the first JSON value in `text` (which starts at the first
# non-space), found by counting brackets and skipping strings: JSON3 stops reading after
# the first value and would let text that follows it pass unnoticed. A bare token (a number,
# `true`, `false`, `null`) ends at white space or a delimiter.
function _jsonValueEnd(text::AbstractString)
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
    _readJson(text) -> Any

The value in the JSON `text`, as plain Julia values (see `_plainJson`).

# Returns
- A `Dict{Symbol,Any}`, `Vector{Any}`, `String`, number, `Bool` or `nothing`.

# Exceptions
- `ArgumentError` saying what is wrong, if `text` is not exactly one JSON value.
"""
function _readJson(text::AbstractString)
    stop = _jsonValueEnd(text)
    all(isspace, SubString(text, min(stop, lastindex(text) + 1))) ||
        throw(ArgumentError("not valid JSON: something follows the value"))
    firstChar = something(findfirst(!isspace, text), 1)
    if firstChar <= lastindex(text) && !(text[firstChar] in "{[\"")
        # a bare token: JSON3 would read a prefix of `1.2.3`
        tok = strip(SubString(text, firstChar, prevind(text, stop)))
        occursin(r"^(true|false|null|-?\d+(\.\d+)?([eE][+-]?\d+)?)$", tok) ||
            throw(ArgumentError("not valid JSON: unexpected token `$tok`"))
    end
    try
        return _plainJson(JSON3.read(text))
    catch e
        e isa InterruptException && rethrow()
        throw(ArgumentError("not valid JSON: " * first(split(sprint(showerror, e), '\n'))))
    end
end


"""
    loadSettings(path = settingsFile()) -> Dict{Symbol,Any}

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
function loadSettings(path::AbstractString = settingsFile())
    saved = nothing
    if isfile(path)
        saved = try
            _readJson(read(path, String))
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
    values, problems = _settingsFrom(saved, path)
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
function _settingsFrom(saved, path::AbstractString)
    names = _settingNames()
    values = Dict{Symbol,Any}(n => _settingDefault(n) for n in names)
    problems = String[]
    content = saved === nothing ? nothing : something(saved)
    if saved === nothing
    elseif !(content isa AbstractDict)
        push!(problems, "$path must hold an object of the screens")
    else
        present, found = _savedValues(content)
        merge!(values, present)
        append!(problems, found)
    end
    isempty(problems) && append!(problems, _relationProblems(values))
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
function _savedValues(content::AbstractDict)
    names = _settingNames()
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
                    present[sym] = _checkedValue(sym, entry[:value])
                catch e
                    e isa ArgumentError || rethrow()
                    push!(problems, "$name = $(repr(entry[:value])): $(e.msg)")
                end
            end
        end
    end
    return present, problems
end

# ---------------------------------------------------------------------------
#     the settings of one model (`model-settings.json`, the `modelSettings` keyword)
# ---------------------------------------------------------------------------

"The file of a project folder that gives some settings per model."
const MODEL_SETTINGS_FILE = "model-settings.json"

"""
The settings that belong to the whole run and may NOT differ from model to model: the
table and figure settings (`TABLE_SIGFIGS`, `FIGURES_TEX`, `FIGURES_COMPILE`,
`FIGURES_FORMATS`, `FIGURES_DIR`, `FIGURES_COMPILER`, `TABLE_DIR`) and every `PLOT_*`
setting (the look
of the figures, the terminal plot sizes, the comparison and its colours, markers and line
width), which are drawn once for the run or the same for every model. Every other
setting is per fit (the data selection, the structure, the model, shell, bead and prior
settings, the sampler) and can be given for one model. A test checks this list against
the kinds of `SETTING_KEYWORDS`, so a new setting has to be classified.
"""
const RUN_LEVEL_SETTINGS = (
    :TABLE_SIGFIGS, :FIGURES_TEX, :FIGURES_COMPILE, :FIGURES_FORMATS, :FIGURES_DIR,
    :FIGURES_COMPILER, :TABLE_DIR,
)

"Whether the setting `name` is one of the whole run (`RUN_LEVEL_SETTINGS`, or a `PLOT_*`)."
_isRunLevel(name::Symbol) =
    name in RUN_LEVEL_SETTINGS || startswith(String(name), "PLOT_")

const _MODEL_SETTINGS_HINT =
    "model-settings.json holds, for each model (its file name without the extension), " *
    "settings in the shape of settings.json; settings of the whole run " *
    "(table, figure and PLOT_* settings) belong in settings.json."

# One line for the problem of a setting of the whole run in the table of a model.
_runLevelProblem(
    who::AbstractString,
    name::Symbol,
) = "$who: $name is a setting of the whole run, not of one model"

"""
The per-model settings file `path` (see [`runProject`](@ref)): `{"<model>": {<sheet>:
{<NAME>: {"value": ...}}}}`, the shape of `settings.json` for each model. Every value is
checked as `loadSettings` checks it, and a setting of the whole run (`RUN_LEVEL_SETTINGS`,
the `PLOT_*` settings) is refused. Names that are no setting are ignored, as in
`settings.json`.

# Returns
- A `Dict` from model name to the `Dict` of the settings it gives (name => checked value).

# Exceptions
- [`InvalidSettingsError`](@ref) if the file cannot be read or is not an object of
    objects, a value is invalid or a setting of the whole run is given; a line for each
    problem, naming the file and the model (a warning is printed for each first).
"""
function _readModelSettings(path::AbstractString)
    label = basename(path)
    content = try
        _readJson(read(path, String))
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
            names = Set(_settingNames())
            refused = Symbol[]
            kept = Dict{Symbol,Any}()
            for (screen, entries) in table
                entries isa AbstractDict || (kept[screen] = entries; continue)
                kept[screen] = Dict{Symbol,Any}(
                    k => v for (k, v) in entries if
                    !(
                        Symbol(k) in names && _isRunLevel(Symbol(k)) &&
                        v isa AbstractDict && haskey(v, :value)
                    ) ||
                        (push!(refused, Symbol(k)); false)
                )
            end
            for name in sort!(refused)
                push!(problems, _runLevelProblem(who, name))
            end
            present, found = _savedValues(kept)
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
The `modelSettings` keyword of [`runProject`](@ref) as the raw overrides it carries:
`models` is an `AbstractDict` or `NamedTuple` from a model name to an `AbstractDict` or
`NamedTuple` of keywords (`qMin`, `nChains`, ... the names of the keywords of the
entry points), or `nothing`. Nothing is checked but the shape and the names.

# Returns
- A `Dict` from model name to the `Dict` of setting name => the value given.

# Exceptions
- `ArgumentError` if the shape is wrong or a name is the keyword of no setting.
"""
function _modelKeywordTable(models)
    models === nothing && return Dict{String,Dict{Symbol,Any}}()
    models isa Union{AbstractDict,NamedTuple} ||
        _bad(
            "modelSettings must be a Dict or NamedTuple from a model name to its settings",
        )
    settingOf = Dict(r.keyword => r.setting for r in SETTING_KEYWORDS)
    out = Dict{String,Dict{Symbol,Any}}()
    for (model, table) in pairs(models)
        table isa Union{AbstractDict,NamedTuple} ||
            _bad(
                "modelSettings: the settings of model $model must be a Dict or NamedTuple",
            )
        d = Dict{Symbol,Any}()
        for (k, v) in pairs(table)
            haskey(settingOf, Symbol(k)) ||
                _bad("modelSettings: model $model: `$k` is the keyword of no setting")
            d[settingOf[Symbol(k)]] = v
        end
        out[String(model)] = d
    end
    return out
end

"""
The overrides of `_modelKeywordTable` checked as `loadSettings` checks the settings
(`nothing` clears a setting that may be `nothing` and is skipped for the others, as for the
other keywords of `runProject`), with a setting of the whole run refused.

# Returns
- A `Dict` from model name to the `Dict` of setting name => checked value.

# Exceptions
- [`InvalidSettingsError`](@ref), with a line for each problem naming the model.
"""
function _checkModelKeywords(raw::AbstractDict{String,Dict{Symbol,Any}})
    out = Dict{String,Dict{Symbol,Any}}()
    problems = String[]
    for model in sort!(collect(keys(raw)))
        who = "modelSettings, model $model"
        d = Dict{Symbol,Any}()
        for name in sort!(collect(keys(raw[model])))
            v = raw[model][name]
            if _isRunLevel(name)
                push!(problems, _runLevelProblem(who, name))
                continue
            end
            v === :settings && continue
            v === nothing && !_isNullable(name) && continue
            try
                d[name] = _checkedValue(name, _settingInput(v))
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
The settings of one model: `base` (the project's, a `Dict` from `loadSettings` with the
keywords of `runProject` applied) with the checked `overrides` on top.

# Returns
- A new `Dict`; `base` is not changed.

# Exceptions
- [`InvalidSettingsError`](@ref) if the rules between settings (`Q_MIN` below `Q_MAX`, ...)
    fail on the result, a line for each, naming the model `label`.
"""
function _modelSettings(base::AbstractDict{Symbol,Any}, overrides::AbstractDict, label)
    s = merge(base, overrides)
    problems = ["$label: $p" for p in _relationProblems(s)]
    isempty(problems) || throw(InvalidSettingsError(problems, _MODEL_SETTINGS_HINT))
    return s
end
