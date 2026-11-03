# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Pipeline/Settings.jl: the reader of settings.edn and `load_settings`, which
# checks every saved value before any code uses one. Valid files of every kind of setting,
# a long list of corrupt ones (bad EDN, wrong types, limits, choices, colours, tuple
# shapes, the rules that tie settings together), and seeded fuzzing: whatever is written
# into the file, `load_settings` either returns settings of the right types or throws an
# `InvalidSettingsError`, and nothing else.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Logging
using Random
using BAYSOL.Pipeline: load_settings, settings_file, InvalidSettingsError, _parse_edn,
    _checked_value, setting_kind, _setting_names, _setting_default, _merged_table,
    _merged_relations, _relation_problem

"Runs `f(path)` on a settings file holding `text`."
function with_file(f, text::AbstractString)
    mktempdir() do dir
        path = joinpath(dir, "settings.edn")
        write(path, text)
        f(path)
    end
end

"The text of a settings file that saves `value` (EDN text) for `name`."
saved(
    name,
    value;
    screen = "sampler",
) = "{:$screen {\"$name\" {:page 1 :default 0 :type :x :limits {} :value $value}}}"

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

@testset "the EDN reader" begin
    @testset "values" begin
        @test _parse_edn("42") === 42
        @test _parse_edn("-7") === -7
        @test _parse_edn("+7") === 7
        @test _parse_edn("3.5") === 3.5
        @test _parse_edn("1e-3") === 1.0e-3
        @test _parse_edn("1.0E+2") === 100.0
        @test _parse_edn(".5") === 0.5
        @test _parse_edn("5.") === 5.0
        @test _parse_edn("true") === true
        @test _parse_edn("false") === false
        @test _parse_edn("nil") === nothing
        @test _parse_edn(":crimson") === :crimson
        @test _parse_edn(":at-least") === :at_least ||
              _parse_edn(":at-least") === Symbol("at-least")
        @test _parse_edn("\"hi\"") == "hi"
        @test _parse_edn("\"a\\nb\\t\\\"q\\\" \\\\ \\u00e9\"") == "a\nb\t\"q\" \\ é"
        @test _parse_edn("\"κ_δρ₁₂ Gyre\"") == "κ_δρ₁₂ Gyre"
        @test _parse_edn("[1 2.0 :a \"b\"]") == Any[1, 2.0, :a, "b"]
        @test _parse_edn("(1 2)") == Any[1, 2]
        @test _parse_edn("[]") == Any[]
        @test _parse_edn("{}") == Dict{Any,Any}()
        @test _parse_edn("{:a 1, \"b\" [2 3]}") == Dict{Any,Any}(:a => 1, "b" => Any[2, 3])
        @test _parse_edn("{:a {:b {:c 1}}}")[:a][:b][:c] == 1
    end
    @testset "white space and comments" begin
        @test _parse_edn("  ,, [1,,2 ,\n 3]  ") == Any[1, 2, 3]
        @test _parse_edn(";; one\n[1 ; two\n 2] ; three") == Any[1, 2]
        @test _parse_edn("; only a comment\n7") == 7
        @test _parse_edn("[1;x\n]") == Any[1]
    end
    @testset "malformed text is an ArgumentError that names the line" begin
        for text in
            ("", "   ", "; nothing", "[", "]", "}", ")", "{", "{:a}", "{:a 1 :a 2}",
            "[1 2", "(1 2", "\"open", "\"bad \\q escape\"", "\"\\u12\"", "\"\\uZZZZ\"",
            "[1 2]]", "1 2", ":", "foo", "NaN", "Infinity", "1.2.3", "0x10", "1/2", "#{1}",
            "#_1 2", "'a", "\\a", "{:a 1", "[[[", "[1 {:a}]", "99999999999999999999",
            "1e", "--1", "+-1", "\"\\")
            @test_throws ArgumentError _parse_edn(text)
        end
        err = try
            _parse_edn("[1\n2\n  foo]")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("line 3", err.msg)
    end
    @testset "nesting is limited" begin
        @test _parse_edn("[" ^ 50 * "]" ^ 50) isa Vector
        @test_throws ArgumentError _parse_edn("[" ^ 200 * "]" ^ 200)
    end
