# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl pkg`: the parts that need no build (the archive name, the swap watch, the
# merge of the traced statements, the guards of the scratch folder, the plan).

using Test
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
    value, peak = P.watch_memory(() -> 42; period = 0.05)
    @test value == 42
    Sys.islinux() && @test peak.ram > 0 && peak.swap >= 0
    Sys.islinux() && @test P.tree_memory()[1] > 0
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
        @test filesize(dest) > 1000
    end
    @test startswith(text, Sys.iswindows() ? "@echo off" : "#!")
end

@testset "the embedded Python entry is valid and complete" begin
    @test occursin("def main() -> int:", P.PYTOOLS_ENTRY)
    @test occursin("m.REPAIR_LIMIT = float(\"inf\")", P.PYTOOLS_ENTRY)
    if Sys.which("python3") !== nothing
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
        icns = P.icns_bytes(sizes)                                # standard types only
        @test icns[1:4] == codeunits("icns") &&
              Int(ntoh(only(reinterpret(UInt32, icns[5:8])))) == length(icns)
        @test !occursin("ix22", String(copy(icns)))
        @test occursin("ix22", String(P.icns_bytes(sizes; extra = true)))
        ico = P.ico_bytes(sizes)
        # 4 entries: 1024 is left out
        @test ico[1:6] == UInt8[0, 0, 1, 0, 4, 0]
        @test ico[6+16*3+1] == 0                            # the 256 entry's side byte
        write(joinpath(dir, "icon_64x64.png"), png(32))           # name and header disagree
        @test_throws ErrorException P.icon_sizes(dir)
        @test isempty(P.icon_sizes(joinpath(dir, "nowhere")))
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
        @test isfile(joinpath(d, "libjulia.so.1.12")) || !Sys.islinux()
        if Sys.islinux()
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
        @test isfile(joinpath(out, "julia", "julia", "libA.so"))
        @test isdir(joinpath(out, "share", "julia", "artifacts", "b"^40))
    end
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
        Sys.iswindows() || symlink("libx.so", joinpath(dir, "liblink.so"))
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
