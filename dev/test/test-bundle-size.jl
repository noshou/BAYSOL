# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl pkg size` and the opt-in size reductions (dev/src/pkg-size.jl), on canned
# temp trees; nothing here needs a build.

using Test
using Dev
using Dev: Platform

const P = Dev.PkgTool

# a small bundle: the three executables, the runtime, frozen tools, a depot package
function make_bundle(dir)
    put(rel, n = 5000; fill = 'x') = begin
        path = joinpath(dir, rel)
        mkpath(dirname(path))
        write(path, repeat(string(fill), n))
        path
    end
    put(P.exe("baysol"), 9000; fill = 'b')
    put(P.exe("baysol-tui"), 8000; fill = 't')
    put("lib/pytools/" * P.exe("baysol-pytools"), 7000; fill = 'p')
    put("lib/pytools/numpy/core.so", 20000; fill = 'n')
    put("lib/pytools/numpy/tests/test_core.py", 3000)
    put("lib/pytools/numpy/__pycache__/core.pyc", 100)
    put("lib/pytools/numpy/core.pyi", 100)
    put("lib/pytools/numpy-1.dist-info/RECORD", 100)
    put("lib/pytools/numpy-1.dist-info/METADATA", 100)
    put("lib/pytools/numpy-1.dist-info/LICENSE.txt", 100)
    put("julia/libLLVM.so.18", 30000; fill = 'l')
    put("julia/libA.so", 6000; fill = 'a')
    put("julia/julia/libA.so", 6000; fill = 'a')         # identical copy
    put("julia/libB.so", 6000; fill = 'b')
    put("julia/julia/libB.so", 6000; fill = 'c')         # same name, other content
    put("julia/tiny.so", 10; fill = 'z')
    put("julia/julia/tiny.so", 10; fill = 'z')           # too small to link
    put("share/julia/artifacts/" * "a"^40 * "/README", 50)
    put("share/julia/artifacts/" * "b"^40 * "/lib.so", 500)
    pkg = "share/julia/packages/Foo/abc"
    put(pkg * "/Project.toml", 50)
    put(pkg * "/Artifacts.toml", 10)
    write(joinpath(dir, pkg, "Artifacts.toml"),
        "[Foo_jll]\ngit-tree-sha1 = \"" * "a"^40 * "\"\n")
    put(pkg * "/src/Foo.jl", 60)
    put(pkg * "/src/README.md", 60)
    put(pkg * "/test/runtests.jl", 60)
    put(pkg * "/docs/make.jl", 60)
    put(pkg * "/README.md", 60)
    put(pkg * "/deps/build.jl", 60)
    put(pkg * "/deps/deps.jl", 60)
    put(pkg * "/deps/lib.c", 60)
    put("LICENSE", 100)
    return dir
end

relset(dir) = Set(first.(P.bundle_files(dir)))

@testset "the size report walks a bundle" begin
    mktempdir() do dir
        make_bundle(dir)
        r = P.size_report(dir)
        @test r.total == sum(last.(P.bundle_files(dir)))
        comps = Dict(r.components)
        @test comps["libLLVM"] == 30000
        @test haskey(comps, "Python tools (lib/pytools)")
        @test comps["baysol (Julia code, compiled in)"] == 9000
        @test comps["Node and TUI (baysol-tui)"] == 8000
        @test sum(last.(r.components)) == r.total
        @test sum(last.(r.kinds)) == r.total
        @test Dict(r.kinds)["shared library"] > 0
        @test first(r.largest[1]) == "julia/libLLVM.so.18"
        @test length(r.largest) <= 30
        @test Dict(r.python)["numpy"] > 0
        @test Dict(r.packages) == Dict(
            "Foo" => sum(
                last.(
                    filter(
                        f -> startswith(first(f), "share/julia/packages/Foo"),
                        P.bundle_files(dir)),
                ),
            ),
        )
        ex = Dict(r.extras)
        @test ex["test and tests folders"] > 0
        @test ex["docs folders"] == 60
        @test ex["*.md files"] == 120
        @test ex["licence files"] == 200
        # the artifact `a...` is named by an Artifacts.toml, `b...` is a candidate
        @test r.judged
        @test first.(r.unreferenced) == ["b"^40]
        @test any(startswith("artifacts/" * "a"^40), first.(r.artifacts))
        @test any(contains("Foo_jll"), first.(r.artifacts))
        @test r.archive === nothing
        arch = joinpath(dir, "x.zip")
        write(arch, "12345")
        @test P.size_report(dir; archive = arch).archive == 5
        lines = P.format_size_report(r)
        @test any(contains("libLLVM"), lines)
        @test_throws Dev.Common.ToolError P.size_report(joinpath(dir, "nothing"))
    end