end

@testset "settings that are not saved are defaults" begin
    defaults = load_settings(joinpath(tempdir(), "no", "such", "settings.edn"))
    @test defaults isa Dict{Symbol,Any}
    @test Set(keys(defaults)) == Set(_setting_names())
    @test length(defaults) == 80
    for n in _setting_names()
        @test defaults[n] == _setting_default(n)
    end
    @testset "$what" for (what, text) in (
        ("an empty map", "{}"),
        ("a comment and an empty map", ";; nothing saved\n{}"),
        ("screens without entries", "{:sampler {} :model {}}"),
        ("entries without a value", "{:sampler {\"N_ADAPT\" {:page 1 :default 300}}}"),
        ("an unknown setting", saved("NOT_A_SETTING", "5")),
        ("a constant that is no setting", saved("PLOT_SUBDIR", "\"x\"")),
        ("a setting under another screen", saved("N_ADAPT", "450"; screen = "plots")),
        ("a screen that does not exist", saved("N_ADAPT", "300"; screen = "nowhere")),
    )
        @test try_load(text)[:RNG_SEED] == 0
    end
    @testset "the defaults file that the terminal interface copies" begin
        copy = read(
            joinpath(@__DIR__, "..", "..", "..", "tui", "resources",
                "default_settings.edn"), String)
        @test try_load(copy) == defaults
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
        @test value_of("PLOT_COLOUR_MAP", ":crimson") === :crimson
        @test value_of("PLOT_COLOUR_MAP", ":antiquewhite4") === :antiquewhite4
        @test value_of("PLOT_COLOUR_DATA", "\"#ff0000\"") == "#ff0000"
        @test value_of("PLOT_COLOUR_DATA", "\"#A0b1C2\"") == "#A0b1C2"
        @test value_of("PLOT_TICK_COLOUR", ":gray20") === :gray20
    end
    @testset "fonts" begin
        @test value_of("PLOT_TEXT_FONT", "\"Latin Modern Roman\"") == "Latin Modern Roman"
        @test value_of("PLOT_MATH_FONT", "\"Garamond-Math\"") == "Garamond-Math"
        @test value_of("PLOT_TEXT_FONT", "\"κ Font δ\"") == "κ Font δ"
        @test value_of("PLOT_TEXT_FONT", "\"" * "x" ^ 100 * "\"") == "x" ^ 100
    end
    @testset "formats" begin
        @test value_of("FIGURES_FORMATS", "[:svg]") === (:svg,)
        @test value_of("FIGURES_FORMATS", "[:svg :pdf]") === (:pdf, :svg)
        @test value_of("FIGURES_FORMATS", "[:svg :png :pdf]") === (:pdf, :png, :svg)
        @test value_of("FIGURES_FORMATS", "(:png)") === (:png,)
    end
    @testset "tuples" begin
        @test value_of("CHAIN_START_RADII", "[1.0 2.0 3.0]") === (1.0, 2.0, 3.0)
        @test value_of("CHAIN_START_RADII", "[1 2 3]") === (1.0, 2.0, 3.0)
        @test value_of("MAP_JITTER_RADII", "[0.5 1 1e1]") === (0.5, 1.0, 10.0)
        @test value_of("PLOT_WIDTH_HEIGHT_CM", "[10 7]") === (10.0, 7.0)
        @test value_of("PLOT_YLIM_LOG", "[0.5 2]") === (0.5, 2.0)
        @test value_of("PLOT_PREVIEW_SIZE", "{:width 80 :height 24}") ===
              (width = 80, height = 24)
        @test value_of("PLOT_PREVIEW_SIZE", "{:height 24 :width 80}") ===
              (width = 80, height = 24)
        @test value_of("PLOT_COLOUR_BAND", "[:red 0.5]") === (:red, 0.5)
        @test value_of("PLOT_COLOUR_BAND", "[:red 0]") === (:red, 0.0)
        @test value_of("PLOT_COLOUR_BAND", "[:red 1]") === (:red, 1.0)
        @test value_of("PLOT_COLOUR_HIST", "[:antiquewhite4 0.6]") === (:antiquewhite4, 0.6)
        @test value_of("BOUNDS_δρ₁₂", "[-5.0 3.0]") === (-5.0, 3.0)
        @test value_of("EXCL_VOL_CORR_BOUNDS", "[0.9 1.2]") === (0.9, 1.2)
    end
    @testset "values that agree with the rules that tie settings together" begin
        text =
            "{:model {\"BOUNDS_δρ₁₂\" {:value [-4.0 4.0]} \"MODE_δρ₁₂\" {:value 3.5}" *
            " \"SHELL_SAMPLE\" {:value 300} \"SASA_N_OCC\" {:value 300}" *
            " \"EXCL_VOL_CORR_BOUNDS\" {:value [0.5 2.0]}" *
            " \"EXCL_VOL_CORR_EPS\" {:value 1.5}}}"
        r = try_load(text)
        @test r isa Dict
        @test r[:MODE_δρ₁₂] === 3.5
        @test r[:SASA_N_OCC] === 300
        @test r[:EXCL_VOL_CORR_EPS] === 1.5
    end
    @testset "several settings at once, with comments and commas" begin
        text = """
        ;; the settings of the user
        {:sampler {"N_ADAPT" {:page 1, :default 300, :type :int, :value 500}
                   "N_DRAWS" {:value 900}},   ; draws
         :plots   {"PLOT_COLOUR_MAP" {:value :darkorange}
                   "PLOT_HIST_BINS" {:value 60}}}
        """
        r = try_load(text)
        @test (r[:N_ADAPT], r[:N_DRAWS], r[:PLOT_HIST_BINS], r[:PLOT_COLOUR_MAP]) ===
              (500, 900, 60, :darkorange)
        @test r[:RNG_SEED] == 0
    end
    @testset "a file the terminal interface wrote is read back" begin
        text =
            "{\n :sampler\n {\n  \"N_ADAPT\" {:page 1, :default 300, :type :int, " *
            ":limits {:at-least 1}, :value 450}\n }\n}\n"
        @test try_load(text)[:N_ADAPT] === 450
    end
