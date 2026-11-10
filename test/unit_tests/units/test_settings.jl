# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Pipeline/Settings.jl: the reader of settings.json and `load_settings`, which
# checks every saved value before any code uses one. Valid files of every kind of setting,
# the cases shared with the terminal interface (test/fixtures/settings/cases.json),
# corrupt files (bad JSON, wrong types, the rules that tie settings together), and seeded
# fuzzing: whatever is written into the file, `load_settings` either returns settings of
# the right types or throws an `InvalidSettingsError`, and nothing else.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Logging
using Random
using BAYSOL.BulkElectronDensity: JSON3
using BAYSOL.Pipeline: load_settings, settings_file, InvalidSettingsError, _read_json,
    _checked_value, setting_kind, _setting_names, _setting_default, _merged_table,
    _merged_relations, _relation_problem

"Runs `f(path)` on a settings file holding `text`."
function with_file(f, text::AbstractString)
    mktempdir() do dir
        path = joinpath(dir, "settings.json")
        write(path, text)
        f(path)
    end
end

"The text of a settings file that saves `value` (JSON text) for `name`."
saved(
    name,
    value;
    screen = "sampler",
) = "{\"$screen\": {\"$name\": {\"page\": 1, \"default\": 0, \"value\": $value}}}"

"`load_settings` on `text`, with its warnings silenced: the settings or the error."
function try_load(text)
    with_file(text) do path
        with_logger(NullLogger()) do
            try
                load_settings(path)
            catch e
                e isa InvalidSettingsError ? e : rethrow()
            end
        end
    end
end

ok(text) = (r = try_load(text); r isa AbstractDict)
bad(text) = try_load(text) isa InvalidSettingsError
value_of(name, text) = try_load(saved(name, text))[Symbol(name)]

@testset "the JSON reader" begin
    @testset "values" begin
        @test _read_json("42") === 42
        @test _read_json("-7") === -7
        @test _read_json("3.5") === 3.5
        @test _read_json("1e-3") === 1.0e-3
        @test _read_json("1.0E+2") == 100.0
        @test _read_json("true") === true
        @test _read_json("false") === false
        @test _read_json("null") === nothing
        @test _read_json("\"hi\"") == "hi"
        @test _read_json("\"a\\nb\\t\\\"q\\\" \\\\ \\u00e9\"") == "a\nb\t\"q\" \\ é"
        @test _read_json("\"κ_δρ₁₂ Gyre\"") == "κ_δρ₁₂ Gyre"
        @test _read_json("[1, 2.0, \"a\", null]") == Any[1, 2.0, "a", nothing]
        @test _read_json("[]") == Any[]
        @test _read_json("{}") == Dict{Symbol,Any}()
        @test _read_json("{\"a\": 1, \"b\": [2, 3]}") ==
              Dict{Symbol,Any}(:a => 1, :b => Any[2, 3])
        @test _read_json("{\"a\": {\"b\": {\"c\": 1}}}")[:a][:b][:c] == 1
        @test _read_json("[1, {\"a\": [2]}]")[2] isa Dict{Symbol,Any}
        @test _read_json("  [1,\n 2 ]  ") == Any[1, 2]
    end
    @testset "malformed text is an ArgumentError" begin
        for text in (
            "", "   ", "[", "]", "}", ")", "{", "{\"a\"}", "[1, 2", "\"open",
            "[1 2]", "1 2", ":", "foo", "NaN", "Infinity", "1.2.3", "'a", "{\"a\": 1",
            "{} x", "[1,2]]", "[[[", "[1, {\"a\"}]", "[1,]", "{,}", "{\"a\": 1,}", "--1",
            "\"\\q\"",
        )
            @test_throws ArgumentError _read_json(text)
        end
    end
end

@testset "settings that are not saved are defaults" begin
    defaults = load_settings(joinpath(tempdir(), "no", "such", "settings.json"))
    @test defaults isa Dict{Symbol,Any}
    @test Set(keys(defaults)) == Set(_setting_names())
    @test length(defaults) == 95
    for n in _setting_names()
        @test defaults[n] == _setting_default(n)
    end
    @testset "$what" for (what, text) in (
        ("an empty object", "{}"),
        ("screens without entries", "{\"sampler\": {}, \"model\": {}}"),
        ("entries without a value",
            "{\"sampler\": {\"N_ADAPT\": {\"page\": 1, \"default\": 300}}}"),
        ("an unknown setting", saved("NOT_A_SETTING", "5")),
        ("a constant that is no setting", saved("PLOT_SUBDIR", "\"x\"")),
        ("a setting under another screen", saved("N_ADAPT", "450"; screen = "plots")),
        ("a screen that does not exist", saved("N_ADAPT", "300"; screen = "nowhere")),
    )
        @test try_load(text)[:RNG_SEED] == 0
    end
    @testset "the defaults file that the terminal interface reads" begin
        # tui/assets/data/default_settings.json is harvested from the source
        # (`bysl harvest defaults`): the same settings, each with the same default
        file = joinpath(@__DIR__, "..", "..", "..", "tui", "assets", "data",
            "default_settings.json")
        harvested = JSON3.read(read(file, String))
        @test Set(keys(harvested)) == Set(_setting_names())
        # a tuple is a JSON array, a symbol (a colour, a format) is a JSON string and a
        # named tuple (the preview size) is a JSON object
        plain(x) =
            x isa Symbol ? String(x) :
            x isa Union{Tuple,AbstractVector} ? map(plain, collect(x)) :
            x isa Union{NamedTuple,AbstractDict} ?
            Dict(Symbol(k) => plain(v) for (k, v) in pairs(x)) : x
        for (name, entry) in harvested
            @test plain(entry[:default]) == plain(defaults[name])
        end
    end
end

