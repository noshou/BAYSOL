# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises tui/src/store/settings-file.jl: the reader of settings.json and `loadSettings`,
# which checks every saved value before any code uses one. Valid files of every kind of
# setting, the cases shared with the terminal interface (test/fixtures/settings/cases.json),
# corrupt files (bad JSON, wrong types, the rules that tie settings together), and seeded
# fuzzing: whatever is written into the file, `loadSettings` either returns settings of the
# right types or throws an `InvalidSettingsError`, and nothing else.
include(joinpath(@__DIR__, "julia-setup.jl"))

using Logging
using Random
using BAYSOL.BulkElectronDensity: JSON3
using BAYSOL.Pipeline: InvalidSettingsError, _checkedValue, settingKind,
    _settingNames, _settingDefault, _mergedTable, _mergedRelations, _relationProblem
using Main.BAYSOLRun: loadSettings, settingsFile, _readJson

"Runs `f(path)` on a settings file holding `text`."
function withFile(f, text::AbstractString)
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

"`loadSettings` on `text`, with its warnings silenced: the settings or the error."
function tryLoad(text)
    withFile(text) do path
        with_logger(NullLogger()) do
            try
                loadSettings(path)
            catch e
                e isa InvalidSettingsError ? e : rethrow()
            end
        end
    end
end

ok(text) = (r = tryLoad(text); r isa AbstractDict)
bad(text) = tryLoad(text) isa InvalidSettingsError
valueOf(name, text) = tryLoad(saved(name, text))[Symbol(name)]

@testset "the JSON reader" begin
    @testset "values" begin
        @test _readJson("42") === 42
        @test _readJson("-7") === -7
        @test _readJson("3.5") === 3.5
        @test _readJson("1e-3") === 1.0e-3
        @test _readJson("1.0E+2") == 100.0
        @test _readJson("true") === true
        @test _readJson("false") === false
        @test _readJson("null") === nothing
        @test _readJson("\"hi\"") == "hi"
        @test _readJson("\"a\\nb\\t\\\"q\\\" \\\\ \\u00e9\"") == "a\nb\t\"q\" \\ é"
        @test _readJson("\"κ_δρ₁₂ Gyre\"") == "κ_δρ₁₂ Gyre"
        @test _readJson("[1, 2.0, \"a\", null]") == Any[1, 2.0, "a", nothing]
        @test _readJson("[]") == Any[]
        @test _readJson("{}") == Dict{Symbol,Any}()
        @test _readJson("{\"a\": 1, \"b\": [2, 3]}") ==
              Dict{Symbol,Any}(:a => 1, :b => Any[2, 3])
        @test _readJson("{\"a\": {\"b\": {\"c\": 1}}}")[:a][:b][:c] == 1
        @test _readJson("[1, {\"a\": [2]}]")[2] isa Dict{Symbol,Any}
        @test _readJson("  [1,\n 2 ]  ") == Any[1, 2]
    end
    @testset "malformed text is an ArgumentError" begin
        for text in (
            "", "   ", "[", "]", "}", ")", "{", "{\"a\"}", "[1, 2", "\"open",
            "[1 2]", "1 2", ":", "foo", "NaN", "Infinity", "1.2.3", "'a", "{\"a\": 1",
            "{} x", "[1,2]]", "[[[", "[1, {\"a\"}]", "[1,]", "{,}", "{\"a\": 1,}", "--1",
            "\"\\q\"",
        )
            @test_throws ArgumentError _readJson(text)
        end
    end
end