end

# Each case: (setting, EDN text of the saved value, what the problem should mention)
const INVALID_VALUES = [
    ("N_ADAPT", "\"300\"", "whole number"), ("N_ADAPT", "300.5", "whole number"),
    ("N_ADAPT", "300.0", "whole number"), ("N_ADAPT", "true", "whole number"),
    ("N_ADAPT", "nil", "whole number"), ("N_ADAPT", "[1]", "whole number"),
    ("N_ADAPT", ":a", "whole number"), ("N_ADAPT", "{}", "whole number"),
    ("N_ADAPT", "0", "at least 1"), ("N_ADAPT", "-5", "at least 1"),
    ("N_DRAWS", "0", "at least 1"), ("N_CHAINS", "0", "at least 1"),
    ("RETRY_N_ADAPT", "0", "at least 1"), ("RETRY_N_DRAWS", "-1", "at least 1"),
    ("MAP_MAX_ITER", "0", "at least 1"), ("MAP_N_STARTS", "0", "at least 1"),
    ("MAP_OPTIMA_KEPT", "0", "at least 1"), ("MAP_F_SUCCESSIVE", "0", "at least 1"),
    ("MAP_JITTER_DIRECTIONS", "0", "at least 1"),
    ("MAP_JITTER_MAX_OPTIMA", "0", "at least 1"),
    ("OPTIMUM_MIN_CHAINS", "0", "at least 1"), ("SHELL_MIN_POINTS", "0", "at least 1"),
    ("SHELL_SAMPLE", "0", "at least 1"), ("BEAD_RAY_DIRS", "0", "at least 1"),
    ("HARVEST_COVER", "-1", "at least 0"), ("HARVEST_DIVERGENT", "-1", "at least 0"),
    ("OPTIMUM_CHAIN_CAP", "-1", "at least 0"),
    ("RNG_SEED", "1.5", "whole number"), ("RNG_SEED", "\"0\"", "whole number"),
    ("TARGET_ACCEPT", "0", "above 0"), ("TARGET_ACCEPT", "100", "below 100"),
    ("TARGET_ACCEPT", "101", "below 100"), ("TARGET_ACCEPT", "-3", "above 0"),
    ("TARGET_ACCEPT", "95.5", "whole number"),
    ("TABLE_SIGFIGS", "0", "at least 1"), ("TABLE_SIGFIGS", "18", "at most 17"),
    ("VAL_SIGMA", "0", "above 0"), ("VAL_SIGMA", "-1", "above 0"),
    ("VAL_SIGMA", "\"2\"", "number"), ("VAL_SIGMA", "true", "number"),
    ("VAL_SIGMA", "nil", "number"), ("VAL_SIGMA", "[2.0]", "number"),
    ("OPTIMUM_CHAIN_FRACTION", "0", "above 0"),
    ("OPTIMUM_CHAIN_FRACTION", "1.5", "at most 1"),
    ("OPTIMUM_CHAIN_RADIUS", "0", "above 0"), ("BASIN_RESTART_NATS", "-2", "above 0"),
    ("MAP_JITTER_WITHIN_NATS", "0", "above 0"), ("κ_δρ₁₂", "0", "above 0"),
    ("κ_δρ₃", "-1", "above 0"), ("φ_max", "0", "above 0"),
    ("PMV_FALLBACK_UNCERT", "0", "above 0"), ("PMV_FALLBACK_UNCERT", "-3.0", "above 0"),
    ("EXCL_VOL_CORR_EPS", "0", "above 0"), ("SHELL_THICKNESS", "0", "above 0"),
    ("SHELL_AREA_PER_POINT", "0", "above 0"), ("BEAD_RAY_RANGE", "0", "above 0"),
    ("SASA_N_OCC", "0", "above 0"), ("PROBE_RADIUS", "-0.1", "at least 0"),
    ("PLOT_LW_MAP", "-0.1", "at least 0"), ("PLOT_MARKERSIZE", "-1", "at least 0"),
    ("PLOT_BORDER_PT", "-8", "at least 0"),
    ("PLOT_YLIM_LIN_PAD_FRAC", "-0.3", "at least 0"),
    ("PLOT_XTICK_ANGLE", "\"45\"", "number"), ("PLOT_HIST_BINS", "0", "at least 1"),
    ("PLOT_HIST_BINS", "40.5", "whole number"),
    ("PLOT_LINMIN_TICKS", "-1", "at least 0"),
    ("FIGURES_TEX", "\"true\"", "true or false"), ("FIGURES_TEX", "1", "true or false"),
    ("FIGURES_COMPILE", "nil", "true or false"),
    ("FIGURES_COMPILE", "[true]", "true or false"),
    ("PLOT_COLOUR_MAP", ":notacolour", "colour"),
    ("PLOT_COLOUR_MAP", "\"red\"", "colour"),
    ("PLOT_COLOUR_MAP", "5", "colour"), ("PLOT_COLOUR_MAP", "\"#GGGGGG\"", "colour"),
    ("PLOT_COLOUR_MAP", "\"#fff\"", "colour"),
    ("PLOT_COLOUR_MAP", "\"#ff00000\"", "colour"),
    ("PLOT_COLOUR_MAP", "nil", "colour"), ("PLOT_COLOUR_AXIS", "[:red]", "colour"),
    ("PLOT_TEXT_FONT", "\"\"", "font"), ("PLOT_TEXT_FONT", "\"   \"", "font"),
    ("PLOT_TEXT_FONT", "5", "font"), ("PLOT_TEXT_FONT", ":font", "font"),
    ("PLOT_TEXT_FONT", "nil", "font"), ("PLOT_TEXT_FONT", "\"a\\u0001b\"", "font"),
    ("PLOT_TEXT_FONT", "\"a\\nb\"", "font"),
    ("PLOT_MATH_FONT", "\"" * "x" ^ 101 * "\"", "font"),
    ("FIGURES_FORMATS", "[]", "at least one"), ("FIGURES_FORMATS", "[:gif]", "some of"),
    ("FIGURES_FORMATS", "[:pdf :pdf]", "some of"),
    ("FIGURES_FORMATS", "\"pdf\"", "some of"),
    ("FIGURES_FORMATS", "[:pdf \"png\"]", "some of"),
    ("FIGURES_FORMATS", ":pdf", "some of"),
    ("FIGURES_FORMATS", "nil", "some of"),
    ("FIGURES_FORMATS", "{:pdf true}", "some of"),
    ("CHAIN_START_RADII", "[1.0 2.0]", "3 parts"),
    ("CHAIN_START_RADII", "[1 2 3 4]", "3 parts"),
    ("CHAIN_START_RADII", "[\"a\" 1 2]", "number"),
    ("CHAIN_START_RADII", "[0 1 2]", "above 0"),
    ("CHAIN_START_RADII", "[-1.0 2.0 3.0]", "above 0"),
    ("CHAIN_START_RADII", "5", "3 parts"),
    ("CHAIN_START_RADII", "{:a 1}", "3 parts"),
    ("CHAIN_START_RADII", "[1 2 nil]", "number"),
    ("MAP_JITTER_RADII", "[1.0 2.0 0.0]", "above 0"),
    ("MAP_JITTER_RADII", "[]", "3 parts"),
    ("BOUNDS_δρ₁₂", "[2.0 1.0]", "first part below"),
    ("BOUNDS_δρ₁₂", "[1.0 1.0]", "first part below"),
    ("BOUNDS_δρ₁₂", "[1 2 3]", "2 parts"), ("BOUNDS_δρ₁₂", "[:a :b]", "number"),
    ("BOUNDS_δρ₁₂", "[0.0 0.5]", "inside"), ("BOUNDS_δρ₁₂", "[1.5 3.0]", "inside"),
    ("MODE_δρ₁₂", "5.0", "inside"), ("MODE_δρ₁₂", "-10.0", "inside"),
    ("MODE_δρ₁₂", "2.0", "inside"), ("MODE_δρ₁₂", "\"1\"", "number"),
    ("EXCL_VOL_CORR_BOUNDS", "[0 1.3]", "above 0"),
    ("EXCL_VOL_CORR_BOUNDS", "[1.3 0.8]", "first part below"),
    ("EXCL_VOL_CORR_BOUNDS", "[-0.5 1.3]", "above 0"),
    ("EXCL_VOL_CORR_BOUNDS", "[0.8]", "2 parts"),
    ("EXCL_VOL_CORR_EPS", "1.0", "width"), ("EXCL_VOL_CORR_EPS", "0.6", "width"),
    ("PLOT_WIDTH_HEIGHT_CM", "[0 5]", "above 0"),
    ("PLOT_WIDTH_HEIGHT_CM", "[16.0 \"x\"]", "number"),
    ("PLOT_WIDTH_HEIGHT_CM", "[16.0]", "2 parts"),
    ("PLOT_WIDTH_HEIGHT_CM", "[-1 5]", "above 0"),
    ("PLOT_PREVIEW_SIZE", "{:width 0 :height 5}", "above 0"),
    ("PLOT_PREVIEW_SIZE", "{:width 70}", "exactly"),
    ("PLOT_PREVIEW_SIZE", "{:width 70 :height 18 :depth 1}", "exactly"),
    ("PLOT_PREVIEW_SIZE", "{:width 7.5 :height 3}", "whole number"),
    ("PLOT_PREVIEW_SIZE", "[70 18]", "exactly"),
    ("PLOT_PREVIEW_SIZE", "{:w 70 :h 18}", "exactly"),
    ("PLOT_PREVIEW_SIZE", "{:width -3 :height 18}", "above 0"),
    ("PLOT_YLIM_LOG", "[1.3 0.7]", "first part below"),
    ("PLOT_YLIM_LOG", "[0 1]", "above 0"),
    ("PLOT_YLIM_LOG", "[-1 1]", "above 0"), ("PLOT_YLIM_LOG", "[0.7]", "2 parts"),
    ("PLOT_COLOUR_BAND", "[:red 1.5]", "opacity"),
    ("PLOT_COLOUR_BAND", "[:red -0.1]", "opacity"),
    ("PLOT_COLOUR_BAND", "[:notacolour 0.5]", "colour"),
    ("PLOT_COLOUR_BAND", "[:red]", "2 parts"),
    ("PLOT_COLOUR_BAND", ":red", "2 parts"),
    ("PLOT_COLOUR_BAND", "[:red \"x\"]", "number"),
    ("PLOT_COLOUR_BAND", "[0.5 :red]", "colour"),
    ("PLOT_COLOUR_BAND", "[:red 0.5 0.1]", "2 parts"),
    ("PLOT_COLOUR_ERRORBAR", "[:red 2]", "opacity"),
    ("PLOT_COLOUR_BAND_RESID", "[:red 1.0001]", "opacity"),
    ("PLOT_COLOUR_HIST", "[:red -1]", "opacity"),
    ("SASA_N_OCC", "500", "at most SHELL_SAMPLE"),
    ("SHELL_SAMPLE", "50", "at most SHELL_SAMPLE"),
]