end

@testset "the artifacts are not judged without an Artifacts.toml" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "share", "julia", "artifacts", "c"^40))
        write(joinpath(dir, "share", "julia", "artifacts", "c"^40, "README"), "x")
        r = P.size_report(dir)
        @test !r.judged && isempty(r.unreferenced)
    end
end

@testset "duplicate grouping" begin
    mktempdir() do dir
        make_bundle(dir)
        d = P.size_duplicates(dir, P.bundle_files(dir))
        @test [x.name for x in d.identical] == ["libA.so"]
        @test d.identical[1].wasted == 6000 && d.identical[1].copies == 2
        @test [x.name for x in d.differing] == ["libB.so"]
        @test d.differing[1].variants == 2
        # files below the minimum are not listed
        @test !any(x -> x.name == "tiny.so", d.identical)
        # the copies of libB are not identical
        @test !any(x -> x.name == "libB.so", d.identical)
    end
end

@testset "the log rows of a report parse back" begin
    mktempdir() do dir
        make_bundle(dir)
        r = P.size_report(dir)
        lines = ["$(x.group)\t$(x.name)\t$(x.bytes)" for x in P.size_log_rows(r)]
        rows = filter(!isnothing, P.parse_size_row.(lines))
        @test length(rows) == length(lines)
        @test first(rows) == P.SizeRow("total", "bundle", r.total)
        @test any(x -> x.group == "duplicateIdentical" && x.bytes == 6000, rows)
        @test P.parse_size_row("junk") === nothing
        @test P.parse_size_row("a\tb\tnotanumber") === nothing
        # a build log with the block, the header rows and an old one without
        text =
            "datetime\tx\nbundleBytes\t$(r.total)\narchiveBytes\t100\n" *
            "dedupe\toff\n\n--- stages ---\nstage x ok   1.0 s\n\n--- size ---\n" *
            join(lines, "\n") * "\n\n--- machine ---\ncpu\tc\n"
        b = P.parse_build_log(text)
        @test length(b.size) == length(lines)
        @test b.rows["bundleBytes"] == string(r.total) && b.rows["cpu"] == "c"
        @test any(contains("bundle"), P.format_build_log(b))
        old = P.parse_build_log("datetime\tx\n--- stages ---\nstage x ok   1.0 s\n")
        @test isempty(old.size)
        @test !any(startswith("size"), P.format_build_log(old))
    end
end

@testset "reduction switches" begin
    @test P.reduction_mode("BAYSOL_X", ("off", "on"); env = Dict{String,String}()) == "off"
    @test P.reduction_mode("BAYSOL_X", ("off", "on"); env = Dict("BAYSOL_X" => "ON")) ==
          "on"
    @test_throws Dev.Common.ToolError P.reduction_mode(
        "BAYSOL_X", ("off", "on"); env = Dict("BAYSOL_X" => "yes"))
end

