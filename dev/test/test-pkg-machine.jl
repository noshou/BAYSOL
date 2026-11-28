# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `pkg-machine.jl` (the machine side of `bysl pkg`): canned input and fakes only,
# so they run on any system; nothing here starts a build or reads a real Mac or Windows.

using Test
using Dev

const P = Dev.PkgTool

# `note` writes to the terminal of the tool: here nowhere
P.REAL_OUT[] = devnull

@testset "memory preflight and guard of disk-backed swap" begin
    @test P.memory_preflight(:linux; ram_mib = 8000, free_disk_mib = 1) === nothing
    ok, what, detail = P.memory_preflight(
        :macos; ram_mib = 16_000, free_disk_mib = 60_000)
    @test ok && occursin("free disk", what) && occursin("16000 MiB RAM", detail)
    @test !P.memory_preflight(:windows; ram_mib = 8000, free_disk_mib = 10_000)[1]
    # the floor stays free: 16000 + (10000 - 4096) < 24000
    @test !P.memory_preflight(:macos; ram_mib = 16_000, free_disk_mib = 10_000)[1]
    unk = P.memory_preflight(:macos; ram_mib = 16_000, free_disk_mib = nothing)
    @test unk[1] && occursin("unknown", unk[3])

    swap = P.parse_meminfo("SwapTotal: 40000000 kB\nSwapFree: 400000 kB\n")
    @test occursin("swap", P.guard_reason(:linux; swap_info = swap))
    @test P.guard_reason(:linux; free_disk_mib = 1) === nothing   # Linux ignores the disk
    @test P.guard_reason(:macos; free_disk_mib = 1000) !== nothing
    @test P.guard_reason(:windows; free_disk_mib = 50_000) === nothing
    @test P.guard_reason(:macos) === nothing                      # not given: not checked
    @test P.guard_reason(:macos; free_disk_mib = 3000, disk_floor = 2000) === nothing

    @test P.swap_volume(:macos; isdir = _ -> true) == "/private/var/vm"
    @test P.swap_volume(:macos; isdir = _ -> false) == "/"
    @test P.swap_volume(:windows; env = Dict("SystemDrive" => "D:")) == "D:\\"
    @test P.swap_volume(:linux) == "/"
    mktempdir() do d
        @test P.free_disk_mib(
            joinpath(d, "not", "there");
            stat = _ -> (; available = 5 * 1024^3),
        ) == 5120
        @test P.free_disk_mib(d; stat = _ -> error("no")) === nothing
    end
    P.MIN_FREE_DISK_SEEN[] = nothing
    P.note_free_disk(nothing)
    @test P.MIN_FREE_DISK_SEEN[] === nothing
    P.note_free_disk(900)
    P.note_free_disk(1200)
    P.note_free_disk(700)
    @test P.MIN_FREE_DISK_SEEN[] == 700
    P.MIN_FREE_DISK_SEEN[] = nothing
end

@testset "parsers of macOS and Windows output" begin
    t = "vm.swapusage: total = 2048.00M  used = 1024.25M  free = 1023.75M  (encrypted)"
    @test P.parse_swapusage(t) == (2048, 1024, 1024)
    @test P.parse_swapusage("total = 1.50G  used = 0.00M  free = 1.50G") == (1536, 0, 1536)
    @test P.parse_swapusage("nothing here") === nothing
    @test P.parse_memory_pressure("x\nSystem-wide memory free percentage: 42%\n") == 42
    @test P.parse_memory_pressure("nope") === nothing

    csv = """
    "ProcessId","ParentProcessId","WorkingSetSize"
    "4","0","147456"
    "100","4","1048576000"
    "200","100","524288000"
    "300","100",""
    garbage
    """
    p = P.parse_windows_processes(csv)
    @test p.parents[200] == 100 && p.parents[4] == 0
    @test p.rss[100] == 1000 && p.rss[200] == 500 && p.rss[300] == 0
    @test length(p.parents) == 4
    @test P.windows_tree_memory(100; csv = () -> csv) == (500, nothing)
    @test P.windows_tree_memory(100; csv = () -> nothing) == (nothing, nothing)   # unknown
    @test P.windows_tree_memory(100; csv = () -> "") == (nothing, nothing)

    @test P.parse_ps_cputime("0:12.50") == 12.5
    @test P.parse_ps_cputime("1:02:03") == 3723.0
    @test P.parse_ps_cputime("2-01:00:00") == 2 * 86400 + 3600.0
    @test P.parse_ps_cputime("x") === nothing
    t = P.parse_ps_table("  1 0 0:01.00\n 50 1 1:00.00\n bad line\n 60 50 0:03.00\n")
    @test t.parents == Dict(1 => 0, 50 => 1, 60 => 50)
    @test t.cpu[50] == 60.0
    @test P.tree_cpu_seconds(50; table = t) == 63.0
    @test P.tree_cpu_seconds(50; table = t, include_root = false) == 3.0
    @test P.tree_cpu_seconds(
        50;
        table = (parents = t.parents, cpu = Dict{Int,Float64}()),
    ) ===
          nothing