@testset "invalid saved values are refused" begin
    @testset "$name = $text" for (name, text, mention) in INVALID_VALUES
        r = try_load(saved(name, text))
        @test r isa InvalidSettingsError
        r isa InvalidSettingsError || continue
        @test length(r.problems) >= 1
        @test any(p -> startswith(p, name) || occursin(name, p), r.problems)
        @test any(p -> occursin(mention, p), r.problems)
        # a direct check of the value agrees, unless it needs another setting to judge
        # a rule needs the other settings to judge; the rest the value alone shows
        rule_mentions = ("inside", "width", "at most SHELL_SAMPLE", "opacity",
            "first part below")
        if !(mention in rule_mentions) &&
           !(
               startswith(text, "[") && mention == "above 0" &&
               name in ("BOUNDS_δρ₁₂", "EXCL_VOL_CORR_BOUNDS",
                   "PLOT_YLIM_LOG")
           ) &&
           !(
               mention == "above 0" && name in ("CHAIN_START_RADII", "MAP_JITTER_RADII",
                   "PLOT_WIDTH_HEIGHT_CM", "PLOT_PREVIEW_SIZE", "EXCL_VOL_CORR_EPS")
           )
            @test_throws ArgumentError _checked_value(Symbol(name), _parse_edn(text))
        end
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
    two = try_load("{:sampler {\"N_ADAPT\" {:value 0} \"N_DRAWS\" {:value \"x\"}}}")
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
        ("", "   \n", "{", "}", "[1 2", "{:a}", "{:a 1 :a 2}", "garbage", "1", "\"s\"",
        "[]", "[{}]", "nil", "true", "{:sampler 5}", "{:sampler [1 2]}", "{:sampler \"x\"}",
        "{:sampler {\"N_ADAPT\" 5}}", "{:sampler {\"N_ADAPT\" [1]}}",
        "{:sampler {\"N_ADAPT\" nil}}", "{:sampler nil}", ";; only a comment",
        "{:sampler {\"N_ADAPT\" {:value 0}}", "{:sampler {\"N_ADAPT\" {:value}}}",
        "{:sampler {\"VAL_SIGMA\" {:value 1e999}}}", "{:sampler {\"N_ADAPT\" {:value :}}}",
        "{:sampler {\"N_ADAPT\" {:value 99999999999999999999}}}")
        r = try_load(text)
        @test r isa InvalidSettingsError
    end
    @testset "bytes that are no text" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.edn")
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
            @test load_settings(joinpath(dir, "missing.edn")) isa Dict
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
        r = try_load("{:model {\"SASA_N_OCC\" {:value 200} \"SHELL_SAMPLE\" {:value 100}}}")
        @test r isa InvalidSettingsError
        @test any(p -> startswith(p, "SASA_N_OCC"), r.problems)
        r2 = try_load("{:model {\"BOUNDS_δρ₁₂\" {:value [-3.0 0.5]}}}")
        @test r2 isa InvalidSettingsError
        @test any(p -> occursin("MODE_δρ₁₂", p), r2.problems)
    end