@testset "valid saved values" begin
    @test value_of("N_ADAPT", "450") === 450
    @test value_of("N_ADAPT", "1") === 1
    @test value_of("RNG_SEED", "-12") === -12
    @test value_of("RNG_SEED", "0") === 0
    @test value_of("TARGET_ACCEPT", "50") === 50
    @test value_of("TARGET_ACCEPT", "99") === 99
    @test value_of("TABLE_SIGFIGS", "1") === 1
    @test value_of("TABLE_SIGFIGS", "17") === 17
    @test value_of("HARVEST_COVER", "0") === 0
    @test value_of("OPTIMUM_CHAIN_CAP", "0") === 0
    @testset "a float setting takes a whole number as a float" begin
        @test value_of("VAL_SIGMA", "3") === 3.0
        @test value_of("VAL_SIGMA", "2.5") === 2.5
        @test value_of("VAL_SIGMA", "1e-3") === 0.001
        @test value_of("PLOT_LW_MAP", "0") === 0.0
        @test value_of("PROBE_RADIUS", "0") === 0.0
        @test value_of("OPTIMUM_CHAIN_FRACTION", "1") === 1.0
        @test value_of("OPTIMUM_CHAIN_FRACTION", "0.25") === 0.25
        @test value_of("PLOT_XTICK_ANGLE", "-30") === -30.0
    end
    @test value_of("FIGURES_TEX", "false") === false
    @test value_of("FIGURES_COMPILE", "true") === true
    @testset "colours" begin
        @test value_of("PLOT_COLOUR_MAP", "\"crimson\"") === :crimson
        @test value_of("PLOT_COLOUR_MAP", "\"antiquewhite4\"") === :antiquewhite4
        @test value_of("PLOT_COLOUR_DATA", "\"#ff0000\"") === Symbol("#ff0000")
        @test value_of("PLOT_COLOUR_DATA", "\"#A0b1C2\"") === Symbol("#A0b1C2")
        @test value_of("PLOT_TICK_COLOUR", "\"gray20\"") === :gray20
    end
    @testset "fonts" begin
        @test value_of("PLOT_TEXT_FONT", "\"Latin Modern Roman\"") == "Latin Modern Roman"
        @test value_of("PLOT_MATH_FONT", "\"Garamond-Math\"") == "Garamond-Math"
        @test value_of("PLOT_TEXT_FONT", "\"κ Font δ\"") == "κ Font δ"
        @test value_of("PLOT_TEXT_FONT", "\"" * "x" ^ 100 * "\"") == "x" ^ 100
    end
    @testset "formats" begin
        @test value_of("FIGURES_FORMATS", "[\"svg\"]") === (:svg,)
        @test value_of("FIGURES_FORMATS", "[\"svg\", \"pdf\"]") === (:pdf, :svg)
        @test value_of("FIGURES_FORMATS", "[\"svg\", \"png\", \"pdf\"]") ===
              (:pdf, :png, :svg)
    end
    @testset "tuples" begin
        @test value_of("CHAIN_START_RADII", "[1.0, 2.0, 3.0]") === (1.0, 2.0, 3.0)
        @test value_of("CHAIN_START_RADII", "[1, 2, 3]") === (1.0, 2.0, 3.0)
        @test value_of("MAP_JITTER_RADII", "[0.5, 1, 1e1]") === (0.5, 1.0, 10.0)
        @test value_of("PLOT_WIDTH_HEIGHT_CM", "[10, 7]") === (10.0, 7.0)
        @test value_of("PLOT_YLIM_LOG", "[0.5, 2]") === (0.5, 2.0)
        @test value_of("PLOT_PREVIEW_SIZE", "{\"width\": 80, \"height\": 24}") ===
              (width = 80, height = 24)
        @test value_of("PLOT_PREVIEW_SIZE", "{\"height\": 24, \"width\": 80}") ===
              (width = 80, height = 24)
        @test value_of("PLOT_COLOUR_BAND", "[\"red\", 0.5]") === (:red, 0.5)
        @test value_of("PLOT_COLOUR_BAND", "[\"red\", 0]") === (:red, 0.0)
        @test value_of("PLOT_COLOUR_BAND", "[\"red\", 1]") === (:red, 1.0)
        @test value_of("PLOT_COLOUR_HIST", "[\"antiquewhite4\", 0.6]") ===
              (:antiquewhite4, 0.6)
        @test value_of("BOUNDS_δρ₁₂", "[-5.0, 3.0]") === (-5.0, 3.0)
        @test value_of("EXCL_VOL_CORR_BOUNDS", "[0.9, 1.2]") === (0.9, 1.2)
    end
    @testset "values that agree with the rules that tie settings together" begin
        text = """
            {"model": {"BOUNDS_δρ₁₂": {"value": [-4.0, 4.0]}, "MODE_δρ₁₂": {"value": 3.5},
                       "SHELL_SAMPLE": {"value": 300}, "SASA_N_OCC": {"value": 300},
                       "EXCL_VOL_CORR_BOUNDS": {"value": [0.5, 2.0]},
                       "EXCL_VOL_CORR_EPS": {"value": 1.5}}}
            """
        r = try_load(text)
        @test r isa Dict
        @test r[:MODE_δρ₁₂] === 3.5
        @test r[:SASA_N_OCC] === 300
        @test r[:EXCL_VOL_CORR_EPS] === 1.5
    end
    @testset "several settings at once" begin
        text = """
        {"sampler": {"N_ADAPT": {"page": 1, "default": 300, "type": "int", "value": 500},
                     "N_DRAWS": {"value": 900}},
         "plots":   {"PLOT_COLOUR_MAP": {"value": "darkorange"},
                     "PLOT_HIST_BINS": {"value": 60}}}
        """
        r = try_load(text)
        @test (r[:N_ADAPT], r[:N_DRAWS], r[:PLOT_HIST_BINS], r[:PLOT_COLOUR_MAP]) ===
              (500, 900, 60, :darkorange)
        @test r[:RNG_SEED] == 0
    end
    @testset "a file the terminal interface wrote is read back" begin
        text = """
            {
              "sampler": {
                "N_ADAPT": {"page": 1, "default": 300, "limits": {"at_least": 1},
                            "value": 450}
              }
            }
            """
        @test try_load(text)[:N_ADAPT] === 450
    end
