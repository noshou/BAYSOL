# SPDX-License-Identifier: LGPL-3.0-or-later

# The command line of a run: `--<setting> VALUE` for every setting that `runProject` takes
# as a keyword (the table `SETTING_KEYWORDS` of BAYSOL.Pipeline, so a new setting is a flag
# the day it is a keyword), `--ladder`, `--model-setting` and the few switches of the run
# itself. Nothing here checks a value by itself: the flags become the keywords of
# `runProject`, which checks them as `loadSettings` checks `settings.json`, so the strength
# is command line > settings files > defaults and a flag is judged exactly like the same
# value in the file. `parseCli` also runs the checks, so a bad flag is refused before
# anything starts.

"A command line that cannot be read (an unknown flag, a flag without value, no project)."
struct CliError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CliError) = print(io, "CliError: ", e.msg)

const CLI_USAGE = """
usage: runProjectCli PROJECT --temperature T [options]

  --<setting> VALUE        any setting of runProject, by the name of its keyword
                           (--nDraws 800, --n-draws 800 and --N_DRAWS 800 are the same);
                           VALUE is JSON (numbers, true, null, [1, 2], {...}) or text
  --ladder VALUE           the retry ladder: `off`, a JSON map from failure class to
                           rungs, a JSON file, or one class as CLASS=JSON (repeatable)
  --model-setting M=JSON   settings of the model M alone, a JSON object (repeatable)
  --memory-headroom P      percent of the memory kept free (also a plain setting)
  --temperature T          the temperature in degrees Celsius (required)
  --run-dir DIR            the run folder (default: a new one in the project)
  --n-samples N            draws including the warm-up (nSamples of runProject)
  --help                   this text

The look of the plots is set by the PLOT_* names (--PLOT_LW_MAP 1.2, --PLOT_TEXT_FONT ...).
"""

# `a-b`, `a_b` and `aB` are one name: lower case without the separators.
_cliKey(s) = lowercase(replace(String(s), r"[-_]" => ""))

"""
The flags of the command line: normalised name => `(keyword, setting, style)`. Every row
of `SETTING_KEYWORDS` is a flag under the name of its setting (`N_DRAWS`, `PLOT_LW_MAP`);
the keywords of `runProject` are flags under their own name too (`nDraws`). A setting that
`runProject` takes no keyword for (the look of the plots) has `style = true`: its value
goes into the `PlotStyle` given as `style`.

# Returns
- A `Dict{String,NamedTuple}`.

# Exceptions
- `ErrorException` if two names normalise to the same flag.
"""
function _cliFlags()
    declared = Set(Base.kwarg_decl(first(methods(runProject))))
    table = Dict{String,NamedTuple}()
    for r in SETTING_KEYWORDS
        style = !(r.keyword in declared)
        names = style ? (r.setting,) : (r.keyword, r.setting)
        for name in names
            key = _cliKey(name)
            haskey(table, key) && table[key].setting !== r.setting &&
                error("the flag $key is the name of two settings")
            table[key] = (; keyword = r.keyword, setting = r.setting, style)
        end
    end
    return table
end

# A value of the command line: JSON when it is JSON, else the text itself.
function _cliValue(text::AbstractString)
    try
        return _readJson(text)
    catch e
        e isa ArgumentError || rethrow()
        return String(text)
    end
end

# The JSON object of `text` (or of the file of that name) as a table of settings.
function _cliObject(text::AbstractString, what::AbstractString)
    v = try
        _readJson(isfile(text) ? read(text, String) : text)
    catch e
        e isa ArgumentError || rethrow()
        throw(CliError("$what: not valid JSON ($(e.msg))"))
    end
    v isa AbstractDict || throw(CliError("$what must be a JSON object"))
    return v
end

