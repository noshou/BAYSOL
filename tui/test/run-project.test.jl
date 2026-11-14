# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises tui/src/store/run-project.jl (and model-references.jl): `runProject` and
# the run folder it writes (the layout, the states of run.json, the rows of the LOGs, a
# failing model that does not stop the loop, an interrupt that marks the run aborted,
# the claim of the folder, the snapshot of the inputs). Most tests replace the fit of a
# model (`fit`) so that they are fast; one runs a real tiny fit end to end.
include(joinpath(@__DIR__, "julia-setup.jl"))

using BAYSOL.Pipeline: _plotStyle
using Main.BAYSOLRun: JSON3
using Main.BAYSOLRun: _utcFields, _unixTime, _runStamp, _isoUtc, _parseIsoUtc,
    _parseRunStamp, _localOffset, _localZone, _zoneLabel, _zoneName, _claimRunDir,
    _projectModels, _readSnapshotData, _liveRun,
    _writeJsonAtomic, RUN_FOLDER, RUN_STALE_S

const _RP_CRAMBIN =
    joinpath(@__DIR__, "..", "..", "test", "fixtures", "molecules", "1CRN-TEST.pdb")

# The rows `name\tvalue` of the first block of a LOG file (after its `=== section ===`
# title, if it has one, up to the next title or `--- block ---`) as a Dict.
function logRows(path)
    rows = Dict{String,String}()
    titled = false
    for l in eachline(path)
        if startswith(l, "===") || startswith(l, "---")
            (titled || startswith(l, "---")) && break
            titled = true
            continue
        end
        isempty(strip(l)) && continue
        cells = split(l, '\t')
        length(cells) >= 2 && (rows[strip(cells[1])] = strip(cells[2]))
    end
    return rows
end

# A project folder with a curve (60 points in nm⁻¹), a buffer with a pH and the models
# `models` (name => path of the file to copy, or a text for a file of that content).
function makeProject(dir; models = ["crambin.pdb" => _RP_CRAMBIN], pH = 7.4)
    mkpath(joinpath(dir, "models"))
    for (name, src) in models
        dest = joinpath(dir, "models", name)
        isfile(src) ? cp(src, dest) : write(dest, src)
    end
    rows = map(range(0.1, 3.0; length = 60)) do q
        I = 1000 * exp(-(q / 10)^2 * 100 / 3)
        s = 0.02 * I + 0.01
        string(q, '\t', I * (1 + 0.01 * sin(7q)), '\t', s)
    end
    write(joinpath(dir, "data.tsv"), join(rows, "\n") * "\n")
    write(
        joinpath(dir, "data.json"),
        """{"units":"nm-1","energy":8000,"energyUnit":"eV","source":"x.dat",""" *
        """"points":60,""" *
        """"mapping":{"path":"x.dat","columns":{"q":1}}}""",
    )
    write(
        joinpath(dir, "buffer.json"),
        """{"solutes":[{"kind":"nonbiological","name":"NaCl",""" *
        """"arg":"sodium chloride","mM":150,"sigmaMm":5},""" *
        """{"kind":"protein","name":"carrier","arg":"MKTAYIAKQR",""" *
        """"mM":0.02,"sigmaMm":0.002}],"pH":$pH,"sigmaPh":0.1}""",
    )
    return dir
end

# A fit that does nothing but record that it ran.
function noopFit(st, rec, inputs, cfg, tee)
    return nothing
end

# (`:tui` watches stdin by default and would end the test process: the tests that want it
# say so, with a stream of their own)
quick(dir; kwargs...) = BAYSOLRun.runProject(
    dir; temperature = 20, tee = false, watchStdin = false, kwargs...,
)

runjson(r) = JSON3.read(read(joinpath(r.dir, "run.json"), String))

# A comparison table (`compare.tsv`): its header and its columns as numbers (`missing` for
# an empty cell).
function readCompare(path)
    lines = readlines(path)
    header = split(lines[1], '\t')
    rows = [split(l, '\t'; keepempty = true) for l in lines[2:end]]
    cols = [
        [isempty(r[j]) ? missing : parse(Float64, r[j]) for r in rows] for
        j in eachindex(header)
    ]
    return header, cols
end

@testset "runProject: UTC time without a package" begin
    @test _utcFields(0) == (1970, 1, 1, 0, 0, 0)
    @test _utcFields(1.7e9) == (2023, 11, 14, 22, 13, 20)
    @test _utcFields(951782400) == (2000, 2, 29, 0, 0, 0)            # a leap day
    # the run folder's name: local time, offset, date (an offset given: any zone testable)
    @test _runStamp(1.7e9, -5 * 3600, "EST") == "17-13-20-000_EST_-0500_2023-11-14"
    @test _runStamp(1.7e9 + 0.123, 0, "UTC") == "22-13-20-123_UTC_+0000_2023-11-14"
    @test _runStamp(1.7e9 + 0.123, 19800, "GMT") == "03-43-20-123_GMT_+0530_2023-11-15"
    # the same literals as tui/test/run.test.ts (instant 2026-11-08T04:35:29.123Z)
    @test _runStamp(1_794_112_529.123, -5 * 3600, "EST") ==
          "23-35-29-123_EST_-0500_2026-11-07"
    @test _runStamp(1_794_112_529.123, 0, "UTC") == "04-35-29-123_UTC_+0000_2026-11-08"
    @test length(_runStamp(1_794_112_529.123, -5 * 3600, "EST")) == 33
    # an accented label: the same text as
    # tui/test/run.test.ts (instant 02:35:29.123Z on the 8th)
    @test _runStamp(1_794_105_329.123, -3 * 3600, "SãoPaulo") ==
          "23-35-29-123_SãoPaulo_-0300_2026-11-07"
    for off in (0, -5 * 3600, 19800, 14 * 3600, -3600 - 1800)
        for t in (0.0, 1.7e9 + 0.123, 951782400.999, 4102444800.5)
            @test _parseRunStamp(_runStamp(t, off, "CEST")) == round(Int, t * 1000)
        end
    end
    # the zone label is opaque to the parser (3 or 4 letters), the instant is the same
    @test _parseRunStamp("17-13-20-000_XYZ_-0500_2023-11-14") == 1_700_000_000_000
    @test _parseRunStamp("17-13-20-000_EDT_-0500_2023-11-14") == 1_700_000_000_000
    @test _parseRunStamp("22-13-20-000_UTC_+0000_2023-11-14") == 1_700_000_000_000
    # any Unicode letters; a decomposed name (macOS) is the same name
    @test _parseRunStamp("23-35-29-123_SãoPaulo_-0300_2026-11-07") == 1_794_105_329_123
    @test _parseRunStamp("23-35-29-123_Sa\u0303oPaulo_-0300_2026-11-07") ==
          1_794_105_329_123
    @test _parseRunStamp("23-35-29-123_Ürümqi_-0300_2026-11-07") == 1_794_105_329_123
    for bad in
        ("", "run", "17-13-20-000_EST_-0500_14-11-2023", "17-13-20-00_EST_-0500_2023-11-14",
        "17:13:20-000_EST_-0500_2023-11-14", "17-13-20-000_EST_0500_2023-11-14",
        "17-13-20-000_EST_-0500_2023-02-31", "24-13-20-000_EST_-0500_2023-11-14",
        "17-60-20-000_EST_-0500_2023-11-14", "17-13-20-000_EST_-0560_2023-11-14",
        "17-13-20-000_EST_-0500_2023-13-14", "17-13-20-000__-0500_2023-11-14",
        "17-13-20-000_ES_-0500_2023-11-14", "17-13-20-000_E1T_-0500_2023-11-14",
        "17-13-20-000_E-T_-0500_2023-11-14",
        "22-13-20-000_UTC_+0000_2023-13-14", "25-13-20-000_UTC_+0000_2023-11-14",
        " 17-13-20-000_EST_-0500_2023-11-14",
    )
        @test _parseRunStamp(bad) === nothing
    end
    # the zone label: the platform's letters as they are, else the zone's own name, else
    # LOCAL; never GMT or UTC as a stand-in
    for (name, zone, label) in (
        ("EST", nothing, "EST"), ("CEST", "Berlin", "CEST"), ("est", nothing, "est"),
        ("Eastern Standard Time", nothing, "EasternStandardTime"),
        ("Coordinated Universal Time", nothing, "CoordinatedUniversalTime"),
        ("UTC", nothing, "UTC"), ("GMT", nothing, "GMT"),
        ("+03", "Istanbul", "Istanbul"), ("GMT-5", "Toronto", "Toronto"),
        ("+0530", "Kolkata", "Kolkata"), ("", "SãoPaulo", "SãoPaulo"),
        ("+03", "Sa\u0303oPaulo", "SãoPaulo"), ("+03", "ab", "LOCAL"),
        ("+03", "EST5EDT", "LOCAL"), ("", nothing, "LOCAL"), ("A", "B", "LOCAL"),
        ("GMT+5", nothing, "LOCAL"),
    )
        @test _zoneLabel(name, zone) == label
    end
    # the zone name: the last segment of TZ, underscores removed; a name that is no letters
    # (POSIX `EST5EDT`, `<+03>-3`) is none
    for (tz, name) in (
        ("America/Toronto", "Toronto"), ("Europe/Istanbul", "Istanbul"),
        ("America/Sao_Paulo", "SaoPaulo"), (":Asia/Kolkata", "Kolkata"),
        ("America/Argentina/Buenos_Aires", "BuenosAires"), ("UTC", "UTC"),
        (":/usr/share/zoneinfo/Asia/Ust-Nera", "UstNera"), ("EST5EDT", nothing),
        ("<+03>-3", nothing),
    )
        @test withenv(() -> _zoneName(), "TZ" => tz) == name
    end
    # the zone of the machine: the offset is a whole number of minutes
    @test _localOffset(1.7e9) % 60 == 0 && abs(_localOffset(1.7e9)) <= 14 * 3600
    @test occursin(r"^\p{L}{3,}$", _localZone(1.7e9))
    @test _parseRunStamp(_runStamp(1.7e9)) == 1_700_000_000_000
    @test _parseRunStamp(nothing) === nothing
    @test _parseRunStamp(nothing) === nothing
    @test _isoUtc(1.7e9) == "2023-11-14T22:13:20Z"
    for t in (0, 86399, 1.7e9, 4102444800, 1_000_000_007)
        @test _parseIsoUtc(_isoUtc(t)) == floor(t)
        @test _unixTime(_utcFields(t)...) == floor(t)
    end
    @test _parseIsoUtc("yesterday") === nothing
    @test _parseIsoUtc(nothing) === nothing
