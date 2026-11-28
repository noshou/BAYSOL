# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl pkg`: the parts that need no build (the archive name, the swap watch, the
# merge of the traced statements, the guards of the scratch folder, the plan).

using Test
using Dev: Platform
using TOML
using Dev
using JSON3

const P = Dev.PkgTool

@testset "archive name" begin
    @test P.archive_name("0.5.0", "linux", "arm64") == "baysol-0.5.0-linux-arm64.zip"
    @test P.archive_name("1.2.3", "windows", "x64") == "baysol-1.2.3-windows-x64.zip"
    @test occursin(r"^baysol-\d+\.\d+\.\d+-(linux|macos|windows)-(arm64|x64)\.zip$",
        P.this_archive())
end

@testset "memory and swap watch" begin
    info = P.parse_meminfo("SwapTotal: 40000000 kB\nSwapFree: 400000 kB\n")
    @test P.swap_low(info)
    info["SwapFree"] = 20_000_000
    @test !P.swap_low(info)
    @test !P.swap_low(Dict{String,Int}())      # no swap: nothing to watch
    @test P.process_memory("Name: x\nVmRSS:\t  2048 kB\nVmSwap:\t  1024 kB\n") == (2, 1)
    @test P.process_memory("") == (0, 0)
    @test sort(P.descendants(Dict(2 => 1, 3 => 2, 4 => 1, 9 => 8), 1)) == [1, 2, 3, 4]
    @test sort(
        P.descendants(Dict(2 => 1, 3 => 2, 4 => 1, 9 => 8), 1; include_root = false),
    ) ==
          [2, 3, 4]
    # a child process is counted, the driver is not
    if Platform.islinux()
        proc = run(`sleep 3`; wait = false)
        sleep(0.3)
        @test P.tree_memory()[1] >= 0
        @test P.tree_memory(getpid())[1] < Sys.total_memory() ÷ 1024^2
        kill(proc)
    end
    # the watcher ends soon after f returns, not after its whole period
    t = @elapsed P.watch_memory(() -> sleep(0.2); period = 2)
    @test t < 1
    value, peak = P.watch_memory(() -> 42; period = 0.05)
    @test value == 42
    Platform.islinux() && @test peak.ram >= 0 && peak.swap >= 0
    # a child with real memory is measured by the watcher, never the driver alone
    if Platform.islinux()
        _, p2 = P.watch_memory(
            () -> (run(`sleep 0.5`); nothing); period = 0.1)
        @test p2.ram > 0
    end
end

@testset "report: steps log to files, the report holds the status" begin
    mktempdir() do d
        P.LOG_DIR[] = d
        empty!(P.REPORT)
        P.REAL_OUT[] = devnull
        @test P.step("quiet", () -> (println("x"); run(`echo child-output`); true))
        @test occursin("child-output", read(joinpath(d, "quiet.log"), String))
        @test !P.step("false", () -> false)
        @test !P.step("throws", () -> error("boom"))
        @test !P.step("tests", () -> (println("Test Failed at a.jl:1"); false);
            pattern = r"Test Failed")
        @test count(l -> occursin(" FAIL ", l), P.REPORT) == 3
        @test any(l -> occursin("ERROR: boom", l), P.REPORT)
        @test any(l -> occursin("Test Failed at a.jl:1", l), P.REPORT)
        @test any(l -> occursin(r"quiet\s+ok\s+\d", l), P.REPORT)
        # the terminal output of the step is not in the report
        @test !any(l -> occursin("child-output", l), P.REPORT)
        log = joinpath(d, "log.txt")
        write(log, join(["l$i" for i in 1:20], "\n") * "\nmodel a failed: x\n")
        @test P.problems(log) == ["model a failed: x"]
        @test P.problems(log, r"zzz") ==
              ["l16", "l17", "l18", "l19", "l20", "model a failed: x"]
        @test P.problems(joinpath(d, "none")) == String[]
        P.write_report(joinpath(d, "report.txt"), "a.zip")
        text = read(joinpath(d, "report.txt"), String)
        @test startswith(text, "bysl pkg") && occursin("archive    a.zip", text)
        P.REAL_OUT[] = stdout
    end
end

@testset "build log: terminal plots and noise are left out, the facts stay" begin
    plot = join(
        [
            "                 ⠀⠀⠀⠀⠀⠈⠉⠉⠑⠒⠢⠤⢄⣀⠀⠀⠀  SASDVA2_3ODQ   χ² = 1.402",
            "   log₁₀ I(q)     ⠀⠀⠀⠀⠀⠀⠀⠀⢹⠀⠀⠀⠂⠀⢀⡠⡄⠀",
            "   [1.22, 1.23)  █████████████████████▊ 11 510",
            "                 └                         ┘",
            "                                                   c1",
        ],
        "\n",
    )
    text = join(
        [
            "Fit finished: reduced χ² = 4.52 on the measured points",
            plot,
            "\e[32mcompiled\e[0m 5328 statements",
            "downloading 10%\rdownloading 50%\rdownloading 100%",
            "same",
            "same",
            "same",
            "",
            "",
            "",
            "tail",
            "x" ^ 300,
            "",
            "",
        ],
        "\n",
    )
    lines = P.clean_log(text)
    @test lines == [
        "Fit finished: reduced χ² = 4.52 on the measured points",
        "compiled 5328 statements",
        "downloading 100%",
        "same   (x 3)",
        "",
        "tail",
        "x" ^ (P.LOG_LINE_MAX - 3) * "...",
    ]
    @test P.clean_log(plot) == String[]
    many = ["line $i" for i in 1:500]
    t = P.trim_log(many)
    @test length(t) == P.LOG_KEEP_HEAD + 1 + P.LOG_KEEP_TAIL
    @test t[P.LOG_KEEP_HEAD+1] ==
          "... $(500 - P.LOG_KEEP_HEAD - P.LOG_KEEP_TAIL) lines left out ..."
    @test first(t) == "line 1" && last(t) == "line 500"
    @test P.trim_log(["a", "b"]) == ["a", "b"]

    mktempdir() do d
        log(n, body) = (f = joinpath(d, n * ".log"); write(f, body); f)
        empty!(P.REPORT)
        empty!(P.STEP_LOGS)
        P.note("stage julia ok    12.3 s   peak RAM 100 MiB, swap 5 MiB")
        push!(P.STEP_LOGS, "juliac" => log("a", text))
        push!(P.STEP_LOGS, "only a plot" => log("b", plot))
        push!(P.STEP_LOGS, "never ran" => joinpath(d, "missing.log"))
        out = joinpath(d, "build-logs", "baysol-9.9.9-linux-arm64.LOG")
        P.write_build_log(out, "/somewhere/baysol-9.9.9-linux-arm64.zip")
        got = read(out, String)
        @test occursin(r"^datetime\s+\t\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}\n"m, got)
        @test occursin(r"^archive\s+\tbaysol-9\.9\.9-linux-arm64\.zip$"m, got)
        @test occursin("--- stages ---\nstage julia ok    12.3 s   peak RAM 100 MiB", got)
        @test occursin("--- step: juliac ---\nFit finished: reduced χ² = 4.52", got)
        @test !occursin("only a plot", got) && !occursin("never ran", got)
        @test !any(c -> '\u2800' <= c <= '\u28ff' || c == '█', got)
        @test occursin("--- machine ---", got)
        # every row's value starts at a tab stop, whatever the name's length
        @test all(l -> (i = findfirst('\t', l); i === nothing || (i - 1) % 8 == 0),
            filter(l -> occursin(r"^[a-z]+\s*\t", l), split(got, '\n')))
    end