end

@testset "the problems say what is wrong" begin
    e = try_load(saved("N_ADAPT", "0"))
    @test e isa InvalidSettingsError
    msg = sprint(showerror, e)
    @test occursin("N_ADAPT", msg)
    @test occursin("at least 1", msg)
    @test occursin("terminal interface", msg)
    @test occursin("1 problem", msg)
    two = try_load(
        "{\"sampler\": {\"N_ADAPT\": {\"value\": 0}, \"N_DRAWS\": {\"value\": \"x\"}}}")
    @test length(two.problems) == 2
    @test occursin("2 problems", sprint(showerror, two))
    @testset "a warning is printed for each problem" begin
        with_file(saved("N_ADAPT", "0")) do path
            warned = r"invalid setting: N_ADAPT"
            @test_logs (:warn, warned) begin
                @test_throws InvalidSettingsError load_settings(path)
            end
        end
        with_file("{ nonsense") do path
            @test_logs (:warn, r"cannot be read") begin
                @test_throws InvalidSettingsError load_settings(path)
            end
        end
    end
end

@testset "a file that is not settings" begin
    for text in
        ("", "   \n", "{", "}", "[1, 2", "{\"a\"}", "{\"a\": 1,}", "garbage", "1", "\"s\"",
        "[]", "[{}]", "null", "true", "{\"sampler\": 5}", "{\"sampler\": [1, 2]}",
        "{\"sampler\": \"x\"}", "{\"sampler\": {\"N_ADAPT\": 5}}",
        "{\"sampler\": {\"N_ADAPT\": [1]}}", "{\"sampler\": {\"N_ADAPT\": null}}",
        "{\"sampler\": null}", "{\"sampler\": {\"N_ADAPT\": {\"value\": 0}}",
        "{\"sampler\": {\"N_ADAPT\": {\"value\"}}}",
        "{\"sampler\": {\"VAL_SIGMA\": {\"value\": 1e999}}}",
        "{\"sampler\": {\"N_ADAPT\": {\"value\": :}}}",
        "{\"sampler\": {\"N_ADAPT\": {\"value\": 99999999999999999999}}}")
        r = try_load(text)
        @test r isa InvalidSettingsError
    end
    @testset "bytes that are no text" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.json")
            write(path, UInt8[0xff, 0xfe, 0x7b, 0x7d, 0x80])
            r = with_logger(NullLogger()) do
                try
                    load_settings(path)
                catch e
                    e
                end
            end
            @test r isa InvalidSettingsError
        end
    end
    @testset "a directory in place of the file is no settings file" begin
        mktempdir() do dir
            @test load_settings(joinpath(dir, "missing.json")) isa Dict
        end
    end
end

@testset "rules that tie settings together" begin
    @testset "every rule of the Params files is checked on the defaults" begin
        defaults = Dict{Symbol,Any}(n => _setting_default(n) for n in _setting_names())
        @test !isempty(_merged_relations())
        for r in _merged_relations()
            @test _relation_problem(r, defaults) === nothing
        end
    end
    @testset "a rule that is broken is reported" begin
        defaults = Dict{Symbol,Any}(n => _setting_default(n) for n in _setting_names())
        broke(name, v) = merge(defaults, Dict(name => v))
        problems(vals) = [
            r.setting for r in _merged_relations()
            if _relation_problem(r, vals) !== nothing
        ]
        @test problems(broke(:MODE_δρ₁₂, 9.0)) == [:MODE_δρ₁₂]
        @test problems(broke(:SASA_N_OCC, 999)) == [:SASA_N_OCC]
        @test problems(broke(:BOUNDS_δρ₁₂, (3.0, 1.0))) == [:BOUNDS_δρ₁₂, :MODE_δρ₁₂]
        @test problems(broke(:EXCL_VOL_CORR_EPS, 5.0)) == [:EXCL_VOL_CORR_EPS]
        @test problems(broke(:PLOT_COLOUR_HIST, (:red, 3.0))) == [:PLOT_COLOUR_HIST]
        @test problems(defaults) == Symbol[]
    end
    @testset "two saved values that break a rule together are both named" begin
        r = try_load(
            "{\"model\": {\"SASA_N_OCC\": {\"value\": 200}, " *
            "\"SHELL_SAMPLE\": {\"value\": 100}}}")
        @test r isa InvalidSettingsError
        @test any(p -> startswith(p, "SASA_N_OCC"), r.problems)
        r2 = try_load("{\"model\": {\"BOUNDS_δρ₁₂\": {\"value\": [-3.0, 0.5]}}}")
        @test r2 isa InvalidSettingsError
        @test any(p -> occursin("MODE_δρ₁₂", p), r2.problems)
    end
end

@testset "the settings file path" begin
    mktempdir() do dir
        withenv("BAYSOL_HOME" => dir) do
            @test settings_file() == joinpath(dir, "settings.json")
            write(settings_file(), saved("N_ADAPT", "777"))
            @test load_settings()[:N_ADAPT] === 777
            write(settings_file(), saved("N_ADAPT", "-1"))
            with_logger(NullLogger()) do
                @test_throws InvalidSettingsError load_settings()
            end
        end
        withenv("BAYSOL_HOME" => "relative/dir") do
            @test !startswith(settings_file(), "relative")
            @test endswith(settings_file(), joinpath("baysol", "settings.json"))
        end
        withenv("BAYSOL_HOME" => "   ") do
            @test endswith(settings_file(), joinpath("baysol", "settings.json"))
        end
    end
