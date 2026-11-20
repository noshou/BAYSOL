# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/inference/statistics.jl (the `StatBuffer` and its recorders) and
# `writeStatistics` of src/pipeline/log.jl: bounded size, flushes at a phase boundary and
# at the cap, order, one block for each attempt with its settings and outcome, the
# replacement of an old section, the `statisticsError` row, and that `results` always writes
# the statistics beside the run log. No sampling runs; the chains are synthetic.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random, LinearAlgebra
using Statistics: mean
using StaticArrays: SVector, SMatrix
using BAYSOL.Inference: StatBuffer, statBuffer, statReset!, statLabel!, statAttempt!,
    statKeep!, statLines, statRow!, statText!, statTable!, statPhase!, statStopped!,
    statNext!, statChains!, statAttempts, ChainDiagnostics, OptimumReport, statParse,
    StatSection, STAT_SECTIONS, statDivergences, statKink!, statSection!, statMapSearch!,
    statUnavailable!, statSettings!
using BAYSOL.Inference: ρₑ_prior, δρ_prior, ξ_priors, κ_δρ₁₂, κ_δρ₃, _SamplingSpace,
    _Optimum, _StartRecord, fmtVec, fmtDiagNuts, fmtChainRow, CHAIN_COLUMNS, _ChainTally
using BAYSOL.BulkElectronDensity: Solute, NonBiological
using BAYSOL.Inference: _ChainRun, statisticsCap, STATISTICS_MEMORY_SHARE,
    STATISTICS_BUFFER_MIN, STATISTICS_BUFFER_MAX
using BAYSOL.Runtime: StageLog
using BAYSOL.Pipeline: writeStatistics, results

# a ChainDiagnostics for two chains and four parameters + log π (R̂ and ESS per quantity)
function synthDiag(; rhat = 1.002, pooled = [true, true])
    return ChainDiagnostics(2, [0.0, 1.0], pooled, ["ok", "ok"], fill(rhat, 5),
        fill(900.0, 5), fill(700.0, 5), 0.0, [1, 1], [1.0], [0.0], [0.1], false, 5,
        NaN, false, 0, OptimumReport[])
end