end

@testset "the build log keeps every run of a resumed build" begin
    mktempdir() do d
        old = joinpath(d, "old.log")
        write(old, "Fit finished: reduced χ² = 1.0\n")
        P.HISTORY[] = joinpath(d, "history.tsv")
        empty!(P.REPORT)
        empty!(P.STEP_LOGS)
        P.note("trace      FAIL  12.0 s")
        P.remember("S", "stage trace", old)
        P.load_history()
        @test P.PRIOR_REPORT == ["trace      FAIL  12.0 s"]
        @test P.PRIOR_STEPS == ["stage trace" => old]
        # the next run: its own lines come after the earlier ones
        empty!(P.REPORT)
        P.note("trace      skipped (done before)")
        out = joinpath(d, "b", "x.LOG")
        P.write_build_log(out, "/s/baysol-9.9.9-linux-arm64.zip")
        got = read(out, String)
        @test occursin("trace      FAIL  12.0 s\n--- last run ---\ntrace      skipped", got)
        @test occursin("--- step: stage trace ---\nFit finished: reduced χ² = 1.0", got)
        P.HISTORY[] = ""
        empty!(P.PRIOR_REPORT)
        empty!(P.PRIOR_STEPS)
    end
end

@testset "the machine memory is given on every system" begin
    m = P.machine_memory()
    @test m.ram > 0
    @test m.swap === nothing || m.swap >= 0
    @test P.mib_or_unknown(nothing) == "unknown" && P.mib_or_unknown(8) == "8 MiB"
end

@testset "merged statements" begin
    lines = [
        "precompile(Tuple{typeof(BAYSOL.f), Int64})",
        "precompile(Tuple{typeof(BAYSOL.f), Int64})",     # twice
        "not a statement",
        "precompile(Tuple{typeof(Main.g), Int64})",       # a script's closure
        "precompile(Tuple{typeof(Test.@test), Int64})",
        "precompile(Tuple{typeof(BAYSOL.h), Float64})",
    ]
    @test P.merge_statements(lines) == [
        "precompile(Tuple{typeof(BAYSOL.f), Int64})",
        "precompile(Tuple{typeof(BAYSOL.h), Float64})",
    ]
end

@testset "statements of modules the app does not hold are dropped" begin
    allowed = Set(["Base", "Core", "BAYSOL", "BAYSOLRun", "Printf"])
    lines = [
        "precompile(Tuple{typeof(BAYSOL.f), Int64})",
        "precompile(Tuple{typeof(BAYSOL.f), NtTest_x.T})",
        "precompile(Tuple{typeof(JET.report), Int64})",
        "precompile(Tuple{typeof(BAYSOLRun.runProjectCli), Vector{String}})",
        "precompile(Tuple{typeof(Base.string), Base.SubString{String}})",
    ]
    kept = P.merge_statements(lines; allowed)
    @test length(kept) == 3
    @test all(l -> !occursin(r"NtTest_|JET", l), kept)
    @test any(occursin("BAYSOLRun", l) for l in kept)
    @test "BAYSOLRun" in P.app_modules() && "Base" in P.app_modules()
end

@testset "the Platform module in the statements" begin
    # every app package holds its own copy of platform.jl:
    # BAYSOL.Platform, SetupWizard.Platform, BAYSOLRun.Platform;
    # Dev.Platform belongs to the development tools only
    app = [
        "precompile(Tuple{typeof(BAYSOL.Platform.exe), String})",
        "precompile(Tuple{typeof(BAYSOL.Platform.which), String})",
        "precompile(Tuple{typeof(SetupWizard.Platform.data_home)})",
        "precompile(Tuple{typeof(SetupWizard.Platform.iswindows)})",
        "precompile(Tuple{typeof(BAYSOLRun.Platform.exe), String})",
        "precompile(Tuple{typeof(BAYSOLRun.Platform.shell)})",
        "precompile(Tuple{typeof(SetupWizard.Platform.which), String})",
    ]
    dev = [
        "precompile(Tuple{typeof(Dev.Platform.exe), String})",
        "precompile(Tuple{typeof(Dev.Platform.which), String})",
        "precompile(Tuple{typeof(Dev.PkgTool.find_7z)})",
        "precompile(Tuple{typeof(Dev.Common.run_cmd), Cmd})",
        # an app function with a Dev-only argument type, and a script's alias
        "precompile(Tuple{typeof(BAYSOL.Platform.exe), Dev.Common.ToolError})",
        "precompile(Tuple{typeof(Main.Platform.exe), String})",
        "precompile(Tuple{typeof(Main.SetupWizard.Platform.exe), String})",
    ]
    allowed = Set(["Base", "Core", "BAYSOL", "SetupWizard", "BAYSOLRun"])
    @test P.merge_statements(vcat(dev, app, dev)) == app
    @test P.merge_statements(vcat(dev, app); allowed) == app
    @test P.merge_statements(dev; allowed) == String[]
    # the modules an app statement names are the first one only: `Platform` is a submodule
    @test all(l -> [m[1] for m in eachmatch(P._MODULE_NAME, l)] ⊆ allowed, app)
    # the manifest of the app lists the three packages
    @test issubset(["BAYSOL", "SetupWizard", "BAYSOLRun"], P.app_modules())
end

@testset "a printed Char literal becomes evaluable" begin
    l = "precompile(Tuple{Printf.Spec{Base.Val{Char(0x67000000)}}})"
    out = only(P.merge_statements([l]))
    @test occursin("reinterpret(Char, 0x67000000)", out)
    @test !occursin(r"\bChar\(0x", out)
    @test Meta.parse(out) isa Expr
end

@testset "the scratch folder is removed only when it is ours" begin
    @test_throws Dev.Common.ToolError P.remove_work(mktempdir())
    dir = mkpath(joinpath(mktempdir(), "baysol-pkg-work"))
    @test_throws Dev.Common.ToolError P.remove_work(dir)       # no marker
    P.finish(dir, "pytools")
    P.remove_work(dir)
    @test !ispath(dir)
end

@testset "a folder with paths over 260 characters is removed (Windows)" begin
    base = mkpath(joinpath(mktempdir(), "baysol-pkg-work", "depot"))
    deep = base
    while length(deep) < 300
        deep = joinpath(deep, "a_long_folder_name_" * "x"^30)
    end
    # Windows creates and fills such a path only by its prefixed name
    full = Platform.iswindows() ? P.LONG_PATH_PREFIX * abspath(deep) : deep
    mkpath(full)
    write(joinpath(full, "f.hpp"), "1")
    P.rm_tree(base)
    @test !ispath(base)
end