end

# Junk that can be written where a value is expected.
const JUNK = ["null", "true", "false", "0", "1", "-1", "2.5", "1e999", "\"\"", "\"x\"",
    "\"#ff0000\"", "\"pdf\"", "\"red\"", "\"notacolour\"", "[]", "[1]", "[1, 2]",
    "[1, 2, 3]", "[\"red\", 0.5]", "[\"pdf\", \"png\"]", "{}",
    "{\"width\": 1, \"height\": 2}", "{\"a\": 1}", "[[1]]",
    "\"" * "y" ^ 120 * "\"", "99999", "-0.0", "[0, 0, 0]", "[null, null]",
    "99999999999999999999"]

@testset "fuzzing the saved value of every setting" begin
    P = BAYSOL.Pipeline
    names = _setting_names()
    @test length(names) == 95
    for n in names
        default = _setting_default(n)
        kind = setting_kind(n, default)
        for junk in JUNK
            r = try_load(saved(String(n), junk))
            if r isa InvalidSettingsError
                @test !isempty(r.problems)
            else
                v = r[n]
                if kind === :int
                    @test v isa Int
                elseif kind === :float
                    @test v isa Float64 && isfinite(v)
                elseif kind === :bool
                    @test v isa Bool
                elseif kind === :optional_float
                    @test v === nothing || (v isa Float64 && isfinite(v))
                elseif kind === :optional_int
                    @test v === nothing || v isa Int
                elseif kind === :ranges
                    @test v isa Tuple && all(x -> x isa Tuple{Float64,Float64}, v)
                    @test all(x -> 0 <= x[1] < x[2], v)
                elseif kind === :strings
                    @test v isa Tuple && all(x -> x isa String && length(x) == 1, v)
                    @test allunique(v)
                elseif kind === :colours
                    @test v isa Tuple && !isempty(v) && all(x -> x isa Symbol, v)
                    @test all(P._is_colour, v)
                elseif kind === :markers
                    @test v isa Tuple && !isempty(v) && all(x -> x isa Symbol, v)
                    @test all(in(P.PLOT_MARKER_NAMES), v)
                elseif kind === :sizes
                    @test v isa Tuple && !isempty(v) && all(x -> x isa Tuple{Int,Int}, v)
                    @test all(k -> v[k][1] > v[k-1][1] && v[k][2] > v[k-1][2], 2:length(v))
                elseif kind === :font
                    @test v isa String && !isempty(strip(v))
                elseif kind === :path
                    @test v isa String && !any(iscntrl, v) && v == strip(v)
                elseif kind === :colour
                    @test v isa Symbol
                elseif kind === :set
                    @test v isa Tuple && !isempty(v) && allunique(v)
                    @test all(x -> x in _merged_table(:SETTING_CHOICES)[n], v)
                else
                    @test length(v) == length(default)
                    @test v isa Union{Tuple,NamedTuple}
                end
                # whatever was accepted respects the limits and the rules
                lim = get(_merged_table(:SETTING_LIMITS), n, (;))
                for (k, ok_) in ((:above, >), (:below, <), (:at_least, >=), (:at_most, <=))
                    haskey(lim, k) && v !== nothing && @test ok_(v, lim[k])
                end
            end
        end
    end
end

"A text with `k` random edits (delete, duplicate or replace a character, or insert junk)."
function mutate(rng, text::String, k)
    chars = collect(text)
    pool = collect("{}[]\":, \n\\1e-+.aA\u00e9")
    for _ in 1:k
        isempty(chars) && break
        i = rand(rng, 1:length(chars))
        op = rand(rng, 1:4)
        if op == 1
            deleteat!(chars, i)
        elseif op == 2
            insert!(chars, i, chars[i])
        elseif op == 3
            chars[i] = rand(rng, pool)
        else
            insert!(chars, i, rand(rng, pool))
        end
    end
    return String(chars)
end

@testset "fuzzing the text of the file" begin
    rng = MersenneTwister(20261101)
    base = """
    {"sampler": {"N_ADAPT": {"page": 1, "default": 300, "value": 450},
                 "RNG_SEED": {"value": -3}},
     "model": {"BOUNDS_δρ₁₂": {"value": [-5.0, 3.0]}, "MODE_δρ₁₂": {"value": 1.5}},
     "output": {"FIGURES_FORMATS": {"value": ["pdf", "svg"]},
                "FIGURES_TEX": {"value": false}},
     "plots": {"PLOT_COLOUR_MAP": {"value": "crimson"},
               "PLOT_PREVIEW_SIZE": {"value": {"width": 80, "height": 24}},
               "PLOT_COLOUR_BAND": {"value": ["darkorange", 0.2]},
               "PLOT_TEXT_FONT": {"value": "Latin Modern Roman"}}}
    """
    @test ok(base)
    accepted = 0
    for trial in 1:1500
        text = mutate(rng, base, rand(rng, 1:6))
        r = try
            with_file(text) do path
                with_logger(NullLogger()) do
                    load_settings(path)
                end
            end
        catch e
            e
        end
        @test (r isa Dict{Symbol,Any}) || (r isa InvalidSettingsError)
        if r isa Dict
            accepted += 1
            @test length(r) == 95
            @test r[:N_ADAPT] isa Int && r[:N_ADAPT] >= 1
            @test r[:RNG_SEED] isa Int
            @test r[:FIGURES_TEX] isa Bool
            @test r[:PLOT_PREVIEW_SIZE] isa NamedTuple
            @test r[:BOUNDS_δρ₁₂][1] < r[:MODE_δρ₁₂] < r[:BOUNDS_δρ₁₂][2]
            @test 0 <= r[:PLOT_COLOUR_BAND][2] <= 1
        end
    end
    @test 0 < accepted < 1500            # some edits are harmless, most break the file
