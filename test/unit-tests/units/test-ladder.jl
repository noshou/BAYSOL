# SPDX-License-Identifier: LGPL-3.0-or-later

# The retry ladder of runModel as data (the setting LADDER): a map from failure class to
# rungs, the validated default, a rung may override fitting settings only (anything else is
# refused with a message that names it), the keyword takes a map, one class, a JSON text, a
# file path, "off" or the former Bool, a model's ladder wins over the project's per class;
# the classifier (`_failureClass`) on synthetic diagnostics of each class; and the walk
# itself (`_runLadder` with a fake runner that never converges, so nothing is sampled): each
# failed attempt is classified and the next rung of its class runs, with only what it names
# changed, a rung that would change nothing is skipped, the class is logged.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Pipeline:
    InvalidSettingsError, _ladderValue, _checkedLadder, _runLadder, _applyKeywords!,
    _failureClass, LADDER, LADDER_CLASSES, LADDER_OVERRIDABLE, LADDER_VALIDATED,
    LADDER_RHAT_FAR, LADDER_COLLAPSE_STEP, _ladderText
using BAYSOL.Inference: NotConvergedError, CHAIN_START_RADII

const _OFF = NamedTuple{LADDER_CLASSES}(ntuple(_ -> (), length(LADDER_CLASSES)))

# the text of a map with one class and one rung
_one(class, overrides) = """{"$class": [{"overrides": $overrides}]}"""

# a failed attempt's diagnostics: a healthy run unless a field is given
_summary(; kw...) = merge(
    (;
        rhat = 1.001, ess = 5000.0, divergentShare = 0.0, treeDepthAvg = 3.0,
        treeDepthMax = 6, meanNSteps = 8.0, meanAccept = 0.9, stepSize = 0.2,
        stepSizeMin = 0.15, modes = 1,
    ),
    (; kw...),
)