# A 64-bit little-endian ELF header with the given
# PT_LOAD segments `(offset, vaddr, align)`.
function fake_elf64(segments)
    io = IOBuffer()
    write(io, UInt8[0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0])
    write(io, zeros(UInt8, 8))                       # e_ident padding
    write(io, UInt16(3), UInt16(62), UInt32(1))      # type, machine, version
    write(io, UInt64(0), UInt64(64), UInt64(0))      # entry, phoff, shoff
    write(io, UInt32(0), UInt16(64), UInt16(56), UInt16(length(segments)))
    write(io, UInt16(64), UInt16(0), UInt16(0))      # shentsize, shnum, shstrndx
    for (offset, vaddr, align) in segments
        write(io, UInt32(1), UInt32(5), UInt64(offset), UInt64(vaddr), UInt64(vaddr))
        write(io, UInt64(0x100), UInt64(0x100), UInt64(align))
    end
    return take!(io)
end

@testset "a file the strip tool left unloadable is put back" begin
    dir = mktempdir()
    good = joinpath(dir, "good.so")
    # libunwind.so.8 of Julia: the third segment at offset 0x7d000 for address 0x233000
    write(
        good,
        fake_elf64([(0, 0, 0x200000), (0x27e78, 0x227e78, 0x200000),
            (0x7d000, 0x233000, 0x1000)]),
    )
    bad = joinpath(dir, "bad.so")                    # after llvm-strip 18.1.3: 0x285f8
    write(
        bad,
        fake_elf64([(0, 0, 0x200000), (0x27e78, 0x227e78, 0x200000),
            (0x285f8, 0x233000, 0x1000)]),
    )
    text = joinpath(dir, "script.sh")
    write(text, "#!/bin/sh\n")
    @test P.elf_load_ok(good) && !P.elf_load_ok(bad) && P.elf_load_ok(text)
    # the "strip" replaces good.so by the broken layout and shrinks the script
    original = read(good)
    runner(l) = (write(good, read(bad)); write(text, "#"); true)
    r = P.strip_checked([["strip", good, text]], [good, text]; os = :linux, runner)
    @test r.restored == [good] && r.failed == String[]
    @test read(good) == original && read(text) == codeunits("#")
    @test !any(endswith(".pre-strip"), readdir(dir))
    # no check (and no copy) on the other systems
    r = P.strip_checked([["strip", good]], [good]; os = :windows, runner)
    @test isempty(r.restored) && read(good) == read(bad)
end

@testset "juliac links with -lm" begin
    w = mktempdir()
    p = P.link_wrapper(w)
    @test isfile(p) && endswith(read(p, String), "exec gcc \"\$@\" -lm\n")
    Sys.iswindows() || @test Sys.isexecutable(p)
end

@testset "the threads of the juliac build process" begin
    default = Platform.isrosetta() ? 1 : 4
    withenv("BAYSOL_JULIAC_THREADS" => nothing) do
        @test P.juliac_threads() == default
    end
    withenv("BAYSOL_JULIAC_THREADS" => "6") do
        @test P.juliac_threads() == 6
    end
    for bad in ("0", "-2", "many", "")
        withenv("BAYSOL_JULIAC_THREADS" => bad) do
            @test P.juliac_threads() == default
        end
    end
    # a copy of juliac.jl whose build process takes its threads from the environment
    root = mktempdir()
    bin = mkpath(joinpath(root, "bin"))
    juliac = mkpath(joinpath(root, "share", "julia", "juliac"))
    line = "cmd = addenv(`x`, \"OPENBLAS_NUM_THREADS\" => 1, \"JULIA_NUM_THREADS\" => 1)