end

@testset "runProject: a failed model is told in a few words" begin
    brief = BAYSOLRun._briefError
    @test brief(BAYSOL.Inference.NotConvergedError(["the worst R̂ is above 1.01"])) ==
          "not converged"
    @test brief(ErrorException("the buffer is empty. Add a solute.")) ==
          "the buffer is empty"
    @test brief(ErrorException("line one\nline two")) == "line one"
    long = brief(ErrorException(repeat("a word ", 30)))
    @test length(long) <= BAYSOLRun._BRIEF_ERROR_WIDTH && !endswith(long, " ")
end

@testset "runProject: claiming a run folder" begin
    mktempdir() do dir
        runs = joinpath(dir, "runs")
        a = _claimRunDir(runs, 1.7e9)
        @test isdir(a) && basename(a) == _runStamp(1.7e9)
        # the same instant: EEXIST, the next millisecond, and never the same folder twice
        b = _claimRunDir(runs, 1.7e9)
        c = _claimRunDir(runs, 1.7e9)
        @test basename(b) == _runStamp(1.7e9 + 0.001) &&
              basename(c) == _runStamp(1.7e9 + 0.002)
        @test [_parseRunStamp(basename(x)) for x in (a, b, c)] ==
              [1_700_000_000_000, 1_700_000_000_001, 1_700_000_000_002]
        @test allunique([a, b, c])
        # what was in a claimed folder stays (nothing is overwritten)
        write(joinpath(a, "keep"), "x")
        _claimRunDir(runs, 1.7e9)
        @test read(joinpath(a, "keep"), String) == "x"
        # a claim races: only distinct folders come out of many at once
        got = fetch.([Threads.@spawn(_claimRunDir(runs, 1.8e9)) for _ in 1:8])
        @test allunique(got) && all(isdir, got)
    end
end

@testset "runProject: the models of a project" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "models"))
        for f in ("b.pdb", "a.CIF", "a.pdb", "run.pdb", "notes.txt", "c.pdb")
            write(joinpath(dir, "models", f), "x")
        end
        names = first.(_projectModels(dir))
        # a clash and a name the run's own files use (`run.LOG`) get a number
        @test names == ["a", "a-2", "b", "c", "run-2"]
        @test all(isabspath, last.(_projectModels(dir)))
        @test isempty(_projectModels(joinpath(dir, "nowhere")))
    end
end

@testset "runProject: the data of the snapshot" begin
    mktempdir() do dir
        write(joinpath(dir, "data.tsv"), "1.0\t10\t1\n\n2.0\t20\t2\n")
        meta = """{"units":"nm-1","energy":8000,"energyUnit":"eV","mapping":{}}"""
        write(joinpath(dir, "data.json"), meta)
        q, I, σ, e = _readSnapshotData(dir)
        @test q == [0.1, 0.2] && I == [10.0, 20.0] && σ == [1.0, 2.0] && e == 8000.0
        meta = """{"units":"A-1","energy":12400.5,"energyUnit":"eV"}"""
        write(joinpath(dir, "data.json"), meta)
        q, _, _, e = _readSnapshotData(dir)
        @test q == [1.0, 2.0] && e == 12400.5
        # the unit is a label: eV, keV, nm and A (wavelengths) give the same eV
        hc = BAYSOL.PhysicalConstants.HC_EV_ANGSTROM
        for (unit, value) in (("eV", 12000), ("keV", 12), ("A", hc / 12000),
            ("nm", hc / 120000))
            write(
                joinpath(dir, "data.json"),
                """{"units":"A-1","energy":$value,"energyUnit":"$unit"}""",
            )
            @test _readSnapshotData(dir)[4] ≈ 12000
        end
        # the unit is required
        write(joinpath(dir, "data.json"), """{"units":"A-1","energy":3}""")
        @test_throws ArgumentError _readSnapshotData(dir)
        write(
            joinpath(dir, "data.json"),
            """{"units":"A-1","energy":3,"energyUnit":"mm"}""",
        )
        @test_throws ArgumentError _readSnapshotData(dir)
        write(
            joinpath(dir, "data.json"),
            """{"units":"mm","energy":1,"energyUnit":"eV"}""",
        )
        @test_throws ArgumentError _readSnapshotData(dir)
        write(
            joinpath(dir, "data.json"),
            """{"units":"A-1","energy":0,"energyUnit":"eV"}""",
        )
        @test_throws ArgumentError _readSnapshotData(dir)
        write(
            joinpath(dir, "data.json"),
            """{"units":"A-1","energy":1,"energyUnit":"eV"}""",
        )
        write(joinpath(dir, "data.tsv"), "1.0\t10\n")
        err = try
            _readSnapshotData(dir)
        catch e
            e
        end
        @test err isa ArgumentError && occursin("line 1", err.msg)
        write(joinpath(dir, "data.tsv"), "1.0\t10\t1\n2.0\tx\t1\n")
        err = try
            _readSnapshotData(dir)
        catch e
            e
        end
        @test err isa ArgumentError && occursin("line 2", err.msg)
        rm(joinpath(dir, "data.tsv"))
        @test_throws ArgumentError _readSnapshotData(dir)
    end
end

@testset "runProject: the plot style of the settings" begin
    # no file: the defaults
    s = BAYSOLRun.loadSettings(joinpath(mktempdir(), "none.json"))
    style, default = _plotStyle(s), BAYSOL.PlotStyle()
    for f in fieldnames(BAYSOL.PlotStyle)
        @test getfield(style, f) == getfield(default, f)
    end
    s[:PLOT_LW_MAP] = 3.5
    s[:PLOT_COLOUR_MAP] = :navy
    @test _plotStyle(s).lwMap == 3.5 && _plotStyle(s).colorMap == :navy
end

@testset "runProject: the plot folder is one for all projects, laid out per model" begin
    s = BAYSOLRun.loadSettings(joinpath(mktempdir(), "none.json"))
    stamp = "23-35-29-123_EST_-0500_2026-11-07"
    st = (; project = joinpath("data", "projects", "demo"),
        dir = joinpath("data", "projects", "demo", "runs", stamp))
    kw = BAYSOL.resultsKeywords(s)
    # no plot folder (the default): the keywords are untouched
    @test kw.plotDir == "" && BAYSOLRun._modelResultsKw(kw, st, "crambin") === kw
    @test kw.latexCompiler == ""
    # with one: <plot dir>/<project>/<run>/<model>
    kw2 = merge(kw, (; plotDir = joinpath("out", "plots")))
    @test BAYSOLRun._modelResultsKw(kw2, st, "crambin").plotDir ==
          joinpath("out", "plots", "demo", "23-35-29-123_EST_-0500_2026-11-07", "crambin")
end