end

@testset "kill by PID" begin
    parents = Dict(1 => 0, 10 => 1, 11 => 10, 12 => 10, 99 => 5)
    killed = Int[]
    r = P.kill_tree(
        10;
        table = (; parents, cpu = Dict{Int,Float64}()),
        killer = pid ->
            push!(killed, pid),
    )
    @test sort(r) == [10, 11, 12] && killed == r
    @test r[end] == 10                                   # the root last
    @test 99 ∉ r && 1 ∉ r
    r2 = P.kill_tree(10; include_root = false,
        table = (; parents, cpu = Dict{Int,Float64}()), killer = _ -> nothing)
    @test sort(r2) == [11, 12]
end

@testset "timeout settings, hang detector and the watchdog" begin
    @test P.fit_timeout_min(; env = Dict{String,String}()) == P.FIT_TIMEOUT_MIN
    @test P.fit_timeout_min(; env = Dict("BAYSOL_PKG_FIT_TIMEOUT_MIN" => "90")) == 90
    @test P.hang_min(; env = Dict("BAYSOL_PKG_HANG_MIN" => "0")) == 0
    @test P.step_timeout_min(; env = Dict("BAYSOL_PKG_STEP_TIMEOUT_MIN" => " 1.5 ")) == 1.5
    for bad in ("x", "-1", "NaN", "Inf")
        @test_throws Dev.Common.ToolError P.hang_min(;
            env = Dict("BAYSOL_PKG_HANG_MIN" => bad))
    end

    h = P.HangState(600, 0)   # 10 min window
    @test !P.hang_update!(h, 0, 5.0, 100)
    @test !P.hang_update!(h, 300, 5.2, 100)    # idle for 5 min
    @test !P.hang_update!(h, 599, 5.4, 100)
    @test P.hang_update!(h, 600, 5.5, 100)     # 10 min idle
    @test !P.hang_update!(h, 700, 9.0, 100)    # CPU grew: active again
    @test !P.hang_update!(h, 1200, 9.0, 200)   # the log grew
    @test P.hang_update!(h, 1800, 9.0, 200)    # idle again for 10 min
    @test !P.hang_update!(h, 1900, 3.0, 200)   # CPU sum fell (a process ended): active
    g = P.HangState(60, 0)
    @test !P.hang_update!(g, 10_000, nothing, 0)   # no CPU figure: never a hang

    @test P.watch_verdict(10, 1, false, 30) == ""
    @test occursin("timeout", P.watch_verdict(61, 1, false, 30))
    @test occursin("hang", P.watch_verdict(5, 0, true, 30))
    @test P.watch_verdict(1e9, 0, false, 30) == ""   # a limit of 0 is off
    @test occursin("timeout", P.watch_verdict(61, 1, true, 30))

    # the watchdog with a fake clock, log and killer: a step that never moves is ended
    mktempdir() do d
        empty!(P.WATCHDOG_KILLS)
        log = joinpath(d, "s.log")
        write(log, "start\n")
        t = Ref(0.0)
        killed = Int[]
        gate = Channel{Nothing}(1)
        value = P.watched(; name = "fit X", limit_min = 0, hang_minutes = 10, period = 0,
            log = () -> log, tree_cpu = _ -> 1.0,
            killer = r -> (push!(killed, r); put!(gate, nothing); [r]),
            clock = () -> (t[] += 400; t[]),
            sleeper = (running, _) -> yield()) do
            take!(gate)
            true            # the program "exited" after the kill
        end
        @test value == false                      # a kill makes the step fail
        @test length(killed) == 1
        @test P.WATCHDOG_KILLS[1][1] == "fit X"
        @test occursin("hang", P.WATCHDOG_KILLS[1][2])
        empty!(P.WATCHDOG_KILLS)
        # a step that finishes before its limit is left alone and keeps its value
        @test P.watched(;
            name = "ok",
            limit_min = 60,
            hang_minutes = 30,
            period = 0.01,
        ) do
            :fine
        end === :fine
        @test isempty(P.WATCHDOG_KILLS)
        # both limits off: f alone
        @test P.watched(() -> 7; name = "n", limit_min = 0, hang_minutes = 0) == 7
    end
