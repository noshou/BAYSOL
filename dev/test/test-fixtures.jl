# SPDX-License-Identifier: LGPL-3.0-or-later

# The fixture archives (`bysl fixtures`, dev/src/fixture-store.jl) on a synthetic
# experiments folder: nothing of the real fixtures is touched, no fit runs.

module TFixtures
using Test
using Dev: Platform
using .Main.Helpers
using Dev.Fixtures: FixtureStore as FS

@testset "fixtures: pack, unpack, resolve, clean" begin
    if Platform.which("7z") === nothing
        @test_skip false
    else
        exp = mktempdir()
        tmp = joinpath(mktempdir(), "unpacked")
        for id in ("AAA1", "BBB2")
            mkpath(joinpath(exp, id, "experimental_data"))
            write(joinpath(exp, id, "$(id)_model1.pdb"), "ATOM $id\n")
            write(joinpath(exp, id, "experimental_data", "$id.dat"), "1 2 3\n")
        end
        @test FS.entry_ids(exp) == ["AAA1", "BBB2"]

        # pack: archive next to the folder, entries start with <ID>/, folder untouched
        @test FS.pack("AAA1"; keep_source = true, base = exp) == :packed
        arc = FS.archive_path("AAA1", exp)
        @test isfile(arc)
        @test FS.archive_entries(arc) ==
              ["AAA1/AAA1_model1.pdb", "AAA1/experimental_data/AAA1.dat"]
        @test isfile(joinpath(exp, "AAA1", "AAA1_model1.pdb"))
        @test isempty(filter(contains("partial"), readdir(exp)))
        # fresh archive: skipped unless forced; a newer file makes it stale
        @test FS.pack("AAA1"; keep_source = true, base = exp) == :skipped
        @test FS.pack("AAA1"; keep_source = true, force = true, base = exp) == :packed
        sleep(1.1)
        write(joinpath(exp, "AAA1", "extra.txt"), "new\n")
        @test !FS.archive_fresh("AAA1", exp)
        @test FS.pack("AAA1"; keep_source = true, base = exp) == :packed
        @test "AAA1/extra.txt" in FS.archive_entries(arc)
        @test_throws ErrorException FS.pack("NOPE"; keep_source = true, base = exp)

        # unpack: into the root, reused when complete, redone when the stamp is missing
        dir, now = FS.unpack("AAA1"; root = tmp, base = exp)
        @test now && dir == joinpath(tmp, "AAA1")
        @test read(joinpath(dir, "experimental_data", "AAA1.dat"), String) == "1 2 3\n"
        @test isfile(joinpath(tmp, FS.MARKER))
        @test FS.unpack("AAA1"; root = tmp, base = exp) == (dir, false)
        rm(dir * ".stamp")
        @test FS.unpack("AAA1"; root = tmp, base = exp)[2]
        @test isempty(filter(contains("partial"), readdir(tmp)))

        # resolve: a fresh archive is unpacked; a stale one falls back to the folder;
        # no archive means the folder; neither is an error
        @test FS.resolve("AAA1"; root = tmp, base = exp)[1] == dir
        sleep(1.1)
        write(joinpath(exp, "AAA1", "later.txt"), "x\n")
        @test FS.resolve("AAA1"; root = tmp, base = exp) ==
              (FS.plain_dir("AAA1", exp), false)
        @test FS.resolve("BBB2"; root = tmp, base = exp)[1] ==
              FS.plain_dir("BBB2", exp)
        @test_throws ErrorException FS.resolve("ZZZ"; root = tmp, base = exp)

        # with_fixture: exports the root, removes only what it unpacked itself
        FS.pack("BBB2"; keep_source = true, base = exp)
        seen = FS.with_fixture("BBB2"; root = tmp, base = exp) do d
            @test isdir(d) && d == joinpath(tmp, "BBB2")
            ENV["BAYSOL_FIXTURES"]
        end
        @test seen == tmp
        @test !isdir(joinpath(tmp, "BBB2")) && !isfile(joinpath(tmp, "BBB2.stamp"))
        @test isdir(joinpath(tmp, "AAA1"))   # unpacked before: left alone

        # clean: refuses a folder it did not make, empties its own
        foreign = mktempdir()
        write(joinpath(foreign, "keep.txt"), "mine\n")
        @test_throws ErrorException FS.clean(; root = foreign)
        @test_throws ErrorException FS.unpack("AAA1"; root = foreign, base = exp)
        @test isfile(joinpath(foreign, "keep.txt"))
        stray = joinpath(tmp, "notes.txt")
        write(stray, "not ours\n")
        @test FS.clean(; root = tmp) == 2    # AAA1 and its stamp
        @test isfile(stray) && !isdir(joinpath(tmp, "AAA1"))
        rm(stray)
        @test FS.clean(; root = tmp) == 0
        @test !isdir(tmp)                    # empty root removed with its marker
        @test FS.clean(; root = tmp) == 0
    end
end