# One `--ladder` argument: `:off`, or the map (class => rungs) it carries.
function _cliLadder(text::AbstractString)
    strip(text) in ("off", "false") && return :off
    m = match(r"^(\w+)=(.*)$"s, text)
    if m !== nothing && Symbol(m[1]) in LADDER_CLASSES
        return Dict{Symbol,Any}(Symbol(m[1]) => _cliValue(m[2]))
    end
    return Dict{Symbol,Any}(_cliObject(text, "--ladder"))
end

"""
The command line `args` as the arguments of `runProject`, checked.

The values are checked as `runProject` checks them: on `settings` (default: what
`loadSettings` reads, the file the run reads), so the relations between settings hold
against the user's own file, not against the defaults.

# Returns
- A `NamedTuple` `(project, temperature, runDir, nSamples, keywords, modelSettings,
  styleSettings)`: `keywords` the settings the flags set (keyword => value, as `runProject`
  takes them), `modelSettings` a `Dict` from model name to such a table, `styleSettings`
  the checked plot-look settings (setting => value; they build the `style`).

# Exceptions
- [`CliError`](@ref) for an unknown flag, a flag without value, a missing project or
  temperature, a repeated flag, a malformed `--model-setting`.
- [`InvalidSettingsError`](@ref) for a value its setting refuses, as in `settings.json`.
"""
function parseCli(
    args::AbstractVector{<:AbstractString};
    settings::AbstractDict{Symbol,Any} = loadSettings(),
)
    flags = _cliFlags()
    positional = String[]
    keywords = Dict{Symbol,Any}()
    styleRaw = Dict{Symbol,Any}()
    models = Dict{String,Dict{Symbol,Any}}()
    ladder = nothing
    temperature = nothing
    runDir = nothing
    nSamples = nothing
    i = 1
    while i <= length(args)
        a = String(args[i])
        i += 1
        if !startswith(a, "--")
            push!(positional, a)
            continue
        end
        flag, inlineValue =
            occursin('=', a) ? Tuple(split(a, '='; limit = 2)) : (a, nothing)
        flag = flag[3:end]
        value() = begin
            inlineValue !== nothing && return String(inlineValue)
            i <= length(args) || throw(CliError("--$flag needs a value"))
            i += 1
            return String(args[i-1])
        end
        key = _cliKey(flag)
        if key == "help"
            throw(CliError(CLI_USAGE))
        elseif key == "temperature"
            temperature = _cliNumber(value(), "--temperature")
        elseif key == "rundir"
            runDir = value()
        elseif key == "nsamples"
            n = _cliNumber(value(), "--n-samples")
            isinteger(n) && n > 0 || throw(CliError("--n-samples must be a whole number"))
            nSamples = Int(n)
        elseif key == "ladder"
            piece = _cliLadder(value())
            off = Dict{Symbol,Any}(c => Any[] for c in LADDER_CLASSES)
            # `off` switches every class off, a later class is then the only one on
            ladder = merge(ladder isa Dict ? ladder : Dict{Symbol,Any}(),
                piece === :off ? off : piece)
            piece === :off && (ladder = off)
        elseif key == "modelsetting"
            text = value()
            m = match(r"^([^=]+)=(.*)$"s, text)
            m === nothing &&
                throw(CliError("--model-setting needs MODEL=JSON, not `$text`"))
            table = _cliObject(m[2], "--model-setting $(m[1])")
            own = get!(models, String(m[1]), Dict{Symbol,Any}())
            for (k, v) in table
                flag = get(flags, _cliKey(k), nothing)
                flag === nothing &&
                    throw(
                        CliError("--model-setting $(m[1]): `$k` is the name of no setting"),
                    )
                # the look of the plots is the run's, a model has none of its own
                own[flag.keyword === :font ? Symbol(flag.setting) : flag.keyword] = v
            end
        elseif haskey(flags, key)
            f = flags[key]
            target = f.style ? styleRaw : keywords
            name = f.style ? f.setting : f.keyword
            haskey(target, name) && throw(CliError("--$flag is given twice"))
            target[name] = _cliValue(value())
        else
            throw(CliError("unknown option --$flag (see --help)"))
        end
    end
    length(positional) == 1 ||
        throw(
            CliError(isempty(positional) ? "no project folder" : "one project folder only"),
        )
    temperature === nothing && throw(CliError("--temperature is required"))
    if ladder !== nothing && !haskey(keywords, :ladder)
        keywords[:ladder] =
            all(c -> haskey(ladder, c) && isempty(ladder[c]), LADDER_CLASSES) ? "off" :
            ladder
    end
    # the checks of loadSettings, now, on the settings the run will start from
    given = NamedTuple{Tuple(keys(keywords))}(Tuple(values(keywords)))
    effective = _applyKeywords!(copy(settings), given)
    settingOf = Dict(r.keyword => r.setting for r in SETTING_KEYWORDS)
    own = _checkModelKeywords(
        Dict{String,Dict{Symbol,Any}}(
            m => Dict{Symbol,Any}(get(settingOf, k, k) => v for (k, v) in t) for
            (m, t) in models
        ),
    )
    for (m, t) in own
        _modelSettings(effective, t, "model $m")
    end
    styleSettings = Dict{Symbol,Any}()
    problems = String[]
    for (name, v) in styleRaw
        try
            styleSettings[name] = _checkedValue(name, _settingInput(v))
        catch e
            e isa ArgumentError || rethrow()
            push!(problems, "$name = $(repr(v)): $(e.msg)")
        end
    end
    isempty(problems) &&
        append!(problems, _relationProblems(merge(effective, styleSettings)))
    isempty(problems) || throw(InvalidSettingsError(problems, _SETTINGS_KEYWORD_HINT))
    return (; project = positional[1], temperature, runDir, nSamples, keywords,
        modelSettings = models, styleSettings)