end

@testset "build paths in the bundle" begin
    @test P.path_scan_mode(; env = Dict{String,String}()) == "warn"
    @test P.path_scan_mode(; env = Dict("BAYSOL_PATH_SCAN" => "fail")) == "fail"
    @test_throws Dev.Common.ToolError P.path_scan_mode(;
        env = Dict("BAYSOL_PATH_SCAN" => "maybe"))
    @test P.path_scan_decision(0, "fail") == (:ok, "no build path in the bundle")
    @test P.path_scan_decision(5, "warn")[1] === :warn
    @test P.path_scan_decision(5, "fail")[1] === :fail
    @test P.path_scan_decision(5, "off")[1] === :ok

    n = P.path_needles(["/home/noso/", "/home/noso/BAYSOL", "x", ""])
    # nested one counted once
    @test [first(x) for x in n] == ["/home/noso", "\\home\\noso"]
    w = P.path_needles(["C:\\Users\\a"]; wide = true)
    @test any(x -> endswith(first(x), "(utf-16)"), w)
    wide = last(first(filter(x -> x[1] == "C:\\Users\\a (utf-16)", w)))
    @test wide[1:4] == UInt8['C', 0, ':', 0]

    @test P.find_bytes(codeunits("abc"), Vector{UInt8}("xxabcxabc"), 1) == 3:5
    @test P.find_bytes(codeunits("abc"), Vector{UInt8}("xxabcxabc"), 4) == 7:9
    @test P.find_bytes(codeunits("abc"), Vector{UInt8}("xxab"), 1) === nothing

    mktempdir() do d
        needle = Vector{UInt8}("/home/noso")
        write(joinpath(d, "a.txt"), "x /home/noso y /home/noso\n")
        mkpath(joinpath(d, "lib"))
        # a match that straddles the chunk boundary counts once, whatever the chunk size
        blob = vcat(zeros(UInt8, 30), needle, zeros(UInt8, 30))
        write(joinpath(d, "lib", "b.so"), blob)
        for chunk in (7, 16, 35, 100, 10_000)
            @test P.scan_file(joinpath(d, "lib", "b.so"), [needle]; chunk) == [1]
        end
        write(joinpath(d, "clean.bin"), rand(UInt8, 200) .| 0x80)   # no ASCII at all
        r = P.scan_paths(d, ["/home/noso" => needle, "work" => Vector{UInt8}("/work")])
        @test r.total == 3 && r.scanned == 3
        @test r.counts == Dict("/home/noso" => 3)
        @test first(first(r.files)) == "a.txt" && last(first(r.files)) == 2
        before = read(joinpath(d, "lib", "b.so"))
        # the step: read only, the result goes to the log row
        P.PATH_SCAN_TOTAL[] = nothing
        @test P.path_scan_step(d; env = Dict("BAYSOL_PATH_SCAN" => "warn"),
            home = "/home/noso", work = "/scratch/work-dir", root = "/home/noso/BAYSOL")
        @test P.PATH_SCAN_TOTAL[] == 3
        @test !P.path_scan_step(d; env = Dict("BAYSOL_PATH_SCAN" => "fail"),
            home = "/home/noso", work = "/scratch/work-dir", root = "/home/noso/BAYSOL")
        @test P.path_scan_step(d; env = Dict("BAYSOL_PATH_SCAN" => "off"),
            home = "/home/noso", work = "/w", root = "/r") &&
              P.PATH_SCAN_TOTAL[] === nothing
        @test read(joinpath(d, "lib", "b.so")) == before
    end
    P.PATH_SCAN_TOTAL[] = nothing

    @test P.juliac_debug_args(; env = Dict{String,String}()) ==
          ["--debug-info=0"]
    @test P.juliac_debug_args(; env = Dict("BAYSOL_JULIAC_DEBUG_INFO" => "1")) ==
          ["--debug-info=1"]
    @test_throws Dev.Common.ToolError P.juliac_debug_args(;
        env = Dict("BAYSOL_JULIAC_DEBUG_INFO" => "3"))