end

@testset "random garbage never crashes the reader" begin
    rng = MersenneTwister(7)
    alphabet = collect("{}[]\":, \n\\0123456789eE+-.abcxyztruefalsnl\u00e9\u03b4")
    for _ in 1:2000
        text = String(rand(rng, alphabet, rand(rng, 0:60)))
        r = try
            _read_json(text)
            :parsed
        catch e
            e
        end
        @test r === :parsed || r isa ArgumentError
    end
end

# The cases the terminal interface judges too (test/fixtures/settings/cases.json): the same
# file is read by the interface's validation tests, so the two sides cannot drift apart.
_plain(x::Tuple) = Any[_plain(y) for y in x]
_plain(x::AbstractVector) = Any[_plain(y) for y in x]
_plain(x::NamedTuple) = Dict{Symbol,Any}(k => _plain(v) for (k, v) in pairs(x))
_plain(x::AbstractDict) = Dict{Symbol,Any}(Symbol(k) => _plain(v) for (k, v) in x)
_plain(x::Symbol) = String(x)
_plain(x) = x

@testset "the cases both sides judge alike" begin
    fixture = _read_json(
        read(joinpath(@__DIR__, "..", "..", "fixtures", "settings", "cases.json"), String),
    )
    cases = fixture[:cases]
    @test length(cases) > 200
    @test count(c -> c[:valid], cases) > 60
    @test count(c -> !c[:valid], cases) > 140
    @test length(unique(c[:setting] for c in cases)) >= 80
    for c in cases
        name = c[:setting]
        entries = Dict{Symbol,Any}(Symbol(name) => Dict{Symbol,Any}(:value => c[:value]))
        for (other, v) in get(c, :with, Dict{Symbol,Any}())
            entries[Symbol(other)] = Dict{Symbol,Any}(:value => v)
        end
        values, problems = BAYSOL.Pipeline._settings_from(
            Some(Dict{Symbol,Any}(:screen => entries)),
            "the fixture",
        )
        if c[:valid]
            @test isempty(problems)
            if haskey(c, :expect)
                @test _plain(values[Symbol(name)]) == _plain(c[:expect])
            end
        else
            @test !isempty(problems)
            @test any(p -> occursin(c[:mention], p), problems)
            @test any(p -> occursin(name, p), problems)
        end
    end
end

# ---------------------------------------------------------------------------
# every setting is a keyword of an entry point (the owner's rule: a user of the library
# passes what the terminal interface keeps in settings.json)
# ---------------------------------------------------------------------------