end

function _cliNumber(text::AbstractString, flag::AbstractString)
    v = _cliValue(text)
    v isa Real && !(v isa Bool) && isfinite(v) || throw(CliError("$flag must be a number"))
    return v
end

"""
Runs the project of the command line `args` (see `CLI_USAGE`): reads it with
[`parseCli`](@ref) and hands it to `runner` (`runProject`).

# Returns
- The exit status: 0 when the run is done (or for `--help`), 1 when it failed or was
  aborted, 2 for a command line or a setting that cannot be used (the reason goes to
  `io`).

# Exceptions
- Whatever `runner` throws besides an `InvalidSettingsError` (that is status 2).
"""
function runProjectCli(
    args::AbstractVector{<:AbstractString};
    runner = runProject,
    io::IO = stderr,
    settings::AbstractDict{Symbol,Any} = loadSettings(),
)::Int
    function refused(e)
        if e isa CliError
            println(io, e.msg)
            return startswith(e.msg, "usage:") ? 0 : 2
        elseif e isa InvalidSettingsError
            println(io, join(e.problems, "\n"))
            println(io, e.hint)
            return 2
        end
        rethrow(e)
    end
    p = try
        parseCli(args; settings)
    catch e
        return refused(e)
    end
    extra = (;
        (p.runDir === nothing ? (;) : (; runDir = p.runDir))...,
        (p.nSamples === nothing ? (;) : (; nSamples = p.nSamples))...,
        (isempty(p.modelSettings) ? (;) : (; modelSettings = p.modelSettings))...,
        (
            isempty(p.styleSettings) ? (;) :
            (; style = _plotStyle(merge(settings, p.styleSettings)))
        )...,
    )
    result = try
        runner(
            p.project;
            temperature = p.temperature,
            ui = :cli,
            extra...,
            NamedTuple{Tuple(keys(p.keywords))}(Tuple(values(p.keywords)))...,
        )
    catch e
        e isa InvalidSettingsError || rethrow()
        return refused(e)
    end
    status = result isa NamedTuple && hasproperty(result, :status) ? result.status : :done
    return Symbol(status) in (:failed, :aborted) ? 1 : 0
end