end

@testset "the archiver chain" begin
    which = n -> n == "7z" ? "/usr/bin/7z" : nothing
    c = P.archiver_candidates(; bundled = "/npm/7za", which)
    @test c == ["/usr/bin/7z", "/npm/7za"]                 # the system one first
    @test P.archiver_candidates(; bundled = nothing, which = _ -> nothing) == String[]
    @test P.pick_archiver(c; probe = p -> p == "/npm/7za") == "/npm/7za"   # first fails
    @test P.pick_archiver(c; probe = _ -> true) == "/usr/bin/7z"
    @test P.pick_archiver(c; probe = _ -> false) === nothing
    @test P.fallback_archiver(:linux; which = _ -> "/x") === nothing
    @test P.fallback_archiver(
        :macos;
        which = n -> n == "zip" ? "/usr/bin/zip" : nothing,
    ).kind ===
          :zip
    fb = P.fallback_archiver(:macos; which = n -> "/usr/bin/$n")
    @test fb.kind === :ditto
    @test P.fallback_archiver(:macos; which = _ -> nothing) === nothing
    cmd, dir = P.fallback_archive_command(fb, "/out/a.zip", "/w/bundle/baysol")
    @test dir == "/w/bundle" && occursin("--keepParent baysol /out/a.zip", string(cmd))
    cmd, _ = P.fallback_archive_command((kind = :zip, path = "/usr/bin/zip"), "/o.zip",
        "/w/bundle/baysol")
    @test occursin("-y /o.zip baysol", string(cmd))
    # the start probe: a program that does not exist or does not say 7-Zip is not one
    @test !P.seven_zip_works("/no/such/program")
    mktempdir() do d
        if !Sys.iswindows()
            f = joinpath(d, "fake")
            write(f, "#!/bin/sh\necho '7-Zip (a) 23.01'\n")
            chmod(f, 0o755)
            @test P.seven_zip_works(f)
            write(f, "#!/bin/sh\necho hello\n")
            @test !P.seven_zip_works(f)
            write(f, "no shebang, not executable\n")
            chmod(f, 0o644)
            @test !P.seven_zip_works(f)
        end
    end
end