@testset "the retry ladder" begin
    @testset "the default: a map of the six classes" begin
        @test keys(LADDER) == LADDER_CLASSES
        @test LADDER.stepCollapse[1].overrides == (TARGET_ACCEPT = 70,)
        @test LADDER.stepCollapse[2].overrides == (TARGET_ACCEPT = 35,)
        @test LADDER.divergent[1].overrides == (TARGET_ACCEPT = 99,)
        # keys are sorted by name, the one order every source gives
        @test LADDER.divergent[2].overrides == (
            CHAIN_START_RADII = (1.0, 2.0, 3.0), RETRY_N_ADAPT = 4000,
            RETRY_N_DRAWS = 4000, TARGET_ACCEPT = 99,
        )
        @test LADDER.divergent[3].overrides == (
            CHAIN_START_RADII = (1.0, 2.0, 3.0), RETRY_N_ADAPT = 4000,
            RETRY_N_DRAWS = 4000, RNG_SEED_STEP = 1, TARGET_ACCEPT = 99,
        )
        @test LADDER.splitChains[1].overrides == (CHAIN_START_RADII = (2.0, 4.0, 6.0),)
        @test LADDER.structural[1].overrides == (SAMPLE_C1 = true,)
        @test LADDER.marginal[1].overrides ==
              (RETRY_N_ADAPT = 6000, RETRY_N_DRAWS = 8000)
        @test LADDER.generic[1].overrides ==
              (RETRY_N_ADAPT = 4000, RETRY_N_DRAWS = 4000, RNG_SEED_STEP = 1)
        rungs = [r for c in LADDER_CLASSES for r in LADDER[c]]
        @test all(issorted(collect(keys(r.overrides))) for r in rungs)
        @test all(k in LADDER_OVERRIDABLE for r in rungs for k in keys(r.overrides))
        @test defaultSettings()[:LADDER] == LADDER
        # the default passes its own check, `true` is the base, `false` and "off" are off
        @test _ladderValue(LADDER) == LADDER
        @test _ladderValue(true) == LADDER
        @test _ladderValue(false) == _OFF
        @test _ladderValue("off") == _OFF
        @test all(k in LADDER_OVERRIDABLE for k in LADDER_VALIDATED)
    end

    @testset "forms: map, one class, JSON text, file, empty" begin
        text = """{"divergent": [{"name": "a", "overrides": {"TARGET_ACCEPT": 97}},
                    {"overrides": {"CHAIN_START_RADII": [1, 2, 3], "RNG_SEED_STEP": 2}}]}"""
        want = (
            (name = "a", overrides = (TARGET_ACCEPT = 97,)),
            (
                name = "",
                overrides = (CHAIN_START_RADII = (1.0, 2.0, 3.0), RNG_SEED_STEP = 2),
            ),
        )
        v = _ladderValue(text)
        # one class replaced, the others keep the default
        @test v.divergent == want
        @test v.stepCollapse == LADDER.stepCollapse && v.marginal == LADDER.marginal
        path = joinpath(mktempdir(), "ladder.json")
        write(path, text)
        @test _ladderValue(path) == v
        @test _ladderValue(v) == v
        # `[]` switches a class off
        w = _ladderValue("""{"generic": [], "marginal": []}""")
        @test w.generic == () && w.marginal == () && w.divergent == LADDER.divergent
        @test _ladderValue(Dict(:stepCollapse => Any[])).stepCollapse == ()
        # a base other than the default is what the unnamed classes keep
        mine = _ladderValue("""{"divergent": []}""")
        @test _ladderValue("""{"generic": []}"""; base = mine).divergent == ()
        @test _ladderValue("{}") == LADDER
    end

    @testset "what a rung may not do" begin
        bad(v) =
            try
                _ladderValue(v)
                ""
            catch e
                e isa ArgumentError ? e.msg : rethrow()
            end
        rung(k, v) = Dict{Symbol,Any}(:overrides => Dict{Symbol,Any}(k => v))
        r(k, v) = Dict(:divergent => [rung(k, v)])
        @test occursin("fitting setting", bad(r(:PLOT_LW_MAP, 1.0)))
        @test occursin("PLOT_LW_MAP", bad(r(:PLOT_LW_MAP, 1.0)))
        @test occursin("fitting setting", bad(r(:BOUNDS_δρ₁₂, [-5, 1])))
        @test occursin("fitting setting", bad(r(:LADDER, [])))
        @test occursin("fitting setting", bad(r(:RNG_SEED, 3)))
        @test occursin("fitting setting", bad(r(:NOPE, 3)))
        @test occursin("above 0", bad(r(:TARGET_ACCEPT, 0)))
        @test occursin("below 100", bad(r(:TARGET_ACCEPT, 100)))
        @test occursin("whole number", bad(r(:RNG_SEED_STEP, 1.5)))
        @test occursin("true or false", bad(r(:SAMPLE_C1, 1)))
        @test occursin("map from failure class", bad(5))
        @test occursin("map from failure class", bad([Dict(:overrides => Dict())]))
        @test occursin("map from failure class", bad("not json {"))
        @test occursin("not a failure class", bad(Dict(:kink => Any[])))
        @test occursin("list of rungs", bad(Dict(:divergent => 5)))
        @test occursin(
            "needs overrides", bad(Dict(:divergent => [Dict{Symbol,Any}(:name => "x")])))
        @test occursin(
            "at least one", bad(Dict(:divergent => [Dict(:overrides => Dict())])))
        @test occursin(
            "only name and overrides",
            bad(Dict(:divergent => [merge(rung(:N_ADAPT, 5), Dict(:extra => 1))])),
        )
        err = try
            _checkedLadder(r(:PLOT_LW_MAP, 1))
        catch e
            e
        end
        @test err isa InvalidSettingsError
    end

    @testset "precedence: keyword over settings, a model over the project" begin
        project = defaultSettings()
        @test project[:LADDER] == LADDER
        mine = Dict(
            :divergent => [Dict{Symbol,Any}(:overrides => Dict(:TARGET_ACCEPT => 90))])
        _applyKeywords!(project, (; ladder = mine))
        @test project[:LADDER].divergent[1].overrides == (TARGET_ACCEPT = 90,)
        @test project[:LADDER].marginal == LADDER.marginal
        # a model that names another class keeps the project's own divergent rungs
        model = copy(project)
        _applyKeywords!(model, (; ladder = Dict(:generic => Any[])))
        @test model[:LADDER].generic == ()
        @test model[:LADDER].divergent[1].overrides == (TARGET_ACCEPT = 90,)
        @test project[:LADDER].generic == LADDER.generic             # untouched
        # the whole ladder off for one model
        off = copy(project)
        _applyKeywords!(off, (; ladder = false))
        @test off[:LADDER] == _OFF
        # `nothing` takes the saved setting
        keep = copy(project)
        _applyKeywords!(keep, (; ladder = nothing))
        @test keep[:LADDER] == project[:LADDER]
        # the CLI form (JSON text) is the same value as the map
        viaText = defaultSettings()
        _applyKeywords!(
            viaText,
            (; ladder = _one("divergent", """{"TARGET_ACCEPT": 90}""")),
        )
        @test viaText[:LADDER].divergent[1].overrides ==
              project[:LADDER].divergent[1].overrides
        @test BAYSOL.runKeywords(viaText).ladder == viaText[:LADDER]
    end

    @testset "the classifier, one synthetic record for each class" begin
        c(; kw...) = _failureClass(_summary(; kw...))
        # a collapsed step with R̂ above the gate (README step 4: about 0.002)
        @test c(rhat = 3.0, stepSize = 0.002, treeDepthAvg = 10.0) == :stepCollapse
        @test c(rhat = 1.02, stepSize = 0.002) == :stepCollapse
        # without a collapsed step the depth is the evidence, and only with R̂ far
        @test c(rhat = 2.0, stepSize = 0.2, treeDepthAvg = 9.5) == :stepCollapse
        @test c(rhat = 1.02, stepSize = 0.2, treeDepthAvg = 9.5) == :marginal
        # a collapsed step with R̂ below the gate is no failure of the chains
        @test c(rhat = 1.0, ess = 100.0, stepSize = 0.002) == :marginal
        # chains in different places: far R̂, several modes, low ESS, a healthy step
        @test c(rhat = 1.6, ess = 20.0, modes = 3) == :splitChains
        @test c(rhat = 1.6, ess = 20.0, modes = 1) == :generic      # one mode: unknown
        @test c(rhat = 1.6, ess = 5000.0, modes = 3) == :generic
        # divergences with a sound R̂
        @test c(divergentShare = 0.003) == :divergent
        @test c(rhat = 1.02, divergentShare = 0.0011) == :divergent
        @test c(divergentShare = 0.0009, rhat = 1.02) == :marginal
        # structural only once a raised δ did not remove them, and only at a high share
        s = _summary(divergentShare = 0.02)
        @test _failureClass(s; deltaRaised = true) == :structural
        @test _failureClass(s) == :divergent
        @test _failureClass(_summary(divergentShare = 0.003); deltaRaised = true) ==
              :divergent
        # R̂ or ESS just outside the gates and nothing else
        @test c(rhat = 1.03) == :marginal
        @test c(ess = 250.0) == :marginal
        @test c(rhat = 1.04, ess = 300.0) == :marginal
        # an attempt without diagnostics
        @test _failureClass(nothing) == :generic
        @test LADDER_RHAT_FAR == 1.05 && LADDER_COLLAPSE_STEP == 0.01
    end

    @testset "the ladder as one readable line (the LOG row ladderRungs)" begin
        txt = _ladderText(LADDER)
        # per class its rung names, classes joined by " | ", no JSON
        @test startswith(
            txt, "stepCollapse: delta 70, delta 35, delta 35 + seed | splitChains: ",
        )
        @test count(" | ", txt) == length(LADDER_CLASSES) - 1
        @test !occursin('{', txt) && !occursin('"', txt) && !occursin('\n', txt)
        for class in LADDER_CLASSES
            @test occursin(String(class) * ":", txt)
        end
        # a rung without a name is written as its overrides
        anon = (stepCollapse = ((name = "", overrides = (TARGET_ACCEPT = 70,)),),)
        @test _ladderText(anon) == "stepCollapse: TARGET_ACCEPT=70"
        # a class with no rungs (the ladder off) is the class and nothing after it
        @test _ladderText(_OFF) == join(("$c: " for c in LADDER_CLASSES), " | ")
    end

    @testset "the walk" begin
        calls = Any[]
        # the summaries the fake runner fails with, in order (the last one repeats)
        queue = Any[]
        function runner(seed, n, a; kw...)
            push!(calls, (; n, a, kw = (; kw...)))
            s = length(queue) >= length(calls) ? queue[length(calls)] : queue[end]
            throw(NotConvergedError(["R-hat 1.5"], s))
        end
        base = (;
            sigma = 2.0, δ = 95, rngSeed = 0, nChains = 4, retry = true,
            retryNAdapt = 2000, retryNDraws = 2000, chainStartRadii = CHAIN_START_RADII,
            kinkFallback = true, sampleC1 = false,
        )
        seed = (; timing = BAYSOL.Runtime.StageLog())
        info() = seed.timing.info
        run(ladder, qs; kw = base, callerSet = nothing) = (
            empty!(calls);
            empty!(queue);
            append!(queue, qs);
            empty!(info());
            try
                _runLadder(seed, 1000, 300, kw, ladder; runner, callerSet)
            catch e
                e isa NotConvergedError || rethrow()
                e
            end
        )
        div = _summary(divergentShare = 0.003)
        collapse = _summary(rhat = 3.0, stepSize = 0.002, treeDepthAvg = 10.0)
        split = _summary(rhat = 1.6, ess = 20.0, modes = 3)
        marginal = _summary(rhat = 1.03)
        # the ladder off: the base run once, its own error
        e = run(_OFF, [div])
        @test length(calls) == 1 && e.problems == ["R-hat 1.5"]
        # a divergent failure walks every rung of its class, in order, then stops
        e = run(LADDER, [div])
        @test length(calls) == 1 + length(LADDER[:divergent])
        @test occursin("ladder exhausted", join(e.problems))
        @test [c.kw.δ for c in calls] == [95, 99, 99, 99]
        @test calls[2].kw.chainStartRadii == CHAIN_START_RADII
        @test calls[3].kw.chainStartRadii == (1.0, 2.0, 3.0)
        @test [c.kw.retryNDraws for c in calls] == [2000, 2000, 4000, 4000]
        @test [c.kw.rngSeed for c in calls] == [0, 0, 0, 1]
        @test all(c -> (c.n, c.a) == (1000, 300), calls)
        @test info()["ladderClass"] == "divergent | divergent | divergent"
        @test info()["ladder"] == "failed" && info()["ladderRung"] == -1
        # the caller's own values stay, also when they equal the default (`callerSet`)
        explicitRadii = (; base..., chainStartRadii = CHAIN_START_RADII)
        run(LADDER, [split]; kw = explicitRadii, callerSet = Set([:CHAIN_START_RADII]))
        # the first rung (radii only) changes nothing and is skipped; the second keeps the
        # radii and changes only what the caller did not set
        @test [c.kw.chainStartRadii for c in calls] ==
              [CHAIN_START_RADII, CHAIN_START_RADII, CHAIN_START_RADII]
        @test calls[2].kw.retryNDraws == 4000
        # without `callerSet` the same default value looks unset and is replaced
        run(LADDER, [split]; kw = explicitRadii)
        @test calls[2].kw.chainStartRadii == (2.0, 4.0, 6.0)
        # a script's retryNDraws = 8000 (SASDMS6) survives every rung; 2000 set
        # explicitly does too
        for (n, set) in ((8000, Set{Symbol}()), (2000, Set([:RETRY_N_DRAWS])))
            kwN = (; base..., retryNDraws = n)
            run(LADDER, [marginal]; kw = kwN, callerSet = set)
            @test [c.kw.retryNDraws for c in calls] == [n, n, n]
            @test [c.kw.retryNAdapt for c in calls] == [2000, 6000, 6000]
        end
        run(LADDER, [marginal]; kw = base, callerSet = Set([:RETRY_N_ADAPT]))
        @test [c.kw.retryNAdapt for c in calls] == [2000, 2000, 2000]
        @test [c.kw.retryNDraws for c in calls] == [2000, 8000, 8000]
        # each class selects its own rungs and logs its name
        run(LADDER, [collapse])
        @test [c.kw.δ for c in calls] == [95, 70, 35, 35]
        @test [c.kw.rngSeed for c in calls] == [0, 0, 0, 1]     # the third rung: next seed
        @test info()["ladderClass"] == "stepCollapse | stepCollapse | stepCollapse"
        run(LADDER, [split])
        @test [c.kw.chainStartRadii for c in calls] ==
              [CHAIN_START_RADII, (2.0, 4.0, 6.0), (1.0, 2.0, 3.0), (1.0, 2.0, 3.0)]
        @test calls[3].kw.retryNDraws == 4000
        @test [c.kw.rngSeed for c in calls] == [0, 0, 0, 1]     # the third rung: next seed
        @test info()["ladderClass"] == "splitChains | splitChains | splitChains"
        run(LADDER, [marginal])
        @test [c.kw.retryNDraws for c in calls] == [2000, 8000, 8000]
        @test [c.kw.retryNAdapt for c in calls] == [2000, 6000, 6000]
        @test [c.kw.rngSeed for c in calls] == [0, 0, 1]
        @test info()["ladderClass"] == "marginal | marginal"
        run(LADDER, [_summary(rhat = 1.6)])                    # unclassified
        @test info()["ladderClass"] == "generic" && length(calls) == 2
        @test calls[2].kw.rngSeed == 1 && calls[2].kw.retryNDraws == 4000
        run(LADDER, [nothing])                                 # no diagnostics
        @test info()["ladderClass"] == "generic"
        # the class is taken anew from each failed rerun
        run(LADDER, [marginal, collapse, collapse])
        @test info()["ladderClass"] ==
              "marginal | stepCollapse | stepCollapse | stepCollapse"
        # the walk goes on until the class is used up (three stepCollapse rungs)
        @test [c.kw.δ for c in calls] == [95, 95, 70, 35, 35]
        # divergences that survive a raised δ at a high share are structural: c1 is sampled
        big = _summary(divergentShare = 0.02)
        run(LADDER, [big, big, big])
        @test info()["ladderClass"] == "divergent | structural"
        @test calls[2].kw.δ == 99 && calls[3].kw.sampleC1 == true
        @test length(calls) == 3
        # a class with no rung left ends the walk
        run(_ladderValue(_one("divergent", """{"TARGET_ACCEPT": 99}""")), [div])
        @test length(calls) == 2 + 0 || length(calls) == 2
        # a caller's own start radii are kept
        run(LADDER, [div]; kw = merge(base, (; chainStartRadii = (2.0, 3.0, 4.0))))
        @test all(c -> c.kw.chainStartRadii == (2.0, 3.0, 4.0), calls)
        # likewise the caller's own retry lengths (SASDMS6: retryNDraws = 8000)
        run(LADDER, [div]; kw = merge(base, (; retryNDraws = 8000, retryNAdapt = 5000)))
        @test all(c -> c.kw.retryNDraws == 8000 && c.kw.retryNAdapt == 5000, calls)
        @test [c.kw.δ for c in calls] == [95, 99, 99, 99]
        # a rung that changes nothing is skipped (the next one of the class runs instead)
        two = """{"divergent": [{"overrides": {"TARGET_ACCEPT": 95}},
                               {"overrides": {"TARGET_ACCEPT": 96}}]}"""
        run(_ladderValue(two), [div])
        @test length(calls) == 2 && calls[2].kw.δ == 96
        # the positional arguments; a fresh seed is left alone
        run(_ladderValue(_one("divergent", """{"N_ADAPT": 500, "N_DRAWS": 800}""")), [div])
        @test (calls[2].n, calls[2].a) == (1300, 500)
        fresh = merge(base, (; rngSeed = nothing))
        run(_ladderValue(_one("divergent", """{"RNG_SEED_STEP": 1}""")), [div]; kw = fresh)
        @test length(calls) == 1
        # any other fitting keyword reaches runModel under its own name
        run(
            _ladderValue(_one("divergent", """{"N_CHAINS": 6, "MAP_N_STARTS": 12}""")),
            [div],
        )
        @test calls[2].kw.nChains == 6 && calls[2].kw.mapNStarts == 12
        # a rung that converges wins and the rest never run
        n = Ref(0)
        win(seed, n_, a; kw...) =
            (n[] += 1; n[] == 2 ? :ok : throw(NotConvergedError(["x"], div)))
        @test _runLadder(seed, 1000, 300, base, LADDER; runner = win) == :ok
        @test n[] == 2
        @test info()["ladder"] == "delta 99" && info()["ladderRung"] == 1
        @test info()["retryRungs"] == sum(length, values(LADDER))
        # retry off: no ladder, the base error as it is
        run(LADDER, [div]; kw = merge(base, (; retry = false)))
        @test length(calls) == 1
    end
end