@testset "fixtures: sets, flat archives, any root" begin
    @test FS.set_names() == ["experiments", "synthetic"]
    @test FS.set_dir("experiments") == FS.EXPERIMENTS
    @test endswith(FS.set_dir("synthetic"), joinpath("fixtures", "synthetic"))
    @test_throws ErrorException FS.set_dir("nope")
    @test FS.env_var("experiments") == "BAYSOL_FIXTURES"
    @test FS.env_var("synthetic") == "BAYSOL_FIXTURES_SYNTHETIC"
    @test FS.env_var("my-set") == "BAYSOL_FIXTURES_MY_SET"
    withenv("BAYSOL_FIXTURES" => nothing, "BAYSOL_FIXTURES_SYNTHETIC" => nothing) do
        @test FS.tmp_root("experiments") ==
              joinpath(Platform.default_cache(), "fixtures", "experiments")
        @test FS.tmp_root("synthetic") ==
              joinpath(Platform.default_cache(), "fixtures", "synthetic")
    end
    withenv("BAYSOL_FIXTURES_SYNTHETIC" => "/tmp/x-syn") do
        @test FS.tmp_root("synthetic") == normpath("/tmp/x-syn")
    end
    if Platform.which("7z") !== nothing
        base = mktempdir()
        tmp = joinpath(mktempdir(), "unpacked")
        mkpath(joinpath(base, "ITEM", "sub"))
        write(joinpath(base, "ITEM", "a.dat"), "1\n")
        write(joinpath(base, "ITEM", "sub", "b.dat"), "2\n")
        # flat: files at the top of the archive, unpacked into <root>/ITEM/ all the same
        @test FS.pack("ITEM"; keep_source = true, flat = true, base) == :packed
        @test FS.archive_entries(FS.archive_path("ITEM", base)) == ["a.dat", "sub/b.dat"]
        dir, now = FS.unpack("ITEM"; root = tmp, base)
        @test now && read(joinpath(dir, "sub", "b.dat"), String) == "2\n"
        # the same item folder-style
        FS.clean(; root = tmp)
        @test FS.pack("ITEM"; keep_source = true, force = true, base) == :packed
        @test "ITEM/a.dat" in FS.archive_entries(FS.archive_path("ITEM", base))
        @test FS.unpack("ITEM"; root = tmp, base)[2]
        # pack removes the folder after the byte check; --keep-source keeps it
        @test FS.bytes_match("ITEM"; base)
        @test FS.pack("ITEM"; force = true, base) == :packed
        @test !isdir(joinpath(base, "ITEM")) && isfile(FS.archive_path("ITEM", base))
        @test FS.unpack("ITEM"; root = tmp, base)[2]
        @test read(joinpath(tmp, "ITEM", "a.dat"), String) == "1\n"
        # a corrupt archive keeps the folder and fails
        mkpath(joinpath(base, "BAD"))
        write(joinpath(base, "BAD", "x.dat"), "x\n")
        FS.pack("BAD"; keep_source = true, base)
        write(joinpath(base, "BAD", "x.dat"), "y\n")      # folder differs from the archive
        run(`touch -d \@1 $(joinpath(base, "BAD", "x.dat"))`)   # ...but looks older: fresh
        @test !FS.bytes_match("BAD"; base)
        @test_throws ErrorException FS.pack("BAD"; base)   # fresh archive is not enough
        @test isdir(joinpath(base, "BAD"))
        # with_fixture exports the variable of its set
        FS.clean(; root = tmp)
        seen = FS.with_fixture("ITEM"; set = "synthetic", root = tmp, base) do d
            ENV["BAYSOL_FIXTURES_SYNTHETIC"]
        end
        @test seen == tmp
        # the tool on an ad-hoc root, nothing of the real sets touched
        withenv("BAYSOL_FIXTURES_" * uppercase(basename(base)) => tmp) do
            @test run_tool(
                "fixtures",
                "pack",
                "--root",
                base,
                "--force",
                "--keep-source",
            )[1] == 0
            @test run_tool("fixtures", "unpack", "ITEM", "--root", base)[1] == 0
            @test isdir(joinpath(tmp, "ITEM"))
            @test run_tool("fixtures", "list", "--root", base)[1] == 0
            @test run_tool("fixtures", "clean", "--root", base)[1] == 0
            @test !isdir(tmp)
        end
    end
end

@testset "fixtures: command line" begin
    @test run_tool("fixtures", "list")[1] == 0
    @test run_tool("fixtures", "list", "--set", "synthetic")[1] == 0
    @test run_tool("fixtures", "list", "--set", "nope")[1] == 2
    @test run_tool("fixtures", "list", "--set", "synthetic", "--root", ".")[1] == 2
    @test run_tool("fixtures", "pack", "--root", "/no/such/dir")[1] == 2
    @test run_tool("fixtures", "--help")[1] == 0
    @test run_tool("fixtures", "pack", "--help")[1] == 0
    @test run_tool("fixtures", "pack", "--bogus")[1] == 2
    @test run_tool("fixtures", "pack", "NO-SUCH-ID")[1] == 2
    @test run_tool("fixtures", "unpack")[1] == 2
    @test run_tool("fixtures", "unpack", "NO-SUCH-ID")[1] == 2
    @test run_tool("fixtures", "clean", "x")[1] == 2
end

end