@testset "runProject: arguments and the live run" begin
    mktempdir() do dir
        @test_throws ArgumentError quick(joinpath(dir, "missing"))
        makeProject(dir)
        @test_throws ArgumentError quick(dir; ui = :gui)
        @test_throws ArgumentError BAYSOLRun.runProject(dir; temperature = -300)
        @test_throws ArgumentError quick(dir; runDir = joinpath(dir, "nowhere"))
        @test !isdir(joinpath(dir, RUN_FOLDER))          # nothing is written for those

        # a live run (running, a fresh heartbeat, this very process) refuses a second one
        live = joinpath(dir, RUN_FOLDER, "00-00-00-000_UTC_+0000_2020-01-01")
        mkpath(live)
        function beat(t; status = "running", pid = getpid())
            _writeJsonAtomic(
                joinpath(live, "run.json"),
                (; status, pid, host = gethostname(), heartbeat = _isoUtc(t)),
            )
        end
        beat(time())
        @test _liveRun(joinpath(dir, RUN_FOLDER)) == getpid()
        err = try
            quick(dir; fit = noopFit)
        catch e
            e
        end
        @test err isa ErrorException && occursin("a run is in progress", err.msg)
        @test occursin("pid $(getpid())", err.msg)
        @test readdir(joinpath(dir, RUN_FOLDER)) == ["00-00-00-000_UTC_+0000_2020-01-01"]
        # no longer live: an old heartbeat, a finished run, a process that is gone
        beat(time() - RUN_STALE_S - 5)
        @test _liveRun(joinpath(dir, RUN_FOLDER)) === nothing
        beat(time(); status = "done")
        @test _liveRun(joinpath(dir, RUN_FOLDER)) === nothing
        if Sys.isunix()
            beat(time(); pid = 2^22 + 12345)            # above any pid_max
            @test _liveRun(joinpath(dir, RUN_FOLDER)) === nothing
        end
        @test quick(dir; fit = noopFit).status == :done
    end
end

@testset "runProject: every setting is a keyword and reaches the fit" begin
    defaults = BAYSOLRun.loadSettings(joinpath(mktempdir(), "none.json"))
    mktempdir() do dir
        makeProject(dir)
        seen = Ref{Any}(nothing)
        function grab(st, rec, inputs, cfg, tee)
            seen[] = (inputs, cfg)
            return nothing
        end
        # no settings.json, no keyword: the constants, through the same helpers
        @test quick(dir; fit = grab).status == :done
        inputs, cfg = seen[]
        @test inputs.seedKw == BAYSOL.seedKeywords(defaults)
        @test cfg.runKw == merge(
            BAYSOL.runKeywords(defaults), (; retry = BAYSOL.Inference.RETRY),
        )
        @test cfg.resultsKw == BAYSOL.resultsKeywords(defaults)
        @test (cfg.nSamples, cfg.nAdapt, cfg.δ) == (1000, 300, 95)

        # a keyword of every kind of entry point overrides the default
        r = quick(
            dir; fit = grab, thickness = 2.5, sasaNOcc = 100, shellSample = 200,
            bounds_δρ₁₂ = (-8, 3), φ_max = 1.5, mapNStarts = 9,
            chainStartRadii = (1, 2, 3), harvestCover = 4, δ = 90, nDraws = 5,
            tex = false, formats = (:pdf, :svg), tableSigfigs = 5,
            style = BAYSOL.PlotStyle(lwMap = 3.0), sigma = 1, nChains = 3,
        )
        @test r.status == :done
        inputs, cfg = seen[]
        @test inputs.seedKw.thickness == 2.5 && inputs.seedKw.sasaNOcc == 100
        @test inputs.seedKw.shellSample == 200 && inputs.seedKw.φ_max == 1.5
        @test inputs.seedKw.bounds_δρ₁₂ == (-8.0, 3.0)
        @test inputs.seedKw.probe == defaults[:PROBE_RADIUS]      # the rest is as it was
        @test cfg.runKw.mapNStarts == 9 && cfg.runKw.harvestCover == 4
        @test cfg.runKw.chainStartRadii == (1.0, 2.0, 3.0) && cfg.runKw.δ == 90
        @test cfg.runKw.sigma == 1 && cfg.runKw.nChains == 3
        @test cfg.runKw.retryNAdapt == 2000
        @test (cfg.nAdapt, cfg.nSamples) == (300, 305)          # 300 warm-up + 5 draws
        @test cfg.resultsKw.tex == false && cfg.resultsKw.formats == (:pdf, :svg)
        @test cfg.resultsKw.tableSigfigs == 5 && cfg.resultsKw.style.lwMap == 3.0

        # the project's settings.json is the base, and a keyword wins over it
        write(
            joinpath(dir, "settings.json"),
            "{\"sampler\": {\"MAP_N_STARTS\": {\"value\": 12}, " *
            "\"SASA_N_OCC\": {\"value\": 90}}}",
        )
        quick(dir; fit = grab)
        @test seen[][1].seedKw.sasaNOcc == 90 && seen[][2].runKw.mapNStarts == 12
        quick(dir; fit = grab, mapNStarts = 9)
        @test seen[][2].runKw.mapNStarts == 9 && seen[][1].seedKw.sasaNOcc == 90

        # a bad keyword value, or one that breaks a rule with the file's settings, fails
        # the run before any model, as a bad settings.json does
        r = quick(dir; fit = grab, mapNStarts = 0)
        @test r.status == :failed && isempty(r.models) == false
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test occursin("MAP_N_STARTS = 0", text) && occursin("at least 1", text)
        @test runjson(r).models[1].status == "skipped"
        r = quick(dir; fit = grab, shellSample = 80)      # the file's SASA_N_OCC is 90
        @test r.status == :failed &&
              occursin("SASA_N_OCC = 90", read(joinpath(r.dir, "run.LOG"), String))
        # the two ways to say how many draws are not both allowed; a name that is no
        # keyword is not accepted
        @test_throws ArgumentError quick(dir; fit = grab, nSamples = 10, nDraws = 5)
        @test_throws MethodError quick(dir; fit = grab, no_such_setting = 1)

        # the data and structure keywords: from the file, or overridden; `nothing` clears
        # a saved qMax and `:settings` (the default) keeps it
        write(
            joinpath(dir, "settings.json"),
            "{\"data\": {\"Q_MAX\": {\"value\": 0.25}, \"LMAX\": {\"value\": 9}," *
            " \"CHAINS\": {\"value\": [\"A\"]}}}",
        )
        quick(dir; fit = grab)
        kw = seen[][1].seedKw
        @test kw.qMax == 0.25 && kw.qMin === nothing && kw.lMax == 9
        @test kw.chains == ("A",) && kw.model == 1 && kw.addHydrogens === true
        @test kw.sigmaScale == 1.0 && kw.excludeQ == ()
        quick(dir; fit = grab, qMax = nothing, lMax = nothing, chains = ())
        kw = seen[][1].seedKw
        @test kw.qMax === nothing && kw.lMax === nothing && kw.chains == ()
        quick(
            dir; fit = grab, qMin = 0.02, sigmaScale = 2, excludeQ = ((0.1, 0.12),),
            model = 2, addHydrogens = false, lMax = 5,
        )
        kw = seen[][1].seedKw
        @test kw.qMin == 0.02 && kw.qMax == 0.25 && kw.sigmaScale == 2.0
        @test kw.excludeQ == ((0.1, 0.12),) && kw.model == 2
        @test kw.addHydrogens === false && kw.lMax == 5
        r = quick(dir; fit = grab, qMin = 0.4)          # above the file's Q_MAX
        @test r.status == :failed &&
              occursin("Q_MIN = 0.4", read(joinpath(r.dir, "run.LOG"), String))
    end
end