@testset "glob and prune list" begin
    rx(g) = P.glob_regex(g)
    @test occursin(rx("**/tests/")[1], "a/b/tests") && rx("**/tests/")[2]
    @test occursin(rx("**/tests/")[1], "tests")
    @test !occursin(rx("**/tests/")[1], "a/mytests")
    @test occursin(rx("**/*.pyi")[1], "a/b.pyi") && !occursin(rx("**/*.pyi")[1], "a/b.py")
    @test occursin(rx("**/*.dist-info/RECORD")[1], "x-1.dist-info/RECORD")
    globs = P.load_prune_globs(P.PY_PRUNE_FILE)
    @test "**/__pycache__/" in globs && !any(contains("LICENSE"), globs)
    mktempdir() do dir
        f = joinpath(dir, "list.txt")
        write(f, "# c\n\n**/x/   # why\n")
        @test P.load_prune_globs(f) == ["**/x/"]
        write(f, "**/x/\n")
        @test_throws Dev.Common.ToolError P.load_prune_globs(f)
    end
end

@testset "python prune" begin
    mktempdir() do dir
        make_bundle(dir)
        tools = joinpath(dir, "lib", "pytools")
        globs = P.load_prune_globs(P.PY_PRUNE_FILE)
        before = relset(dir)
        dry = P.prune_python(tools; globs, dry = true)
        @test relset(dir) == before                     # a dry run changes nothing
        @test dry.freed == 3000 + 100 + 100 + 100
        r = P.prune_python(tools; globs)
        @test sort(r.removed) == sort(dry.removed) && r.freed == dry.freed
        after = relset(dir)
        @test "lib/pytools/numpy/core.so" in after
        @test "lib/pytools/numpy-1.dist-info/METADATA" in after
        @test "lib/pytools/numpy-1.dist-info/LICENSE.txt" in after
        @test !("lib/pytools/numpy/tests/test_core.py" in after)
        @test !("lib/pytools/numpy-1.dist-info/RECORD" in after)
        @test !("lib/pytools/numpy/core.pyi" in after)
        @test !isdir(joinpath(tools, "numpy", "__pycache__"))
        @test P.prune_python(joinpath(dir, "nothing"); globs).removed == String[]
    end
end

@testset "julia prune" begin
    mktempdir() do dir
        make_bundle(dir)
        depot = joinpath(dir, "share", "julia")
        before = relset(dir)
        dry = P.prune_julia(depot; dry = true)
        @test relset(dir) == before
        r = P.prune_julia(depot)
        @test sort(r.removed) == sort(dry.removed) && r.freed == dry.freed
        pkg = "share/julia/packages/Foo/abc"
        after = relset(dir)
        for keep in ("/Project.toml", "/Artifacts.toml", "/src/Foo.jl", "/src/README.md",
            "/deps/deps.jl")
            @test pkg * keep in after
        end
        for gone in ("/test/runtests.jl", "/docs/make.jl", "/README.md", "/deps/build.jl",
            "/deps/lib.c")
            @test !(pkg * gone in after)
        end
        @test "share/julia/artifacts/" * "b"^40 * "/lib.so" in after   # artifacts stay
        @test r.freed == 60 * 5
    end
end

