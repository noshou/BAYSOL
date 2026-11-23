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