@testset "runProject: the folder, run.json and the LOG of a run" begin
    mktempdir() do dir
        makeProject(
            dir;
            models = [
                "m1.pdb" => _RP_CRAMBIN,
                "m2.cif" => _RP_CRAMBIN,
                "m3.pdb" => _RP_CRAMBIN,
            ],
        )
        r = quick(dir; fit = noopFit, ui = :tui, rngSeed = 5, nChains = 2)
        @test r.status == :done
        @test dirname(r.dir) == joinpath(dir, "runs") &&
              _parseRunStamp(basename(r.dir)) !== nothing
        @test [m.name for m in r.models] == ["m1", "m2", "m3"]
        @test all(m -> m.status == :done, r.models)
        for f in ("settings.json", "buffer.json", "solutes.json", "data.tsv", "data.json",
            "models.json", "run.LOG")
            @test isfile(joinpath(r.dir, f))
        end
        @test sort(readdir(r.dir)) == sort(
            ["settings.json", "buffer.json", "solutes.json", "data.tsv", "data.json",
            "models.json", "run.LOG", "run.json"],
        )                                              # flat: no folder, no stage left
        j = runjson(r)
        @test j.status == "done" && j.ui == "tui" && j.pid == getpid()
        @test j.host == gethostname() && j.project == abspath(dir)
        @test j.rngSeed == 5
        @test _parseIsoUtc(j.started) !== nothing && _parseIsoUtc(j.ended) !== nothing
        @test _parseIsoUtc(j.heartbeat) !== nothing
        @test j.julia == string(VERSION) && startswith(j.baysol, "v")
        @test [m.name for m in j.models] == ["m1", "m2", "m3"]
        @test all(
            m -> m.status == "done" && m.error === nothing && m.seconds >= 0,
            j.models,
        )
        @test all(m -> m.size == filesize(_RP_CRAMBIN) && length(m.sha256) == 64, j.models)
        @test j.models[1].path == abspath(joinpath(dir, "models", "m1.pdb"))
        @test haskey(j.timings, :seconds) && haskey(j.timings.models, :m1)
        @test !any(isfile, filter(f -> occursin(".tmp.", f), readdir(r.dir; join = true)))

        # run.LOG: the conditions as flat rows, the output, the result
        rows = logRows(joinpath(r.dir, "run.LOG"))
        @test rows["temperatureC"] == "20.0" && rows["ph"] == "7.4"
        @test rows["sigmaPh"] == "0.1" && rows["energyEv"] == "8000.0"
        @test rows["models"] == "3" && rows["rngSeed"] == "5" && rows["ui"] == "tui"
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test occursin("--- output ---", text) && occursin("--- result ---", text)
        @test occursin(r"status\s+\tdone", text) && occursin(r"modelsDone\s+\t3", text)
        @test !occursin("=== ERRORS ===", text)

        # solutes.json: each solute resolved, the sequence only summarised
        sol = JSON3.read(read(joinpath(r.dir, "solutes.json"), String))
        @test sol.temperatureC == 20 && sol.pH == 7.4 && sol.sigmaPh == 0.1
        @test sol.rhoE > 0.3 && sol.sigmaRhoE > 0
        @test [s.name for s in sol.solutes] == ["NaCl", "carrier"]
        @test sol.solutes[1].Z == 28 && sol.solutes[1].arg == "sodium chloride"
        @test sol.solutes[1].mM == 150 && sol.solutes[1][Symbol("sigmaMm")] == 5
        @test sol.solutes[1].pmv > 0 && sol.solutes[1][Symbol("sigmaPmv")] >= 0
        @test sol.solutes[2].kind == "protein" && sol.solutes[2].Z > 0
        @test sol.solutes[2].sequence.length == 10 && !haskey(sol.solutes[2], :arg)
        # the snapshot is a copy of the project's files
        for f in ("buffer.json", "data.tsv", "data.json")
            @test read(joinpath(r.dir, f), String) == read(joinpath(dir, f), String)
        end
        @test read(joinpath(r.dir, "settings.json"), String) == "{}\n"
        # a second run is a second folder; nothing of the first is touched
        r2 = quick(dir; fit = noopFit)
        @test r2.dir != r.dir && length(readdir(joinpath(dir, "runs"))) == 2
        @test runjson(r).status == "done"
    end
end

@testset "runProject: a failing model is recorded and the loop goes on" begin
    mktempdir() do dir
        makeProject(
            dir;
            models = ["a.pdb" => _RP_CRAMBIN, "b.pdb" => _RP_CRAMBIN,
                "c.pdb" => _RP_CRAMBIN],
        )
        function flaky(st, rec, inputs, cfg, tee)
            noopFit(st, rec, inputs, cfg, tee)
            rec.name == "b" && throw(ArgumentError("no radius for the element Xx"))
            return nothing
        end
        r = quick(dir; fit = flaky)
        @test r.status == :failed
        @test [m.status for m in r.models] == [:done, :failed, :done]     # c still ran
        j = runjson(r)
        @test j.status == "failed"
        @test j.models[2].status == "failed" && occursin("no radius", j.models[2].error)
        @test j.models[1].error === nothing
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test occursin("=== ERRORS ===", text) && occursin("model b", text)
        @test occursin("no radius for the element Xx", text)
        @test occursin(r"modelsFailed\s+\t1", text)
        # the failed model has a LOG too, with the conditions and what went wrong
        rows = logRows(joinpath(r.dir, "b.LOG"))
        @test rows["status"] == "failed" && occursin("no radius", rows["error"])
        @test occursin("temperatureC", read(joinpath(r.dir, "b.LOG"), String))
    end
    # invalid inputs fail the run before any model, and the reason is in the files
    mktempdir() do dir
        makeProject(dir)
        write(joinpath(dir, "buffer.json"), """{"solutes":[]}""")                # no pH
        r = quick(dir; fit = noopFit)
        @test r.status == :failed && [m.status for m in r.models] == [:skipped]
        @test occursin(
            "InvalidBufferError",
            read(joinpath(r.dir, "run.LOG"), String),
        )
        @test runjson(r).status == "failed"
    end
    mktempdir() do dir
        makeProject(dir; models = Pair{String,String}[])
        r = quick(dir; fit = noopFit)
        @test r.status == :failed && isempty(r.models)
        @test occursin("no model", read(joinpath(r.dir, "run.LOG"), String))
    end
end

@testset "runProject: an interrupt marks the run aborted" begin
    mktempdir() do dir
        makeProject(
            dir;
            models = ["a.pdb" => _RP_CRAMBIN, "b.pdb" => _RP_CRAMBIN,
                "c.pdb" => _RP_CRAMBIN],
        )
        function ctrlC(st, rec, inputs, cfg, tee)
            rec.name == "b" && throw(InterruptException())
            return noopFit(st, rec, inputs, cfg, tee)
        end
        r = quick(dir; fit = ctrlC)
        @test r.status == :aborted
        @test [m.status for m in r.models] == [:done, :aborted, :skipped]
        j = runjson(r)
        @test j.status == "aborted" && j.ended !== nothing
        @test [m.status for m in j.models] == ["done", "aborted", "skipped"]
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test occursin(r"status\s+\taborted", text) &&
              occursin(r"modelsSkipped\s+\t1", text)
        @test !occursin("=== ERRORS ===", text)           # an abort is no error
    end
    # the end of the standard input (the caller is gone) stops the run after the model
    mktempdir() do dir
        makeProject(dir; models = ["a.pdb" => _RP_CRAMBIN, "b.pdb" => _RP_CRAMBIN])
        pipe = Base.BufferStream()
        function closesStdin(st, rec, inputs, cfg, tee)
            noopFit(st, rec, inputs, cfg, tee)
            close(pipe)
            sleep(0.5)                                     # the watcher sees it
            return nothing
        end
        r = quick(dir; fit = closesStdin, ui = :tui, watchStdin = true, stdinIo = pipe,
            exitOnEof = false)
        @test r.status == :aborted
        @test [m.status for m in r.models] == [:done, :skipped]
    end
    # on a terminal (`:cli`) the end of stdin means nothing: it is not watched
    mktempdir() do dir
        makeProject(dir)
        pipe = Base.BufferStream()
        close(pipe)
        r = BAYSOLRun.runProject(
            dir; temperature = 20, tee = false, fit = noopFit, stdinIo = pipe,
            exitOnEof = false,
        )
        @test r.status == :done
    end
end

@testset "runProject: the heartbeat" begin
    mktempdir() do dir
        makeProject(dir)
        seen = String[]
        function slow(st, rec, inputs, cfg, tee)
            noopFit(st, rec, inputs, cfg, tee)
            for _ in 1:8
                sleep(0.5)
                j = JSON3.read(read(joinpath(st.dir, "run.json"), String))
                j.status == "running" && push!(seen, j.heartbeat)
            end
        end
        r = quick(dir; fit = slow, heartbeat = 0.3)
        # run.json is rewritten while the model runs: the heartbeat moves
        @test length(unique(seen)) >= 3
        @test runjson(r).status == "done"
    end
end

@testset "runProject: the snapshot does not follow later edits" begin
    mktempdir() do dir
        makeProject(dir)
        before = (read(joinpath(dir, "buffer.json"), String),
            read(joinpath(dir, "data.tsv"), String))
        seen = Ref{Any}(nothing)
        function edited(st, rec, inputs, cfg, tee)
            seen[] = (
                inputs.pH,
                inputs.σ_pH,
                inputs.energy,
                copy(inputs.q),
                length(inputs.solutes),
            )
            # the user edits the project while the run goes on
            write(
                joinpath(dir, "buffer.json"),
                """{"solutes":[],"pH":9.0,"sigmaPh":1.0}""",
            )
            write(joinpath(dir, "data.tsv"), "1\t1\t1\n")
            write(
                joinpath(dir, "data.json"),
                """{"units":"A-1","energy":1,"energyUnit":"eV"}""",
            )
            rm(joinpath(dir, "models", "crambin.pdb"))
            return noopFit(st, rec, inputs, cfg, tee)
        end
        r = quick(dir; fit = edited)
        @test r.status == :done
        @test seen[][1:3] == (7.4, 0.1, 8000.0) && seen[][5] == 2
        @test seen[][4][1] ≈ 0.01                           # nm⁻¹ read as Å⁻¹
        @test read(joinpath(r.dir, "buffer.json"), String) == before[1]
        @test read(joinpath(r.dir, "data.tsv"), String) == before[2]
        rows = logRows(joinpath(r.dir, "run.LOG"))
        @test rows["ph"] == "7.4" && rows["energyEv"] == "8000.0"
        @test runjson(r).models[1].path == abspath(joinpath(dir, "models", "crambin.pdb"))
    end
end