@testset "every setting is a keyword of an entry point" begin
    P = BAYSOL.Pipeline
    rows = P.SETTING_KEYWORDS
    # the keyword names of all methods of `f`
    kws(f) = Set(reduce(vcat, [Base.kwarg_decl(m) for m in methods(f)]))
    positional(f) = Set(reduce(vcat, [Base.method_argnames(m)[2:end] for m in methods(f)]))

    @testset "the table covers the catalog exactly" begin
        @test allunique(r.setting for r in rows)
        @test Set(r.setting for r in rows) == Set(_setting_names())
        @test length(rows) == 95
    end

    @testset "the keyword exists where the table says" begin
        for r in rows
            if r.entry === :seed_model
                @test r.keyword in kws(BAYSOL.seed_model)
            elseif r.entry === :run_model
                @test r.keyword in kws(BAYSOL.run_model)
            elseif r.entry === :results
                @test r.keyword in kws(BAYSOL.results)
            elseif r.entry === :run_project
                # a switch of the run alone (checked through run_project's overrides)
                @test r.keyword in kws(BAYSOL.run_project)
                @test !(r.keyword in kws(BAYSOL.results))
            elseif r.entry === :run_model_args
                # the positional `n_adapt` of run_model; `n_samples` is N_ADAPT + N_DRAWS
                @test :n_adapt in positional(BAYSOL.run_model) &&
                      :n_samples in positional(BAYSOL.run_model)
            elseif r.entry === :PlotStyle
                @test r.keyword in fieldnames(BAYSOL.PlotStyle)
            else
                @test false
            end
            # run_project takes every one that is not a field of the style
            if r.entry !== :PlotStyle
                @test r.keyword in kws(BAYSOL.run_project)
            end
        end
        @test :style in kws(BAYSOL.run_project) && :style in kws(BAYSOL.results)
        @test :font in kws(BAYSOL.results)
        # checked keywords (the new ones) are exactly the ones validated at the entry
        @test all(
            r -> r.entry in (:seed_model, :run_model, :results),
            filter(r -> r.check, rows),
        )
        # the 30 that had no keyword, 6 data ones, the terminal plot sizes, the plot dir,
        # the compiler
        @test count(r -> r.check, rows) == 39
    end

    defaults = load_settings(joinpath(tempdir(), "no", "such", "settings.json"))

    @testset "the helpers carry the defaults of the settings" begin
        for (helper, entry) in (
            (BAYSOL.seed_keywords, :seed_model), (BAYSOL.run_keywords, :run_model),
        )
            k = helper(defaults)
            mine = filter(r -> r.entry === entry, rows)
            @test collect(keys(k)) == [r.keyword for r in mine]
            for r in mine
                @test k[r.keyword] == _setting_default(r.setting)
            end
        end
        rk = BAYSOL.results_keywords(defaults)
        @test rk.table_sigfigs == 17 && rk.tex == true && rk.compile == false
        @test rk.formats == (:pdf,) && rk.style == BAYSOL.PlotStyle()
        @test BAYSOL.run_arguments(defaults) == (n_samples = 1000, n_adapt = 300)
        @test length(BAYSOL.seed_keywords(defaults)) == 24
        @test length(BAYSOL.run_keywords(defaults)) == 22
        # a changed setting is the keyword
        s = copy(defaults)
        s[:MAP_N_STARTS] = 9
        s[:SASA_N_OCC] = 100
        s[:N_ADAPT] = 50
        s[:N_DRAWS] = 70
        s[:PLOT_LW_MAP] = 3.5
        @test BAYSOL.run_keywords(s).map_n_starts == 9
        @test BAYSOL.seed_keywords(s).sasa_n_occ == 100
        @test BAYSOL.run_arguments(s) == (n_samples = 120, n_adapt = 50)
        @test BAYSOL.results_keywords(s).style.lw_map == 3.5
        # the run keywords build the sampler options the defaults build
        ck = P._checked_keywords(
            :run_model,
            NamedTuple{Tuple(r.keyword for r in rows if r.entry === :run_model && r.check)}(
                Tuple(
                    BAYSOL.run_keywords(defaults)[r.keyword]
                    for r in rows if r.entry === :run_model && r.check
                )),
        )
        a, b = BAYSOL.Inference.SamplerOptions(; ck...), BAYSOL.Inference.SamplerOptions()
        @test all(f -> getfield(a, f) == getfield(b, f), fieldnames(typeof(a)))
    end

    @testset "the keywords are checked as load_settings checks the settings" begin
        chk = P._checked_keywords
        # the defaults pass and come back unchanged, in the types of the defaults
        ok = chk(
            :seed_model,
            (; shell_sample = 256, sasa_n_occ = 104, φ_max = 2,
                bounds_δρ₁₂ = (-10, 2), mode_δρ₁₂ = 1, excl_vol_corr_bounds = [0.8, 1.3]),
        )
        @test ok.shell_sample === 256 && ok.φ_max === 2.0
        @test ok.bounds_δρ₁₂ === (-10.0, 2.0) && ok.excl_vol_corr_bounds === (0.8, 1.3)
        # one bad value, the line is the one load_settings gives
        for (entry, kw, setting, words) in (
            (:run_model, (; map_n_starts = 0), "MAP_N_STARTS", "at least 1"),
            (:run_model, (; map_jitter_radii = (3.0, -1.0, 12.0)), "MAP_JITTER_RADII",
                "above 0"),
            (:run_model, (; optimum_chain_fraction = 1.5), "OPTIMUM_CHAIN_FRACTION",
                "at most 1"),
            (:run_model, (; chain_start_radii = (4.0, 10.0)), "CHAIN_START_RADII",
                "3 parts"),
            (:run_model, (; harvest_cover = -1), "HARVEST_COVER", "at least 0"),
            (:run_model, (; basin_restart_nats = NaN), "BASIN_RESTART_NATS", "finite"),
            (:run_model, (; retry_n_draws = 1.5), "RETRY_N_DRAWS", "whole number"),
            (:seed_model, (; φ_max = 0), "φ_max", "above 0"),
            (:seed_model, (; shell_min_points = 0), "SHELL_MIN_POINTS", "at least 1"),
            (:seed_model, (; bead_ray_range = -2.0), "BEAD_RAY_RANGE", "above 0"),
            (:results, (; table_sigfigs = 0), "TABLE_SIGFIGS", "at least 1"),
            (:results, (; table_sigfigs = 18), "TABLE_SIGFIGS", "at most 17"),
        )
            e = try
                chk(entry, kw)
            catch err
                err
            end
            @test e isa InvalidSettingsError
            @test length(e.problems) == 1 && startswith(e.problems[1], setting * " = ")
            @test occursin(words, e.problems[1])
            # the same text as `load_settings` for the same value
            name = Symbol(setting)
            msg = try
                _checked_value(name, P._setting_input(first(values(kw))))
                ""
            catch err
                err.msg
            end
            # (a rule between settings, not a limit of one, is the relations' text)
            @test isempty(msg) || endswith(e.problems[1], ": " * msg)
        end
        # the relations between settings, with the same lines
        for (kw, setting, words) in (
            ((; bounds_δρ₁₂ = (-10.0, 2.0), mode_δρ₁₂ = 5.0), "MODE_δρ₁₂",
                "strictly inside BOUNDS_δρ₁₂"),
            ((; bounds_δρ₁₂ = (2.0, -10.0), mode_δρ₁₂ = 1.0), "BOUNDS_δρ₁₂",
                "first part below its second"),
            ((; excl_vol_corr_bounds = (0.8, 0.82), excl_vol_corr_eps = 0.05),
                "EXCL_VOL_CORR_EPS", "at most the width"),
            ((; shell_sample = 64, sasa_n_occ = 100), "SASA_N_OCC",
                "at most SHELL_SAMPLE"),
        )
            e = try
                chk(:seed_model, kw)
            catch err
                err
            end
            @test e isa InvalidSettingsError
            @test any(p -> startswith(p, setting * " = ") && occursin(words, p), e.problems)
        end
        # all the problems at once; the error says the values were keywords
        e = try
            chk(:run_model, (; map_n_starts = 0, harvest_cover = -1))
        catch err
            err
        end
        @test length(e.problems) == 2
        @test occursin("passed as keywords", sprint(showerror, e))
        # the settings-file error keeps its hint
        @test occursin("terminal interface", sprint(showerror, InvalidSettingsError(["x"])))
        # a valid pair is fine where each alone would not be
        @test chk(:seed_model, (; shell_sample = 64, sasa_n_occ = 64)).sasa_n_occ == 64
        @test chk(:seed_model, (; bounds_δρ₁₂ = (-4, 6), mode_δρ₁₂ = 5)).mode_δρ₁₂ === 5.0
    end

    @testset "run_project's overrides are checked together with the file's settings" begin
        s = copy(defaults)
        P._apply_keywords!(
            s,
            (; map_n_starts = 9, tex = nothing, formats = (:pdf, :svg),
                n_draws = 5, mode_δρ₁₂ = nothing),
        )
        @test s[:MAP_N_STARTS] == 9 && s[:N_DRAWS] == 5 && s[:TARGET_ACCEPT] == 95
        @test s[:FIGURES_FORMATS] == (:pdf, :svg)
        # a rule against a value of the file is caught too
        t = copy(defaults)
        t[:SHELL_SAMPLE] = 100
        @test_throws InvalidSettingsError P._apply_keywords!(t, (; sasa_n_occ = 104))
        @test t[:SASA_N_OCC] == 104                       # unchanged on failure
        u = copy(defaults)
        @test_throws InvalidSettingsError P._apply_keywords!(u, (; thickness = -1.0))
        @test u[:SHELL_THICKNESS] == 3.0
    end