@testset "settings that are not saved are defaults" begin
    defaults = defaultSettings()
    @test defaults isa Dict{Symbol,Any}
    @test Set(keys(defaults)) == Set(_settingNames())
    @test length(defaults) == 96
    for n in _settingNames()
        @test defaults[n] == _settingDefault(n)
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
        @test tryLoad(text)[:RNG_SEED] == 0
    end
    @testset "the defaults file that the terminal interface reads" begin
        # tui/assets/data/default_settings.json is harvested from the source
        # (`bysl harvest defaults`): the same settings, each with the same default
        file = joinpath(@__DIR__, "..", "assets", "data",
            "default_settings.json")
        harvested = JSON3.read(read(file, String))
        @test Set(keys(harvested)) == Set(_settingNames())
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
    @test valueOf("N_ADAPT", "450") === 450
    @test valueOf("N_ADAPT", "1") === 1
    @test valueOf("RNG_SEED", "-12") === -12
    @test valueOf("RNG_SEED", "0") === 0
    @test valueOf("TARGET_ACCEPT", "50") === 50
    @test valueOf("TARGET_ACCEPT", "99") === 99
    @test valueOf("TABLE_SIGFIGS", "1") === 1
    @test valueOf("TABLE_SIGFIGS", "17") === 17
    @test valueOf("HARVEST_COVER", "0") === 0
    @test valueOf("OPTIMUM_CHAIN_CAP", "0") === 0
    @testset "a float setting takes a whole number as a float" begin
        @test valueOf("VAL_SIGMA", "3") === 3.0
        @test valueOf("VAL_SIGMA", "2.5") === 2.5
        @test valueOf("VAL_SIGMA", "1e-3") === 0.001
        @test valueOf("PLOT_LW_MAP", "0") === 0.0
        @test valueOf("PROBE_RADIUS", "0") === 0.0
        @test valueOf("OPTIMUM_CHAIN_FRACTION", "1") === 1.0
        @test valueOf("OPTIMUM_CHAIN_FRACTION", "0.25") === 0.25
        @test valueOf("PLOT_XTICK_ANGLE", "-30") === -30.0
    end
    @test valueOf("FIGURES_TEX", "false") === false
    @test valueOf("FIGURES_COMPILE", "true") === true
    @testset "colours" begin
        @test valueOf("PLOT_COLOUR_MAP", "\"crimson\"") === :crimson
        @test valueOf("PLOT_COLOUR_MAP", "\"antiquewhite4\"") === :antiquewhite4
        @test valueOf("PLOT_COLOUR_DATA", "\"#ff0000\"") === Symbol("#ff0000")
        @test valueOf("PLOT_COLOUR_DATA", "\"#A0b1C2\"") === Symbol("#A0b1C2")
        @test valueOf("PLOT_TICK_COLOUR", "\"gray20\"") === :gray20
    end
    @testset "fonts" begin
        @test valueOf("PLOT_TEXT_FONT", "\"Latin Modern Roman\"") == "Latin Modern Roman"
        @test valueOf("PLOT_MATH_FONT", "\"Garamond-Math\"") == "Garamond-Math"
        @test valueOf("PLOT_TEXT_FONT", "\"κ Font δ\"") == "κ Font δ"
        @test valueOf("PLOT_TEXT_FONT", "\"" * "x" ^ 100 * "\"") == "x" ^ 100
    end
    @testset "formats" begin
        @test valueOf("FIGURES_FORMATS", "[\"svg\"]") === (:svg,)
        @test valueOf("FIGURES_FORMATS", "[\"svg\", \"pdf\"]") === (:pdf, :svg)
        @test valueOf("FIGURES_FORMATS", "[\"svg\", \"png\", \"pdf\"]") ===
              (:pdf, :png, :svg)
    end
    @testset "tuples" begin
        @test valueOf("CHAIN_START_RADII", "[1.0, 2.0, 3.0]") === (1.0, 2.0, 3.0)
        @test valueOf("CHAIN_START_RADII", "[1, 2, 3]") === (1.0, 2.0, 3.0)
        @test valueOf("MAP_JITTER_RADII", "[0.5, 1, 1e1]") === (0.5, 1.0, 10.0)
        @test valueOf("PLOT_WIDTH_HEIGHT_CM", "[10, 7]") === (10.0, 7.0)
        @test valueOf("PLOT_YLIM_LOG", "[0.5, 2]") === (0.5, 2.0)
        @test valueOf("PLOT_PREVIEW_SIZE", "{\"width\": 80, \"height\": 24}") ===
              (width = 80, height = 24)
        @test valueOf("PLOT_PREVIEW_SIZE", "{\"height\": 24, \"width\": 80}") ===
              (width = 80, height = 24)
        @test valueOf("PLOT_COLOUR_BAND", "[\"red\", 0.5]") === (:red, 0.5)
        @test valueOf("PLOT_COLOUR_BAND", "[\"red\", 0]") === (:red, 0.0)
        @test valueOf("PLOT_COLOUR_BAND", "[\"red\", 1]") === (:red, 1.0)
        @test valueOf("PLOT_COLOUR_HIST", "[\"antiquewhite4\", 0.6]") ===
              (:antiquewhite4, 0.6)
        @test valueOf("BOUNDS_δρ₁₂", "[-5.0, 3.0]") === (-5.0, 3.0)
        @test valueOf("EXCL_VOL_CORR_BOUNDS", "[0.9, 1.2]") === (0.9, 1.2)
    end
    @testset "values that agree with the rules that tie settings together" begin
        text = """
            {"model": {"BOUNDS_δρ₁₂": {"value": [-4.0, 4.0]}, "MODE_δρ₁₂": {"value": 3.5},
                       "SHELL_SAMPLE": {"value": 300}, "SASA_N_OCC": {"value": 300},
                       "EXCL_VOL_CORR_BOUNDS": {"value": [0.5, 2.0]},
                       "EXCL_VOL_CORR_EPS": {"value": 1.5}}}
            """
        r = tryLoad(text)
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
        r = tryLoad(text)
        @test (r[:N_ADAPT], r[:N_DRAWS], r[:PLOT_HIST_BINS], r[:PLOT_COLOUR_MAP]) ===
              (500, 900, 60, :darkorange)
        @test r[:RNG_SEED] == 0
    end
    @testset "a file the terminal interface wrote is read back" begin
        text = """
            {
              "sampler": {
                "N_ADAPT": {"page": 1, "default": 300, "limits": {"atLeast": 1},
                            "value": 450}
              }
            }
            """
        @test tryLoad(text)[:N_ADAPT] === 450
    end