@testset "parallel jobs" begin
    @test P.pkg_jobs(; env = Dict{String,String}(), cores = 8) == 1
    @test P.pkg_jobs(; env = Dict("BAYSOL_PKG_JOBS" => "3"), cores = 8) == 3
    @test P.pkg_jobs(; env = Dict("BAYSOL_PKG_JOBS" => "16"), cores = 4) == 4
    for bad in ("0", "-2", "x", "1.5")
        @test_throws Dev.Common.ToolError P.pkg_jobs(;
            env = Dict("BAYSOL_PKG_JOBS" => bad), cores = 8)
    end
    @test P.fits_memory(4000, 0, 7000, 0)
    @test !P.fits_memory(4000, 4000, 6000, 1000)
    @test P.fits_memory(4000, 4000, 6000, 8000)

    log1 =
        "--- stages ---\n" *
        "julia packages test (cold depot)   ok   10.0 s   peak RAM 900 MiB\n"
    log2 =
        "--- stages ---\n" *
        "julia packages test (cold depot)   ok   10.0 s   peak RAM 1500 MiB\n" *
        "unknownstep   ok   1.0 s   peak RAM unknown\n"
    pk = P.known_peaks([log1, log2])
    @test pk["julia packages test (cold depot)"] == 1500
    @test !haskey(pk, "unknownstep")

    # one slot: the old behaviour, in order, in the calling task
    order = Int[]
    jobs = [P.Job("j$i", 1, () -> (push!(order, i); i != 2)) for i in 1:4]
    @test P.run_jobs(jobs, 1) == [true, false, true, true]
    @test order == [1, 2, 3, 4]

    # with slots: the first alone, never more than `slots` at once, results in job order
    active = Ref(0)
    most = Ref(0)
    started = Int[]
    mk(i, ok) = P.Job("j$i", 100, () -> begin
        push!(started, i)
        active[] += 1
        most[] = max(most[], active[])
        sleep(0.05)
        active[] -= 1
        ok
    end)
    res = P.run_jobs([mk(1, true), mk(2, false), mk(3, true), mk(4, true)], 2;
        first_alone = true, poll = 0.01)
    @test res == [true, false, true, true]
    @test started[1] == 1 && sort(started) == [1, 2, 3, 4]
    @test most[] == 2
    # first_alone: job 1 finished before job 2 started
    active[] = 0
    most[] = 0
    empty!(started)
    P.run_jobs([mk(1, true), mk(2, true)], 2; first_alone = true, poll = 0.01)
    @test most[] == 1
    # a memory gate that never admits degrades to sequential and still finishes
    active[] = 0
    most[] = 0
    res = P.run_jobs([mk(1, true), mk(2, true), mk(3, true)], 3;
        admit = (_, _) -> false, poll = 0.01)
    @test all(res) && most[] == 1
    # a job that throws counts as failed and does not stop the others
    @test P.run_jobs([P.Job("a", 1, () -> error("x")), P.Job("b", 1, () -> true)], 2;
        poll = 0.01) == [false, true]

    # the depot installs as jobs, with a fake runner (nothing is installed)
    mktempdir() do d
        old = P.LOG_DIR[]
        P.LOG_DIR[] = d
        try
            ran = String[]
            js =
                P.instantiate_jobs("julia", ["test" => "/p/test", "tui/julia" => "/p/tui"],
                    Dict("julia packages test (cold depot)" => 900),
                    (cmd, log) -> (push!(ran, string(cmd)); true))
            @test [j.peak for j in js] == [900, P.JOB_DEFAULT_PEAK_MIB]
            @test all(j -> j.run(), js)
            @test all(c -> occursin("Pkg.instantiate", c), ran)
            @test occursin("--project=/p/test", ran[1])
            empty!(P.STEP_LOGS)
            ok = P.parallel_depot("julia", ["a" => "/p/a", "b" => "/p/b"], 2;
                admit = (_, _) -> true, run_cmd = (_, _) -> true)
            @test ok && length(P.STEP_LOGS) == 2
            @test !P.parallel_depot("julia", ["a" => "/p/a", "b" => "/p/b"], 2;
                admit = (_, _) -> true, run_cmd = (c, _) -> !occursin("/p/b", string(c)))
            @test P.earlier_peaks(joinpath(d, "none")) == Dict{String,Int}()
            write(joinpath(d, "x.LOG"), log2)
            @test P.earlier_peaks(d)["julia packages test (cold depot)"] == 1500
        finally
            P.LOG_DIR[] = old
            empty!(P.STEP_LOGS)
        end
    end
end

@testset "the log rows of the machine file" begin
    P.ARCHIVER[] = nothing
    P.PATH_SCAN_TOTAL[] = nothing
    empty!(P.WATCHDOG_KILLS)
    rows = Dict(P.machine_log_rows())
    @test rows["buildPathStrings"] == "not scanned" && !haskey(rows, "archiver")
    @test rows["juliacDebugInfo"] == "--debug-info=0"
    P.ARCHIVER[] = "7-Zip /x/7za"
    P.PATH_SCAN_TOTAL[] = 12
    push!(P.WATCHDOG_KILLS, ("fit A", "hang: x"))
    rows = Dict(P.machine_log_rows())
    @test rows["archiver"] == "7-Zip /x/7za" && rows["buildPathStrings"] == "12"
    @test occursin("fit A", rows["timeouts"])
    P.ARCHIVER[] = nothing
    P.PATH_SCAN_TOTAL[] = nothing
    empty!(P.WATCHDOG_KILLS)

    # a stage row with an unknown peak still reads, as a row without peaks
    log = Dev.PkgTool.parse_build_log(
        "--- stages ---\n" * "fit X   ok   12.0 s   peak RAM unknown\n",
    )
    @test length(log.stages) == 1 && log.stages[1].ram === nothing
end