@testset "runProject: a claimed folder and a snapshot made by the caller" begin
    mktempdir() do dir
        makeProject(dir)
        mine = joinpath(dir, "runs", "00-00-00-000_UTC_+0000_2030-01-01")
        mkpath(mine)
        # the caller's own snapshot of the buffer is the one the run uses, not the project's
        write(
            joinpath(mine, "buffer.json"),
            """{"solutes":[],"pH":6.5,"sigmaPh":0.2}""",
        )
        pH = Ref(0.0)
        r = quick(dir; runDir = mine, fit = (st, rec, inp, cfg, tee) -> (pH[] = inp.pH))
        @test r.dir == mine
        @test readdir(joinpath(dir, "runs")) == ["00-00-00-000_UTC_+0000_2030-01-01"]
        @test pH[] == 6.5
        @test runjson(r).status == "done"
        @test isfile(joinpath(mine, "data.tsv"))   # the rest: the project's
    end
end

@testset "runProject: the whole fit, end to end" begin
    mktempdir() do dir
        makeProject(
            dir;
            models = [
                "a-broken.pdb" => "this is not a structure\n",
                "crambin.pdb" => _RP_CRAMBIN,
            ],
        )
        # a setting of this model's own, in the project's model-settings.json
        write(
            joinpath(dir, "model-settings.json"),
            """{"crambin": {"data": {"SIGMA_SCALE": {"value": 1.5}}}}""",
        )
        # the depositor's curve of this model and its chi2 (model-references.json)
        mkpath(joinpath(dir, "reference-fit"))
        write(
            joinpath(dir, "reference-fit", "CRYSOL.tsv"),
            join(("$q\t$(900 * exp(-q^2 * 100 / 3))" for q in 1.0:0.5:3.0), "\n") * "\n",
        )
        write(
            joinpath(dir, "model-references.json"),
            """{"crambin": {"fit": "CRYSOL.tsv", "software": "CRYSOL", "tag": "m1",""" *
            """"refChi2": "CRYSOL 1.37"}}""",
        )
        r = BAYSOLRun.runProject(
            dir; temperature = 25, ui = :tui, watchStdin = false, nSamples = 300,
            nAdapt = 150, nChains = 2,
            retry = false, addHydrogens = false,
        )
        # the broken model failed, the next one was fitted
        @test r.status == :failed
        @test [m.status for m in r.models] == [:failed, :done]
        run = r.dir
        @test isfile(joinpath(run, "crambin.LOG")) &&
              isfile(joinpath(run, "crambin.xlsx"))
        @test isfile(joinpath(run, "crambin.tex"))
        @test !any(isdir, readdir(run; join = true))     # the run folder is flat
        # the model's files are listed in run.json
        @test "crambin.xlsx" in runjson(r).models[2].files &&
              "crambin.tex" in runjson(r).models[2].files &&
              "crambin-plots.txt" in runjson(r).models[2].files
        rows = logRows(joinpath(run, "crambin.LOG"))
        @test rows["temperatureC"] == "25.0" && rows["ph"] == "7.4"
        @test rows["sigmaPh"] == "0.1" && rows["energyEv"] == "8000.0"
        @test rows["nAtoms"] == "327" && haskey(rows, "chi2")
        # the setup rows sit together, before the sizes
        names = [first(split(l, '\t')) for l in eachline(joinpath(run, "crambin.LOG"))]
        names = strip.(names)
        @test findfirst(==("temperatureC"), names) < findfirst(==("nAtoms"), names)
        # the plots are plain text, in the model's and the run's plots.txt
        plots = read(joinpath(run, "crambin-plots.txt"), String)
        @test occursin("χ²", plots) && !occursin('\e', plots)
        @test occursin(
            "=== crambin ===",
            read(joinpath(r.dir, "plots.txt"), String),
        )
        # the override is in the LOG next to the setting that it changed, and in run.json
        @test rows["overrideSigmaScale"] == "1.5" && rows["sigmaScale"] == "1.5"
        @test !any(startswith("override"), names[1:findfirst(==("temperatureC"), names)])
        j = runjson(r)
        @test collect(j.models[2].overrides) == ["SIGMA_SCALE"] &&
              isempty(j.models[1].overrides)
        @test isfile(joinpath(r.dir, "model-settings.json"))
        # the model's figure holds the reference curve and both chi2; the LOG the
        # depositor's
        @test isfile(joinpath(r.dir, "model-references.json"))
        @test rows["refChi2"] == "CRYSOL 1.37"
        tex = read(joinpath(run, "crambin_comparison.tex"), String)
        @test occursin("CRYSOL m1", tex) && occursin("(CRYSOL 1.37)", tex)
        @test occursin("BAYSOL MAP", tex) && occursin("χ² = ", tex)
        @test "crambin_comparison.tex" in runjson(r).models[2].files
        # the terminal plots at every size, measured:
        # the smallest fits 76 columns by 10 rows
        sizes = BAYSOL.Pipeline.PLOT_TUI_SIZES
        entries = j.models[2].plotSizes
        @test [e.file for e in entries] ==
              ["crambin-$(W)x$(H).txt" for (W, H) in sizes]
        for (e, (W, H)) in zip(entries, sizes)
            text = read(joinpath(r.dir, e.file), String)
            lines = split(strip(text), '\n')
            @test e.width == maximum(textwidth, lines) <= W
            @test e.rows ==
                  maximum(
                      length(split(b, '\n')) for b in split(strip(text), r"\n[ \t]*\n")
                  ) <= H + 5
        end
        @test entries[1].width <= 76 && entries[1].rows <= 10
        @test isempty(j.models[1].plotSizes)                  # the broken one drew nothing
        # plots.txt is the plot of the setting's PLOT_PREVIEW_SIZE alone: it is what the
        # run's plots.txt holds under the model's name
        body = read(joinpath(r.dir, "plots.txt"), String)
        @test occursin("=== crambin ===\n" * plots, body)
        # run.LOG: the output of the run is in it, then the result and the one error
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test occursin("=== model crambin ===", text) && occursin("Fit finished", text)
        @test occursin("=== ERRORS ===", text) && occursin("model a-broken", text)
        @test runjson(r).models[1].error !== nothing
    end
end

# ---------------------------------------------------------------------------
# the combined comparison of a run, and the reference curves of a project
# ---------------------------------------------------------------------------

# A fit that hands back a stand-in result (the MAP curve and its chi2, which the comparison
# reads) scaled by `k`, on the q the project's curve has (60 points, 0.01 to 0.3 Å⁻¹).
function resultFit(k)
    return function (st, rec, inputs, cfg, tee)
        q = inputs.q
        I = 1000 .* exp.(-(q .* 10) .^ 2 .* 100 ./ 3) .* k
        return (; result = (nothing, 0.0, (Dict("chisqRed" => 1.5k), hcat(q, I)), nothing))
    end
end

# the references of a test project: two good curves, one bad file and one of another kind
function addReferences(dir; folder = "reference-fit")
    refs = joinpath(dir, folder)
    mkpath(refs)
    # q in nm⁻¹ like the project's data: 1 to 3 nm⁻¹ is 0.1 to 0.3 Å⁻¹
    write(
        joinpath(refs, "CRYSOL.tsv"),
        "# fit\n" *
        join(
            ("$(q)\t$(900 * exp(-q^2 * 100 / 3))" for q in 1.0:0.5:3.0), "\n") * "\n",
    )
    write(joinpath(refs, "FoXS.dat"), "1.0 800 5\n2.0 700 5\n3.0 600 5\n")
    write(joinpath(refs, "broken.txt"), "1.0 800\nthis is not a curve\n")
    write(joinpath(refs, "readme.md"), "not a curve")
    return refs
end