end

@testset "the problems say what is wrong" begin
    e = tryLoad(saved("N_ADAPT", "0"))
    @test e isa InvalidSettingsError
    msg = sprint(showerror, e)
    @test occursin("N_ADAPT", msg)
    @test occursin("at least 1", msg)
    @test occursin("terminal interface", msg)
    @test occursin("1 problem", msg)
    two = tryLoad(
        "{\"sampler\": {\"N_ADAPT\": {\"value\": 0}, \"N_DRAWS\": {\"value\": \"x\"}}}")
    @test length(two.problems) == 2
    @test occursin("2 problems", sprint(showerror, two))
    @testset "a warning is printed for each problem" begin
        withFile(saved("N_ADAPT", "0")) do path
            warned = r"invalid setting: N_ADAPT"
            @test_logs (:warn, warned) begin
                @test_throws InvalidSettingsError loadSettings(path)
            end
        end
        withFile("{ nonsense") do path
            @test_logs (:warn, r"cannot be read") begin
                @test_throws InvalidSettingsError loadSettings(path)
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
        r = tryLoad(text)
        @test r isa InvalidSettingsError
    end
    @testset "bytes that are no text" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.json")
            write(path, UInt8[0xff, 0xfe, 0x7b, 0x7d, 0x80])
            r = with_logger(NullLogger()) do
                try
                    loadSettings(path)
                catch e
                    e
                end
            end
            @test r isa InvalidSettingsError
        end
    end
    @testset "a directory in place of the file is no settings file" begin
        mktempdir() do dir
            @test loadSettings(joinpath(dir, "missing.json")) isa Dict
        end
    end
end

@testset "rules that tie settings together" begin
    @testset "every rule of the Params files is checked on the defaults" begin
        defaults = Dict{Symbol,Any}(n => _settingDefault(n) for n in _settingNames())
        @test !isempty(_mergedRelations())
        for r in _mergedRelations()
            @test _relationProblem(r, defaults) === nothing
        end
    end
    @testset "a rule that is broken is reported" begin
        defaults = Dict{Symbol,Any}(n => _settingDefault(n) for n in _settingNames())
        broke(name, v) = merge(defaults, Dict(name => v))
        problems(vals) = [
            r.setting for r in _mergedRelations()
            if _relationProblem(r, vals) !== nothing
        ]
        @test problems(broke(:MODE_δρ₁₂, 9.0)) == [:MODE_δρ₁₂]
        @test problems(broke(:SASA_N_OCC, 999)) == [:SASA_N_OCC]
        @test problems(broke(:BOUNDS_δρ₁₂, (3.0, 1.0))) == [:BOUNDS_δρ₁₂, :MODE_δρ₁₂]
        @test problems(broke(:EXCL_VOL_CORR_EPS, 5.0)) == [:EXCL_VOL_CORR_EPS]
        @test problems(broke(:PLOT_COLOUR_HIST, (:red, 3.0))) == [:PLOT_COLOUR_HIST]
        @test problems(defaults) == Symbol[]
    end
    @testset "two saved values that break a rule together are both named" begin
        r = tryLoad(
            "{\"model\": {\"SASA_N_OCC\": {\"value\": 200}, " *
            "\"SHELL_SAMPLE\": {\"value\": 100}}}")
        @test r isa InvalidSettingsError
        @test any(p -> startswith(p, "SASA_N_OCC"), r.problems)
        r2 = tryLoad("{\"model\": {\"BOUNDS_δρ₁₂\": {\"value\": [-3.0, 0.5]}}}")
        @test r2 isa InvalidSettingsError
        @test any(p -> occursin("MODE_δρ₁₂", p), r2.problems)
    end