end

# ---------------------------------------------------------------------------
# the settings of the comparison figure: a switch, two ordered lists (colours and
# markers: the kinds `:colours` and `:markers`), a line width
# ---------------------------------------------------------------------------

@testset "the settings of the comparison figure" begin
    P = BAYSOL.Pipeline
    rows = Dict(r.setting => r for r in P.SETTING_KEYWORDS)
    defaults = load_settings(joinpath(tempdir(), "no", "such", "settings.json"))

    @testset "catalog rows, kinds and defaults" begin
        @test rows[:PLOT_COMPARE].entry === :run_project &&
              rows[:PLOT_COMPARE].keyword === :plot_compare
        for (s, k) in ((:PLOT_COMPARE_COLOURS, :colors_compare),
            (:PLOT_COMPARE_MARKERS, :markers_compare), (:PLOT_LW_COMPARE, :lw_compare))
            @test rows[s].entry === :PlotStyle && rows[s].keyword === k
            @test k in fieldnames(BAYSOL.PlotStyle)
        end
        @test setting_kind(:PLOT_COMPARE, true) === :bool
        @test setting_kind(:PLOT_COMPARE_COLOURS, ()) === :colours
        @test setting_kind(:PLOT_COMPARE_MARKERS, ()) === :markers
        @test setting_kind(:PLOT_LW_COMPARE, 1.2) === :float
        @test defaults[:PLOT_COMPARE] === true && defaults[:PLOT_LW_COMPARE] == 1.2
        @test length(defaults[:PLOT_COMPARE_COLOURS]) >= 8
        @test allunique(defaults[:PLOT_COMPARE_COLOURS])
        @test all(P._is_colour, defaults[:PLOT_COMPARE_COLOURS])
        @test all(in(P.PLOT_MARKER_NAMES), defaults[:PLOT_COMPARE_MARKERS])
        @test P._merged_table(:SETTING_CHOICES).PLOT_COMPARE_MARKERS === P.PLOT_MARKER_NAMES
        # the style carries them, and the settings reach the style
        style = BAYSOL.results_keywords(defaults).style
        @test style == BAYSOL.PlotStyle()
        @test style.colors_compare == P.PLOT_COMPARE_COLOURS &&
              style.lw_compare == P.PLOT_LW_COMPARE
        s = copy(defaults)
        s[:PLOT_COMPARE_COLOURS] = (:red, :blue)
        s[:PLOT_COMPARE_MARKERS] = (:square, :square, Symbol("+"))
        s[:PLOT_LW_COMPARE] = 2.5
        st = BAYSOL.results_keywords(s).style
        @test st.colors_compare == (:red, :blue) && st.lw_compare == 2.5
        @test st.markers_compare == (:square, :square, Symbol("+"))
    end

    @testset "values are checked as the other settings are" begin
        v(name, text) = try_load(saved(name, text))
        # an ordered list: repeats and any order are kept
        r = v("PLOT_COMPARE_COLOURS", "[\"navy\", \"#00ff00\", \"navy\"]")
        @test r[:PLOT_COMPARE_COLOURS] == (:navy, Symbol("#00ff00"), :navy)
        r = v("PLOT_COMPARE_MARKERS", "[\"x\", \"o\", \"x\", \"square*\"]")
        @test r[:PLOT_COMPARE_MARKERS] == (:x, :o, :x, Symbol("square*"))
        for junk in ("[]", "\"red\"", "[\"notacolour\"]", "[1]", "[[\"red\"]]", "null")
            @test v("PLOT_COMPARE_COLOURS", junk) isa InvalidSettingsError
        end
        for junk in ("[]", "\"x\"", "[\"circle\"]", "[\"o\", 3]", "null", "[\"*\", \"\"]")
            @test v("PLOT_COMPARE_MARKERS", junk) isa InvalidSettingsError
        end
        @test v("PLOT_COMPARE", "false")[:PLOT_COMPARE] === false
        @test v("PLOT_COMPARE", "1") isa InvalidSettingsError
        @test v("PLOT_LW_COMPARE", "-1") isa InvalidSettingsError
        @test v("PLOT_LW_COMPARE", "0")[:PLOT_LW_COMPARE] == 0.0
        # run_project's keyword overrides the setting
        s = copy(defaults)
        P._apply_keywords!(s, (; plot_compare = false))
        @test s[:PLOT_COMPARE] === false
        P._apply_keywords!(s, (; plot_compare = nothing))      # nothing: take the setting
        @test s[:PLOT_COMPARE] === false
        # a PlotStyle built by hand is checked too
        @test_throws ArgumentError BAYSOL.results(
            nothing, ([1.0], [1.0], [1.0]);
            style = BAYSOL.PlotStyle(; markers_compare = (:circle,)),
        )
        @test_throws ArgumentError BAYSOL.Pipeline._check_style(
            BAYSOL.PlotStyle(; colors_compare = ()),
        )
        @test_throws ArgumentError BAYSOL.Pipeline._check_style(
            BAYSOL.PlotStyle(; colors_compare = (:notacolour,)),
        )
        @test_throws ArgumentError BAYSOL.Pipeline._check_style(
            BAYSOL.PlotStyle(; lw_compare = -1.0),
        )
    end