@testset "runProject: the comparison figure of a run" begin
    mktempdir() do dir
        makeProject(dir; models = ["m1.pdb" => _RP_CRAMBIN, "m2.pdb" => _RP_CRAMBIN])
        addReferences(dir)
        function fit(st, rec, inputs, cfg, tee)
            resultFit(rec.name == "m1" ? 1.0 : 1.2)(st, rec, inputs, cfg, tee)
        end
        r = quick(dir; fit, ui = :tui)
        @test r.status == :done                      # a bad reference file fails nothing
        cdir = r.dir                                 # the run folder is flat
        name = basename(r.dir)
        sizes = BAYSOL.Pipeline.PLOT_TUI_SIZES
        @test sort(filter(startswith("compare"), readdir(cdir))) == sort(
            vcat(["compare-plots.txt", "compare.tex", "compare.tsv"],
                ["compare-$(W)x$(H).txt" for (W, H) in sizes]),
        )
        @test !any(isdir, readdir(cdir; join = true))
        # the snapshot has the references, not the files of other kinds
        @test sort(filter(startswith("reference-fit-"), readdir(r.dir))) ==
              ["reference-fit-CRYSOL.tsv", "reference-fit-FoXS.dat",
            "reference-fit-broken.txt"]
        j = runjson(r)
        @test j.compare.status == "done" && j.compare.error === nothing
        @test collect(j.compare.files) ==
              ["compare.tex", "compare.tsv", "compare-plots.txt"]
        @test collect(j.compare.models) == ["m1", "m2"]
        @test collect(j.compare.references) == ["CRYSOL", "FoXS"]
        # the plot at each size: the file, its measured width and its rows
        @test [p.file for p in j.compare.plotSizes] ==
              ["compare-$(W)x$(H).txt" for (W, H) in sizes]
        for (p, (W, H)) in zip(j.compare.plotSizes, sizes)
            lines = split(strip(read(joinpath(r.dir, p.file), String)), '\n')
            @test p.width == maximum(textwidth, lines) && p.rows == length(lines)
            @test p.width <= W && p.rows <= H + 5
        end
        @test j.compare.plotSizes[1].width <= 76 && j.compare.plotSizes[1].rows <= 10
        @test all(f -> isfile(joinpath(r.dir, f)), j.compare.files)
        # the plot is plain text, in the comparison's and the run's plots.txt
        plots = read(joinpath(cdir, "compare-plots.txt"), String)
        @test occursin("comparison", plots) && occursin("CRYSOL", plots) &&
              !occursin('\e', plots)
        @test occursin(
            "=== compare ===",
            read(joinpath(r.dir, "plots.txt"), String),
        )
        # the table: the models and both references (q in nm⁻¹ was divided by 10)
        header, cols = readCompare(joinpath(cdir, "compare.tsv"))
        @test header[4:end] == ["fit_m1 (a.u.)", "fit_m2 (a.u.)",
            "ref_CRYSOL (a.u.)", "ref_FoXS (a.u.)"]
        @test cols[1] ≈ range(0.01, 0.3; length = 60) atol = DEFAULT_ATOL
        @test cols[5][end] ≈ 1.2 * cols[4][end] atol = DEFAULT_ATOL
        # the references lie inside 0.1 to 0.3: none of the first points has a value
        @test all(ismissing, cols[6][1:4]) && !ismissing(cols[6][end])
        # the bad reference is a note in the ERRORS section and nothing more
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test occursin("=== ERRORS ===", text) && occursin("broken.txt was skipped", text)
        @test occursin("line 2", text) && !occursin("compare:", text)
        @test occursin(r"status\s+\tdone", text)
        # not printed in :tui, printed in :cli (to the terminal, past run.LOG)
        out = mktemp() do path, io
            redirect_stdout(io) do
                quick(dir; fit, ui = :cli)
            end
            close(io)
            read(path, String)
        end
        @test occursin("comparison", out)
        # `:cli` prints the default size only: no files of the other sizes
        rc = quick(dir; fit, ui = :cli)
        @test !any(f -> occursin(r"^compare-\d+x\d+\.txt$", f), readdir(rc.dir))
        @test isempty(runjson(rc).compare.plotSizes)
        # the sizes are a keyword too, checked as the setting is
        rs = quick(dir; fit, ui = :tui, plotTuiSizes = ((70, 4), (90, 7)))
        @test [p.file for p in runjson(rs).compare.plotSizes] ==
              ["compare-70x4.txt", "compare-90x7.txt"]
        rb = quick(dir; fit, ui = :tui, plotTuiSizes = ((70, 4), (60, 7)))
        @test rb.status == :failed
        @test occursin("PLOT_TUI_SIZES", read(joinpath(rb.dir, "run.LOG"), String))
        out = mktemp() do path, io
            redirect_stdout(io) do
                quick(dir; fit, ui = :tui)
            end
            close(io)
            read(path, String)
        end
        @test !occursin("comparison", out)
    end
end

@testset "runProject: tableDir copies the data without replacing a file" begin
    using Main.BAYSOLRun: _freeNames
    mktempdir() do folder
        @test _freeNames(folder, ["a.xlsx", "a.txt"]) == ["a.xlsx", "a.txt"]
        write(joinpath(folder, "a.xlsx"), "x")
        # one taken name numbers the whole unit, the number that frees every name
        @test _freeNames(folder, ["a.xlsx", "a.txt"]) == ["a-2.xlsx", "a-2.txt"]
        write(joinpath(folder, "a-2.txt"), "x")
        @test _freeNames(folder, ["a.xlsx", "a.txt"]) == ["a-3.xlsx", "a-3.txt"]
    end
    mktempdir() do dir
        makeProject(dir; models = ["a.pdb" => _RP_CRAMBIN, "b.pdb" => _RP_CRAMBIN])
        mktempdir() do folder
            project = basename(dir)
            r1 = quick(dir; ui = :tui, fit = resultFit(1.0), tableDir = folder)
            @test r1.status == :done
            @test readdir(folder) == ["$project-compare.tsv"]
            # a second run does not replace the first one's file
            r2 = quick(dir; ui = :tui, fit = resultFit(1.0), tableDir = folder)
            @test sort(readdir(folder)) ==
                  ["$project-compare-2.tsv", "$project-compare.tsv"]
            @test read(joinpath(folder, "$project-compare.tsv"), String) ==
                  read(joinpath(r1.dir, "compare.tsv"), String)
            # the setting is a path: a bad value is refused as the others are
            bad = quick(dir; fit = noopFit, tableDir = "a\nb")
            @test bad.status == :failed &&
                  occursin("TABLE_DIR", read(joinpath(bad.dir, "run.LOG"), String))
        end
    end
end

@testset "runProject: the comparison switched off, absent or failing" begin
    mktempdir() do dir
        makeProject(dir; models = ["a.pdb" => _RP_CRAMBIN, "b.pdb" => _RP_CRAMBIN])
        addReferences(dir)
        # the switch, as a keyword and as a setting: no folder, no key in run.json
        r = quick(dir; ui = :tui, fit = resultFit(1.0), plotCompare = false)
        @test r.status == :done && !isfile(joinpath(r.dir, "compare.tsv"))
        @test !haskey(runjson(r), :compare)
        write(
            joinpath(dir, "settings.json"),
            "{\"plots\": {\"PLOT_COMPARE\": {\"value\": false}}}",
        )
        r = quick(dir; ui = :tui, fit = resultFit(1.0))
        @test !isfile(joinpath(r.dir, "compare.tsv")) && !haskey(runjson(r), :compare)
        # a keyword wins over the file
        r = quick(dir; ui = :tui, fit = resultFit(1.0), plotCompare = true)
        @test isfile(joinpath(r.dir, "compare.tsv")) && runjson(r).compare.status == "done"
        rm(joinpath(dir, "settings.json"))
        # nothing came back from the fits (the seam of the other tests): no comparison
        r = quick(dir; ui = :tui, fit = noopFit)
        @test r.status == :done && !isfile(joinpath(r.dir, "compare.tsv"))
        @test !haskey(runjson(r), :compare)
        # a model that failed is not in it, the one that finished is (one model is fine)
        function half(st, rec, inputs, cfg, tee)
            rec.name == "a" && throw(ArgumentError("no radius for the element Xx"))
            resultFit(1.0)(st, rec, inputs, cfg, tee)
        end
        r = quick(dir; ui = :tui, fit = half)
        @test r.status == :failed && runjson(r).compare.status == "done"
        @test collect(runjson(r).compare.models) == ["b"]
        # a comparison that fails is a note in the ERRORS section: the status stays
        function bad(st, rec, inputs, cfg, tee)
            return (;
                result = (nothing, 0.0, (Dict("chisqRed" => 1.0), zeros(3, 1)), nothing)
            )
        end
        r = quick(dir; ui = :tui, fit = bad)
        @test r.status == :done && [m.status for m in r.models] == [:done, :done]
        j = runjson(r)
        @test j.status == "done" && j.compare.status == "failed"
        @test j.compare.error isa String && isempty(j.compare.files)
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test occursin("=== ERRORS ===", text) && occursin("compare:", text)
        @test occursin(r"modelsDone\s+\t2", text)
        # an interrupted run makes none
        function stop(st, rec, inputs, cfg, tee)
            resultFit(1.0)(st, rec, inputs, cfg, tee)
            st.abortRequested = true
        end
        r = quick(dir; ui = :tui, fit = stop)
        @test r.status == :aborted && !haskey(runjson(r), :compare)
    end
    # a model named `compare` does not take the comparison's folder
    mktempdir() do dir
        mkpath(joinpath(dir, "models"))
        write(joinpath(dir, "models", "compare.pdb"), "x")
        @test first.(_projectModels(dir)) == ["compare-2"]
    end
    mktempdir() do dir
        makeProject(dir)
        addReferences(dir)
        run = mktempdir()
        cp(joinpath(dir, "data.json"), joinpath(run, "data.json"))
        for f in readdir(joinpath(dir, "reference-fit"))
            cp(joinpath(dir, "reference-fit", f), joinpath(run, "reference-fit-" * f))
        end
        got, problems = BAYSOLRun._snapshotReferences(run)
        @test [r.name for r in got] == ["CRYSOL", "FoXS"]
        @test length(problems) == 1
    end
    # no references folder: the models and the measured curve alone
    mktempdir() do dir
        makeProject(dir)
        r = quick(dir; ui = :tui, fit = resultFit(1.0))
        j = runjson(r)
        @test j.compare.status == "done" && isempty(j.compare.references)
        @test !any(startswith("reference-fit-"), readdir(r.dir))
        text = read(joinpath(r.dir, "run.LOG"), String)
        @test !occursin("=== ERRORS ===", text)
    end