# the priors and the sampling space of a synthetic four-parameter run
const SYN_ρ = ρₑ_prior(7.4, 0.05, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
const SYN_PR = ξ_priors(SYN_ρ, δρ_prior(κ_δρ₁₂, κ_δρ₃, mean(SYN_ρ))...)
const SYN_PROB = (; pr = SYN_PR, nQ = 120, nAtoms = 3000, lMax = 25)
const SYN_I4 = SMatrix{4,4,Float64}(I)
const SYN_SP = _SamplingSpace(zeros(SVector{4}), ones(SVector{4}), zeros(SVector{4}),
    SYN_I4, 3, 4, 1, true, 120, -2.5,
    [_Optimum(zeros(SVector{4}), 2.5, ones(SVector{4}), SYN_I4, -1.7)],
    [_StartRecord(1, true, 2.5, 14, true, false, false, 30, 1.0e-9),
        _StartRecord(2, false, NaN, 0, false, false, false, 0, NaN),
        _StartRecord(3, true, 2.6, 200, false, false, true, 420, 3.0e-3)])

# two synthetic chains of `nAdapt` warm-up and `nDraw` sampling iterations; chain 1 has one
# divergent draw in the warm-up (iteration 2) and `div` in the sampling; `tally` gives every
# chain the whitened draws and gradient-difference quotients the real chains record
function synthRuns(nAdapt = 5, nDraw = 60; div = 1, tally = true)
    rng = Xoshiro(1)
    n = nAdapt + nDraw
    mk(k) = _ChainRun(k,
        [
            SVector(7.0 + 0.1randn(rng), 1.0 + 0.1randn(rng), 2.0 + 0.1randn(rng),
                3.0 + 0.1randn(rng)) for _ in 1:n
        ],
        [
            (;
                numerical_error = (k == 1 && i == 2) ||
                                  (i > nAdapt && i ≤ nAdapt + div && k == 1),
                step_size = 0.3, tree_depth = 3, n_steps = 7, acceptance_rate = 0.9,
                hamiltonian_energy = randn(rng), hamiltonian_energy_error = 0.1,
                log_density = -1.0 - 0.5randn(rng)^2) for i in 1:n
        ],
        nothing, 0.5, 0.7,
        tally ?
        _ChainTally([randn(rng, 4) for _ in 1:n], 4n, 3, 1.0 .+ rand(rng, 4n - 1),
            4nAdapt) : nothing)
    return [mk(1), mk(2)]
end

# what the run holds besides the chains: the c1
# re-profile of every draw, the counters, the data
function synthExtra(runs, nAdapt)
    rng = Xoshiro(2)
    n = length(first(runs).ξ)
    nQ = 40
    iObs = randn(rng, nQ)
    c1 = [clamp.(1.0 .+ 0.15randn(rng, n), 0.8, 1.3) for _ in runs]
    curves = [iObs .+ 0.1 .* randn(rng, nQ, n) for _ in runs]
    return (; pk = [1, 2], rows = [collect(1:n), collect(1:n)], c1, curves,
        c1base = (solves = 10, brentIters = 50, scanEdge = 0, wlsErrors = 0),
        c1now = (solves = 510, brentIters = 2550, scanEdge = 2, wlsErrors = 1),
        iObs, weights = ones(nQ), cmin = 0.8, cmax = 1.3)
end

# the sizes of the synthetic runs: 5 warm-up + 60 draws
const SYN_ARGS = (65, 5, 80, 7)

# the grammar of the writer: every section is in STAT_SECTIONS, of its kind and level, with
# its names (scalars) or its header (tables) as listed
function checkGrammar(secs)
    for s in secs
        def = BAYSOL.Inference._statSection(s.name)
        @test def !== nothing
        def === nothing && continue
        @test s.kind == def.kind
        if s.kind == :scalars
            @test all(p -> first(p) in def.columns, s.scalars)
        elseif s.kind == :table
            n = length(def.columns)
            @test s.header[1:min(n, end)] == def.columns[1:min(n, end)]
            def.open || @test s.header == def.columns
            @test all(r -> length(r) == length(s.header), s.rows)
        end
    end
    # names are unique within an attempt
    for k in unique(s.attempt for s in secs)
        names = [s.name for s in secs if s.attempt == k]
        @test allunique(names)
    end
end

section(secs, name; attempt = 1) =
    only(filter(s -> s.name == name && s.attempt == attempt, secs))
scalar(sec, name) = last(only(filter(p -> first(p) == name, sec.scalars)))
col(sec, name) = [r[findfirst(==(name), sec.header)] for r in sec.rows]

lineOf(lines, name) = only(filter(l -> startswith(l, name * " "), lines))
cell(lines, name) = split(lineOf(lines, name), '\t')[2]

@testset "statistics" begin
    @testset "rows are aligned; not-finite and missing are never zero" begin
        b = StatBuffer()
        statRow!(b, "name", 1.23456789)
        statRow!(b, "nan", NaN)
        statRow!(b, "gone", missing)
        statUnavailable = BAYSOL.Inference.statUnavailable!
        statUnavailable(b, "x", "no draws")
        lines = statLines(b)
        @test lines[1] == rpad("name", 32) * "\t1.23457"
        @test startswith(cell(lines, "nan"), "unavailable")
        @test cell(lines, "gone") == "unavailable"
        @test cell(lines, "x") == "unavailable: no draws"
        @test_throws ArgumentError statRow!(b, "n"^32, 1)
        # a nothing buffer is a no-op everywhere
        @test statRow!(nothing, "a", 1) === nothing && statPhase!(nothing) === nothing
    end

    @testset "the cap is a small share of the forward cache's memory budget" begin
        GiB = 2^30
        # 16 GiB free of 32, headroom 10 % of the total: budget 16 - 3.2 GiB
        mem() = (16GiB, 32GiB)
        budget = 16GiB - round(Int, 0.10 * 32GiB)
        @test statisticsCap(10; memory = mem) ==
              round(Int, STATISTICS_MEMORY_SHARE * budget)
        # a bigger headroom, a smaller budget, a smaller cap
        @test statisticsCap(50; memory = mem) < statisticsCap(10; memory = mem)
        # no memory left: the floor; a huge machine: the ceiling
        @test statisticsCap(10; memory = () -> (GiB, 32GiB)) == STATISTICS_BUFFER_MIN
        @test statisticsCap(10; memory = () -> (2^50, 2^51)) == STATISTICS_BUFFER_MAX
        @test STATISTICS_BUFFER_MIN ≤ statisticsCap() ≤ STATISTICS_BUFFER_MAX
        # the run's `memoryHeadroom` (in its stage log) reaches the buffer
        t = StageLog()
        t.info["memoryHeadroom"] = 90
        @test statBuffer(t).cap == statisticsCap(90)
        @test StatBuffer().cap == statisticsCap()
    end

    @testset "bounded size: flush at the cap and at a phase boundary, order kept" begin
        b = StatBuffer(; cap = 200)
        for i in 1:50
            statRow!(b, "row$i", i)
            @test b.bytes < 200 + 64              # never far past the cap
        end
        @test b.nFlushes ≥ 5 && b.spill !== nothing
        n = b.nFlushes
        statRow!(b, "tail", 1)
        statPhase!(b)                             # a phase boundary flushes the rest
        @test b.nFlushes == n + 1 && isempty(b.lines) && b.bytes == 0
        out = statLines(b)
        @test [split(l, ' ')[1] for l in out[1:50]] == ["row$i" for i in 1:50]
        @test split(out[51], ' ')[1] == "tail"
        @test b.flushSeconds ≥ 0
        spill = b.spill
        statReset!(b)
        @test !isfile(spill) && b.spill === nothing && isempty(b.attempts)
    end

    @testset "one block for each attempt, in order, with settings and outcome" begin
        log = StageLog()
        b = statBuffer(log)
        @test statBuffer(log) === b
        # base run, gate fails, retry, kept; then a ladder rung and a sampled-c1 restart
        k1 = statAttempt!(b, log)
        runs = synthRuns()
        statChains!(b, SYN_PR, SYN_SP, runs, synthDiag(rhat = 1.3), ["slvntEDns"],
            SYN_ARGS..., log, synthExtra(runs, 5))
        statNext!(b, "retry")
        statLabel!(b, "retry, longer warm-up", "R̂ 1.3";
            class = "convergence", rung = "longer warm-up and run")
        k2 = statAttempt!(b, log)
        runs = synthRuns(; div = 0)
        statChains!(b, SYN_PR, SYN_SP, runs, synthDiag(), ["slvntEDns"],
            SYN_ARGS..., log, synthExtra(runs, 5))
        statKeep!(b, k2, "the retry passed")
        statLabel!(b, "ladder rung stepSize", "failure class stepSize")
        k3 = statAttempt!(b, log)
        statStopped!(b, "KinkDetected: the profiled c1 is kinked")
        statLabel!(b, "sampled-c1 restart", "KinkDetected")
        k4 = statAttempt!(b, log)
        @test (k1, k2, k3, k4) == (1, 2, 3, 4) && statAttempts(b) == 4
        statKeep!(b, 2, "kept")
        lines = statLines(b)
        heads = filter(startswith("--- attempt"), lines)
        @test heads == ["--- attempt 1: base run ---",
            "--- attempt 2: retry, longer warm-up ---",
            "--- attempt 3: ladder rung stepSize ---",
            "--- attempt 4: sampled-c1 restart ---"]
        secs = statParse(lines)
        checkGrammar(secs)
        # the trigger of an attempt: what, its class and the rung applied
        @test scalar(section(secs, "settings"; attempt = 1), "triggerClass") == "none"
        s2 = section(secs, "settings"; attempt = 2)
        @test scalar(s2, "triggeredBy") == "R̂ 1.3"
        @test scalar(s2, "triggerClass") == "convergence"
        @test scalar(s2, "rung") == "longer warm-up and run"
        # the gate of each attempt, from its own R̂ and divergences
        g1, g2 = section(secs, "gate"; attempt = 1), section(secs, "gate"; attempt = 2)
        @test scalar(g1, "rhatMax") == "1.3" && scalar(g2, "rhatMax") == "1.002"
        @test startswith(scalar(g1, "gate"), "failed") && scalar(g2, "gate") == "passed"
        @test scalar(section(secs, "outcome"; attempt = 1), "next") == "retry"
        @test scalar(g1, "nDivergent") == "1" && scalar(g2, "nDivergent") == "0"
        @test startswith(scalar(section(secs, "outcome"; attempt = 3), "stopped"),
            "KinkDetected")
        # the attempts table and the result
        t = section(secs, "attempts"; attempt = 0)
        @test col(t, "label") == ["base run", "retry, longer warm-up",
            "ladder rung stepSize", "sampled-c1 restart"]
        @test col(t, "outcome") == ["dropped", "kept", "dropped", "dropped"]
        r = section(secs, "result"; attempt = 0)
        @test scalar(r, "keptAttempt") == "2" && scalar(r, "keptBecause") == "kept"
        # a failed run has no kept attempt
        f = section(statParse(statLines(b; failure = "boom")), "result"; attempt = 0)
        @test scalar(f, "keptAttempt") == "none" && scalar(f, "failed") == "boom"
    end

    @testset "every section of the report, filled from the run's draws only" begin
        b = StatBuffer()
        statAttempt!(b, nothing)
        statMapSearch!(b, SYN_PROB, SYN_SP, 1.234)
        runs = synthRuns()
        statKink!(b, 1, 4, 80, 3, 0)
        statKink!(b, 2, 4, 80, 0, 0)
        statChains!(b, SYN_PR, SYN_SP, runs, synthDiag(), ["slvntEDns", "d1", "d2", "d3"],
            SYN_ARGS..., nothing, synthExtra(runs, 5))
        lines = statLines(b)
        secs = statParse(lines)
        checkGrammar(secs)
        names = [s.name for s in secs if s.attempt == 1]
        @test names == ["settings", "problem", "map search", "nuts", "chains",
            "chain totals", "kink check", "posterior", "bounds", "axes", "correlation",
            "residuals", "convergence", "gate", "modes", "health", "c1 search"]
        # problem and map search keep the diagnose wording
        pr = section(secs, "problem").text
        @test pr[1] == "="^100 && occursin("nQ=120  nAtoms=3000", pr[2])
        @test startswith(pr[3], "δρ₃ support = [")
        ms = section(secs, "map search").text
        @test ms[1] == "MAP search: 1.2s  nOk=3/4  nModes=1  whitened=true"
        @test ms[2] == "L-BFGS starts (z space):"
        @test occursin("start 1: f=2.5000 iters= 14 g_conv=true iter_limit=false evals=30",
            ms[3])
        @test ms[4] == "  start 2: infeasible (no finite optimum)"
        @test occursin("iter_limit=true evals=420", ms[5])
        @test occursin("pass 1 = [1, 1, 1, 1]", ms[6])      # the first-pass Hessian
        @test occursin("mode 1: f=2.500", ms[8])
        # nuts
        nuts = section(secs, "nuts").text
        @test occursin("init ε=0.7", nuts[1]) && occursin("final ε=0.3", nuts[1])
        @test occursin("mean nSteps=7.0", nuts[1]) && occursin("diverged=1", nuts[1])
        @test nuts[2] == "mean nSteps by window: [1:65]=7  [6:65]=7"
        @test occursin("mean accept = 0.900   mean |ΔH| = 0.100", nuts[3])
        # the chains table: a row per chain, warm-up split, BFMI, c1 pinned, tallies
        ch = section(secs, "chains")
        @test ch.header == CHAIN_COLUMNS && length(ch.rows) == 2
        @test col(ch, "kept") == ["60", "60"]
        @test col(ch, "div") == ["1", "0"] && col(ch, "warm-up div") == ["1", "0"]
        @test col(ch, "gradient evals") == ["260", "260"] &&
              col(ch, "non-finite") == ["3", "3"]
        @test all(x -> 0 < parse(Float64, x) < 3, col(ch, "BFMI"))
        @test all(x -> 0 ≤ parse(Float64, x) ≤ 1, col(ch, "c1 at bound"))
        @test all(==("0.000"), col(ch, "depth≥10"))
        tot = section(secs, "chain totals")
        @test scalar(tot, "pooledDraws") == "120" && scalar(tot, "divergentDraws") == "1"
        @test scalar(tot, "warmupDivergentDraws") == "1"
        # the kink watch
        kk = section(secs, "kink check")
        @test col(kk, "drawsTwoBasins") == ["3", "0"] &&
              col(kk, "firedAtDraw") == ["none", "none"]
        # the posterior in w, the bounds, the axes
        po = section(secs, "posterior").text
        @test startswith(po[1], "post-warmup w: sd = [")
        @test any(startswith("  cov(w) eigenvalues"), po) &&
              any(startswith("ℓπ at L-BFGS"), po)
        bo = section(secs, "bounds")
        @test col(bo, "coordinate") == ["slvntEDns", "d1", "d2", "d3"]
        ax = section(secs, "axes").text
        @test startswith(ax[1], "Δf/(s²/2) along whitened axes")
        @test count(startswith("  w"), ax) ≥ 4
        @test any(l -> occursin("local λ_max(−∇²ℓπ) min/median/max", l), ax)
        @test any(l -> occursin("c1-tol noise=unavailable", l), ax)
        co = section(secs, "correlation")
        @test co.header == ["parameter", "slvntEDns", "d1", "d2", "d3"] &&
              length(co.rows) == 4
        @test all(i -> parse(Float64, co.rows[i][i+1]) ≈ 1, 1:4)
        # the residuals: Durbin-Watson and the runs test
        re = section(secs, "residuals")
        @test 0 < parse(Float64, scalar(re, "durbinWatson")) < 4
        @test scalar(re, "residualCount") == "40" && haskey(Dict(re.scalars), "runsZ")
        # convergence: R̂, ESS, sd, MCSE = sd/√ESS
        cv = section(secs, "convergence")
        @test length(cv.rows) == 5 && last(col(cv, "parameter")) == "logDensity"
        sd, ess, mc =
            parse.(Float64, (col(cv, "sd")[1], col(cv, "essBulk")[1], col(cv, "mcse")[1]))
        @test mc ≈ sd / sqrt(ess) rtol = 1e-4
        # health and the c1 search counters (the difference over the attempt)
        he = section(secs, "health")
        @test scalar(he, "leapfrogTotal") == string(7 * 130)
        @test parse(Float64, scalar(he, "leapfrogPerEss")) ≈ 7 * 130 / 900 rtol = 1e-5
        @test scalar(he, "gradientEvals") == "520" && scalar(he, "nonFiniteEvals") == "6"
        c1 = section(secs, "c1 search")
        @test scalar(c1, "c1Solves") == "500" && scalar(c1, "c1BrentIterations") == "2500"
        @test parse(Float64, scalar(c1, "c1BrentPerSolve")) == 5 &&
              scalar(c1, "c1ScanAtEdge") == "2"
        @test scalar(c1, "c1WlsErrors") == "1"
        # the divergent draws are not in the log; they are in the buffer's list
        text = join(lines, "\n")
        @test !occursin("divergent draws", text) && !occursin("iteration 6", text)
        dv = statDivergences(b)
        @test [(d.attempt, d.chain, d.draw, d.phase) for d in dv] ==
              [(1, 1, 2, "warm-up"), (1, 1, 6, "sampling")]
        @test all(d -> length(d.xi) == 4 && d.steps == 7 && d.depth == 3, dv)
        @test all(d -> isfinite(d.logπ) && isfinite(d.dLogπ), dv)
        # what a run does not compute is not in the log: no placeholders of the old design
        for gone in ("gradient error", "second pass", "pass 2", "reference curve")
            @test !occursin(gone, text)
        end
    end

    @testset "without a tally or re-profile the sections say unavailable, never zero" begin
        b = StatBuffer()
        statAttempt!(b, nothing)
        statChains!(b, SYN_PR, SYN_SP, synthRuns(; tally = false), synthDiag(),
            ["slvntEDns"], SYN_ARGS..., nothing)
        secs = statParse(statLines(b))
        checkGrammar(secs)
        @test startswith(only(section(secs, "posterior").text), "unavailable")
        he = section(secs, "health")
        @test startswith(scalar(he, "gradientEvals"), "unavailable")
        @test startswith(scalar(he, "c1AtLowerBound"), "unavailable")
        @test startswith(scalar(section(secs, "c1 search"), "c1Solves"), "unavailable")
        @test startswith(
            scalar(section(secs, "residuals"), "residualSource"),
            "unavailable",
        )
        ch = section(secs, "chains")
        @test all(==("unavailable"), col(ch, "gradient evals"))
    end

    @testset "the grammar round-trips and STAT_SECTIONS lists every section" begin
        b = StatBuffer()
        statAttempt!(b, nothing)
        statSection!(b, "chain totals")
        statRow!(b, "chainsRun", 2)
        statRow!(b, "divergentDraws", NaN)
        statSection!(b, "bounds")
        statTable!(b, ["coordinate", "median", "sd", "distanceSd", "shareNearBound"],
            [["a", 1.5, 0.25, missing, 0.0], ["b", -2, NaN, 1, 1]])
        statSection!(b, "nuts")
        statText!(b, "NUTS: free text  with spaces\tand more")
        secs = statParse(statLines(b))
        tot = section(secs, "chain totals")
        @test tot.scalars == ["chainsRun" => "2",
            "divergentDraws" => "unavailable (not finite: NaN)"]
        bo = section(secs, "bounds")
        @test bo.rows == [["a", "1.5", "0.25", "unavailable", "0.0"],
            ["b", "-2", "unavailable (not finite: NaN)", "1", "1"]]
        @test section(secs, "nuts").text == ["NUTS: free text  with spaces\tand more"]
        # names are unique, kinds are valid, and the README table has every one of them
        @test allunique(s.name for s in STAT_SECTIONS)
        @test all(s -> s.kind in (:scalars, :table, :text) && s.level in (:run, :attempt),
            STAT_SECTIONS)
        readme = read(joinpath(pkgdir(BAYSOL), "src", "inference", "README.md"), String)
        for s in STAT_SECTIONS
            @test occursin("`$(s.name)`", readme)
        end
        # an unknown section is read as text, never dropped
        @test only(statParse(["-- mystery --", "a line"])).text == ["a line"]
    end

    @testset "formatters: not finite is unavailable, never a number" begin
        @test fmtVec([1.0, NaN]) == "[1, unavailable]"
        @test occursin("init ε=unavailable", fmtDiagNuts(1.0, NaN, 0.3, 7.0, 3.0, 0.0, 0))
        row =
            fmtChainRow((; k = 1, start = 0.0, mode = 1, pooled = true, nPost = 20, div = 1,
                warmDiv = 0, warmN = 5, ε = 0.3, steps = 7.0, accept = 0.9, logπ = -1.0,
                eSd = 0.1, deep = 0.0, bfmi = NaN, pin = 0.0, grads = missing, bad = 3,
                note = ""))
        @test length(row) == length(CHAIN_COLUMNS)
        @test row[findfirst(==("BFMI"), CHAIN_COLUMNS)] == "unavailable"
        @test row[findfirst(==("gradient evals"), CHAIN_COLUMNS)] == "unavailable"
        @test row[findfirst(==("div%"), CHAIN_COLUMNS)] == "5.0"
    end

    @testset "a chain that stopped is unavailable, not zero" begin
        b = StatBuffer()
        runs = Any[synthRuns()...]
        runs[2] = _ChainRun(2, runs[2].ξ, nothing, ErrorException("x"), 0.1)
        statAttempt!(b, nothing)
        statChains!(b, SYN_PR, SYN_SP, runs, synthDiag(pooled = [true, false]), ["p"],
            SYN_ARGS..., nothing)
        secs = statParse(statLines(b))
        ch = section(secs, "chains")
        row2 = only(filter(r -> r[1] == "2", ch.rows))
        @test occursin("chain stopped", row2[end]) &&
              row2[findfirst(==("kept"), ch.header)] == "0"
        @test row2[findfirst(==("div"), ch.header)] == "unavailable"
        # only the pooled chain's draws are in the totals
        @test scalar(section(secs, "chain totals"), "pooledDraws") == "60"
    end

    @testset "a recorder that fails writes statisticsError and does not throw" begin
        b = StatBuffer()
        statAttempt!(b, nothing)
        @test statChains!(b, SYN_PR, SYN_SP, "not chains", synthDiag(), ["p"], SYN_ARGS...,
            nothing) === nothing
        lines = statLines(b)
        secs = statParse(lines)
        @test any(startswith("statisticsError"), section(secs, "statistics error").text)
    end

    @testset "writeStatistics: sections replaced once, file next to the run log" begin
        mktempdir() do dir
            path = joinpath(dir, "statistics-" * basename(dir) * ".LOG")
            function run(name, value)
                log = StageLog()
                log.info["workbook"] = joinpath(dir, name * ".xlsx")
                b = statBuffer(log)
                statAttempt!(b, log)
                statRow!(b, "marker", value)
                statKeep!(b, 1, "only")
                spill = (statPhase!(b); b.spill)
                @test writeStatistics(((; timing = log),)) == path
                return spill
            end
            run("res_fit1", "a")
            run("res_fit2", "b")
            run("res_fit1", "c")              # replaces the first section where it stands
            text = read(path, String)
            @test [m.captures[1] for m in eachmatch(r"^=== (.*) ===$"m, text)] ==
                  ["fit1", "fit2"]
            @test count("marker", text) == 2 &&
                  occursin("marker                          \tc", text)
            @test !occursin("\ta\n", text)
            run("res", "d")                   # res.xlsx: the folder's name
            @test occursin("=== $(basename(dir)) ===", read(path, String))
            @test readdir(dir) == [basename(path)]      # no .part left over
        end
    end

    @testset "a failed run: workbook only with divergences, error as workbookError" begin
        P = BAYSOL.Pipeline
        XLSX = P.XLSX
        mktempdir() do dir
            log = StageLog()
            b = statBuffer(log)
            statAttempt!(b, log)
            runs = synthRuns()
            statChains!(b, SYN_PR, SYN_SP, runs, synthDiag(), ["slvntEDns"],
                SYN_ARGS..., log, synthExtra(runs, 5))
            nDiv = length(statDivergences(b))
            @test nDiv > 0
            path = joinpath(dir, "res_fit1.xlsx")
            @test P._writeFailedWorkbook(path, ErrorException("boom"), log) == path
            xf = XLSX.readxlsx(path)
            @test XLSX.sheetnames(xf) == ["run", "divergences"]
            @test size(xf["divergences"][:], 1) == nDiv + 1       # header plus the rows
            @test xf["run"][:][2, 2] == "status"
            # no divergences, no workbook; a log without a buffer neither
            empty = StageLog()
            statAttempt!(statBuffer(empty), empty)
            @test P._writeFailedWorkbook(joinpath(dir, "none.xlsx"), ErrorException("x"),
                empty) === nothing
            @test P._writeFailedWorkbook(joinpath(dir, "none.xlsx"), ErrorException("x"),
                nothing) === nothing
            @test !isfile(joinpath(dir, "none.xlsx"))
            # a workbook that cannot be written: a
            # workbookError row, the script's error kept
            sub = joinpath(dir, "SASDYYY")
            mkpath(sub)
            script = joinpath(sub, "SASDYYY_fit1.jl")
            write(script, "error(\"boom\")\n")
            mkpath(joinpath(sub, "res_fit1.xlsx"))       # a directory where the file goes
            P._LAST_LOG[] = nothing
            err = try
                P._runLogged(script; path = joinpath(sub, "SASDYYY.LOG"))
                nothing
            catch e
                e
            end
            @test err !== nothing && occursin("boom", sprint(showerror, err))
            lines = P._failureLines(ErrorException("x"), nothing;
                workbookError = "disk full", workbook = nothing)
            @test any(l -> startswith(l, "workbookError"), lines)
            lines = P._failureLines(ErrorException("x"), nothing; workbook = "a.xlsx")
            @test any(l -> startswith(l, "workbook") && endswith(l, "a.xlsx"), lines)
        end
    end
end