"
    write(joinpath(juliac, "juliac.jl"), "# juliac
" * line * "run(cmd)
")
    write(
        joinpath(juliac, "Artifacts.toml"),
        "# artifacts
",
    )
    write(
        joinpath(root, "share", "julia", "julia-config.jl"),
        "# config
",
    )
    work = mktempdir()
    path = P.patched_juliac(work; bindir = bin)
    text = read(path, String)
    @test occursin("get(ENV, \"BAYSOL_JULIAC_THREADS\", \"1\")", text)
    @test occursin("\"OPENBLAS_NUM_THREADS\" => 1", text)
    @test !occursin("\"JULIA_NUM_THREADS\" => 1)", text)
    @test isfile(joinpath(dirname(path), "Artifacts.toml"))
    @test isfile(joinpath(dirname(dirname(path)), "julia-config.jl"))
    @test read(joinpath(juliac, "juliac.jl"), String) == "# juliac
" * line * "run(cmd)
"
    P.patched_juliac(work; bindir = bin)             # a second call replaces the copy
    # another juliac.jl (no such line, or two): the stage stops instead of running unpatched
    write(
        joinpath(juliac, "juliac.jl"),
        "run(cmd)
",
    )
    @test_throws Dev.Common.ToolError P.patched_juliac(work; bindir = bin)
    write(joinpath(juliac, "juliac.jl"), line * line)
    @test_throws Dev.Common.ToolError P.patched_juliac(work; bindir = bin)
end

@testset "the strip mode of the juliac compile command" begin
    text = "strip_args = String[]\ncmd = addenv(`x`, \"JULIA_NUM_THREADS\" => 1)\n"
    threaded = "\"JULIA_NUM_THREADS\" => get(ENV, \"BAYSOL_JULIAC_THREADS\", \"1\"))"
    @test P.patch_juliac_text(text) ==
          replace(text, "\"JULIA_NUM_THREADS\" => 1)" => threaded)
    @test occursin(
        "strip_args = String[\"--strip-metadata\"]",
        P.patch_juliac_text(text, "metadata"),
    )
    ir = P.patch_juliac_text(text, "ir")
    @test occursin("String[\"--strip-metadata\", \"--strip-ir\"]", ir)
    @test_throws Dev.Common.ToolError P.patch_juliac_text(text, "bogus")
    nostrip = replace(text, "strip_args = String[]" => "x = 1")
    @test P.patch_juliac_text(nostrip) isa String
    @test_throws Dev.Common.ToolError P.patch_juliac_text(nostrip, "ir")
    @test_throws Dev.Common.ToolError P.patch_juliac_text(text * text, "ir")
    withenv("BAYSOL_JULIAC_STRIP" => nothing) do
        @test P.juliac_strip() == "metadata"
    end
    withenv("BAYSOL_JULIAC_STRIP" => "none") do
        @test P.juliac_strip() == "none"
    end
    withenv("BAYSOL_JULIAC_STRIP" => "ir") do
        @test P.juliac_strip() == "ir"
    end
    withenv("BAYSOL_JULIAC_STRIP" => "all") do
        @test_throws Dev.Common.ToolError P.juliac_strip()
    end
end

@testset "a stage line without a swap figure still parses" begin
    b = P.parse_build_log("--- stages ---\nstage x ok   1.0 s   peak RAM 5 MiB\n")
    @test b.stages[1].ram == 5 && b.stages[1].swap === nothing
end

@testset "cold caches" begin
    env = P.cold_env("/w/baysol-pkg-work")
    @test env["JULIA_DEPOT_PATH"] == joinpath("/w/baysol-pkg-work", "depot")
    @test startswith(env["BAYSOL_CACHE"], "/w/baysol-pkg-work")
    @test startswith(env["UV_CACHE_DIR"], "/w/baysol-pkg-work")
    dir = mkpath(joinpath(mktempdir(), "baysol-pkg-work"))
    @test_throws Dev.Common.ToolError P.remove_caches(dir)        # not ours yet
    mkpath(joinpath(dir, "logs"))
    for c in P.COLD_CACHES
        write(joinpath(mkpath(joinpath(dir, c)), "x"), "1")
    end
    mkpath(joinpath(dir, "pytools"))
    @test P.remove_caches(dir) == length(P.COLD_CACHES)
    @test !any(c -> ispath(joinpath(dir, c)), P.COLD_CACHES)
    @test isdir(joinpath(dir, "pytools"))                          # only the caches
    @test !P.looks_like_work(mktempdir())
end

@testset "plan" begin
    @test P.STAGES == ["pytools", "tui", "trace", "julia", "bundle"]
    @test P.WORKLOAD == unique(P.WORKLOAD)
end

@testset "launcher and icon of this system" begin
    name, text = P.launcher()
    @test occursin(r"baysol(\.exe\"|\s)", text) && !occursin("baysol-tui", text)
    mktempdir() do dir      # the real icons of the repository pack into this system's file
        dest =
            P.pack_icon(joinpath(dir, P.icon_file()), joinpath(Dev.Common.root(), "icons"))
        @test Platform.islinux() ? isdir(joinpath(dest, "hicolor")) : filesize(dest) > 1000
    end
    @test startswith(text, Platform.iswindows() ? "@echo off" : "#!")
end

@testset "the embedded Python entry is valid and complete" begin
    @test occursin("def main() -> int:", P.PYTOOLS_ENTRY)
    @test occursin("m.REPAIR_LIMIT = float(\"inf\")", P.PYTOOLS_ENTRY)
    # a `python3` that is only a Windows app-execution alias does not run: ask it
    python_runs = try
        success(`python3 --version`)
    catch
        false
    end
    if python_runs
        f = tempname() * ".py"
        write(f, P.PYTOOLS_ENTRY)
        @test success(
            `python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" $f`,
        )
    end
end

@testset "the reduced trace list names real, distinct entries" begin
    @test allunique(P.TRACE_FITS)
    @test all(in(Dev.Common.ids()), P.TRACE_FITS)
    # the real runs' projects are traced too
    @test all(in(P.TRACE_FITS), P.WORKLOAD)
    @test P.TRACE_FITS == [e.id for e in P.TRACE_ENTRIES]
    @test length(P.TRACE_FITS) < length(Dev.Common.ids()) ÷ 10
    @test Meta.parse("begin\n" * P.OUTPUT_DRIVER * "\nend") isa Expr
end

@testset "mirror_entry copies an entry into a scratch tree" begin
    root = Dev.Common.root()
    for id in (first(P.TRACE_FITS), first(Dev.Common.synthetic_ids()))
        scratch = mktempdir()
        script = Dev.Fits.Fit.mirror_entry(id, scratch)
        tree =
            id in Dev.Common.synthetic_ids() ? Dev.Common.SYNTHETIC_DIR :
            Dev.Common.FIT_DIR
        @test script == joinpath(scratch, tree, id, basename(Dev.Common.script_of(id)))
        @test isfile(script)
        @test isfile(joinpath(scratch, Dev.Common.FIT_DIR, "common.jl"))
        @test ispath(joinpath(scratch, "test", "fixtures"))
        names = readdir(joinpath(scratch, tree, id))
        @test !("plots" in names)
        @test !any(n -> endswith(n, ".xlsx") || endswith(n, ".LOG"), names)
        # everything else of the source folder is there
        kept = filter(
            n -> n != "plots" && !endswith(n, ".xlsx") && !endswith(n, ".LOG"),
            readdir(joinpath(root, tree, id)),
        )
        @test sort(names) == sort(kept)
    end
end

@testset "sea_config: every asset goes into the executable" begin
    assets = joinpath(Dev.Common.root(), "tui", "assets")
    config = JSON3.read(P.sea_config(assets), Dict{String,Any})     # valid JSON
    @test config["main"] == "baysol-tui.mjs"
    keys_ = sort!(collect(keys(config["assets"])))
    # keyed by the path below assets/ with `/`, the way `readAssetText` asks
    @test "data/default_settings.json" in keys_
    @test "logo/logo-large.txt" in keys_
    @test all(k -> isfile(config["assets"][k]), keys_)
    n = sum(length(names) for (_, _, names) in walkdir(assets))
    @test length(keys_) == n
end

@testset "native_assets: the files of the system being built on" begin
    mktempdir() do dir
        mk(parts...) = (p = joinpath(dir, parts...); mkpath(dirname(p)); write(p, "x"); p)
        mk("@resvg", "resvg-js-linux-arm64-gnu", "resvgjs.linux-arm64-gnu.node")
        mk("pdf-raster-linux-arm64-gnu", "pdf-raster.linux-arm64-gnu.node")
        mk("pdf-raster-linux-arm64-gnu", "libpdfium.so")
        mk("7zip-bin", "linux", "arm64", "7za")
        got = P.native_assets(dir; os = "linux", arch = "arm64")
        @test sort!(collect(keys(got))) ==
              ["native/7za", "native/pdf-raster.node", "native/pdfium", "native/resvg.node"]
        @test all(isfile, values(got))
        # another system has other files, and a missing one is named
        err = try
            P.native_assets(dir; os = "win", arch = "x64")
        catch e
            sprint(showerror, e)
        end
        @test occursin("resvg-js-win32-x64-msvc", err)
        mk("@resvg", "resvg-js-darwin-arm64", "resvgjs.darwin-arm64.node")
        mk("pdf-raster-darwin-arm64", "pdf-raster.darwin-arm64.node")
        mk("pdf-raster-darwin-arm64", "libpdfium.dylib")
        mk("7zip-bin", "mac", "arm64", "7za")
        mac = P.native_assets(dir; os = "darwin", arch = "arm64")
        @test endswith(mac["native/pdfium"], "libpdfium.dylib")
    end
end

@testset "jll_search_env: bare names resolve while the build runs" begin
    mktempdir() do d
        src = joinpath(d, "hash", "lib")
        mkpath(src)
        write(joinpath(src, "libearcut.so"), "e")
        libs = [("EarCut_jll", "u", "libearcut_path", joinpath(src, "libearcut.so"))]
        var, value = P.jll_search_env(joinpath(d, "jll-lib"), libs)
        @test var in ("LD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "PATH")
        @test startswith(value, joinpath(d, "jll-lib"))
        @test read(joinpath(d, "jll-lib", "libearcut.so"), String) == "e"
    end
end

@testset "icon: the hand-made sizes are packed as they are" begin
    mktempdir() do dir
        be(n) = collect(reinterpret(UInt8, [hton(UInt32(n))]))
        png(px) = vcat(UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], be(13),
            codeunits("IHDR"), be(px), be(px), zeros(UInt8, 5))
        for (name, px) in ("icon_16x16.png" => 16, "icon_16x16@2x.png" => 32,
            "icon_22x22.png" => 22, "icon_32x32.png" => 32, "icon_256x256.png" => 256,
            "icon_512x512@2x.png" => 1024, "notes.txt" => 0)
            write(joinpath(dir, name), px == 0 ? UInt8[1] : png(px))
        end
        sizes = P.icon_sizes(dir)
        @test first.(sizes) == [16, 22, 32, 256, 1024]           # @2x only where no plain
        @test endswith(last(sizes[3]), "icon_32x32.png")
        # Linux: the PNGs go into the folder as they are, one hicolor folder per size
        dest = P.pack_icon(joinpath(dir, "icons"), dir; system = :linux)
        @test sort(readdir(joinpath(dest, "hicolor"))) ==
              sort(["16x16", "22x22", "32x32", "256x256", "512x512@2"])
        @test read(joinpath(dest, "hicolor", "32x32", "baysol.png")) ==
              read(joinpath(dir, "icon_32x32.png"))
        @test P.hicolor_folder(1024) == "512x512@2" && P.hicolor_folder(48) == "48x48"
        ico = P.ico_bytes(sizes)
        # 4 entries: 1024 is left out
        @test ico[1:6] == UInt8[0, 0, 1, 0, 4, 0]
        @test ico[6+16*3+1] == 0                            # the 256 entry's side byte
        write(joinpath(dir, "icon_64x64.png"), png(32))           # name and header disagree
        @test_throws ErrorException P.icon_sizes(dir)
        @test isempty(P.icon_sizes(joinpath(dir, "nowhere")))
    end
end

@testset "icon: macOS ships the hand-made icns verbatim, the others are built" begin
    mktempdir() do dir
        be(n) = collect(reinterpret(UInt8, [hton(UInt32(n))]))
        png(px) = vcat(UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], be(13),
            codeunits("IHDR"), be(px), be(px), zeros(UInt8, 5))
        for (name, px) in ("icon_16x16.png" => 16, "icon_22x22.png" => 22,
            "icon_256x256.png" => 256)
            write(joinpath(dir, name), png(px))
        end
        icns(entries) = (
            body = reduce(vcat,
                [vcat(codeunits(t), be(8 + length(d)), d) for (t, d) in entries];
                init = UInt8[]);
            vcat(codeunits("icns"), be(8 + length(body)), body)
        )
        # no hand-made icns: macOS is an error, never the PNG-built file
        @test_throws ErrorException P.icon_bytes(:macos, dir)
        @test_throws ErrorException P.pack_icon(joinpath(dir, "x"), dir; system = :macos)
        @test !isfile(joinpath(dir, "x"))
        @test !P._icon_ready(:macos, dir) && P._icon_ready(:linux, dir)
        # an unusual but valid file (TOC, ARGB, mask and PNG entries) is copied as it is
        mac = icns([
            "TOC " => zeros(UInt8, 8),
            "ic04" => vcat(codeunits("ARGB"), zeros(UInt8, 9)),
            "s8mk" => zeros(UInt8, 5), "ic11" => png(32), "ic10" => png(1024),
        ])
        write(joinpath(dir, "icon.icns"), mac)
        @test P.icon_bytes(:macos, dir) == mac
        dest = P.pack_icon(joinpath(dir, "baysol.icns"), dir; system = :macos)
        @test read(dest) == mac && P._icon_ready(:macos, dir)
        # broken files: bad header, wrong length field, truncated entry, no entry
        for bad in (vcat(codeunits("junk"), mac[5:end]),
            vcat(mac[1:4], be(length(mac) + 1), mac[9:end]),
            mac[1:(end-3)],
            icns([]))
            write(joinpath(dir, "icon.icns"), bad)
            @test_throws ErrorException P.icon_bytes(:macos, dir)
            @test !P._icon_ready(:macos, dir)
        end
        write(joinpath(dir, "icon.icns"), mac)
        # Windows and Linux ignore it and use the PNG sizes (Linux has no single file)
        sizes = P.icon_sizes(dir)
        @test P.icon_bytes(:windows, dir) == P.ico_bytes(sizes)
        @test_throws ErrorException P.icon_bytes(:linux, dir)
        @test_throws ErrorException P.icon_bytes(:plan9, dir)
    end
