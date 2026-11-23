# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises tui/julia/src/cli.jl: the command line of a run. Every flag is the setting of
# the same name in settings.json, so the test is that the command-line form and the file
# form give the same value (a number, a bool, a list, the ladder, a setting of one model),
# that precedence is flag > file > default, that every checked setting of the table is a
# flag, and that `runProjectCli` hands the run what the flags say.
include(joinpath(@__DIR__, "julia-setup.jl"))

using Logging: NullLogger, with_logger
using Main.BAYSOLRun: parseCli, runProjectCli, CliError, InvalidSettingsError,
    SETTING_KEYWORDS, _cliFlags, _cliKey, _applyKeywords!, _settingDefault, _settingNames,
    _readModelSettings, _modelSettings, loadSettings, _checkModelKeywords

_defaults() = Dict{Symbol,Any}(n => _settingDefault(n) for n in _settingNames())

# `parseCli` on the default settings (not the machine's own settings.json).
P(args; settings = _defaults()) = parseCli(args; settings)

# The value of `setting` after the flags `args` (on the defaults, or on `base`).
function viaCli(args, setting; base = _defaults())
    p = P(["proj", "--temperature", "20", args...]; settings = base)
    s = copy(base)
    _applyKeywords!(s, (; (k => v for (k, v) in p.keywords)...))
    return s[setting]
end

# The value of `setting` after a settings.json holding `json` (the `value` of its entry).
function viaFile(json, setting)
    mktempdir() do dir
        file = joinpath(dir, "settings.json")
        write(file, "{\"screen\": {\"$setting\": {\"value\": $json}}}")
        return loadSettings(file)[setting]
    end
end

@testset "a flag equals the same value in settings.json" begin
    cases = [
        (["--nDraws", "800"], "800", :N_DRAWS),
        (["--n-draws", "800"], "800", :N_DRAWS),
        (["--N_DRAWS=800"], "800", :N_DRAWS),
        (["--δ", "95"], "95", :TARGET_ACCEPT),
        (["--addHydrogens", "false"], "false", :ADD_HYDROGENS),
        (["--memory-headroom", "25"], "25", :MEMORY_HEADROOM),
        (["--chainStartRadii", "[1, 2, 3]"], "[1, 2, 3]", :CHAIN_START_RADII),
        (["--qMin", "null"], "null", :Q_MIN),
        (["--qMin", "0.02"], "0.02", :Q_MIN),
        (["--excludeQ", "[[0.1, 0.12]]"], "[[0.1, 0.12]]", :EXCLUDE_Q),
        (["--tex", "true"], "true", :FIGURES_TEX),
    ]
    for (args, json, setting) in cases
        if any(r -> r.setting === setting, SETTING_KEYWORDS)
            @test viaCli(args, setting) == viaFile(json, setting)
        end
    end
    # the cases above name settings that exist (the table is the source of the names)
    @test count(c -> any(r -> r.setting === c[3], SETTING_KEYWORDS), cases) >= 8
end

@testset "the ladder: a whole map, one class, off, a file" begin
    rung = """{"name": "wide", "overrides": {"TARGET_ACCEPT": 99}}"""
    whole = """{"divergent": [$rung], "marginal": []}"""
    fromFile = viaFile(whole, :LADDER)
    @test viaCli(["--ladder", whole], :LADDER) == fromFile
    one = viaCli(["--ladder", "divergent=[$rung]"], :LADDER)
    @test one.divergent == fromFile.divergent
    @test one.marginal == _settingDefault(:LADDER).marginal   # one class leaves the rest
    @test viaCli(["--ladder", "off"], :LADDER) == viaFile("\"off\"", :LADDER)
    @test all(isempty, values(viaCli(["--ladder", "off"], :LADDER)))
    # the classes of several flags add up, the later one wins a class
    two = viaCli(["--ladder", "divergent=[$rung]", "--ladder", "marginal=[]"], :LADDER)
    @test two.divergent == fromFile.divergent && isempty(two.marginal)
    mktempdir() do dir
        file = joinpath(dir, "ladder.json")
        write(file, whole)
        @test viaCli(["--ladder", file], :LADDER) == fromFile
    end
    # the checks of loadSettings apply: a class that does not exist, a setting out of scope
    @test_throws InvalidSettingsError P(["p", "--temperature", "20", "--ladder",
        """{"nothing": []}"""])
    @test_throws InvalidSettingsError P(["p", "--temperature", "20", "--ladder",
        """{"divergent": [{"overrides": {"PLOT_LW_MAP": 1}}]}"""])