end

# ---------------------------------------------------------------------------
# the settings of single models: model-settings.json and the `modelSettings` keyword
# ---------------------------------------------------------------------------

# a fit that records what each model was given
function recorder(seen)
    return function (st, rec, inputs, cfg, tee)
        seen[rec.name] = (; seedKw = inputs.seedKw, cfg)
        return nothing
    end
end

# a file of overrides: B gets two data settings and two sampler settings
const _MS_FILE = """{
  "data": "ignored",
  "B": {
    "data": {"Q_MAX": {"value": 0.2}, "EXCLUDE_Q": {"value": [[0.1, 0.12]]}},
    "sampler": {"N_CHAINS": {"value": 3}, "VAL_SIGMA": {"value": 3}}
  }
}"""

@testset "runProject: the settings of single models" begin
    defaults = BAYSOLRun.loadSettings(joinpath(mktempdir(), "none.json"))
    two = ["A.pdb" => _RP_CRAMBIN, "B.pdb" => _RP_CRAMBIN]
    mktempdir() do dir
        makeProject(dir; models = two)
        # the file: B has its own, A is the project's
        write(
            joinpath(dir, "model-settings.json"),
            replace(_MS_FILE, "\"data\": \"ignored\",\n" => ""),
        )
        seen = Dict{String,Any}()
        r = quick(dir; fit = recorder(seen), ui = :tui)
        @test r.status == :done
        a, b = seen["A"], seen["B"]
        @test a.seedKw.qMax === nothing && a.seedKw.excludeQ == ()
        @test b.seedKw.qMax == 0.2 && b.seedKw.excludeQ == ((0.1, 0.12),)
        @test a.cfg.nChains == defaults[:N_CHAINS] && b.cfg.nChains == 3
        @test b.cfg.runKw.nChains == 3 && b.cfg.sigma == 3 && b.cfg.runKw.sigma == 3
        @test a.cfg.sigma == defaults[:VAL_SIGMA]
        # nothing else of B is changed
        @test merge(b.seedKw, (; qMax = nothing, excludeQ = ())) == a.seedKw
        @test isempty(a.cfg.overrides)
        @test b.cfg.overrides == [:EXCLUDE_Q => ((0.1, 0.12),), :N_CHAINS => 3,
            :Q_MAX => 0.2, :VAL_SIGMA => 3.0]
        j = runjson(r)
        @test isempty(j.models[1].overrides)
        @test collect(j.models[2].overrides) ==
              ["EXCLUDE_Q", "N_CHAINS", "Q_MAX", "VAL_SIGMA"]
        # the file is part of the snapshot
        @test read(joinpath(r.dir, "model-settings.json"), String) ==
              read(joinpath(dir, "model-settings.json"), String)

        # precedence: settings.json < keywords of the call < the file < `modelSettings`
        write(
            joinpath(dir, "settings.json"),
            """{"data": {"Q_MAX": {"value": 0.25}},
                "sampler": {"N_CHAINS": {"value": 4}}}""",
        )
        quick(dir; fit = recorder(seen))
        @test seen["A"].seedKw.qMax == 0.25 && seen["A"].cfg.nChains == 4
        @test seen["B"].seedKw.qMax == 0.2 && seen["B"].cfg.nChains == 3
        quick(dir; fit = recorder(seen), qMax = 0.3, nChains = 5, sigma = 1.5)
        @test seen["A"].seedKw.qMax == 0.3 && seen["A"].cfg.nChains == 5
        @test seen["A"].cfg.sigma == 1.5 && seen["B"].cfg.sigma == 3     # B's own wins
        @test seen["B"].seedKw.qMax == 0.2 && seen["B"].cfg.nChains == 3
        quick(
            dir; fit = recorder(seen), qMax = 0.3,
            modelSettings = (; B = (; qMax = 0.15), A = Dict(:nChains => 2)),
        )
        # file: N_CHAINS
        @test seen["B"].seedKw.qMax == 0.15 && seen["B"].cfg.nChains == 3
        @test seen["A"].cfg.nChains == 2 && seen["A"].seedKw.qMax == 0.3
        @test seen["B"].cfg.overrides[3] == (:Q_MAX => 0.15)
        # `nothing` clears a setting that may be `nothing`, here the project's Q_MAX
        quick(dir; fit = recorder(seen), modelSettings = Dict("A" => (; qMax = nothing)))
        @test seen["A"].seedKw.qMax === nothing && seen["B"].seedKw.qMax == 0.2
        # `modelSettings` alone, with no file
        rm(joinpath(dir, "model-settings.json"))
        r = quick(
            dir; fit = recorder(seen),
            modelSettings = Dict("B" => (; mapNStarts = 7)),
        )
        @test seen["B"].cfg.runKw.mapNStarts == 7 &&
              seen["A"].cfg.runKw.mapNStarts == defaults[:MAP_N_STARTS]
        @test collect(runjson(r).models[2].overrides) == ["MAP_N_STARTS"]
        @test !isfile(joinpath(r.dir, "model-settings.json"))
    end

    @testset "settings of the whole run are refused, before any model" begin
        mktempdir() do dir
            makeProject(dir; models = two)
            calls = Ref(0)
            fit(st, rec, inputs, cfg, tee) = (calls[] += 1; nothing)
            write(
                joinpath(dir, "model-settings.json"),
                """{"B": {"plots": {"PLOT_COMPARE": {"value": false}},
                         "data": {"Q_MAX": {"value": 0.2}}}}""",
            )
            r = quick(dir; fit)
            @test r.status == :failed && calls[] == 0
            @test [m.status for m in r.models] == [:skipped, :skipped]
            text = read(joinpath(r.dir, "run.LOG"), String)
            @test occursin("InvalidSettingsError", text) && occursin("PLOT_COMPARE", text)
            @test occursin("model-settings.json, model B", text)
            @test occursin("a setting of the whole run, not of one model", text)
            for name in
                ("PLOT_TUI_SIZES", "TABLE_SIGFIGS", "FIGURES_TEX", "PLOT_COLOUR_MAP",
                "PLOT_LW_COMPARE")
                write(
                    joinpath(dir, "model-settings.json"),
                    """{"A": {"x": {"$name": {"value": 1}}}}""",
                )
                r = quick(dir; fit)
                text = read(joinpath(r.dir, "run.LOG"), String)
                @test r.status == :failed &&
                      occursin("$name is a setting of the whole", text)
            end
            # the same for the keyword, with the name of the keyword's setting
            rm(joinpath(dir, "model-settings.json"))
            for kw in (:plotCompare, :tex, :tableSigfigs, :plotTuiSizes, :lwCompare,
                :colorsCompare)
                r = quick(dir; fit, modelSettings = Dict("A" => Dict(kw => nothing)))
                text = read(joinpath(r.dir, "run.LOG"), String)
                @test r.status == :failed &&
                      occursin("modelSettings, model A", text) &&
                      occursin("a setting of the whole run", text)
            end
            @test calls[] == 0
        end
    end

    @testset "an invalid file fails the run before any model" begin
        mktempdir() do dir
            makeProject(dir; models = two)
            write(joinpath(dir, "settings.json"), """{"d": {"Q_MAX": {"value": 0.25}}}""")
            calls = Ref(0)
            fit(st, rec, inputs, cfg, tee) = (calls[] += 1; nothing)
            for (text, expected) in (
                ("{not json", "model-settings.json cannot be read"),
                ("[1, 2]", "must hold an object with a table of settings for each model"),
                ("""{"B": 5}""", "model-settings.json, model B: must be an object"),
                ("""{"B": {"d": {"Q_MAX": {"value": -1}}}}""",
                    "model-settings.json, model B: Q_MAX = -1: must be above 0"),
                ("""{"A": {"d": {"MAP_N_STARTS": {"value": "x"}}}}""",
                    "model-settings.json, model A: MAP_N_STARTS"),
                # a rule between the project's settings and the model's own
                ("""{"B": {"d": {"Q_MIN": {"value": 0.4}}}}""",
                    "model B: Q_MIN = 0.4: must be below Q_MAX = 0.25"),
            )
                write(joinpath(dir, "model-settings.json"), text)
                r = quick(dir; fit)
                log = read(joinpath(r.dir, "run.LOG"), String)
                @test r.status == :failed && occursin(expected, log)
                @test [m.status for m in r.models] == [:skipped, :skipped]
            end
            @test calls[] == 0
            # a keyword that is out of its limits or breaks a rule fails the same way
            rm(joinpath(dir, "model-settings.json"))
            r = quick(dir; fit, modelSettings = (; A = (; qMax = -1)))
            @test r.status == :failed &&
                  occursin(
                "modelSettings, model A: Q_MAX = -1",
                read(
                    joinpath(r.dir, "run.LOG"), String),
            )
            r = quick(dir; fit, modelSettings = (; A = (; qMin = 0.4)))
            @test r.status == :failed
            # a name that is no keyword, or a table of the wrong shape, is an error at
            # once, with no run folder
            nRuns = length(readdir(joinpath(dir, "runs")))
            @test_throws ArgumentError quick(
                dir;
                fit,
                modelSettings = (; A = (; nope = 1)),
            )
            @test_throws ArgumentError quick(dir; fit, modelSettings = 5)
            @test_throws ArgumentError quick(dir; fit, modelSettings = (; A = 5))
            @test calls[] == 0
            @test length(readdir(joinpath(dir, "runs"))) == nRuns
        end
    end

    @testset "a name that is no model is a note, and ignored" begin
        mktempdir() do dir
            makeProject(dir; models = two)
            write(
                joinpath(dir, "model-settings.json"),
                """{"ghost": {"d": {"Q_MAX": {"value": 0.2}}},
                    "A": {"d": {"Q_MAX": {"value": 0.21}}}}""",
            )
            seen = Dict{String,Any}()
            r = quick(
                dir;
                fit = recorder(seen),
                modelSettings = (; phantom = (; qMax = 0.3)),
            )
            @test r.status == :done && sort(collect(keys(seen))) == ["A", "B"]
            @test seen["A"].seedKw.qMax == 0.21 && seen["B"].seedKw.qMax === nothing
            text = read(joinpath(r.dir, "run.LOG"), String)
            @test occursin("=== ERRORS ===", text)
            @test occursin("no model named ghost", text) &&
                  occursin("no model named phantom", text)
            @test occursin(r"status\s+\tdone", text)
        end
    end

    @testset "the LOG of a model that failed names its overrides" begin
        mktempdir() do dir
            makeProject(dir; models = two)
            write(
                joinpath(dir, "model-settings.json"),
                _MS_FILE[(findfirst("\"B\"", _MS_FILE)[1]-1):end] |>
                t -> "{" * t,
            )
            function boom(st, rec, inputs, cfg, tee)
                rec.name == "B" && throw(ArgumentError("no radius for the element Xx"))
                return nothing
            end
            r = quick(dir; fit = boom)
            @test [m.status for m in r.models] == [:done, :failed]
            rows = logRows(joinpath(r.dir, "B.LOG"))
            @test rows["overrideQMax"] == "0.2" && rows["overrideNChains"] == "3"
            @test rows["overrideValSigma"] == "3.0" && haskey(rows, "overrideExcludeQ")
        end
    end

    @testset "the comparison draws models with different q ranges" begin
        mktempdir() do dir
            makeProject(dir; models = two)
            write(
                joinpath(dir, "model-settings.json"),
                """{"B": {"d": {"Q_MAX": {"value": 0.2}}}}""",
            )
            # a fit whose curve covers the q range the model was given
            function ranged(st, rec, inputs, cfg, tee)
                hi = something(inputs.seedKw.qMax, Inf)
                q = filter(<=(hi), inputs.q)
                I = 1000 .* exp.(-(q .* 10) .^ 2 .* 100 ./ 3)
                return (;
                    result = (
                        nothing,
                        0.0,
                        (Dict("chisqRed" => 1.0), hcat(q, I)),
                        nothing,
                    )
                )
            end
            r = quick(dir; fit = ranged, ui = :tui)
            @test r.status == :done && runjson(r).compare.status == "done"
            _, cols = readCompare(joinpath(r.dir, "compare.tsv"))
            qs = cols[1]
            fa, fb = cols[4], cols[5]
            @test !any(ismissing, fa)                          # A: the whole curve
            @test all(ismissing, fb[qs .> 0.2+DEFAULT_ATOL])  # B: its own range
            @test !any(ismissing, fb[qs .<= 0.2])
        end
    end