end

@testset "the settings file path" begin
    mktempdir() do dir
        withenv("BAYSOL_HOME" => dir) do
            @test settingsFile() == joinpath(dir, "settings.json")
            write(settingsFile(), saved("N_ADAPT", "777"))
            @test loadSettings()[:N_ADAPT] === 777
            write(settingsFile(), saved("N_ADAPT", "-1"))
            with_logger(NullLogger()) do
                @test_throws InvalidSettingsError loadSettings()
            end
        end
        withenv("BAYSOL_HOME" => "relative/dir") do
            @test !startswith(settingsFile(), "relative")
            @test endswith(settingsFile(), joinpath("baysol", "settings.json"))
        end
        withenv("BAYSOL_HOME" => "   ") do
            @test endswith(settingsFile(), joinpath("baysol", "settings.json"))
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
    R = BAYSOLRun
    names = _settingNames()
    @test length(names) == 96
    allLimits = _mergedTable(:SETTING_LIMITS)      # built once, not for every junk value
    allChoices = _mergedTable(:SETTING_CHOICES)
    for n in names
        default = _settingDefault(n)
        kind = settingKind(n, default)
        for junk in JUNK
            r = tryLoad(saved(String(n), junk))
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
                elseif kind === :optionalFloat
                    @test v === nothing || (v isa Float64 && isfinite(v))
                elseif kind === :optionalInt
                    @test v === nothing || v isa Int
                elseif kind === :ranges
                    @test v isa Tuple && all(x -> x isa Tuple{Float64,Float64}, v)
                    @test all(x -> 0 <= x[1] < x[2], v)
                elseif kind === :strings
                    @test v isa Tuple && all(x -> x isa String && length(x) == 1, v)
                    @test allunique(v)
                elseif kind === :colours
                    @test v isa Tuple && !isempty(v) && all(x -> x isa Symbol, v)
                    @test all(P._isColour, v)
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
                    @test all(x -> x in allChoices[n], v)
                else
                    @test length(v) == length(default)
                    @test v isa Union{Tuple,NamedTuple}
                end
                # whatever was accepted respects the limits and the rules
                lim = get(allLimits, n, (;))
                for (k, ok_) in ((:above, >), (:below, <), (:atLeast, >=), (:atMost, <=))
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
    trials = 300
    for trial in 1:trials
        text = mutate(rng, base, rand(rng, 1:6))
        r = try
            withFile(text) do path
                with_logger(NullLogger()) do
                    loadSettings(path)
                end
            end
        catch e
            e
        end
        @test (r isa Dict{Symbol,Any}) || (r isa InvalidSettingsError)
        if r isa Dict
            accepted += 1
            @test length(r) == 96
            @test r[:N_ADAPT] isa Int && r[:N_ADAPT] >= 1
            @test r[:RNG_SEED] isa Int
            @test r[:FIGURES_TEX] isa Bool
            @test r[:PLOT_PREVIEW_SIZE] isa NamedTuple
            @test r[:BOUNDS_δρ₁₂][1] < r[:MODE_δρ₁₂] < r[:BOUNDS_δρ₁₂][2]
            @test 0 <= r[:PLOT_COLOUR_BAND][2] <= 1
        end
    end
    @test 0 < accepted < trials          # some edits are harmless, most break the file
end