end

@testset "runtime_files: one real file per library, no symlinks" begin
    mktempdir() do dir
        write(joinpath(dir, "libjulia.so.1.12.7"), "j")
        symlink("libjulia.so.1.12.7", joinpath(dir, "libjulia.so.1.12"))
        symlink("libjulia.so.1.12.7", joinpath(dir, "libjulia.so"))
        write(joinpath(dir, "libblastrampoline.so.5"), "b")
        symlink("libblastrampoline.so.5", joinpath(dir, "libblastrampoline.so.5.15.0"))
        symlink("libblastrampoline.so.5", joinpath(dir, "libblastrampoline.so"))
        write(joinpath(dir, "libgcc_s.so"), "linker script")   # left out: link time only
        write(joinpath(dir, "sys.so"), "system image")        # left out: never loaded
        write(joinpath(dir, "README"), "not a library")
        for n in ("libccalltest.so", "libccalltest.so.debug", "libllvmcalltest.so")
            write(joinpath(dir, n), "test library")      # the app never loads these
        end
        files = P.runtime_files(dir)
        @test first.(files) == ["libblastrampoline.so.5", "libjulia.so.1.12"]
        out = joinpath(dir, "out")
        for (n, from) in files
            mkpath(out)
            cp(from, joinpath(out, n); follow_symlinks = true)
        end
        @test read(joinpath(out, "libjulia.so.1.12"), String) == "j"
        @test !any(islink, readdir(out; join = true))
    end
end

@testset "copy_runtime: libjulia beside, the rest nested, bare names real" begin
    mktempdir() do d
        P.copy_runtime(d)
        nested = joinpath(d, "julia")
        all = [joinpath(r, f) for (r, _, fs) in walkdir(d) for f in fs]
        @test !any(islink, all)
        @test isfile(joinpath(d, "libjulia.so.1.12")) || !Platform.islinux()
        if Platform.islinux()
            @test isfile(joinpath(nested, "libjulia-internal.so.1.12"))
            @test isfile(joinpath(nested, "libopenlibm.so"))
            @test isfile(joinpath(nested, "libopenblas64_.so"))
            @test !isfile(joinpath(nested, "libopenblas64_.so.0"))
            @test isfile(joinpath(nested, "libpcre2-8.so"))
        end
    end
end

@testset "baked_artifacts: the hashes inside a binary, across chunk borders" begin
    h1, h2 = "a"^40, "0123456789abcdef0123456789abcdef01234567"
    mktempdir() do d
        f = joinpath(d, "exe")
        write(
            f,
            vcat(rand(UInt8, 100), Vector{UInt8}("/home/u/.julia/artifacts/$h1/lib/x.so"),
                zeros(UInt8, 50), Vector{UInt8}("/artifacts/$h2"),
                Vector{UInt8}("/artifacts/short")),
        )
        @test P.baked_artifacts(f) == sort([h1, h2])
    end