@testset "dedupe by relative symlinks" begin
    mktempdir() do dir
        make_bundle(dir)
        exes = [joinpath(dir, P.exe("baysol"))]
        before = relset(dir)
        dry = P.dedupe_identical(dir; dry = true, os = :linux, exes)
        @test dry.mode === :dry && relset(dir) == before
        @test dry.items == ["julia/julia/libA.so" => "julia/libA.so"]
        @test dry.freed == 6000
        r = P.dedupe_identical(dir; os = :linux, exes)
        @test r.mode === :linked && r.items == dry.items
        if !Platform.iswindows()
            link = joinpath(dir, "julia", "julia", "libA.so")
            @test islink(link)
            @test readlink(link) == joinpath("..", "libA.so")
            @test read(link, String) == read(joinpath(dir, "julia", "libA.so"), String)
            # the other files are untouched
            @test !islink(joinpath(dir, "julia", "julia", "libB.so"))
            @test !islink(joinpath(dir, "julia", "julia", "tiny.so"))
            @test !islink(joinpath(dir, P.exe("baysol")))
            # run again: nothing left to link
            @test isempty(P.dedupe_identical(dir; os = :linux, exes).items)
        end
    end
    # Windows: only a report, never a link
    mktempdir() do dir
        make_bundle(dir)
        r = P.dedupe_identical(dir; os = :windows)
        @test r.mode === :report && length(r.items) == 1
        @test !any(islink, joinpath.(dir, first.(r.items)))
    end
    # macOS: a .app folder and a library with another install name are left alone
    mktempdir() do dir
        make_bundle(dir)
        for sub in ("A.app/Contents/libC.dylib", "libC.dylib", "sub/libC.dylib")
            path = joinpath(dir, sub)
            mkpath(dirname(path))
            write(path, repeat("c", 5000))
        end
        id(path) =
            endswith(path, joinpath("sub", "libC.dylib")) ? "@rpath/libOther.dylib" :
            "@rpath/libC.dylib"
        r = P.dedupe_identical(dir; dry = true, os = :macos, installname = id)
        @test "A.app/Contents/libC.dylib" in first.(r.skipped)
        @test "sub/libC.dylib" in first.(r.skipped)
        @test !any(p -> first(p) == "libC.dylib" || startswith(first(p), "A.app"), r.items)
    end
end

@testset "the orchestrators log a row each" begin
    mktempdir() do dir
        make_bundle(dir)
        env = Dict{String,String}()
        @test Dict(P.reduce_prune(dir; env)) ==
              Dict("pyPrune" => "off", "juliaPrune" => "off")
        @test P.reduce_dedupe(dir; env) == ["dedupe" => "off"]
        before = relset(dir)
        rows = Dict(P.reduce_prune(dir; env = Dict("BAYSOL_PY_PRUNE" => "on"), dry = true))
        @test startswith(rows["pyPrune"], "dry run: would remove") && relset(dir) == before
        rows = Dict(P.reduce_prune(dir; env = Dict("BAYSOL_PY_PRUNE" => "on")))
        @test startswith(rows["pyPrune"], "on: removed") && rows["juliaPrune"] == "off"
        row =
            P.reduce_dedupe(dir; env = Dict("BAYSOL_DEDUPE" => "identical"), os = :windows)
        @test contains(row[1][2], "report only")
        @test_throws Dev.Common.ToolError P.reduce_dedupe(dir;
            env = Dict("BAYSOL_DEDUPE" => "all"))
    end
end

@testset "the build log header carries the sizes" begin
    empty!(P.SIZE_ROWS)
    P.SIZE_REPORT[] = nothing
    rows = Dict(P.size_header_rows("/no/archive.zip"))
    @test rows["bundleBytes"] == "unknown" && rows["dedupe"] == "unknown"
    @test !haskey(rows, "archiveBytes") && isempty(P.size_block_lines("/no/archive.zip"))
    mktempdir() do dir
        make_bundle(dir)
        P.SIZE_REPORT[] = P.size_report(dir)
        push!(P.SIZE_ROWS, "dedupe" => "off", "pyPrune" => "off", "juliaPrune" => "off")
        arch = joinpath(dir, "a.zip")
        write(arch, "1234")
        rows = Dict(P.size_header_rows(arch))
        @test rows["bundleBytes"] == string(P.SIZE_REPORT[].total)
        @test rows["archiveBytes"] == "4" && rows["dedupe"] == "off"
        lines = P.size_block_lines(arch)
        @test lines[2] == "--- size ---" && any(startswith("archive\tcompressed\t4"), lines)
        @test !P.reductions_active()
        push!(P.SIZE_ROWS, "dedupe" => "identical, linked 1 files")
        @test P.reductions_active()
    end
    empty!(P.SIZE_ROWS)
    P.SIZE_REPORT[] = nothing
end
