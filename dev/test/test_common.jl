# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of Common (the git helpers, the fitting-test lookups, the command line splitting,
# the number formatting) and of the cache.

using Test

# --- Common

module TCommon
using Test
using Dev.Common
using .Main.Helpers

# A throwaway git repository with commits of increasing dates, `tags_at` being `(date,
# [tag ...])` pairs, one commit each, with the tags on them.
function make_repo(dir, tags_at)
    mkpath(dir)
    git(env, args...) = run(
        pipeline(
            setenv(
                `git -C $dir -c user.name=t -c user.email=t@example.com $(collect(args))`,
                merge(ENV, Dict(env))); stdout = devnull, stderr = devnull),
    )
    git(Dict(), "init", "-q")
    for (n, (date, tags)) in enumerate(tags_at)
        write_file(joinpath(dir, "f$(n - 1).txt"), string(n - 1))
        git(Dict(), "add", ".")
        git(Dict("GIT_COMMITTER_DATE" => date, "GIT_AUTHOR_DATE" => date), "commit",
            "-q", "-m", "c$(n - 1)")
        foreach(t -> git(Dict(), "tag", t), tags)
    end
end

@testset "latest release" begin
    scratch = scratch_dir()
    make_repo(
        joinpath(scratch, "r1"),
        [
            ("2020-01-01T00:00:00", ["v0.1.0-a"]),
            ("2021-01-01T00:00:00", ["v0.2.0-b"]),
            ("2022-01-01T00:00:00", ["nightly", "vnext"]),
        ],
    )
    Common.ROOT_OVERRIDE[] = joinpath(scratch, "r1")
    try
        @testset "the newest tag that looks like a release, not the newest tag" begin
            @test latest_release() == "v0.2.0-b"
            @test length(resolve_rev("v0.1.0-a")) == 40
            @test resolve_rev("no-such-rev") === nothing
        end
        make_repo(joinpath(scratch, "r2"), [("2020-01-01T00:00:00", ["nightly"])])
        Common.ROOT_OVERRIDE[] = joinpath(scratch, "r2")
        @testset "no v<digit> tag means no release" begin
            @test latest_release() === nothing
        end
    finally
        Common.ROOT_OVERRIDE[] = nothing
    end
end

@testset "baseline_for" begin
    scratch = scratch_dir()
    for f in ["v1.0.0-x-cold-hostA", "v1.0.0-x-cold-hostB", "v2.0.0-y-cold-hostA"]
        write_file(joinpath(scratch, "root", "test", "baselines", f * ".json"), "")
    end
    Common.ROOT_OVERRIDE[] = joinpath(scratch, "root")
    try
        name(p) = p === nothing ? nothing : basename(p)
        @test [name(baseline_for("v1.0.0-x")), name(baseline_for("v2.0.0-y")),
            baseline_for("v9.9.9")] ==
              ["v1.0.0-x-cold-hostB.json", "v2.0.0-y-cold-hostA.json", nothing]
    finally
        Common.ROOT_OVERRIDE[] = nothing
    end
end

@testset "single run" begin
    @test single_run.([[""], ["a"], ["a", "b"], String[]]) == [true, false, false, false]
end

@testset "fitting-test lookups" begin
    @test length(ids()) ==
          count(n -> startswith(n, "SASD") && isdir(joinpath(repo_dir, FIT_DIR, n)),
        readdir(joinpath(repo_dir, FIT_DIR)))
    @test tags_of("SASDBS6") ==
          ["fit2_model1", "fit2_model2", "fit2_model3", "fit2_model4", "fit2_model5"]
    @test tags_of("SASDMJ9") == [""]
    @test tags_of("SASDMZ9") == ["model1", "model2", "model3"]
    @test tags_of("SASDJ72") == ["model1", "model2"]
    @test basename.(script_of.(["SASDMJ9", "SASDA52"])) ==
          ["SASDMJ9.jl", "SASDA52_fit1.jl"]
    @test specs_of(["SASDMJ9", "SASDJ72"]) ==
          ["SASDMJ9", "SASDJ72:model1", "SASDJ72:model2"]
end

@testset "take_threads" begin
    @test take_threads(["SASDMJ9", "--threads", "4,1", "--report"]) ==
          (["SASDMJ9", "--report"], Dict("JULIA_NUM_THREADS" => "4,1"))
    @test take_threads(["SASDMJ9", "--report"]) ==
          (["SASDMJ9", "--report"], Dict{String,String}())
    err = try
        take_threads(["--threads"])
    catch e
        e
    end
    @test err isa ToolError &&
          occursin("--threads needs a value (e.g. 4, auto, 4,1)", err.message)
end

@testset "split_args" begin
    r = split_args("t", ["--out", "--n"], ["--dry-run"],
        ["A", "--out", "x", "--dry-run", "B:c", "--n", "3"])
    @test r.opts == ["--out" => "x", "--n" => "3"]
    @test r.flags == ["--dry-run"]
    @test r.specs == ["A", "B:c"]
    for args in (["--bad"], ["--out"])
        err = try
            split_args("t.clj", ["--out"], String[], args)
        catch e
            e
        end
        @test err isa ToolError && err.status == 2 && startswith(err.message, "t.clj: ")
    end