end

# ---------------------------------------------------------------------------
# the sizes of the terminal plots (kind `:sizes`), and which settings are of one model
# ---------------------------------------------------------------------------

@testset "the sizes of the terminal plots" begin
    P = BAYSOL.Pipeline
    rows = Dict(r.setting => r for r in P.SETTING_KEYWORDS)
    defaults = load_settings(joinpath(tempdir(), "no", "such", "settings.json"))

    @testset "catalog row, kind and default" begin
        @test rows[:PLOT_TUI_SIZES].entry === :results &&
              rows[:PLOT_TUI_SIZES].keyword === :plot_tui_sizes &&
              rows[:PLOT_TUI_SIZES].check
        @test setting_kind(:PLOT_TUI_SIZES, ()) === :sizes
        @test :PLOT_TUI_SIZES in _setting_names()
        d = defaults[:PLOT_TUI_SIZES]
        @test d == P.PLOT_TUI_SIZES && d isa Tuple && all(x -> x isa Tuple{Int,Int}, d)
        # the default is valid, and the terminal's CLI size is its own setting
        @test P._checked_value(:PLOT_TUI_SIZES, collect(collect.(d))) == d
        @test P.PLOT_PREVIEW_SIZE == (width = 70, height = 18)
        @test BAYSOL.results_keywords(defaults).plot_tui_sizes == d
    end

    @testset "valid values and the JSON round trip" begin
        v(text) = try_load(saved("PLOT_TUI_SIZES", text, screen = "plots"))
        r = v("[[30, 4]]")
        @test r[:PLOT_TUI_SIZES] == ((30, 4),)
        r = v("[[24, 3], [25, 4], [400, 100]]")
        @test r[:PLOT_TUI_SIZES] == ((24, 3), (25, 4), (400, 100))
        # what the harvest writes is what the loader reads back
        text = JSON3.write(collect(collect.(P.PLOT_TUI_SIZES)))
        @test v(text)[:PLOT_TUI_SIZES] == P.PLOT_TUI_SIZES
        # a tuple of tuples (library use) is the same list
        @test P._checked_value(:PLOT_TUI_SIZES, ((60, 5), (90, 8))) == ((60, 5), (90, 8))
    end

    @testset "invalid values are refused with a message" begin
        v(text) = try_load(saved("PLOT_TUI_SIZES", text, screen = "plots"))
        for junk in ("[]", "null", "\"big\"", "5", "[[30]]", "[[30, 4, 1]]", "[30, 4]",
            "[[30.5, 4]]", "[[\"30\", 4]]", "[[true, 4]]",
            "[[23, 4]]", "[[30, 2]]", "[[401, 4]]", "[[30, 101]]", "[[0, 0]]",
            "[[-30, 4]]", "[[40, 5], [40, 6]]", "[[40, 5], [50, 5]]",
            "[[50, 6], [40, 5]]", "[[40, 5], [60, 7], [59, 9]]")
            r = v(junk)
            @test r isa InvalidSettingsError
            r isa InvalidSettingsError && @test any(
                p -> startswith(p, "PLOT_TUI_SIZES = "), r.problems,
            )
        end
        e = v("[[40, 5], [40, 6]]")
        @test occursin("must grow in both width and height", e.problems[1])
        e = v("[[23, 4]]")
        @test occursin("a width of 24 to 400 and a height of 3 to 100", e.problems[1])
        # the keyword of results is checked the same way
        res = ([1.0, 2.0], [1.0, 1.0], [0.1, 0.1])
        @test_throws InvalidSettingsError BAYSOL.results(
            nothing, res; plot_tui_sizes = ((50, 6), (50, 7)),
        )
    end
end

@testset "which settings may differ per model" begin
    P = BAYSOL.Pipeline
    rows = P.SETTING_KEYWORDS
    per_fit = (:seed_model, :run_model, :run_model_args)
    # the run-level list is the settings of the entries that are not a fit's own, and a
    # new setting has to be placed in one or the other
    run_level = Set(r.setting for r in rows if !(r.entry in per_fit))
    @test run_level == Set(n for n in _setting_names() if P._is_run_level(n))
    @test Set(P.RUN_LEVEL_SETTINGS) ⊆ run_level
    @test all(n -> startswith(String(n), "PLOT_") || n in P.RUN_LEVEL_SETTINGS, run_level)
    for n in (:PLOT_COMPARE, :PLOT_COMPARE_COLOURS, :PLOT_COMPARE_MARKERS,
        :PLOT_LW_COMPARE, :PLOT_TUI_SIZES, :PLOT_PREVIEW_SIZE, :FIGURES_TEX,
        :FIGURES_COMPILE, :FIGURES_FORMATS, :TABLE_SIGFIGS, :FIGURES_DIR,
        :FIGURES_COMPILER)
        @test P._is_run_level(n)
    end
    for n in (:Q_MIN, :Q_MAX, :SIGMA_SCALE, :EXCLUDE_Q, :CHAINS, :MODEL, :ADD_HYDROGENS,
        :LMAX, :RNG_SEED, :VAL_SIGMA, :TARGET_ACCEPT, :N_CHAINS, :N_ADAPT, :N_DRAWS,
        :SHELL_THICKNESS, :MAP_N_STARTS, :BOUNDS_δρ₁₂)
        @test !P._is_run_level(n)
    end
end