end

@testset "the settings file path" begin
    mktempdir() do dir
        withenv("BAYSOL_HOME" => dir) do
            @test settings_file() == joinpath(dir, "settings.edn")
            write(settings_file(), saved("N_ADAPT", "777"))
            @test load_settings()[:N_ADAPT] === 777
            write(settings_file(), saved("N_ADAPT", "-1"))
            with_logger(NullLogger()) do
                @test_throws InvalidSettingsError load_settings()
            end
        end
        withenv("BAYSOL_HOME" => "relative/dir") do
            @test !startswith(settings_file(), "relative")
            @test endswith(settings_file(), joinpath("baysol", "settings.edn"))
        end
        withenv("BAYSOL_HOME" => "   ") do
            @test endswith(settings_file(), joinpath("baysol", "settings.edn"))
        end
    end
end

# Junk that can be written where a value is expected.
const JUNK = ["nil", "true", "false", "0", "1", "-1", "2.5", "1e999", "\"\"", "\"x\"",
    "\"#ff0000\"", ":pdf", ":red", ":notacolour", "[]", "[1]", "[1 2]", "[1 2 3]",
    "[:red 0.5]", "[:pdf :png]", "{}", "{:width 1 :height 2}", "{:a 1}", "(1 2)",
    "[[1]]",
    "\"" * "y" ^ 120 * "\"", "99999", "-0.0", "[0 0 0]", "[nil nil]"]