end

@testset "formatting" begin
    @testset "C-style conversions on the exact value of the double" begin
        @test [fmt("%.1f", 0.15), fmt("%.2f", "0.15"), fmt("%.2f", -0.001),
            fmt("%+.2f", 1.5), fmt("%.3g", 21.485), fmt("%.3g", 100000.0),
            fmt("%.3g", 0.0012345), fmt("%.3g", 100.2), fmt("%d", "7")] ==
              ["0.1", "0.15", "-0.00", "+1.50", "21.5", "1e+05", "0.00123", "100", "7"]
    end
    @test as_number.(["3.20", "+0.33", "+7", "true", ""]) == [3.2, 0.33, 7, "true", ""]
    @test [num_str(12170.0), num_str(0.0002), num_str(6.75346e-7), num_str(1.5)] ==
          ["12170.0", "0.0002", "6.75346e-7", "1.5"]
    @test [num_str(1e-5), num_str(1e16), num_str(-0.5), num_str(100.0)] ==
          ["1e-5", "10000000000000000.0", "-0.5", "100.0"]
end

end

# --- rm_tree

module TRmTree

using Test
using Dev.Common
using .Main.Helpers

@testset "removes the tree, unlinks a symlink, leaves its target alone" begin
    scratch = scratch_dir()
    write_file(joinpath(scratch, "target", "sub", "sentinel.txt"), "keep")
    d = joinpath(scratch, "baysol-bench-x")
    mkpath(joinpath(d, "inner", ".hiddendir"))
    write_file(joinpath(d, "inner", "f.txt"), "x")
    write_file(joinpath(d, ".dotfile"), "x")
    symlink(joinpath(scratch, "target"), joinpath(d, "link"))
    rm_tree(d)
    @test !ispath(d)
    @test isfile(joinpath(scratch, "target", "sub", "sentinel.txt"))
end

@testset "a directory not named baysol-bench-* is never removed" begin
    scratch = scratch_dir()
    mkpath(joinpath(scratch, "target"))
    err = try
        rm_tree(joinpath(scratch, "target"))
    catch e
        e
    end
    @test err isa ToolError && occursin("refusing to delete", err.message)
    @test isdir(joinpath(scratch, "target"))
end

end

# --- Cache

module TCache

using Test
using Dev.Common
using .Main.Helpers

# A throwaway cache folder as BAYSOL_CACHE, with some files in it before a program runs.
function with_cache(f)
    dir = scratch_dir()
    withenv("BAYSOL_CACHE" => joinpath(dir, "_cache")) do
        write_file(joinpath(dir, "_cache", "old.pka"), "was there before")
        f(joinpath(dir, "_cache"))
    end
end

@testset "the cache is the operating system's, never the repository's" begin
    withenv("BAYSOL_CACHE" => nothing, "XDG_CACHE_HOME" => "/xdg/cache") do
        Sys.islinux() && @test cache_root() == "/xdg/cache/baysol/_cache"
    end
    withenv("BAYSOL_CACHE" => "relative/dir") do
        @test !startswith(cache_root(), joinpath(repo_dir, "_cache"))
    end
end

@testset "what a program creates is cleared, structures and components are kept" begin
    with_cache() do root
        track_cache() do
            write_file(joinpath(root, "1ABC.pdb"), "downloaded")
            write_file(joinpath(root, "1ABC_pH7.4.pka"), "derived")
            write_file(joinpath(root, "x", "y", "protonated.balance"), "derived")
            write_file(joinpath(root, "components", "ALA.cif"), "component")
            write_file(joinpath(root, "2XYZ.CIF"), "downloaded")
        end
        @test sort(manifest_entries()) == ["1ABC_pH7.4.pka", "x/y/protonated.balance"]
        @test clear_cache!() == 2
        @test !isfile(joinpath(root, "1ABC_pH7.4.pka"))
        @test !isdir(joinpath(root, "x"))              # the folder it left empty goes too
        @test isfile(joinpath(root, "1ABC.pdb"))
        @test isfile(joinpath(root, "components", "ALA.cif"))
        @test isfile(joinpath(root, "2XYZ.CIF"))
        @test isfile(joinpath(root, "old.pka"))        # it was there before: not ours
        @test isempty(manifest_entries())
    end
end

@testset "only paths inside the cache are touched" begin
    with_cache() do root
        outside = write_file(joinpath(dirname(root), "outside.txt"), "keep")
        mkpath(dirname(Common.cache_manifest()))
        write(Common.cache_manifest(), "../outside.txt\n/etc/passwd\n")
        @test clear_cache!() == 0
        @test isfile(outside)
    end
end

@testset "a program started by the tools gets the cache folder" begin
    with_cache() do root
        cmd = Common.to_cmd(["julia", "-e", "1"])
        @test cmd.env !== nothing && "BAYSOL_CACHE=$root" in cmd.env
    end
end

end
