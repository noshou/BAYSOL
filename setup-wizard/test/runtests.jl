# SPDX-License-Identifier: LGPL-3.0-or-later

using Test
using BAYSOLSetup
using BAYSOLSetup: targets, defaultThreads, desktopDir, desktopEntry, _pinned, _unpinned,
    iconPngs, iconFiles, hicolorDir, ICON_FILE

# a stand-in PNG (signature and header only) of px x px pixels
function fakePng(px)
    be(n) = collect(reinterpret(UInt8, [hton(UInt32(n))]))
    return vcat(UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], be(13),
        codeunits("IHDR"), be(px), be(px), zeros(UInt8, 5))
end

# an `.icns` of stand-in PNGs, the way `bysl pkg` writes one
function fakeIcns(file, sizes)
    be(n) = collect(reinterpret(UInt8, [hton(UInt32(n))]))
    body = UInt8[]
    for (type, px) in sizes
        png = fakePng(px)
        append!(body, codeunits(type), be(8 + length(png)), png)
    end
    return write(file, vcat(codeunits("icns"), be(8 + length(body)), body))
end

# every path goes into a temporary folder: no test touches the real home
@testset "BAYSOLSetup" begin
    home = mktempdir()
    env = Dict(
        "XDG_DATA_HOME" => joinpath(home, "d"),
        "XDG_CACHE_HOME" => joinpath(home, "c"),
        "XDG_CONFIG_HOME" => joinpath(home, "cfg"),
    )
    @testset "defaults follow XDG, a relative XDG value is ignored" begin
        d = defaultInstall(; env, home)
        @test d.home == joinpath(home, "d", "baysol")
        @test d.cache == joinpath(home, "c", "baysol", "_cache")
        @test installFile(; env, home) == joinpath(home, "cfg", "baysol", "install.json")
        rel = Dict("XDG_DATA_HOME" => "relative/path")
        stock = joinpath(home, ".local", "share", "baysol")
        @test defaultInstall(; env = rel, home).home == stock
    end
    @testset "install.json round trip, odd characters, damaged file" begin
        f = joinpath(home, "x", "install.json")
        i = Install(; home = "/a \"b\"/c\\d", cache = "/k", structureCache = "/s",
            desktop = true)
        writeInstall(f, i)
        @test readInstall(f) == i
        @test !isfile(f * ".tmp")
        write(f, "{ not json")
        @test readInstall(f) === nothing
        @test readInstall(joinpath(home, "none.json")) === nothing
    end
    bundle = mkpath(joinpath(home, "bundle"))
    write(joinpath(bundle, "baysol"), "#!/bin/sh\n")
    @testset "check finds what is wrong and applyInstall repairs it" begin
        d = mktempdir()
        e = Dict("XDG_DATA_HOME" => joinpath(d, "d"),
            "XDG_CONFIG_HOME" => joinpath(d, "cfg"))
        b = mkpath(joinpath(d, "bundle"))
        c = check(b; env = e, home = d)
        @test any(occursin("install.json is missing", x) for x in c.fixable)
        @test length(c.missing) == length(BAYSOLSetup.BUNDLE_FILES)
        i = Install(; home = joinpath(d, "h"), cache = joinpath(d, "c"),
            structureCache = joinpath(d, "s"), desktop = true, pathLink = true)
        applyInstall(i, b; env = e, home = d)
        @test isempty(check(b; env = e, home = d).fixable)
        rm(i.cache; recursive = true)
        rm(targets(; env = e, home = d).desktop)
        write(installFile(; env = e, home = d), "{ broken")
        c = check(b; env = e, home = d)
        @test any(occursin("damaged", x) for x in c.fixable)
        write(installFile(; env = e, home = d), "")
        writeInstall(installFile(; env = e, home = d), i)
        c = check(b; env = e, home = d)
        @test length(c.fixable) == 2  # cache folder and desktop entry
        applyInstall(i, b; env = e, home = d)
        @test isempty(check(b; env = e, home = d).fixable)
    end
    @testset "desktop icon, pin lists, new icon" begin
        d = mktempdir()
        e = Dict("XDG_DATA_HOME" => joinpath(d, "d"),
            "XDG_CONFIG_HOME" => joinpath(d, "cfg"), "XDG_CURRENT_DESKTOP" => "KDE")
        @test desktopDir(; env = e, home = d) == joinpath(d, "Desktop")
        if Sys.islinux()
            mkpath(joinpath(d, "cfg"))
            write(joinpath(d, "cfg", "user-dirs.dirs"),
                "XDG_DESKTOP_DIR=\"\$HOME/Schreibtisch\"\n")
            @test desktopDir(; env = e, home = d) == joinpath(d, "Schreibtisch")
            b = mkpath(joinpath(d, "bundle"))
            fakeIcns(joinpath(b, ICON_FILE), ["icp4" => 16, "ix22" => 22, "ic10" => 1024])
            i = Install(; home = joinpath(d, "h"), cache = joinpath(d, "c"),
                structureCache = joinpath(d, "s"), desktopIcon = true, taskbarPin = true,
            )
            log = applyInstall(i, b; env = e, home = d)  # no Desktop folder yet
            t = targets(; env = e, home = d)
            @test any(occursin("desktop icon skipped", x) for x in log)
            @test any(occursin("not GNOME", x) for x in log)  # KDE: told, not pinned
            @test isfile(t.desktop)  # a pin needs the menu entry
            mkpath(dirname(t.icon))
            applyInstall(i, b; env = e, home = d)
            @test isfile(t.icon) && (filemode(t.icon) & 0o111) != 0
            # by name: the theme picks
            @test occursin("Icon=baysol\n", read(t.icon, String))
            @test [first(p) for p in iconPngs(joinpath(b, ICON_FILE))] == [16, 22, 1024]
            sizes = iconFiles([16, 22, 1024]; env = e, home = d)
            @test all(isfile, sizes)
            @test endswith(sizes[3], joinpath("512x512@2", "apps", "baysol.png"))
            rm(sizes[1])
            @test any(
                occursin("icon sizes are missing", x)
                for x in check(b; env = e, home = d).fixable
            )
            applyInstall(i, b; env = e, home = d)
            @test all(isfile, sizes)  # repair puts them back
            rm(t.icon)
            @test any(
                occursin("desktop icon is missing", x)
                for x in check(b; env = e, home = d).fixable
            )
            applyInstall(i, b; env = e, home = d)
            @test isempty(check(b; env = e, home = d).fixable)
            uninstall(b; env = e, home = d)
            @test !isfile(t.icon) && !isfile(t.desktop)
            @test !any(isfile, sizes)
        end
        @test _pinned(["a.desktop"], "baysol.desktop") == ["a.desktop", "baysol.desktop"]
        @test _pinned(["baysol.desktop"], "baysol.desktop") == ["baysol.desktop"]
        @test _unpinned(["a.desktop", "baysol.desktop"], "baysol.desktop") == ["a.desktop"]
        f = joinpath(d, "i.json")
        j = Install(; home = "/a", cache = "/k", structureCache = "/s",
            desktopIcon = true, taskbarPin = true)
        writeInstall(f, j)
        @test readInstall(f) == j
    end
    @testset "a failed apply is undone" begin
        d = mktempdir()
        e = Dict("XDG_DATA_HOME" => joinpath(d, "d"),
            "XDG_CONFIG_HOME" => joinpath(d, "cfg"))
        old = joinpath(d, "old")
        mkpath(old)
        # the structure cache sits under a plain file, so its mkpath fails midway
        write(joinpath(d, "file"), "x")
        i = Install(; home = joinpath(d, "new", "h"), cache = joinpath(d, "c"),
            structureCache = joinpath(d, "file", "s"), desktop = true, pathLink = true)
        journal = Function[]
        @test_throws Exception applyInstall(i, d; env = e, home = d, journal)
        rollback!(journal)
        @test !isdir(joinpath(d, "new")) && !isdir(joinpath(d, "c"))
        @test !isfile(installFile(; env = e, home = d))
        @test isdir(old) && read(joinpath(d, "file"), String) == "x"
        # a good apply over an existing entry and link restores them on rollback
        b = mkpath(joinpath(d, "bundle"))
        t = targets(; env = e, home = d)
        mkpath(dirname(t.desktop))
        write(t.desktop, "mine")
        mkpath(dirname(t.link))
        symlink("/usr/bin/env", t.link)
        good = Install(; home = joinpath(d, "h"), cache = joinpath(d, "c2"),
            structureCache = joinpath(d, "s2"), desktop = true, pathLink = true)
        journal = Function[]
        applyInstall(good, b; env = e, home = d, journal)
        @test readlink(t.link) == joinpath(b, "baysol")
        rollback!(journal)
        @test read(t.desktop, String) == "mine" && readlink(t.link) == "/usr/bin/env"
        @test !isdir(joinpath(d, "h")) && !isfile(installFile(; env = e, home = d))
    end
    @testset "an existing project folder is recognised and kept" begin
        d = mktempdir()
        @test !hasProject(d)
        mkpath(joinpath(d, "projects"))
        write(joinpath(d, "projects", "p.txt"), "x")
        @test hasProject(d)
        e = Dict("XDG_CONFIG_HOME" => joinpath(d, "cfg"))
        i = Install(; home = d, cache = joinpath(d, "c"), structureCache = joinpath(d, "s"))
        applyInstall(i, d; env = e, home = d)  # no error on the existing folder
        @test isfile(joinpath(d, "projects", "p.txt"))
        @test readInstall(installFile(; env = e, home = d)).home == d
    end
    @testset "first run, threads, typed paths" begin
        fresh = mktempdir()
        e = Dict("XDG_CONFIG_HOME" => joinpath(fresh, "cfg"))
        @test needsSetup(; env = e, home = fresh)
        i = Install(; home = "/h", cache = "/c", structureCache = "/s", threads = 3)
        writeInstall(installFile(; env = e, home = fresh), i)
        @test !needsSetup(; env = e, home = fresh)
        @test readInstall(installFile(; env = e, home = fresh)).threads == 3
        writeInstall(installFile(; env = e, home = fresh),
            Install(; home = " ", cache = "/c", structureCache = "/s"))
        @test needsSetup(; env = e, home = fresh)
        @test 1 <= defaultThreads() <= 8
        @test cleanPath("~/a/../b"; home = "/u") == "/u/b"
        @test cleanPath("  /x//y/ "; home = "/u") == "/x/y"
        @test cleanPath("rel/dir"; home = "/u") == "/u/rel/dir"
    end
    @testset "apply makes folders, entry, link, install.json" begin
        i = Install(; home = joinpath(home, "P"), cache = joinpath(home, "C"),
            structureCache = joinpath(home, "S"), desktop = true, pathLink = true)
        applyInstall(i, bundle; env, home)
        @test isdir(i.home) && isdir(i.cache) && isdir(i.structureCache)
        t = targets(; env, home)
        if Sys.islinux()
            exec = "Exec=\"$(joinpath(bundle, "baysol"))\""
            @test occursin(exec, read(t.desktop, String))
        end
        @test readlink(t.link) == joinpath(bundle, "baysol")
        @test readInstall(installFile(; env, home)) == i
        applyInstall(i, bundle; env, home)  # a second run is the same
        @test readlink(t.link) == joinpath(bundle, "baysol")
    end
    @testset "uninstall: caches always go, projects only with data" begin
        i = readInstall(installFile(; env, home))
        write(joinpath(i.home, "project.txt"), "x")
        write(joinpath(i.cache, "CACHEDIR.TAG"), "tag")
        write(joinpath(i.structureCache, "foreign.txt"), "not ours")
        keep = mkpath(joinpath(home, "keep-bundle"))
        uninstall(keep; i, env, home)  # app and caches
        @test isfile(joinpath(i.home, "project.txt")) && !isdir(keep)
        @test !isdir(i.cache)  # marked cache removed
        @test isfile(joinpath(i.structureCache, "foreign.txt"))  # not marked: kept
        @test isfile(installFile(; env, home)) == false
        uninstall(bundle; data = true, i, env, home)
        @test !isdir(i.home) && !isdir(bundle)
        @test isfile(joinpath(i.structureCache, "foreign.txt"))
        @test !islink(targets(; env, home).link)
    end
    @testset "a link that points elsewhere is not removed" begin
        t = targets(; env, home)
        mkpath(dirname(t.link))
        symlink("/usr/bin/env", t.link)
        uninstall(mkpath(joinpath(home, "b2")); env, home)
        @test islink(t.link)
    end
    @testset "exit statuses: the TUI's SETUP_UNINSTALLED is the wizard's" begin
        @test UNINSTALLED == 22  # tui/src/core/file-system.ts SETUP_UNINSTALLED
        @test length(unique((0, LAUNCH_TUI, LAUNCH_CLI, UNINSTALLED))) == 4
    end
    @testset "clearCache empties only a BAYSOL cache" begin
        d = mkpath(joinpath(mktempdir(), "c"))
        write(joinpath(d, BAYSOLSetup.CACHE_TAG), "")
        write(joinpath(d, "a.pdb"), "x")
        mkpath(joinpath(d, "sub"))
        write(joinpath(d, "sub", "b"), "y")
        @test occursin("2 entries", clearCache(d))
        @test readdir(d) == [BAYSOLSetup.CACHE_TAG]
        f = mkpath(joinpath(mktempdir(), "foreign"))
        write(joinpath(f, "k.txt"), "k")
        @test occursin("kept", clearCache(f))
        @test isfile(joinpath(f, "k.txt"))
        @test occursin("no folder", clearCache(joinpath(f, "nope")))
    end
    @testset "openFolder: a missing folder, and the shell runs in the folder" begin
        io = IOBuffer()
        @test !openFolder("/no/such/folder"; io, managers = Cmd[], shell = nothing)
        d = realpath(mktempdir())
        out = joinpath(d, "pwd.txt")
        sh = `sh -c "pwd > $out"`
        @test openFolder(d; io, managers = Cmd[], shell = sh)
        @test readchomp(out) == d
        @test occursin("No file manager", String(take!(io)))
        @test shellCommand(; env = Dict("SHELL" => "/bin/zsh")) == `/bin/zsh`
    end
end