@testset "fuzzing the saved value of every setting" begin
    names = _setting_names()
    @test length(names) == 80
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
                elseif kind === :font
                    @test v isa String && !isempty(strip(v))
                elseif kind === :colour
                    @test v isa Union{Symbol,String}
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
                    haskey(lim, k) && @test ok_(v, lim[k])
                end
            end
        end
    end
end

"A text with `k` random edits (delete, duplicate or replace a character, or insert junk)."
function mutate(rng, text::String, k)
    chars = collect(text)
    pool = collect("{}[]()\":;, \n\\#'1e-+.:aA\u00e9")
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
    {:sampler {"N_ADAPT" {:page 1, :default 300, :value 450}
               "RNG_SEED" {:value -3}}
     :model {"BOUNDS_δρ₁₂" {:value [-5.0 3.0]} "MODE_δρ₁₂" {:value 1.5}}
     :output {"FIGURES_FORMATS" {:value [:pdf :svg]} "FIGURES_TEX" {:value false}}
     :plots {"PLOT_COLOUR_MAP" {:value :crimson}
             "PLOT_PREVIEW_SIZE" {:value {:width 80 :height 24}}
             "PLOT_COLOUR_BAND" {:value [:darkorange 0.2]}
             "PLOT_TEXT_FONT" {:value "Latin Modern Roman"}}}
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
            @test length(r) == 80
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
    alphabet = collect("{}[]()\":;, \n\\#'0123456789eE+-.:abcxyztruefalsenil\u00e9\u03b4")
    for _ in 1:2000
        text = String(rand(rng, alphabet, rand(rng, 0:60)))
        r = try
            _parse_edn(text)
            :parsed
        catch e
            e
        end
        @test r === :parsed || r isa ArgumentError
    end