end

@testset "a setting of one model" begin
    rung = """{"overrides": {"TARGET_ACCEPT": 99}}"""
    p = P(["p", "--temperature", "20", "--model-setting",
        """m1={"nDraws": 600, "ladder": {"divergent": [$rung]}}""",
        "--model-setting", """m1={"qMin": 0.03}""", "--model-setting",
        """m2={"δ": 90}"""])
    @test Set(keys(p.modelSettings)) == Set(["m1", "m2"])
    @test Set(keys(p.modelSettings["m1"])) == Set([:nDraws, :ladder, :qMin])
    # the same table in model-settings.json
    mktempdir() do dir
        file = joinpath(dir, "model-settings.json")
        write(
            file,
            """{"m1": {"screen": {"N_DRAWS": {"value": 600},
    "LADDER": {"value": {"divergent": [$rung]}}}}}""",
        )
        own = with_logger(NullLogger()) do
            _readModelSettings(file)
        end
        settingOf = Dict(r.keyword => r.setting for r in SETTING_KEYWORDS)
        cli = _checkModelKeywords(
            Dict(
                "m1" => Dict(
                    settingOf[k] => p.modelSettings["m1"][k]
                    for k in (:nDraws, :ladder)
                ),
            ),
        )
        @test cli["m1"][:N_DRAWS] == own["m1"][:N_DRAWS]
        @test cli["m1"][:LADDER].divergent == own["m1"][:LADDER].divergent
    end
    @test_throws CliError P(["p", "--temperature", "20", "--model-setting", "m1"])
    @test_throws CliError P(["p", "--temperature", "20", "--model-setting",
        """m1={"nothingSuch": 1}"""])
    @test_throws InvalidSettingsError P(["p", "--temperature", "20",
        "--model-setting", """m1={"nDraws": -4}"""])
    # a setting of the whole run is refused for a model
    @test_throws InvalidSettingsError P(["p", "--temperature", "20",
        "--model-setting", """m1={"plotDir": "x"}"""])
end

@testset "precedence is flag > file > default" begin
    mktempdir() do dir
        file = joinpath(dir, "settings.json")
        write(
            file,
            """{"screen": {"N_DRAWS": {"value": 700}, "MEMORY_HEADROOM": {"value": 30}}}""",
        )
        base = loadSettings(file)
        @test base[:N_DRAWS] == 700
        @test viaCli(["--nDraws", "900"], :N_DRAWS; base) == 900     # flag over file
        @test viaCli(["--nDraws", "900"], :MEMORY_HEADROOM; base) == 30  # file over default
        @test viaCli(String[], :N_DRAWS; base) == 700
        @test viaCli(String[], :N_DRAWS) == _settingDefault(:N_DRAWS)
    end
end

const T20 = ["p", "--temperature", "20"]

@testset "every row of SETTING_KEYWORDS is a flag, and bad lines are refused" begin
    flags = _cliFlags()
    declared = Set(Base.kwarg_decl(first(methods(Main.BAYSOLRun.runProject))))
    for r in SETTING_KEYWORDS
        # by the name of its setting, always; by its keyword too when runProject has it
        @test get(flags, _cliKey(r.setting), nothing) !== nothing
        @test flags[_cliKey(r.setting)].setting === r.setting
        if r.keyword in declared
            @test flags[_cliKey(r.keyword)].keyword === r.keyword
            @test !flags[_cliKey(r.setting)].style
        else
            @test flags[_cliKey(r.setting)].style
        end
    end
    @test length(unique(r.setting for r in SETTING_KEYWORDS)) == length(SETTING_KEYWORDS)
    @test haskey(flags, "memoryheadroom")
    # a value is judged as the file judges it
    @test_throws InvalidSettingsError P([T20..., "--nDraws", "-1"])
    @test_throws InvalidSettingsError P([T20..., "--nDraws", "1.5"])
    @test_throws InvalidSettingsError P([T20..., "--addHydrogens", "maybe"])
    @test_throws CliError P([T20..., "--bogus", "1"])
    @test_throws CliError P([T20..., "--nDraws"])
    @test_throws CliError P([T20..., "--nDraws", "1", "--nDraws", "2"])
    @test_throws CliError P(["--temperature", "20"])
    @test_throws CliError P(["p"])
    @test_throws CliError P(["p", "q", "--temperature", "20"])
