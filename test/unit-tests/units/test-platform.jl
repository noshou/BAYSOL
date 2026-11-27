# SPDX-License-Identifier: LGPL-3.0-or-later

# The operating-system module (platform.jl, the one place that detects the system): the
# predicates agree with each other, and the helpers give what their system uses.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL: Platform

@testset "Platform" begin
    @testset "detection" begin
        @test count((Platform.iswindows(), Platform.ismacos(), Platform.islinux())) <= 1
        @test Platform.isunix() == !Platform.iswindows()
        @test Platform.os() in (:windows, :macos, :linux, :other)
        @test (Platform.os() === :windows) == Platform.iswindows()
        @test Platform.arch() isa Symbol
        @test occursin(string(Platform.arch()), Platform.describe()) ||
              !isempty(Platform.describe())
    end

    @testset "names and separators" begin
        @test Platform.exe("tool") == (Platform.iswindows() ? "tool.exe" : "tool")
        @test Platform.PATH_SEP == (Platform.iswindows() ? ';' : ':')
        @test '/' in Platform.DIR_SEPARATORS
        @test ('\\' in Platform.DIR_SEPARATORS) == Platform.iswindows()
        @test Platform.library_path_variable() in
              ("PATH", "DYLD_FALLBACK_LIBRARY_PATH", "LD_LIBRARY_PATH")
    end

    @testset "which" begin
        bindir = Sys.BINDIR
        withenv("PATH" => bindir * Platform.PATH_SEP * get(ENV, "PATH", "")) do
            found = Platform.which("julia")
            @test found !== nothing
            @test isabspath(found)
        end
        @test Platform.which("no-such-program-baysol-xyz") === nothing
    end

    @testset "folders" begin
        home = abspath("some-home")
        abs1 = abspath("abs-folder")
        env = Dict("LOCALAPPDATA" => abs1, "APPDATA" => abs1, "XDG_DATA_HOME" => abs1,
            "XDG_CACHE_HOME" => abs1, "XDG_CONFIG_HOME" => abs1, "SHELL" => abs1,
            "COMSPEC" => abs1, "XDG_RUNTIME_DIR" => abs1, "TMPDIR" => abs1)
        if Platform.ismacos()
            @test Platform.data_home(; env, home) ==
                  joinpath(home, "Library", "Application Support")
            @test Platform.cache_home(; env, home) == joinpath(home, "Library", "Caches")
        else
            @test Platform.data_home(; env, home) == abs1
            @test Platform.cache_home(; env, home) == abs1
            @test Platform.config_home(; env, home) == abs1
        end
        @test Platform.shell(; env) == abs1
        # a relative value counts as unset
        rel = Dict("XDG_DATA_HOME" => "rel", "LOCALAPPDATA" => "rel", "SHELL" => "sh",
            "COMSPEC" => "cmd")
        if !Platform.ismacos()
            @test Platform.data_home(; env = rel, home) ==
                  (
                Platform.iswindows() ? joinpath(home, "AppData", "Local") :
                joinpath(home, ".local", "share")
            )
        end
        @test Platform.shell(; env = rel) == (Platform.iswindows() ? "cmd.exe" : "/bin/sh")
        @test !isempty(Platform.user_id())
    end

    # The same table is pinned by tui/test/platform.test.ts (`cacheFolder` and friends):
    # change both together, or the two implementations have drifted.
    @testset "the caches folder, one default" begin
        slashes(p) = replace(p, "\\" => "/")
        cases = [
            (:windows, Dict{String,String}(), "/h/u/AppData/Local/baysol-cache"),
            (:windows, Dict("LOCALAPPDATA" => "/d/local"), "/d/local/baysol-cache"),
            (:windows, Dict("LOCALAPPDATA" => "rel"), "/h/u/AppData/Local/baysol-cache"),
            (:macos, Dict{String,String}(), "/h/u/Library/Caches/baysol"),
            (:linux, Dict{String,String}(), "/h/u/.cache/baysol"),
            (:linux, Dict("XDG_CACHE_HOME" => "/x/cache"), "/x/cache/baysol"),
            (:linux, Dict("XDG_CACHE_HOME" => "/x/data", "XDG_DATA_HOME" => "/x/data"),
                "/x/data/baysol-cache"),
        ]
        for (system, env, folder) in cases
            kw = (; env, home = "/h/u", system)
            @test slashes(Platform.cache_dir(; kw...)) == folder
            @test slashes(Platform.default_cache(; kw...)) == "$folder/_cache"
            @test slashes(Platform.default_structure_cache(; kw...)) ==
                  "$folder/_structures"
            @test slashes(Platform.structure_cache(; kw...)) == "$folder/_structures"
        end
        kw = (; home = "/h/u", system = :linux)
        @test Platform.structure_cache(; env = Dict("BAYSOL_CACHE" => "/b/c"), kw...) ==
              "/b/c"
        @test slashes(
            Platform.structure_cache(; env = Dict("BAYSOL_CACHE" => "rel"), kw...),
        ) ==
              "/h/u/.cache/baysol/_structures"
        @test slashes(
            Platform.default_cache(; env = Dict("BAYSOL_CACHE" => "/b/c"), kw...),
        ) ==
              "/h/u/.cache/baysol/_cache"
        @test Platform.within("/a/b", "/a") && Platform.within("/a", "/a")
        @test !Platform.within("/ab", "/a")
    end

    # The same names are pinned by tui/test/platform.test.ts (`tmpFolder`).
    @testset "the temporary root, one folder" begin
        slashes(p) = replace(p, "\\" => "/")
        @test slashes(Platform.tmp_dir(; base = "/t")) == "/t/baysol"
        @test slashes(Platform.tmp_process_dir(4242; base = "/t")) == "/t/baysol/4242"
        @test slashes(Platform.tmp_dir(; base = "/var/folders/x/T")) ==
              "/var/folders/x/T/baysol"
        @test Platform.tmp_dir() == joinpath(tempdir(), "baysol")
        @test basename(Platform.tmp_process_dir()) == string(getpid())
    end

    @testset "which and find_tool" begin
        dir = mktempdir()
        script(name, body = "") = (
            f = joinpath(dir, name);
            write(f, body);
            chmod(f, 0o755);
            f
        )
        # Windows: the `.cmd` beside an extensionless shell script is the one found
        # (the script cannot be started; this is `npm` and `npm.cmd`)
        if Platform.iswindows()
            script(
                "npmx",
                "#!/bin/sh
",
            )
            cmd = script(
                "npmx.cmd",
                "@exit /b 0
",
            )
            withenv("PATH" => dir) do
                @test Platform.which("npmx") == cmd
                @test Platform.which("NPMX") == cmd
                @test Platform.which("npmx.cmd") == cmd
            end
        end
        # find_tool: the PATH first, then the folders installers use
        tool = script(
            Platform.exe("baysol-fake-tool"),
            "#!/bin/sh
exit 0
",
        )
        withenv("PATH" => "") do
            @test Platform.which("baysol-fake-tool") === nothing
            @test Platform.find_tool("baysol-fake-tool"; dirs = String[]) === nothing
            @test Platform.find_tool("baysol-fake-tool"; dirs = [dir]) == tool
            @test Platform.find_tool("nope-1", "baysol-fake-tool"; dirs = [dir]) == tool
        end
        withenv("PATH" => dir) do
            other = mktempdir()
            write(joinpath(other, Platform.exe("baysol-fake-tool")), "")
            @test Platform.find_tool("baysol-fake-tool"; dirs = [other]) ==
                  Platform.which("baysol-fake-tool")
        end
        @test all(isdir, Platform.tool_dirs())
        Platform.iswindows() || Platform.ismacos() || @test isempty(Platform.tool_dirs())
    end
end

@testset "free_memory: between the free pages and the total" begin
    free = Platform.free_memory()
    @test free isa Int && 0 < free <= Sys.total_memory()
    # macOS: the kernel answers, with more than the empty pages (a quarter less for drift)
    Platform.ismacos() && @test Platform._mac_available_memory() > 0.75 * Sys.free_memory()
    @test (Platform._mac_available_memory() === nothing) == !Platform.ismacos()
end

@testset "utc_offset: the zone's offset as a number, on every system" begin
    t = 1.7e9
    off = Platform.utc_offset(t)
    @test off isa Int && abs(off) <= 14 * 3600 && off % 60 == 0
    text = Platform.utc_offset_text(t)
    @test occursin(r"^[+-]\d{4}$", text)
    @test (text[1] == '-') == (off < 0)
    @test parse(Int, text[2:3]) * 3600 + parse(Int, text[4:5]) * 60 == abs(off)
    # two instants a half year apart can differ by the daylight-saving hour, no more
    @test abs(Platform.utc_offset(t) - Platform.utc_offset(t + 182 * 86400)) <= 3600
    # the stamp the logs use ends with that offset, never with a zone name
    @test occursin(r"[+-]\d{4}$", BAYSOL.Pipeline._logStamp())
end