end

@testset "runProject: the reference curve of single models" begin
    P = BAYSOL.Pipeline
    R = BAYSOLRun
    @testset "the file is read and checked" begin
        mktempdir() do dir
            file = joinpath(dir, "model-references.json")
            write(
                file,
                """{"a": {"fit": "A.tsv", "software": "FoXS", "tag": 3,""" *
                """"refChi2": 1.2, "rescale": true},""" *
                """"b": {"rescale": "yes", "color": "red", "tag": ""},""" *
                """"c": 7, "d": {}}""",
            )
            table, problems = R._readModelReferences(file)
            @test table["a"] == Dict(
                :fit => "A.tsv", :software => "FoXS", :tag => "3", :refChi2 => "1.2",
                :rescale => true,
            )
            @test !haskey(table, "b") && !haskey(table, "c") && !haskey(table, "d")
            @test any(
                occursin("model b: rescale must be true or false", p) for p in problems
            )
            @test any(occursin("model b: color is not known", p) for p in problems)
            @test any(occursin("model c: must be an object", p) for p in problems)
            # a file that is not JSON, or not an object, is one problem and nothing else
            write(file, "{not json")
            table, problems = R._readModelReferences(file)
            @test isempty(table) && length(problems) == 1 &&
                  occursin("cannot be read", problems[1])
            write(file, "[1, 2]")
            table, problems = R._readModelReferences(file)
            @test isempty(table) && occursin("must hold an object", only(problems))
        end
    end

    @testset "a model's curve: named, read in Å⁻¹, rescaled onto the data" begin
        mktempdir() do dir
            # a fit in nm⁻¹ with the intensity of the data divided by 4: rescale finds ×4
            qd = collect(range(0.1, 0.3; length = 20))
            id = 1000 .* exp.(-(qd .* 10) .^ 2 .* 100 ./ 3)
            write(
                joinpath(dir, "reference-fit-A.tsv"),
                join(("$(10q)\t$(I / 4)" for (q, I) in zip(qd, id)), "\n") * "\n",
            )
            entry = Dict{Symbol,Any}(
                :fit => "A.tsv", :software => "FoXS", :tag => "m1",
                :refChi2 => "FoXS 0.8", :rescale => true,
            )
            got = R._modelReference(dir, "m", entry, (qd, id), 0.1)
            @test isempty(got.problems) && got.refChi2 == "FoXS 0.8"
            ref = only(got.references)
            @test ref.name == "FoXS m1 (rescaled)"
            @test ref.q ≈ qd && ref.I ≈ id
            # no rescale: the curve as it is, named by the software and tag
            delete!(entry, :rescale)
            ref = only(R._modelReference(dir, "m", entry, (qd, id), 0.1).references)
            @test ref.name == "FoXS m1" && ref.I ≈ id ./ 4
            # nothing but a chi2: no curve, the chi2 is kept; a name that is not there is
            # one problem and no curve
            got = R._modelReference(
                dir, "m", Dict{Symbol,Any}(:refChi2 => "x 1"), (qd, id), 0.1,
            )
            @test isempty(got.references) && got.refChi2 == "x 1" && isempty(got.problems)
            got = R._modelReference(
                dir, "m", Dict{Symbol,Any}(:fit => "gone.tsv"), (qd, id), 0.1,
            )
            @test isempty(got.references) && got.refChi2 === nothing
            @test occursin("model m: the reference fit was skipped", only(got.problems))
        end
    end

    @testset "runProject hands every model its own and notes what is wrong" begin
        mktempdir() do dir
            makeProject(dir; models = ["m1.pdb" => _RP_CRAMBIN, "m2.pdb" => _RP_CRAMBIN])
            mkpath(joinpath(dir, "reference-fit"))
            write(
                joinpath(dir, "reference-fit", "CRYSOL.tsv"),
                join(
                    ("$q\t$(900 * exp(-q^2 * 100 / 3))" for q in 1.0:0.5:3.0), "\n",
                ) * "\n",
            )
            write(
                joinpath(dir, "model-references.json"),
                """{"m1": {"fit": "CRYSOL.tsv", "tag": "a", "refChi2": "CRYSOL 1.4"},""" *
                """"m2": {"fit": "gone.tsv"}, "m3": {"tag": "x"}}""",
            )
            seen = Dict{String,Any}()
            function fit(st, rec, inputs, cfg, tee)
                seen[rec.name] = cfg.modelRef
                return nothing
            end
            r = quick(dir; fit)
            @test r.status == :done
            @test only(seen["m1"].references).name == "a" &&
                  seen["m1"].refChi2 == "CRYSOL 1.4"
            @test isempty(seen["m2"].references) && seen["m2"].refChi2 === nothing
            errors = read(joinpath(r.dir, "run.LOG"), String)
            @test occursin("model m2: the reference fit was skipped", errors)
            @test occursin("there is no model named m3", errors)
        end
    end
end

@testset "runProject takes the keyword of every setting of the table" begin
    kws = Set(reduce(vcat, [Base.kwarg_decl(m) for m in methods(BAYSOLRun.runProject)]))
    for r in BAYSOL.Pipeline.SETTING_KEYWORDS
        # every one that is not a field of the style, and the style itself
        r.entry === :PlotStyle || @test r.keyword in kws
        # a switch of the run alone is no keyword of results
        r.entry === :runProject && @test r.keyword in kws
    end
    @test :style in kws
end