end

@testset "jll preferences: the library of each JLL by its bare name" begin
    libs = [
        (
            "A_jll",
            "11111111-1111-1111-1111-111111111111",
            "libA_path",
            "/d/artifacts/h/lib/libA.so",
        ),
        (
            "A_jll",
            "11111111-1111-1111-1111-111111111111",
            "libB_path",
            "/d/artifacts/h/lib/libB.so",
        )]
    mktempdir() do d
        lp = P.write_jll_preferences(d, libs)
        @test occursin(d, lp) && endswith(lp, "@stdlib")
        prefs = TOML.parsefile(joinpath(d, "LocalPreferences.toml"))
        @test prefs["A_jll"] == Dict("libA_path" => "libA.so", "libB_path" => "libB.so")
        @test TOML.parsefile(joinpath(d, "Project.toml"))["extras"]["A_jll"] ==
              "11111111-1111-1111-1111-111111111111"
        exe = joinpath(d, "exe")
        write(exe, "xx/artifacts/" * "b"^40 * "/lib/libA.so")
        lib = joinpath(d, "libA.so")
        write(lib, "so")
        out = joinpath(d, "out")
        @test P.install_jll_libraries(exe, [("A_jll", "u", "k", lib)], out) == ["b"^40]
        @test isfile(joinpath(P.runtime_layout(out).private, "libA.so"))
        @test isdir(joinpath(out, "share", "julia", "artifacts", "b"^40))
    end
end

@testset "pkg: the runtime layout per system" begin
    @test P.runtime_layout("/o", :linux) ==
          (; libjulia = joinpath("/o", "julia"), private = joinpath("/o", "julia", "julia"))
    @test P.runtime_layout("/o", :macos) == P.runtime_layout("/o", :linux)
    # Windows: every DLL beside the exe (no RUNPATH, `juliac --relative-rpath` is refused)
    @test P.runtime_layout("/o", :windows) == (; libjulia = "/o", private = "/o")
    @test P.juliac_flags(:windows) == String[]
    @test P.juliac_flags(:linux) == ["--relative-rpath"]
    @test P.juliac_flags(:macos) == ["--relative-rpath"]
    @test P.juliac_flags() == P.juliac_flags(Platform.os())
    # the bare names carry the extension of this system
    @test all(endswith("." * Base.BinaryPlatforms.platform_dlext()), P.BARE_RUNTIME_NAMES)
    @test "libopenblas64_." * Base.BinaryPlatforms.platform_dlext() in P.BARE_RUNTIME_NAMES
end

@testset "pkg: what a Windows runtime folder ships and prunes" begin
    # the DLLs of Julia's `bin` (1.12, Windows): the test libraries, libgit2, libdSFMT and
    # libgmpxx go; libuv-2.dll and every mingw runtime DLL the others import stay
    mktempdir() do dir
        keep = ["libjulia.dll", "libjulia-internal.dll", "libjulia-codegen.dll",
            "libLLVM-18jl.dll", "libopenblas64_.dll", "libopenlibm.dll",
            "libgcc_s_seh-1.dll",
            "libgfortran-5.dll", "libquadmath-0.dll", "libstdc++-6.dll",
            "libwinpthread-1.dll", "libgmp-10.dll", "libmpfr-6.dll", "libpcre2-8-0.dll",
            "libuv-2.dll", "libatomic-1.dll", "libssp-0.dll", "libz.dll"]
        skip = ["libccalltest.dll", "libccalllazyfoo.dll", "libccalllazybar.dll",
            "libllvmcalltest.dll", "libgit2.dll", "libdSFMT.dll", "libgmpxx.dll"]
        for n in vcat(keep, skip, ["julia.exe", "README.txt"])
            write(joinpath(dir, n), "x")
        end
        @test first.(P.runtime_files(dir)) == sort(keep)
        out = mkpath(joinpath(dir, "out"))
        for (name, from) in P.runtime_files(dir)
            cp(from, joinpath(P.runtime_layout(out, :windows).libjulia, name))
        end
        @test sort(readdir(out)) == sort(keep)
    end
end

@testset "pkg: Windows and Python details of the stages" begin
    @test "patchelf" in P.py_packages(:linux)
    @test !("patchelf" in P.py_packages(:windows)) && !("patchelf" in P.py_packages(:macos))
    @test all(p -> p in P.py_packages(:linux), P.py_packages(:windows))
    @test "nuitka==4.3.5" in P.py_packages(:windows)
    # a C compiler is a Linux and macOS requirement: juliac downloads MinGW-w64 on Windows
    @test !("gcc" in P.preflight_programs(:windows))
    @test "gcc" in P.preflight_programs(:linux) && "gcc" in P.preflight_programs(:macos)
    mktempdir() do d
        bin = mkpath(joinpath(d, ".bin"))
        write(joinpath(bin, "esbuild"), "#!/bin/sh")
        @test P.node_tool("esbuild"; modules = d) == joinpath(bin, "esbuild")
        write(joinpath(bin, "esbuild.cmd"), "@echo off")       # npm writes it on Windows
        @test P.node_tool("esbuild"; modules = d) == joinpath(bin, "esbuild.cmd")
        @test P.node_tool("postject"; modules = d) == joinpath(bin, "postject")
    end
    nd = joinpath("x", "node-v26-win-x64")
    @test P.node_program(nd) ==
          (Platform.iswindows() ? joinpath(nd, "node.exe") : joinpath(nd, "bin", "node"))
    @test P.unpack_command("a.tar.xz", "d") == `tar -xf a.tar.xz -C d`
    zipcmd = P.unpack_command("a.zip", "d")
    @test zipcmd === nothing || any(==("-od"), zipcmd.exec)
    # a trailing separator of the work folder is no reason to refuse it
    mktempdir() do d
        work = mkpath(joinpath(d, "baysol-pkg-work"))
        mkpath(joinpath(work, "logs"))
        @test P.looks_like_work(work)
        @test P.looks_like_work(work * "/")
        Platform.iswindows() && @test P.looks_like_work(work * "\\")
    end
end

@testset "pkg: a refused strip is reported, not fatal" begin
    files = ["/b/a.dll", "/b/bad.dll", "/b/c.dll"]
    lines = P.strip_windows("s", files, String[])
    ran = Vector{String}[]
    runner(l) = (push!(ran, l); !("/b/bad.dll" in l))
    @test P.run_strip(lines, files; runner) == ["/b/bad.dll"]
    @test ran[1] == lines[1]
    @test ran[2:end] == [
        ["s", "--strip-all", "/b/a.dll"], ["s", "--strip-all", "/b/bad.dll"],
        ["s", "--strip-all", "/b/c.dll"],
    ]
    @test P.run_strip(lines, files; runner = _ -> true) == String[]
end