end

# The cases the terminal interface judges too (test/fixtures/settings/cases.edn): the same
# file is read by baysol.tui.validate's tests, so the two sides cannot drift apart.
_plain(x::Tuple) = Any[_plain(y) for y in x]
_plain(x::AbstractVector) = Any[_plain(y) for y in x]
_plain(x::NamedTuple) = Dict{Any,Any}(k => _plain(v) for (k, v) in pairs(x))
_plain(x::AbstractDict) = Dict{Any,Any}(k => _plain(v) for (k, v) in x)
_plain(x) = x

@testset "the cases both sides judge alike" begin
    cases = _parse_edn(
        read(joinpath(@__DIR__, "..", "..", "fixtures", "settings", "cases.edn"), String),
    )
    @test length(cases) > 200
    @test count(c -> c[:valid], cases) > 60
    @test count(c -> !c[:valid], cases) > 140
    @test length(unique(c[:setting] for c in cases)) >= 80
    for c in cases
        name = c[:setting]
        entries = Dict{Any,Any}(name => Dict{Any,Any}(:value => c[:value]))
        for (other, v) in get(c, :with, Dict())
            entries[other] = Dict{Any,Any}(:value => v)
        end
        values, problems = BAYSOL.Pipeline._settings_from(
            Some(Dict{Any,Any}(:screen => entries)),
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