end

@testset "the look of the plots goes into the style" begin
    p = P([T20..., "--PLOT_LW_MAP", "2.5", "--PLOT_TEXT_FONT", "TeX Gyre Heros"])
    @test p.styleSettings[:PLOT_LW_MAP] == 2.5
    @test p.styleSettings[:PLOT_TEXT_FONT] == "TeX Gyre Heros"
    @test isempty(p.keywords)
    @test_throws InvalidSettingsError P([T20..., "--PLOT_LW_MAP", "-1"])
    seen = Ref{Any}(nothing)
    runner = (project; kw...) -> (seen[] = (; kw...); (; status = "done"))
    runProjectCli([T20..., "--PLOT_LW_MAP", "2.5"]; runner, io = devnull,
        settings = _defaults())
    @test seen[].style.lwMap == 2.5
end

@testset "the relations are checked on the settings the run starts from" begin
    mktempdir() do dir
        file = joinpath(dir, "settings.json")
        # SASA_N_OCC may not exceed SHELL_SAMPLE: the file raises the sample, so a
        # flag that is invalid on the defaults is valid on the file
        write(file, """{"screen": {"SHELL_SAMPLE": {"value": 4000}}}""")
        base = loadSettings(file)
        @test base[:SHELL_SAMPLE] == 4000 && _settingDefault(:SHELL_SAMPLE) < 300
        flag = ["--sasaNOcc", "300"]
        @test viaCli(flag, :SASA_N_OCC; base) == 300
        @test_throws InvalidSettingsError P([T20..., flag...])
        # a model's own settings are checked on the same base
        own = ["--model-setting", """m1={"sasaNOcc": 300}"""]
        @test P([T20..., own...]; settings = base).modelSettings["m1"][:sasaNOcc] == 300
        @test_throws InvalidSettingsError P([T20..., own...])
    end
end

@testset "--ladder off, then a class: that class alone" begin
    rung = """[{"overrides": {"TARGET_ACCEPT": 99}}]"""
    v = viaCli(["--ladder", "off", "--ladder", "divergent=$rung"], :LADDER)
    @test length(v.divergent) == 1
    @test all(isempty, (v.stepCollapse, v.splitChains, v.structural, v.marginal, v.generic))
end

@testset "runProjectCli hands runProject the flags" begin
    seen = Ref{Any}(nothing)
    runner = (project; kw...) -> (seen[] = (project, (; kw...)); (; status = "done"))
    run(args; r = runner) = runProjectCli(args; runner = r, io = devnull,
        settings = _defaults())
    code = run(["proj", "--temperature", "25.5", "--nDraws", "600", "--run-dir", "/tmp/r",
        "--ladder", "off", "--model-setting", """m1={"δ": 90}"""])
    @test code == 0
    project, kw = seen[]
    @test project == "proj"
    @test kw.temperature == 25.5 && kw.runDir == "/tmp/r" && kw.ui === :cli
    @test kw.nDraws == 600 && kw.ladder == "off"
    @test kw.modelSettings == Dict("m1" => Dict(:δ => 90))
    # exit codes: a failed run is 1, a bad line 2 (nothing runs), --help 0
    failing = (project; kw...) -> (; status = "failed")
    @test run(["proj", "--temperature", "20"]; r = failing) == 1
    seen[] = nothing
    @test run(["proj", "--temperature", "20", "--nDraws", "x"]) == 2
    @test seen[] === nothing
    @test run(["--help"]) == 0
    # a setting that runProject itself refuses is status 2, not a stack trace
    refusing = (project; kw...) -> throw(InvalidSettingsError(["X = 1: no"], "hint"))
    @test run(["proj", "--temperature", "20"]; r = refusing) == 2
end

@testset "the documented command: julia -e '...runProjectCli(ARGS)' -- PROJECT ..." begin
    root = normpath(joinpath(@__DIR__, "..", ".."))
    env = joinpath(root, "tui", "julia")
    program = "using BAYSOLRun; exit(BAYSOLRun.runProjectCli(ARGS))"
    out = IOBuffer()
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$env -e $program -- proj
        --temperature 20 --nDraws -3`
    proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = out))
    text = String(take!(out))
    @test proc.exitcode == 2 && occursin("N_DRAWS", text)
end