@testset "pkg: libraries and frozen files the app never loads" begin
    for n in ("libgit2.so.1.9", "libuv.so.2", "libdSFMT.so", "libgmpxx.so.4", "sys.so")
        @test occursin(P.RUNTIME_SKIP, n)
    end
    for n in ("libgmp.so.10", "libjulia.so.1.12", "libopenblas64_.so")
        @test !occursin(P.RUNTIME_SKIP, n)
    end
    mktempdir() do dir
        mkpath(joinpath(dir, "numpy", "random"))
        mkpath(joinpath(dir, "numpy", "_core"))
        write(joinpath(dir, "numpy", "random", "mtrand.so"), "12345")
        write(joinpath(dir, "numpy", "random", "note.txt"), "x")
        write(joinpath(dir, "numpy", "_core", "_multiarray_umath.so"), "y")
        write(joinpath(dir, "libscipy_openblas64_-1b7162d6.so"), "z")
        @test P.prune_pytools(dir) == 5
        @test !isfile(joinpath(dir, "numpy", "random", "mtrand.so"))
        @test isfile(joinpath(dir, "numpy", "random", "note.txt"))
        @test isfile(joinpath(dir, "numpy", "_core", "_multiarray_umath.so"))
        @test isfile(joinpath(dir, "libscipy_openblas64_-1b7162d6.so"))
    end
end

@testset "pkg: the app is built for the generic CPU" begin
    @test P.CPU_TARGET == "generic"
end

@testset "pkg: strip command lines per platform" begin
    libs = ["/b/a.so", "/b/c.so.1"]
    exes = ["/b/baysol"]
    @test P.strip_linux("strip", libs, exes) == [
        ["strip", "--strip-all", "/b/a.so", "/b/c.so.1"],
        ["strip", "--strip-all", "/b/baysol"],
    ]
    @test P.strip_macos("strip", ["/b/a.dylib"], exes) ==
          [["strip", "-x", "/b/a.dylib"], ["strip", "-S", "-x", "/b/baysol"]]
    @test P.strip_windows("strip", ["/b/a.dll"], exes) ==
          [["strip", "--strip-all", "/b/a.dll"], ["strip", "--strip-all", "/b/baysol"]]
    @test P.strip_command_lines(:windows, "s", libs, exes) ==
          P.strip_windows("s", libs, exes)
    @test P.STRIP_TOOL == "llvm-strip"
    @test_throws P.ToolError P.strip_command_lines(:plan9, "strip", libs, exes)
    @test P.strip_command_lines(:linux, "s", libs, exes) == P.strip_linux("s", libs, exes)
    @test P.strip_command_lines(:macos, "s", libs, exes) == P.strip_macos("s", libs, exes)
    many = ["/b/l$i.so" for i in 1:(2*P.STRIP_CHUNK+1)]
    lines = P.strip_linux("strip", many, String[])
    @test length(lines) == 3
    @test all(l -> length(l) <= P.STRIP_CHUNK + 2, lines)
    @test reduce(vcat, [l[3:end] for l in lines]) == many
    @test P.strip_linux("strip", String[], String[]) == []
end

@testset "pkg: strip targets and the bundle step" begin
    mktempdir() do dir
        elf = UInt8[0x7f, 0x45, 0x4c, 0x46, 1, 2, 3]
        write(joinpath(dir, "libx.so"), elf)
        write(joinpath(dir, "libx.so.1.2"), elf)
        write(joinpath(dir, "libscript.so"), "GROUP ( libgcc_s.so.1 )")
        write(joinpath(dir, "readme.txt"), elf)
        write(joinpath(dir, "baysol"), elf)
        write(joinpath(dir, "baysol-tui"), elf)
        Platform.iswindows() || symlink("libx.so", joinpath(dir, "liblink.so"))
        libs, exes = P.strip_targets(dir, [joinpath(dir, "baysol"), joinpath(dir, "nope")])
        @test basename.(libs) == ["libx.so", "libx.so.1.2"]
        @test basename.(exes) == ["baysol"]
        @test P.tree_bytes(dir) > 0

        empty!(P.REPORT)
        P.REAL_OUT[] = devnull
        before = read(joinpath(dir, "libx.so"))
        # a system without a command: reported, not a failure
        empty!(P.REPORT)
        @test !P.strip_bundle(dir, [joinpath(dir, "baysol")]; os = :plan9, tool = "x")
        @test any(l -> occursin("left unstripped", l) && occursin("plan9", l), P.REPORT)
        @test read(joinpath(dir, "libx.so")) == before
    end
end

@testset "reference fits of the trace projects" begin
    mktempdir() do dir
        @test P.unpack_references(dir) == 0       # no archive: nothing to unpack
        sz = P.find_7z()
        if sz !== nothing
            stage = mkpath(joinpath(dir, "stage"))
            write(joinpath(stage, "CRYSOL_fit1.tsv"), "0.1\t1.0\t0.1\n")
            archive = joinpath(dir, "reference-fit.7z")
            run(
                pipeline(`$sz a $archive $(joinpath(stage, "CRYSOL_fit1.tsv"))`;
                    stdout = devnull),
            )
            @test P.unpack_references(dir) == 1
            @test isfile(joinpath(dir, "reference-fit", "CRYSOL_fit1.tsv"))
            @test P.unpack_references(dir) == 0   # the folder is there: left alone
        end
    end
    mktempdir() do logs
        old = P.LOG_DIR[]
        P.LOG_DIR[] = logs
        try
            write(joinpath(logs, "run-a.log"), "fine\n")
            @test P.check_no_skipped_reference("run a") === nothing
            write(joinpath(logs, "run-b.log"), "model x: the reference fit was skipped\n")
            @test_throws Dev.Common.ToolError P.check_no_skipped_reference("run b")
        finally
            P.LOG_DIR[] = old
        end
    end
end