@testset "random garbage never crashes the reader" begin
    rng = MersenneTwister(7)
    alphabet = collect("{}[]\":, \n\\0123456789eE+-.abcxyztruefalsnl\u00e9\u03b4")
    for _ in 1:400
        text = String(rand(rng, alphabet, rand(rng, 0:60)))
        r = try
            _readJson(text)
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
    fixture = _readJson(
        read(
            joinpath(@__DIR__, "..", "..", "test", "fixtures", "settings", "cases.json"),
            String,
        ),
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
        values, problems = BAYSOLRun._settingsFrom(
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
# the settings of the comparison figure: a switch, two ordered lists (colours and
# markers: the kinds `:colours` and `:markers`), a line width
# ---------------------------------------------------------------------------

@testset "the settings of the comparison figure" begin
    P = BAYSOL.Pipeline
    R = BAYSOLRun
    rows = Dict(r.setting => r for r in P.SETTING_KEYWORDS)
    defaults = defaultSettings()

    @testset "catalog rows, kinds and defaults" begin
        @test rows[:PLOT_COMPARE].entry === :runProject &&
              rows[:PLOT_COMPARE].keyword === :plotCompare
        for (s, k) in ((:PLOT_COMPARE_COLOURS, :colorsCompare),
            (:PLOT_COMPARE_MARKERS, :markersCompare), (:PLOT_LW_COMPARE, :lwCompare))
            @test rows[s].entry === :PlotStyle && rows[s].keyword === k
            @test k in fieldnames(BAYSOL.PlotStyle)
        end
        @test settingKind(:PLOT_COMPARE, true) === :bool
        @test settingKind(:PLOT_COMPARE_COLOURS, ()) === :colours
        @test settingKind(:PLOT_COMPARE_MARKERS, ()) === :markers
        @test settingKind(:PLOT_LW_COMPARE, 1.2) === :float
        @test defaults[:PLOT_COMPARE] === true && defaults[:PLOT_LW_COMPARE] == 1.2
        @test length(defaults[:PLOT_COMPARE_COLOURS]) >= 8
        @test allunique(defaults[:PLOT_COMPARE_COLOURS])
        @test all(P._isColour, defaults[:PLOT_COMPARE_COLOURS])
        @test all(in(P.PLOT_MARKER_NAMES), defaults[:PLOT_COMPARE_MARKERS])
        @test P._mergedTable(:SETTING_CHOICES).PLOT_COMPARE_MARKERS === P.PLOT_MARKER_NAMES
        # the style carries them, and the settings reach the style
        style = BAYSOL.resultsKeywords(defaults).style
        @test style == BAYSOL.PlotStyle()
        @test style.colorsCompare == P.PLOT_COMPARE_COLOURS &&
              style.lwCompare == P.PLOT_LW_COMPARE
        s = copy(defaults)
        s[:PLOT_COMPARE_COLOURS] = (:red, :blue)
        s[:PLOT_COMPARE_MARKERS] = (:square, :square, Symbol("+"))
        s[:PLOT_LW_COMPARE] = 2.5
        st = BAYSOL.resultsKeywords(s).style
        @test st.colorsCompare == (:red, :blue) && st.lwCompare == 2.5
        @test st.markersCompare == (:square, :square, Symbol("+"))
    end

    @testset "values are checked as the other settings are" begin
        v(name, text) = tryLoad(saved(name, text))
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
        # runProject's keyword overrides the setting
        s = copy(defaults)
        P._applyKeywords!(s, (; plotCompare = false))
        @test s[:PLOT_COMPARE] === false
        P._applyKeywords!(s, (; plotCompare = nothing))      # nothing: take the setting
        @test s[:PLOT_COMPARE] === false
        # a PlotStyle built by hand is checked too
        @test_throws ArgumentError BAYSOL.results(
            nothing, ([1.0], [1.0], [1.0]);
            style = BAYSOL.PlotStyle(; markersCompare = (:circle,)),
        )
        @test_throws ArgumentError BAYSOL.Pipeline._checkStyle(
            BAYSOL.PlotStyle(; colorsCompare = ()),
        )
        @test_throws ArgumentError BAYSOL.Pipeline._checkStyle(
            BAYSOL.PlotStyle(; colorsCompare = (:notacolour,)),
        )
        @test_throws ArgumentError BAYSOL.Pipeline._checkStyle(
            BAYSOL.PlotStyle(; lwCompare = -1.0),
        )
    end
end

# ---------------------------------------------------------------------------
# the sizes of the terminal plots (kind `:sizes`), and which settings are of one model
# ---------------------------------------------------------------------------

@testset "the sizes of the terminal plots" begin
    P = BAYSOL.Pipeline
    R = BAYSOLRun
    rows = Dict(r.setting => r for r in P.SETTING_KEYWORDS)
    defaults = defaultSettings()

    @testset "catalog row, kind and default" begin
        @test rows[:PLOT_TUI_SIZES].entry === :results &&
              rows[:PLOT_TUI_SIZES].keyword === :plotTuiSizes &&
              rows[:PLOT_TUI_SIZES].check
        @test settingKind(:PLOT_TUI_SIZES, ()) === :sizes
        @test :PLOT_TUI_SIZES in _settingNames()
        d = defaults[:PLOT_TUI_SIZES]
        @test d == P.PLOT_TUI_SIZES && d isa Tuple && all(x -> x isa Tuple{Int,Int}, d)
        # the default is valid, and the terminal's CLI size is its own setting
        @test P._checkedValue(:PLOT_TUI_SIZES, collect(collect.(d))) == d
        @test P.PLOT_PREVIEW_SIZE == (width = 70, height = 18)
        @test BAYSOL.resultsKeywords(defaults).plotTuiSizes == d
    end

    @testset "valid values and the JSON round trip" begin
        v(text) = tryLoad(saved("PLOT_TUI_SIZES", text, screen = "plots"))
        r = v("[[30, 4]]")
        @test r[:PLOT_TUI_SIZES] == ((30, 4),)
        r = v("[[24, 3], [25, 4], [400, 100]]")
        @test r[:PLOT_TUI_SIZES] == ((24, 3), (25, 4), (400, 100))
        # what the harvest writes is what the loader reads back
        text = JSON3.write(collect(collect.(P.PLOT_TUI_SIZES)))
        @test v(text)[:PLOT_TUI_SIZES] == P.PLOT_TUI_SIZES
        # a tuple of tuples (library use) is the same list
        @test P._checkedValue(:PLOT_TUI_SIZES, ((60, 5), (90, 8))) == ((60, 5), (90, 8))
    end

    @testset "invalid values are refused with a message" begin
        v(text) = tryLoad(saved("PLOT_TUI_SIZES", text, screen = "plots"))
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
            nothing, res; plotTuiSizes = ((50, 6), (50, 7)),
        )
    end
end

@testset "which settings may differ per model" begin
    P = BAYSOL.Pipeline
    R = BAYSOLRun
    rows = P.SETTING_KEYWORDS
    perFit = (:seedModel, :runModel, :runModelArgs)
    # the run-level list is the settings of the entries that are not a fit's own, and a
    # new setting has to be placed in one or the other
    runLevel = Set(r.setting for r in rows if !(r.entry in perFit))
    @test runLevel == Set(n for n in _settingNames() if R._isRunLevel(n))
    @test Set(R.RUN_LEVEL_SETTINGS) ⊆ runLevel
    @test all(n -> startswith(String(n), "PLOT_") || n in R.RUN_LEVEL_SETTINGS, runLevel)
    for n in (:PLOT_COMPARE, :PLOT_COMPARE_COLOURS, :PLOT_COMPARE_MARKERS,
        :PLOT_LW_COMPARE, :PLOT_TUI_SIZES, :PLOT_PREVIEW_SIZE, :FIGURES_TEX,
        :FIGURES_COMPILE, :FIGURES_FORMATS, :TABLE_SIGFIGS, :FIGURES_DIR,
        :FIGURES_COMPILER, :TABLE_DIR)
        @test R._isRunLevel(n)
    end
    for n in (:Q_MIN, :Q_MAX, :SIGMA_SCALE, :EXCLUDE_Q, :CHAINS, :MODEL, :ADD_HYDROGENS,
        :LMAX, :RNG_SEED, :VAL_SIGMA, :TARGET_ACCEPT, :N_CHAINS, :N_ADAPT, :N_DRAWS,
        :SHELL_THICKNESS, :MAP_N_STARTS, :BOUNDS_δρ₁₂)
        @test !R._isRunLevel(n)
    end
end

@testset "settings.json: null is no limit (the data selection)" begin
    mktempdir() do dir
        path = joinpath(dir, "settings.json")
        write(
            path,
            """{"data": {"Q_MIN": {"value": 0.05}, "Q_MAX": {"value": null},
                          "EXCLUDE_Q": {"value": [[0.1, 0.12]]},
                          "CHAINS": {"value": ["A"]}, "LMAX": {"value": 9}}}""",
        )
        s = loadSettings(path)
        @test s[:Q_MIN] === 0.05 && s[:Q_MAX] === nothing && s[:LMAX] === 9
        @test s[:EXCLUDE_Q] == ((0.1, 0.12),) && s[:CHAINS] == ("A",)
        write(path, """{"data": {"Q_MIN": {"value": 0.4}, "Q_MAX": {"value": 0.1}}}""")
        e = with_logger(NullLogger()) do
            try
                loadSettings(path)
            catch err
                err
            end
        end
        @test e isa InvalidSettingsError && occursin("Q_MIN", e.problems[1])
    end
end