@testset "build log reader: stages, peaks and the short view" begin
    text = join(
        [
            "datetime        \t2026-11-24 23:06:42 -0500",
            "version \tv0.5.1 pẽnegda",
            "revision        \tf0f169c4-dirty",
            "julia   \t1.12.7",
            "node    \t26.13.1",
            "python  \t3.12",
            "system  \tlinux-arm64, Fedora Linux Asahi Remix 45",
            "",
            "--- stages ---",
            "pytools skipped (done before)",
            "stage julia ok      2020.3 s   peak RAM 11961 MiB, swap 16019 MiB",
            "  juliac              ok     1500.0 s   peak RAM 11000 MiB, swap 15000 MiB",
            "stage bundle FAIL      13.2 s   peak RAM 1403 MiB, swap 0 MiB",
            "  pytools: 4.0 MiB of unused numpy files left out",
            "total      33.7 min",
            "",
            "--- step: stage julia ---",
            "datetime\tnot a row of the head",
            "",
            "--- machine ---",
            "cpu     \tBlizzard-M2",
            "threads \t8",
            "ram     \t15624 MiB",
            "swap    \t49147 MiB",
        ],
        "\n",
    )
    b = P.parse_build_log(text)
    @test b.rows["version"] == "v0.5.1 pẽnegda"
    @test b.rows["datetime"] == "2026-11-24 23:06:42 -0500"    # not the step's row
    @test b.rows["cpu"] == "Blizzard-M2"
    @test [(s.name, s.top, s.ok) for s in b.stages] ==
          [("stage julia", true, true), ("juliac", false, true),
        ("stage bundle", true, false)]
    @test b.stages[1].seconds == 2020.3
    @test (b.stages[1].ram, b.stages[1].swap) == (11961, 16019)
    @test b.skipped == ["pytools"]
    @test b.total == 33.7
    short = P.format_build_log(b)
    @test any(l -> occursin("total", l) && occursin("33.7 min", l), short)
    @test any(l -> occursin("julia", l) && occursin("11.7 GiB", l), short)
    @test any(l -> occursin("bundle FAIL", l), short)
    @test !any(l -> occursin("juliac", l), short)
    @test any(l -> occursin("juliac", l), P.format_build_log(b; steps = true))
    @test any(l -> occursin("Blizzard-M2", l) && occursin("RAM 15.3 GiB", l), short)
    summary = P.format_build_summary(["a.LOG" => b])
    @test occursin("11.7 GiB", summary[2]) && occursin("15.6 GiB", summary[2])
    @test endswith(summary[2], "FAIL")
    # the reader copes with a log that has no stage table
    @test P.parse_build_log("").total === nothing
    @test P.duration_text(59.6) == "60 s" && P.duration_text(180) == "3.0 min"
    @test P.size_text(nothing) == "-" && P.size_text(512) == "512 MiB"
    mktempdir() do dir
        write(joinpath(dir, "baysol-0.5.1-linux-arm64.LOG"), text)
        write(joinpath(dir, "baysol-0.5.1-windows-x64.LOG"), text)
        write(joinpath(dir, "notes.txt"), "")
        @test length(P.build_log_files(dir, String[])) == 2
        @test basename.(P.build_log_files(dir, ["WINDOWS"])) ==
              ["baysol-0.5.1-windows-x64.LOG"]
        @test isempty(P.build_log_files(joinpath(dir, "none"), String[]))
    end
end

@testset "macOS: the Mach-O files of a bundle and their signatures" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "lib"))
        macho = [0xcf, 0xfa, 0xed, 0xfe, 0x00]
        for f in ("baysol", joinpath("lib", "b.dylib"), joinpath("lib", "a.so"))
            write(joinpath(dir, f), macho)
        end
        write(joinpath(dir, "note.txt"), "text")
        write(joinpath(dir, "empty.so"), "")
        # the libraries before the executable, nothing else
        files = P.macho_files(dir)
        @test relpath.(files, dir) ==
              [joinpath("lib", "a.so"), joinpath("lib", "b.dylib"), "baysol"]
        ran = Vector{String}[]
        P.sign_macos(files; runner = c -> (push!(ran, collect(c.exec)); true))
        @test length(ran) == 6
        @test ran[1] == ["codesign", "--force", "--sign", "-", files[1]]
        @test ran[2] == ["codesign", "--verify", "--strict", files[1]]
        # a refused signature stops the build
        @test_throws Exception P.sign_macos(files; runner = _ -> false)
    end
end

@testset "macOS: the names the runtime libraries are shipped under" begin
    names(file, bare, id) = P.macos_names(file, bare; id)
    @test names("libz.1.3.1.dylib", nothing, "@rpath/libz.1.dylib") == ["libz.1.dylib"]
    @test names("libopenlibm.4.0.dylib", "libopenlibm.dylib",
        "@rpath/libopenlibm.4.dylib") == ["libopenlibm.4.dylib", "libopenlibm.dylib"]
    v = "$(VERSION.major).$(VERSION.minor)"
    # one name only: two copies would be two runtimes
    @test names("libjulia-internal.$v.7.dylib", nothing,
        "@rpath/libjulia-internal.dylib") == ["libjulia-internal.$v.dylib"]
    @test names("/x/libfoo.dylib", nothing, nothing) == ["libfoo.dylib"]
    ran = Vector{String}[]
    P.relink_macos(["/b/libjulia-codegen.$v.dylib", "/b/baysol"];
        runner = c -> (push!(ran, collect(c.exec)); true))
    @test "@rpath/libjulia-internal.$v.dylib" in ran[2] && !("-id" in ran[2])
    @test "-id" in ran[1] && ran[1][end] == "/b/libjulia-codegen.$v.dylib"
    @test_throws Exception P.relink_macos(["/b/x"]; runner = _ -> false)
end

@testset "trace fits: resume reruns a fit with no marker or no workbook" begin
    mktempdir() do d
        fits, results = mkpath(joinpath(d, "fits")), mkpath(joinpath(d, "results"))
        @test P.fit_pending(fits, results, "A")             # no marker
        write(joinpath(fits, "A.done"), "")
        @test P.fit_pending(fits, results, "A")             # marker, no workbook
        mkpath(joinpath(results, "test", "fitting_tests", "A"))
        write(joinpath(results, "test", "fitting_tests", "A", "res.xlsx"), "")
        @test !P.fit_pending(fits, results, "A")            # both: done
        @test P.fit_pending(fits, results, "B")
    end
end

@testset "logical cores, macOS deployment target, MiB rows" begin
    @test P.logical_cores(; os = :macos, sysctl = () -> "8\n") == 8
    @test P.logical_cores(; os = :macos, sysctl = () -> "x") == Sys.CPU_THREADS
    @test P.logical_cores(; os = :macos, sysctl = () -> error("no")) == Sys.CPU_THREADS
    @test P.logical_cores(; os = :linux, sysctl = () -> "8") == Sys.CPU_THREADS
    withenv("MACOSX_DEPLOYMENT_TARGET" => nothing) do
        @test P.macos_deployment_target(:macos) == "14.0"
        @test P.macos_deployment_target(:linux) === nothing
    end
    withenv("MACOSX_DEPLOYMENT_TARGET" => "15.2") do
        @test P.macos_deployment_target(:macos) == "15.2"
    end
    macos = Platform.ismacos()
    @test haskey(P.cold_env("/w"), "MACOSX_DEPLOYMENT_TARGET") == macos
end

@testset "smoke test of the built program" begin
    ok, text = P.smoke_run(`echo v1.2 hello`)
    @test ok && occursin("v1.2", text)
    ok, text = P.smoke_run(`false`)
    @test !ok
    ok, text = P.smoke_run(Cmd(["/nonexistent/baysol-xyz"]))
    @test !ok && occursin("cannot start", text)
    if !Sys.iswindows()
        t = @elapsed (r = P.smoke_run(`sleep 5`; timeout = 0.3))
        @test !r[1] && t < 3 && occursin("no answer", r[2])
    end
    mktempdir() do d
        @test_throws Dev.Common.ToolError P.smoke_test(d)       # no program there
    end
end

@testset "the macOS launcher finds its window by a unique title" begin
    text = P.MACOS_LAUNCHER
    @test startswith(text, "#!/bin/zsh")
    @test occursin("name of w contains", text) && !occursin("tty of tab", text)
    @test occursin("baysol-launch-", text)
    # the window is closed by its id, only when it has one tab and the program ended well
    @test occursin("close w saving no", text) && occursin("(count of tabs of w) is 1", text)
    Platform.ismacos() && @test P.launcher()[2] == text
end
