# SPDX-License-Identifier: LGPL-3.0-or-later

using Test
using SetupWizard
const Platform = SetupWizard.Platform
using SetupWizard: targets, defaultThreads, desktopDir, desktopEntry, _pinned, _unpinned,
    iconPngs, bundleIcons, iconFiles, hicolorDir, ICON_FILE, readManifest, manifestFile,
    _installMacApp!, _installWindows!

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

# the `icons/hicolor` folders of a Linux bundle, the way `bysl pkg` writes them
function fakeIcons(bundle, folders)
    for (folder, px) in folders
        mkpath(joinpath(bundle, "icons", "hicolor", folder))
        write(joinpath(bundle, "icons", "hicolor", folder, "baysol.png"), fakePng(px))
    end
    return bundle
end

# the variables that place the data, cache and configuration folders: XDG on Linux, the
# Windows ones on Windows (where data and cache share LOCALAPPDATA); macOS has none
function placeEnv(d; data = joinpath(d, "d"), cache = joinpath(d, "c"),
    config = joinpath(d, "cfg"))
    Platform.iswindows() && return Dict("LOCALAPPDATA" => data, "APPDATA" => config)
    return Dict("XDG_DATA_HOME" => data, "XDG_CACHE_HOME" => cache,
        "XDG_CONFIG_HOME" => config)
end
# where the folders land for `placeEnv` (macOS ignores the variables, so it is not asked)
winOr(win, other) = Platform.iswindows() ? win : other

# every path goes into a temporary folder: no test touches the real home
@testset "SetupWizard" begin
    home = mktempdir()
    env = placeEnv(home)
    @testset "defaults follow XDG, a relative XDG value is ignored" begin
        d = defaultInstall(; env, home)
        if !Platform.ismacos()
            @test d.home == joinpath(home, "d", "baysol")
            @test d.structureCache ==
                  winOr(joinpath(home, "d", "baysol-cache", "_structures"),
                joinpath(home, "c", "baysol", "_structures"))
            @test !hasfield(Install, :cache)  # the separate cache folder is gone
            @test installFile(; env, home) ==
                  joinpath(home, "cfg", "baysol", "install.json")
        end
        rel = Dict("XDG_DATA_HOME" => "relative/path", "LOCALAPPDATA" => "relative/path")
        stock =
            Platform.iswindows() ? joinpath(home, "AppData", "Local", "baysol") :
            Platform.ismacos() ?
            joinpath(home, "Library", "Application Support", "baysol") :
            joinpath(home, ".local", "share", "baysol")
        @test defaultInstall(; env = rel, home).home == stock
    end
    @testset "first-run defaults per system" begin
        d = defaultInstall(; env, home)
        @test d.desktop && !d.desktopIcon && !d.taskbarPin
        @test d.pathLink == !Platform.iswindows()
        @test d.opens == "tui" && d.terminal == "auto" && d.threads == defaultThreads()
        # the checklist offers exactly the shortcuts of the system, defaults ticked
        for os in (:linux, :macos, :windows)
            offered = first.(SetupWizard.shortcutChoices(os))
            @test :desktop in offered && :desktopIcon in offered
            @test (:pathLink in offered) == (os != :windows)
            @test (:taskbarPin in offered) == (os != :macos)
        end
        # the whole default Install survives the file
        f = joinpath(mktempdir(), "install.json")
        writeInstall(f, d)
        @test readInstall(f) == d
    end
    @testset "yes/no parsing and the question helper" begin
        @test parseYesNo("y", false) === true && parseYesNo(" YES ", false) === true
        @test parseYesNo("n", true) === false && parseYesNo("No", true) === false
        @test parseYesNo("", true) === true && parseYesNo("  ", false) === false
        for bad in ("yep", "never", "install now", "not now", "cancel", "1", "yes no")
            @test parseYesNo(bad, true) === nothing
        end
        feed(lines) = (l = copy(lines); io -> popfirst!(l))
        ask(lines, default) = SetupWizard._askYesNo(IOBuffer(), "Q?", default;
            read = feed(lines))
        @test ask([""], true) === true && ask([""], false) === false
        @test ask(["y"], false) === true && ask(["no"], true) === false
        # anything else is refused and asked again until a valid answer
        io = IOBuffer()
        @test SetupWizard._askYesNo(
            io,
            "Q?",
            true;
            read = feed(["never", "maybe", "n"]),
        ) ===
              false
        @test count("Please answer Yes or No.", String(take!(io))) == 2
        # the threads: a number, clamped; the default on an empty or bad line
        @test parseThreads("6", 4) == 6 && parseThreads("", 4) == 4
        @test parseThreads("x", 4) == 4 && parseThreads("0", 4) == 1
        @test parseThreads("9999", 4) == 256
    end
    @testset "describeInstall and startNow" begin
        i = Install(; home = "/h", structureCache = "/s", threads = 3, desktop = true,
            pathLink = true)
        io = IOBuffer()
        describeInstall(io, i; os = :linux)
        out = String(take!(io))
        @test occursin("/h", out) && occursin("threads     3", out)
        @test occursin("application menu entry", out) && occursin("PATH link", out)
        @test !occursin("Desktop icon", out)
        # the start question: Yes starts what `opens` says, No starts nothing
        yes(_, _, _) = true
        no(_, _, _) = false
        @test startNow(IOBuffer(), i; ask = yes) == SetupWizard.LAUNCH_TUI
        cli = SetupWizard._copy(i; opens = "cli")
        @test startNow(IOBuffer(), cli; ask = yes) == SetupWizard.LAUNCH_CLI
        @test startNow(IOBuffer(), i; ask = no) == 0
        @test SetupWizard._copy(i; threads = 9).threads == 9
        @test SetupWizard._copy(i; threads = 9).home == "/h"
    end
    @testset "install.json round trip, odd characters, damaged file" begin
        f = joinpath(home, "x", "install.json")
        i = Install(; home = "/a \"b\"/c\\d", structureCache = "/s",
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
        e = placeEnv(d)
        b = mkpath(joinpath(d, "bundle"))
        c = check(b; env = e, home = d)
        @test any(occursin("install.json is missing", x) for x in c.fixable)
        @test length(c.missing) == length(SetupWizard.BUNDLE_FILES)
        i = Install(;
            home = joinpath(d, "h"),
            structureCache = joinpath(d, "s"),
            desktop = true,
            pathLink = true,
        )
        applyInstall(i, b; env = e, home = d)
        @test isempty(check(b; env = e, home = d).fixable)
        rm(i.structureCache; recursive = true)
        # the menu entry (Linux), the Start Menu shortcut (Windows)
        entry =
            Platform.iswindows() ? targets(; env = e, home = d).lnk :
            targets(; env = e, home = d).desktop
        Platform.ismacos() || rm(entry)
        write(installFile(; env = e, home = d), "{ broken")
        c = check(b; env = e, home = d)
        @test any(occursin("damaged", x) for x in c.fixable)
        write(installFile(; env = e, home = d), "")
        writeInstall(installFile(; env = e, home = d), i)
        c = check(b; env = e, home = d)
        # cache folder and desktop entry (macOS: only the cache folder, the app is kept)
        @test length(c.fixable) == (Platform.ismacos() ? 1 : 2)
        applyInstall(i, b; env = e, home = d)
        @test isempty(check(b; env = e, home = d).fixable)
    end
    @testset "desktop icon, pin lists, new icon" begin
        d = mktempdir()
        e = merge(placeEnv(d), Dict("XDG_CURRENT_DESKTOP" => "KDE"))
        @test desktopDir(; env = e, home = d) == joinpath(d, "Desktop")
        if Platform.islinux()
            mkpath(joinpath(d, "cfg"))
            write(joinpath(d, "cfg", "user-dirs.dirs"),
                "XDG_DESKTOP_DIR=\"\$HOME/Schreibtisch\"\n")
            @test desktopDir(; env = e, home = d) == joinpath(d, "Schreibtisch")
            b = mkpath(joinpath(d, "bundle"))
            fakeIcons(b, ["16x16" => 16, "22x22" => 22, "512x512@2" => 1024])
            i = Install(;
                home = joinpath(d, "h"),
                structureCache = joinpath(d, "s"),
                desktopIcon = true,
                taskbarPin = true,
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
            @test [first(p) for p in bundleIcons(b)] == [16, 22, 1024]
            # an older bundle with the `.icns` instead of the folder still installs
            old = mkpath(joinpath(d, "oldbundle"))
            fakeIcns(joinpath(old, "baysol.icns"), ["icp4" => 16, "ix22" => 22])
            @test [first(p) for p in bundleIcons(old)] == [16, 22]
            @test isempty(bundleIcons(mkpath(joinpath(d, "nobundle"))))
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
            @test !isfile(manifestFile(; env = e, home = d))
        end
        @test _pinned(["a.desktop"], "baysol.desktop") == ["a.desktop", "baysol.desktop"]
        @test _pinned(["baysol.desktop"], "baysol.desktop") == ["baysol.desktop"]
        @test _unpinned(["a.desktop", "baysol.desktop"], "baysol.desktop") == ["a.desktop"]
        f = joinpath(d, "i.json")
        j = Install(; home = "/a", structureCache = "/s",
            desktopIcon = true, taskbarPin = true)
        writeInstall(f, j)
        @test readInstall(f) == j
    end
    @testset "uninstall removes only what the manifest names" begin
        d = mktempdir()
        e = placeEnv(d)
        b = mkpath(joinpath(d, "bundle"))
        fakeIcons(b, ["16x16" => 16, "256x256" => 256])
        i = Install(;
            home = joinpath(d, "h"),
            structureCache = joinpath(d, "s"),
            desktop = true,
        )
        if Platform.islinux()
            applyInstall(i, b; env = e, home = d)
            m = readManifest(manifestFile(; env = e, home = d))
            files = [p for (k, p) in m if k == "file"]
            @test length(files) == 3  # two icon sizes and the entry
            @test all(isfile, files)
            @test occursin(".desktop", join(files))
            # a file of someone else in the theme, and an icon of another app
            other = joinpath(dirname(files[1]), "other.png")
            write(other, "x")
            keep = joinpath(d, "d", "applications", "other.desktop")
            write(keep, "x")
            uninstall(b; i, env = e, home = d)
            @test !any(isfile, files)
            @test isfile(other) && isfile(keep)
            # a second uninstall without a manifest removes no icons and entries
            mkpath(b)
            fakeIcons(b, ["16x16" => 16, "256x256" => 256])
            applyInstall(i, b; env = e, home = d)
            rm(manifestFile(; env = e, home = d))
            uninstall(mkpath(joinpath(d, "b2")); i, env = e, home = d)
            @test all(isfile, files)
        end
    end

    @testset "macOS app bundle and Windows shortcut builders (any OS, stubs)" begin
        d = mktempdir()
        icns = joinpath(d, "baysol.icns")
        fakeIcns(icns, ["icp4" => 16])
        made, journal = String[], Function[]
        app = joinpath(d, "Applications", "BAYSOL.app")
        SetupWizard._installMacApp!(journal, made, joinpath(d, "bundle"), app, icns)
        @test isfile(joinpath(app, "Contents", "Info.plist"))
        @test occursin(
            "baysol</string>",
            read(joinpath(app, "Contents", "Info.plist"), String),
        )
        @test occursin("<string>arm64</string>",
            read(joinpath(app, "Contents", "Info.plist"), String))
        @test isfile(joinpath(app, "Contents", "Resources", "baysol.icns"))
        # the hand-made macOS file (TOC, ARGB and mask entries, duplicate PNG sizes) is
        # copied byte for byte, and the PNG reader of the Linux side does not choke on it
        be(n) = collect(reinterpret(UInt8, [hton(UInt32(n))]))
        entry(t, d) = vcat(codeunits(t), be(8 + length(d)), d)
        body = vcat(entry("TOC ", zeros(UInt8, 8)), entry("ic04", codeunits("ARGB....")),
            entry("is32", zeros(UInt8, 9)), entry("ic11", fakePng(32)),
            entry("ic08", fakePng(256)), entry("ic13", fakePng(256)))
        macIcns = joinpath(d, "mac.icns")
        write(macIcns, vcat(codeunits("icns"), be(8 + length(body)), body))
        macApp = joinpath(d, "Applications2", "BAYSOL.app")
        SetupWizard._installMacApp!(Function[], String[], joinpath(d, "bundle"), macApp,
            macIcns)
        @test read(joinpath(macApp, "Contents", "Resources", "baysol.icns")) ==
              read(macIcns)
        @test [first(p) for p in iconPngs(macIcns)] == [32, 256]
        exe = joinpath(app, "Contents", "MacOS", "BAYSOL")
        @test occursin("BAYSOL.command", read(exe, String))
        # the path survives the shell, and a moved bundle is noticed
        odd = joinpath(d, "a \$HOME `x` \"q\" 'r'")
        script = SetupWizard._macAppScript(odd)
        arg = Base.shell_split(split(split(script, "command="; limit = 2)[2], '\n')[1])
        @test only(arg) == joinpath(odd, "BAYSOL.command")
        @test SetupWizard._isMacAppOf(app, joinpath(d, "bundle"))
        @test !SetupWizard._isMacAppOf(app, joinpath(d, "moved"))
        # an apply over an app that exists is undone to what was there
        before = read(exe, String)
        again = Function[]
        SetupWizard._installMacApp!(again, String[], joinpath(d, "moved"), app, icns)
        @test read(exe, String) != before
        rollback!(again)
        @test read(exe, String) == before
        @test count(startswith("file\t"), made) == 3
        # an uninstall by this manifest leaves the app folder gone and nothing else
        sibling = joinpath(d, "Applications", "Other.app")
        mkpath(sibling)
        entries = [first(split(l, '\t')) => last(split(l, '\t')) for l in made]
        SetupWizard._removeManifest(entries, joinpath(d, "bundle"))
        @test !isdir(app) && isdir(sibling)
        made = String[]
        lnk = joinpath(d, "Start", "BAYSOL.lnk")
        ico = joinpath(d, "baysol.ico")
        write(ico, "ico")
        seen = Ref{Any}(nothing)
        stub = (l, t, ic, w) -> (write(l, "lnk"); seen[] = (l, t, ic))
        SetupWizard._installWindows!(Function[], made, joinpath(d, "bundle"), lnk,
            joinpath(d, "cfg", "baysol.ico"), ico; makeShortcut = stub, home = d)
        @test isfile(lnk) && isfile(joinpath(d, "cfg", "baysol.ico"))
        @test seen[][2] == joinpath(d, "bundle", "baysol.exe")
        entries = [first(split(l, '\t')) => last(split(l, '\t')) for l in made]
        SetupWizard._removeManifest(entries, joinpath(d, "bundle"))
        @test !ispath(lnk) && !ispath(joinpath(d, "cfg", "baysol.ico")) &&
              !isdir(dirname(lnk))
    end

    @testset "the terminal of the macOS icon" begin
        choices = SetupWizard._terminalChoices
        @test first.(choices(["iterm2", "wezterm"])) ==
              ["auto", "iterm2", "wezterm", "terminal"]
        @test last(choices(["wezterm"])[1]) == "Automatic"
        @test first.(choices(String[])) == ["auto", "terminal"]
        d = mktempdir()
        f = joinpath(d, "i.json")
        for id in SetupWizard.MAC_TERMINAL_IDS
            i = Install(; home = "/a", structureCache = "/s", terminal = id)
            writeInstall(f, i)
            @test readInstall(f) == i
        end
        write(f, replace(read(f, String), "wezterm" => "bogus"))
        @test readInstall(f).terminal == "auto"
        # the script run for real, with a stand-in `open` and application folder
        if Platform.ismacos()
            apps = mkpath(joinpath(d, "Apps"))
            seen = joinpath(d, "seen")
            open_ = joinpath(d, "open")
            write(open_, "#!/bin/zsh\nprint -rl -- \"\$@\" > $seen\n")
            chmod(open_, 0o755)
            b = joinpath(d, "my 'b'")
            cmd = joinpath(b, "BAYSOL.command")
            function opened(id)
                s = replace(SetupWizard._macAppScript(b, id), "/usr/bin/open" => open_,
                    "in /Applications" => "in $apps")
                file = joinpath(d, "run.zsh")
                write(file, s)
                run(addenv(`/bin/zsh $file`, "HOME" => joinpath(d, "nohome")))
                return readlines(seen)
            end
            term = ["-a", "Terminal", cmd]
            wez = ["-a", joinpath(apps, "WezTerm.app"), "-n", "--args", "start", "--", cmd]
            iterm = ["-a", joinpath(apps, "iTerm.app"), cmd]
            @test all(opened(id) == term for id in SetupWizard.MAC_TERMINAL_IDS)
            mkdir(joinpath(apps, "WezTerm.app"))
            @test opened("auto") == wez && opened("wezterm") == wez
            @test opened("iterm2") == term && opened("terminal") == term
            mkdir(joinpath(apps, "iTerm.app"))
            @test opened("auto") == iterm && opened("iterm2") == iterm
            @test opened("wezterm") == wez && opened("terminal") == term
        end
    end

    Platform.ismacos() && @testset "macOS Desktop icon" begin
        d = mktempdir()
        e = placeEnv(d)
        b = mkpath(joinpath(d, "bundle"))
        write(joinpath(b, "baysol"), "")
        i = Install(; home = joinpath(d, "h"), structureCache = joinpath(d, "s"),
            desktopIcon = true)
        t = targets(; env = e, home = d)
        log = applyInstall(i, b; env = e, home = d)  # no Desktop folder yet
        @test any(occursin("desktop icon skipped", x) for x in log)
        @test isdir(t.app)  # the icon needs the app bundle
        mkpath(dirname(t.macIcon))
        missing_(c) = any(occursin("desktop icon is missing", x) for x in c.fixable)
        @test missing_(check(b; env = e, home = d))
        # something else of that name is left alone
        write(t.macIcon, "mine")
        applyInstall(i, b; env = e, home = d)
        @test read(t.macIcon, String) == "mine"
        rm(t.macIcon)
        # undone by a rollback
        journal = Function[]
        applyInstall(i, b; env = e, home = d, journal)
        @test readlink(t.macIcon) == t.app
        rollback!(journal)
        @test !islink(t.macIcon)
        # a refusal does not fail the setup
        chmod(dirname(t.macIcon), 0o555)
        log = applyInstall(i, b; env = e, home = d)
        @test any(occursin("macOS refused", x) for x in log)
        chmod(dirname(t.macIcon), 0o755)
        applyInstall(i, b; env = e, home = d)
        applyInstall(i, b; env = e, home = d)  # a second run is the same
        @test isempty(check(b; env = e, home = d).fixable)
        uninstall(b; i, env = e, home = d)
        @test !islink(t.macIcon) && !isdir(t.app)
    end

    @testset "a failed apply is undone" begin
        d = mktempdir()
        e = placeEnv(d)
        old = joinpath(d, "old")
        mkpath(old)
        # the structure cache sits under a plain file, so its mkpath fails midway
        write(joinpath(d, "file"), "x")
        i = Install(;
            home = joinpath(d, "new", "h"),
            structureCache = joinpath(d, "file", "s"),
            desktop = true,
            pathLink = true,
        )
        journal = Function[]
        @test_throws Exception applyInstall(i, d; env = e, home = d, journal)
        rollback!(journal)
        @test !isdir(joinpath(d, "new")) && !isdir(joinpath(d, "c"))
        @test !isfile(installFile(; env = e, home = d))
        @test isdir(old) && read(joinpath(d, "file"), String) == "x"
        # a good apply over an existing entry and link restores them on rollback
        b = mkpath(joinpath(d, "bundle"))
        t = targets(; env = e, home = d)
        # a menu entry of the user's (Linux only: Windows has a shortcut, made afresh)
        if Platform.islinux()
            mkpath(dirname(t.desktop))
            write(t.desktop, "mine")
        end
        # the PATH link is made on Unix only (a symlink needs a privilege on Windows)
        if Platform.isunix()
            mkpath(dirname(t.link))
            symlink("/usr/bin/env", t.link)
        end
        good = Install(;
            home = joinpath(d, "h"),
            structureCache = joinpath(d, "s2"),
            desktop = true,
            pathLink = true,
        )
        journal = Function[]
        applyInstall(good, b; env = e, home = d, journal)
        if Platform.isunix()
            @test readlink(t.link) == joinpath(b, "baysol")
        end
        rollback!(journal)
        if Platform.islinux()
            @test read(t.desktop, String) == "mine"
        end
        Platform.isunix() && @test readlink(t.link) == "/usr/bin/env"
        Platform.iswindows() && @test !ispath(t.lnk)
        @test !isdir(joinpath(d, "h")) && !isfile(installFile(; env = e, home = d))
    end
    @testset "an existing project folder is recognised and kept" begin
        d = mktempdir()
        @test !hasProject(d)
        mkpath(joinpath(d, "projects"))
        write(joinpath(d, "projects", "p.txt"), "x")
        @test hasProject(d)
        e = placeEnv(d)
        i = Install(; home = d, structureCache = joinpath(d, "s"))
        applyInstall(i, d; env = e, home = d)  # no error on the existing folder
        @test isfile(joinpath(d, "projects", "p.txt"))
        @test readInstall(installFile(; env = e, home = d)).home == d
    end
    @testset "first run, threads, typed paths" begin
        fresh = mktempdir()
        e = placeEnv(fresh)
        @test needsSetup(; env = e, home = fresh)
        i = Install(; home = "/h", structureCache = "/s", threads = 3)
        writeInstall(installFile(; env = e, home = fresh), i)
        @test !needsSetup(; env = e, home = fresh)
        @test readInstall(installFile(; env = e, home = fresh)).threads == 3
        writeInstall(installFile(; env = e, home = fresh),
            Install(; home = " ", structureCache = "/s"))
        @test needsSetup(; env = e, home = fresh)
        @test 1 <= defaultThreads() <= 8
        # a POSIX-style home is absolute on Windows too, with its own separators there
        @test cleanPath("~/a/../b"; home = "/u") == normpath("/u/b")
        @test cleanPath("  /x//y/ "; home = "/u") == normpath("/x/y")
        @test cleanPath("rel/dir"; home = "/u") == normpath("/u/rel/dir")
        @test cleanPath("/"; home = "/u") == normpath("/")
        if Platform.iswindows()
            @test cleanPath("C:\\"; home = "C:\\u") == "C:\\"
            @test cleanPath("C:\\x\\y\\"; home = "C:\\u") == "C:\\x\\y"
            @test cleanPath("~\\z"; home = "C:\\u") == "C:\\u\\z"
        end
    end
    @testset "apply makes folders, entry, link, install.json" begin
        i = Install(;
            home = joinpath(home, "P"),
            structureCache = joinpath(home, "S"),
            desktop = true,
            pathLink = true,
        )
        applyInstall(i, bundle; env, home)
        @test isdir(i.home) && isdir(i.structureCache)
        t = targets(; env, home)
        if Platform.islinux()
            exec = "Exec=\"$(joinpath(bundle, "baysol"))\""
            @test occursin(exec, read(t.desktop, String))
        end
        Platform.isunix() && @test readlink(t.link) == joinpath(bundle, "baysol")
        Platform.iswindows() && @test isfile(t.lnk)
        @test readInstall(installFile(; env, home)) == i
        applyInstall(i, bundle; env, home)  # a second run is the same
        Platform.isunix() && @test readlink(t.link) == joinpath(bundle, "baysol")
        @test isempty(check(bundle; env, home).fixable)
    end
    @testset "uninstall: caches always go, projects only with data" begin
        i = readInstall(installFile(; env, home))
        write(joinpath(i.home, "project.txt"), "x")
        write(joinpath(i.structureCache, "CACHEDIR.TAG"), "tag")
        keep = mkpath(joinpath(home, "keep-bundle"))
        write(joinpath(keep, "baysol"), "")  # a bundle holds the program
        uninstall(keep; i, env, home)  # app and caches
        @test isfile(joinpath(i.home, "project.txt")) && !isdir(keep)
        @test !isdir(i.structureCache)  # marked cache removed
        @test isfile(installFile(; env, home)) == false
        # a cache that is not marked (and not empty) is kept, with the projects removed
        mkpath(i.structureCache)
        write(joinpath(i.structureCache, "foreign.txt"), "not ours")
        uninstall(bundle; data = true, i, env, home)
        @test !isdir(i.home) && !isdir(bundle)
        @test isfile(joinpath(i.structureCache, "foreign.txt"))
        @test !islink(targets(; env, home).link)
    end
    @testset "uninstall leaves nothing of the app behind" begin
        d = mktempdir()
        h = joinpath(d, "h")
        e = placeEnv(d)
        tmp = mkpath(joinpath(d, "tmp"))
        caches = Platform.cache_dir(; env = e, home = h)
        function setup(settings)
            i = Install(; home = joinpath(d, "projects"),
                structureCache = Platform.default_structure_cache(; env = e, home = h))
            mkpath(i.structureCache)
            write(joinpath(i.structureCache, "CACHEDIR.TAG"), "tag")
            mkpath(joinpath(caches, "_cache"))
            write(joinpath(caches, "_cache", "fixture"), "x")
            mkpath(i.home)
            write(joinpath(i.home, "settings.json"), settings)
            mkpath(joinpath(tmp, "baysol"))
            b = mkpath(joinpath(d, "bundle"))
            write(joinpath(b, "baysol"), "")
            return i, b
        end
        # no projects: the empty settings.json of the interface goes, the folder stays
        i, b = setup("{}\n")
        uninstall(b; i, env = e, home = h, tmp)
        @test !isdir(caches) && !isdir(joinpath(tmp, "baysol")) && !isdir(b)
        @test isdir(i.home) && !isfile(joinpath(i.home, "settings.json"))
        @test isempty(readdir(i.home))
        # settings that hold something, and a project, stay
        i, b = setup("{\"fitting\": 1}\n")
        write(joinpath(i.home, "p.txt"), "project")
        uninstall(b; i, env = e, home = h, tmp)
        @test isfile(joinpath(i.home, "settings.json")) && isfile(joinpath(i.home, "p.txt"))
        # everything: not even the projects folder
        i, b = setup("{}\n")
        uninstall(b; data = true, i, env = e, home = h, tmp)
        @test !isdir(i.home) && !isdir(caches) && !isdir(b)
        # a scratch folder of a process that still runs is not touched
        i, b = setup("{}\n")
        mkpath(joinpath(tmp, "baysol", "1234"))
        uninstall(b; i, env = e, home = h, tmp)
        @test isdir(joinpath(tmp, "baysol", "1234"))
        # a cache folder that holds the projects (or the user's home) is kept whole
        i = Install(; home = joinpath(caches, "projects"),
            structureCache = joinpath(caches, "_structures"))
        mkpath(i.home)
        mkpath(i.structureCache)
        @test SetupWizard._removeCacheRoot(; env = e, home = h, protect = [i.home]) ===
              "kept $caches (it holds $(i.home))"
        @test isdir(i.home)
        # no settings.json in a folder: nothing to remove
        @test SetupWizard._removeEmptySettings(joinpath(d, "nothing")) == false
    end
    @testset "the Dock entry of BAYSOL on macOS" begin
        text = """
        Array {
            Dict {
                GUID = 1
                tile-data = Dict {
                    bundle-identifier = com.apple.Safari
                    file-label = Safari
                }
                tile-type = file-tile
            }
            Dict {
                GUID = 2
                tile-data = Dict {
                    bundle-identifier = org.baysol.app
                    file-label = BAYSOL
                }
                tile-type = file-tile
            }
            Dict {
                GUID = 3
                tile-type = spacer-tile
            }
            Dict {
                GUID = 4
                tile-data = Dict {
                    bundle-identifier = org.baysol.app
                }
            }
        }
        """
        @test SetupWizard._dockIndices(text) == [1, 3]
        @test SetupWizard._dockIndices("Array {\n}\n") == Int[]
        @test SetupWizard._dockIndices("") == Int[]
        plist = joinpath(mktempdir(), "com.apple.dock.plist")
        @test SetupWizard._unpinDock(; plist) === nothing  # no Dock file: nothing
        write(plist, "x")
        ran = Cmd[]
        line = SetupWizard._unpinDock(; plist, capture = c -> text,
            exec = c -> push!(ran, c))
        @test line == "removed BAYSOL from the Dock"
        pb = SetupWizard.PLIST_BUDDY
        @test ran == [
            Cmd([pb, "-c", "Delete :persistent-apps:3", plist]),
            Cmd([pb, "-c", "Delete :persistent-apps:1", plist]),
            Cmd(["/usr/bin/killall", "Dock"]),
        ]
        empty!(ran)
        @test SetupWizard._unpinDock(; plist, capture = c -> "Array {\n}\n",
            exec = c -> push!(ran, c)) === nothing
        @test isempty(ran)  # nothing of BAYSOL in the Dock: the Dock is not restarted
        @test SetupWizard._unpinDock(; plist, capture = c -> error("no"),
            exec = c -> push!(ran, c)) === nothing
        @test SetupWizard._dockPrint(plist) ==
              Cmd([pb, "-c", "Print :persistent-apps", plist])
    end
    @testset "a link that points elsewhere is not removed" begin
        t = targets(; env, home)
        if Platform.isunix()
            mkpath(dirname(t.link))
            symlink("/usr/bin/env", t.link)
            uninstall(mkpath(joinpath(home, "b2")); env, home)
            @test islink(t.link)
        end
    end
    @testset "exit statuses: the TUI's SETUP_UNINSTALLED is the wizard's" begin
        @test UNINSTALLED == 22  # tui/src/core/file-system.ts SETUP_UNINSTALLED
        @test length(unique((0, LAUNCH_TUI, LAUNCH_CLI, UNINSTALLED))) == 4
    end
    @testset "default caches never sit inside the projects folder" begin
        d = defaultInstall(; env, home)
        @test !SetupWizard._within(d.structureCache, d.home)
        # an unrelated folder is not "within"; the folder itself and a child are
        @test SetupWizard._within(joinpath(home, "a", "b"), joinpath(home, "a"))
        @test SetupWizard._within(joinpath(home, "a"), joinpath(home, "a"))
        @test !SetupWizard._within(joinpath(home, "ab"), joinpath(home, "a"))
        if Platform.iswindows()
            @test d.home == joinpath(home, "d", "baysol")
            @test d.structureCache == joinpath(home, "d", "baysol-cache", "_structures")
        end
    end
    @testset "PATH link is offered except on Windows" begin
        fields(os) = first.(SetupWizard.shortcutChoices(os))
        @test fields(:linux) == [:desktop, :desktopIcon, :taskbarPin, :pathLink]
        @test fields(:windows) == [:desktop, :desktopIcon, :taskbarPin]
        @test fields(:macos) == [:desktop, :desktopIcon, :pathLink]  # no GNOME pin
        @test !any(occursin("GNOME", last(c)) for c in SetupWizard.shortcutChoices(:macos))
        @test SetupWizard.shortcutChoices() == SetupWizard.shortcutChoices(Platform.os())
    end
    @testset "_removeBundle: refusals, real removal, the PowerShell command" begin
        scratch = mktempdir()
        mkbundle(name) = (b = mkpath(joinpath(scratch, name));
            write(joinpath(b, "baysol"), ""); b)
        rb = SetupWizard._removeBundle
        recorded = Cmd[]
        spawn(c) = (push!(recorded, c); nothing)
        # refused: root, home, a parent of the projects folder, a folder with no program,
        # a relative or non-normal path; nothing is spawned or deleted
        for (p, protect) in (
            (abspath("/"), String[]),
            (homedir(), String[]),
            (scratch, String[]),                       # no baysol program in it
            (mkbundle("holds-projects"), [joinpath(scratch, "holds-projects", "p")]),
            ("relative", String[]),
            (joinpath(scratch, "x", "..", "y"), String[]),
        )
            line = rb(p, protect; spawn)
            @test startswith(line, "kept ")
            @test isempty(recorded)
        end
        @test isdir(joinpath(scratch, "holds-projects"))
        # a plain bundle is removed for real
        b = mkbundle("plain")
        mkpath(joinpath(b, "lib", "deep"))
        @test rb(b, [joinpath(scratch, "projects")]; spawn) == "removed $b"
        @test !ispath(b)
        @test isempty(recorded)
        # a stray sibling is never touched
        @test isdir(joinpath(scratch, "holds-projects"))
        # the command: the path is in the environment, never in the script
        for name in ("sp ace", "qu\"ote", "dollar\$env", "uni-é-ß-日本", "semi;colon'")
            c = SetupWizard._cleanupCommand(joinpath(scratch, name))
            @test any(==("BAYSOL_GONE=" * joinpath(scratch, name)), c.env)
            @test !any(a -> occursin(name, a), c.exec)
            @test c.exec[1] == "powershell"
            @test occursin("-LiteralPath \$env:BAYSOL_GONE", c.exec[end])
            @test c.flags & Base.UV_PROCESS_DETACHED != 0
        end
        # an in-use bundle (Windows: rm fails) hands the removal to the spawner
        if Platform.iswindows()
            b = mkbundle("busy")
            f = open(joinpath(b, "baysol"), "r")  # an open file blocks the delete
            try
                line = rb(b; spawn)
                @test occursin("in use", line)
                @test length(recorded) == 1
                @test recorded[1].dir == scratch
            finally
                close(f)
            end
        end
        # uninstall passes the projects folder as protected
        keep = mkbundle("keepme")
        i = Install(;
            home = joinpath(keep, "projects"),
            structureCache = joinpath(scratch, "s"),
        )
        log = uninstall(keep; i, env, home = mktempdir())
        @test any(l -> startswith(l, "kept $keep") && occursin("contains", l), log)
        @test isdir(keep)
    end
    @testset "clearCache empties only a BAYSOL cache" begin
        d = mkpath(joinpath(mktempdir(), "c"))
        write(joinpath(d, SetupWizard.CACHE_TAG), "")
        write(joinpath(d, "a.pdb"), "x")
        mkpath(joinpath(d, "sub"))
        write(joinpath(d, "sub", "b"), "y")
        @test occursin("2 entries", clearCache(d))
        @test readdir(d) == [SetupWizard.CACHE_TAG]
        f = mkpath(joinpath(mktempdir(), "foreign"))
        write(joinpath(f, "k.txt"), "k")
        @test occursin("kept", clearCache(f))
        @test isfile(joinpath(f, "k.txt"))
        @test occursin("no folder", clearCache(joinpath(f, "nope")))
        # an entry that cannot be removed (a loaded library on Windows) does not stop the
        # rest: it is kept and named, the others go
        b = mkpath(joinpath(mktempdir(), "busy"))
        write(joinpath(b, SetupWizard.CACHE_TAG), "")
        write(joinpath(b, "free.pdb"), "x")
        write(joinpath(b, "locked.dll"), "y")
        line = clearCache(
            b;
            remove = p ->
                basename(p) == "locked.dll" ? error("in use") : rm(p; force = true),
        )
        @test occursin("1 entries", line) && occursin("kept locked.dll", line)
        @test sort(readdir(b)) == sort([SetupWizard.CACHE_TAG, "locked.dll"])
    end
    @testset "openFolder: a missing folder, and the shell runs in the folder" begin
        io = IOBuffer()
        @test !openFolder("/no/such/folder"; io, managers = Cmd[], shell = nothing)
        d = realpath(mktempdir())
        out = joinpath(d, "pwd.txt")
        # `cd` alone prints the folder in cmd.exe, `pwd` in sh
        sh = Platform.iswindows() ? `cmd.exe /d /c cd '>' $out` : `sh -c "pwd > $out"`
        @test openFolder(d; io, managers = Cmd[], shell = sh)
        @test lowercase(readchomp(out)) == lowercase(d)
        @test occursin("No file manager", String(take!(io)))
        if Platform.iswindows()
            @test shellCommand(; env = Dict("COMSPEC" => raw"C:\x\cmd.exe")) ==
                  Cmd([raw"C:\x\cmd.exe"])
            @test shellCommand(; env = Dict("COMSPEC" => "rel")) == `cmd.exe`
        else
            @test shellCommand(; env = Dict("SHELL" => "/bin/zsh")) == `/bin/zsh`
        end
    end
    @testset "dependency check" begin
        # Homebrew (macOS) comes first and has tests of its own
        items = filter(i -> i.id != "brew", defaultItems())
        byId(rs, id) = only(r for r in rs if r.item.id == id)
        # a PATH that holds only the programs named; nothing real is looked at
        fakeWhich(names...) = n -> n in names ? "/fake/bin/$n" : nothing
        big = (30, 100)
        @testset "OS gating and detection" begin
            only_win = DepItem("w", "Windows only", :optional, [:windows], "why", false,
                Route[], Pair{Symbol,String}[])
            r = scanDependencies([only_win]; os = :linux, which = fakeWhich(), dims = big)
            @test !only(r).applicable && !only(r).found
            r = scanDependencies([only_win]; os = :windows, which = fakeWhich(),
                dims = big, detect = (i, e, w, d) -> SetupWizard.Detection(true, "x"))
            @test only(r).applicable && only(r).found
            none = scanDependencies(; os = :linux, env = Dict{String,String}(),
                which = fakeWhich(), dims = big)
            @test !byId(none, "latex").found && !byId(none, "sixel").found
            @test byId(none, "size").found
            @test !byId(
                scanDependencies(; env = Dict{String,String}(),
                    which = fakeWhich(), dims = (23, 100)), "size").found
            @test !byId(
                scanDependencies(; env = Dict{String,String}(),
                    which = fakeWhich(), dims = (30, 79)), "size").found
            tex = scanDependencies(; env = Dict{String,String}(),
                which = fakeWhich("xelatex"), dims = big)
            @test byId(tex, "latex").found
            @test occursin("xelatex", byId(tex, "latex").detail)
            for (env, found) in (Dict("TERM_PROGRAM" => "iTerm.app") => true,
                Dict("TERM_PROGRAM" => "WezTerm") => true,
                Dict("WT_SESSION" => "x") => true,
                Dict("KONSOLE_VERSION" => "2312") => true, Dict("TERM" => "foot") => true,
                Dict("TERM" => "xterm-256color") => false,
                Dict("TERM_PROGRAM" => "Apple_Terminal") => false)
                r = scanDependencies(; env, which = fakeWhich(), dims = big)
                @test byId(r, "sixel").found == found
            end
            r = scanDependencies(; env = Dict("TERM" => "xterm"),
                which = fakeWhich("wezterm"), dims = big)
            @test !byId(r, "sixel").found && occursin("wezterm", byId(r, "sixel").detail)
            for v in ("truecolor", "24bit")
                r = scanDependencies(; env = Dict("COLORTERM" => v), which = fakeWhich(),
                    dims = big)
                @test byId(r, "truecolor").found
            end
            @test !byId(
                scanDependencies(; env = Dict("COLORTERM" => ""),
                    which = fakeWhich(), dims = big), "truecolor").found
        end
        @testset "Homebrew on macOS" begin
            brew = first(defaultItems())
            @test brew.id == "brew" && brew.oses == [:macos]
            scan(w; os = :macos) = only(scanDependencies([brew]; os, which = w, dims = big))
            @test !scan(fakeWhich()).found && scan(fakeWhich("brew")).found
            @test !scan(fakeWhich(); os = :linux).applicable
            ran, have = Cmd[], Set{String}()
            which = n -> n in have ? "/fake/bin/$n" : nothing
            offer(k, runner = c -> (push!(ran, c); true)) =
                offerInstall(IOBuffer(), brew, :macos; which, runner, ask = (p, c) -> k)
            @test [offer(k) for k in (0, 2)] == ["later", "no"]
            @test isempty(ran)
            @test offer(1) == "later"  # the installer ended without Homebrew
            @test offer(1, c -> false) == "later"
            # Homebrew just installed: the iTerm2 offer that follows uses it
            d = mktempdir()
            empty!(ran)
            prompts = String[]
            runner = c -> (push!(ran, c); push!(have, "brew"); true)
            checkDependencies(IOBuffer(); env = placeEnv(d), home = d, os = :macos, which,
                dims = big, runner,
                items = [brew, only(i for i in items if i.id == "sixel")],
                detect = (a...) -> SetupWizard.Detection(false, ""),
                ask = (p, c) -> (push!(prompts, c[1]); 1))
            @test prompts == ["Yes", "Yes"]
            @test ran == [SetupWizard.BREW_INSTALL,
                Cmd(["/fake/bin/brew", "install", "--cask", "iterm2"])]
        end
        @testset "iTerm2 on a Mac without Homebrew" begin
            sixel = only(i for i in items if i.id == "sixel")
            ran, have = Cmd[], Set{String}()
            which = n -> n in have ? "/fake/bin/$n" : nothing
            brewComes = c -> (push!(ran, c); push!(have, "brew"); true)
            function offer(pick; runner = c -> (push!(ran, c); true), os = :macos)
                empty!(ran)
                return offerInstall(IOBuffer(), sixel, os; which, runner,
                    ask = (p, c) -> pick)
            end
            @test [offer(k) for k in (0, 2)] == ["later", "no"]
            @test isempty(ran)  # nothing runs without the Yes
            io = IOBuffer()
            offerInstall(io, sixel, :macos; which, runner = c -> true,
                ask = (p, c) -> (@test c == ["Yes", "No"]; 2))
            @test occursin(SetupWizard.ITERM_PAGE, String(take!(io)))  # the page is named
            # the installer fails, or ends without Homebrew: iTerm2 is not tried
            @test offer(1; runner = c -> (push!(ran, c); false)) == "later"
            @test length(ran) == 1
            @test offer(1) == "later" && length(ran) == 1
            @test offer(1; runner = brewComes) == "yes"
            @test ran[1] == SetupWizard.BREW_INSTALL
            @test ran[2] == Cmd(["/fake/bin/brew", "install", "--cask", "iterm2"])
            # Homebrew is there now: the plain offer
            @test offer(1) == "yes" && only(ran) == ran[1] && "install" in ran[1].exec
            # iTerm2 installed, but BAYSOL runs in Terminal: nothing to install
            r = scanDependencies([sixel]; env = Dict("TERM_PROGRAM" => "Apple_Terminal"),
                which = fakeWhich("iTerm.app"), dims = big)
            @test only(r).found && occursin("iTerm2 is installed", only(r).detail)
            r = scanDependencies([sixel]; env = Dict("TERM_PROGRAM" => "Apple_Terminal"),
                which = fakeWhich("WezTerm.app"), dims = big)
            @test only(r).found && occursin("WezTerm is installed", only(r).detail)
        end
        @testset "Terminal font on macOS" begin
            font = only(i for i in items if i.id == "font")
            mac = Dict("TERM_PROGRAM" => "Apple_Terminal")
            found(f; env = mac, w = fakeWhich("osascript")) =
                SetupWizard._detectFont(env, w; read = _ -> f).found
            @test !found("SFMono-Regular 11") && !found("SFMono-Bold 14")
            @test found("Menlo-Regular 14")
            # not asked: the font is unknown, or it is another terminal
            @test found(nothing) && found("") && found("SFMono-Regular 11"; w = fakeWhich())
            @test found("SFMono-Regular 11"; env = Dict("TERM_PROGRAM" => "iTerm.app"))
            @test SetupWizard._macFont("/no/such/osascript") === nothing
            for os in (:linux, :windows)
                r = scanDependencies([font]; os, env = mac, which = fakeWhich(), dims = big)
                @test !only(r).applicable
            end
            # changed only after an explicit yes
            ran = Cmd[]
            offer(pick, io = IOBuffer()) = offerInstall(io, font, :macos;
                which = fakeWhich("osascript"), runner = c -> (push!(ran, c); true),
                ask = (p, c) -> (@test c == ["Yes", "No"]; pick))
            @test [offer(k) for k in (0, 2)] == ["later", "no"]
            @test isempty(ran)
            io = IOBuffer()
            @test offer(1, io) == "yes"
            @test only(ran) ==
                  Cmd(["/fake/bin/osascript", "-e", SetupWizard.MAC_FONT_SET])
            text = String(take!(io))
            @test occursin("osascript -e 'tell", text) && occursin("to undo", text)
            report = IOBuffer()
            dependencyReport(report, [DepResult(font, true, false, "SFMono-Regular 11")])
            @test occursin("suggestion", String(take!(report)))
        end
        @testset "Terminal spacing on macOS" begin
            spacing = only(i for i in items if i.id == "spacing")
            mac = Dict("TERM_PROGRAM" => "Apple_Terminal")
            found(x; env = mac) =
                SetupWizard._detectSpacing(env, fakeWhich(); read = _ -> x).found
            @test found((1.0, 1.0)) && found(nothing)
            @test !found((1.004032258064516, 1.0)) && !found((1.0, 1.1))
            @test !found((0.9959677419354839, 1.0))
            @test found((1.2, 1.2); env = Dict("TERM_PROGRAM" => "iTerm.app"))
            @test SetupWizard._macSpacing(fakeWhich()) === nothing
            @test SetupWizard._macSpacing(fakeWhich("osascript", "defaults", "plutil")) ===
                  nothing
            parsed = SetupWizard._parseSpacing
            @test parsed("<dict></dict>") == (1.0, 1.0)
            @test parsed(
                "<key>FontWidthSpacing</key>\n\t<real>1.004</real>" *
                "<key>FontHeightSpacing</key><integer>2</integer>",
            ) == (1.004, 2.0)
            ran = Cmd[]
            texts = String[]
            answers = map(0:2) do k
                io = IOBuffer()
                a = offerInstall(io, spacing, :macos; which = fakeWhich(),
                    runner = c -> (push!(ran, c); true),
                    ask = (p, c) -> (@test c == ["Yes", "No"]; k))
                push!(texts, String(take!(io)))
                a
            end
            @test answers == ["later", "yes", "no"]
            @test isempty(ran)  # Terminal has no command: the steps are shown, not run
            steps = "character spacing and line spacing to 1.0"
            @test occursin(steps, texts[2])  # a Yes shows the steps
            @test !occursin(steps, texts[1]) && !occursin(steps, texts[3])
            @test !any(occursin("I changed it", t) for t in texts)
        end
        @testset "report content" begin
            r = scanDependencies(items; os = :linux, env = Dict{String,String}(),
                which = fakeWhich("lualatex"), dims = big)
            io = IOBuffer()
            dependencyReport(io, r)
            text = String(take!(io))
            @test occursin("present", text) && occursin("lualatex", text)
            @test occursin("missing (optional)", text) && occursin("Sixel", text)
            @test occursin("hint", text)
            @test occursin("Unicode plots", text)
            @test !occursin("Julia required", text)
            gone = [DepResult(items[1], false, false, "")]
            io = IOBuffer()
            dependencyReport(io, gone)
            @test occursin("not applicable", String(take!(io)))
            # the check never looks for what the bundle carries
            @test !any(
                occursin(p, lowercase(join([i.id * i.name for i in items])))
                for p in ("julia", "node", "python", "7-zip", "7za")
            )
            @test all(i -> i.level in (:optional, :info), items)
        end
        # an answers sequence: asks are scripted, installs are recorded and never run
        script(picks) =
            (p = copy(picks); (prompt, choices) -> isempty(p) ? 0 : popfirst!(p))
        latexOnly = [items[1]]
        @testset "no install without a yes; admin and missing manager" begin
            ran = Cmd[]
            runner = c -> (push!(ran, c); true)
            io = IOBuffer()
            # macOS cask needs admin: a note with the command, never a question, never run
            noAsk = (p, c) -> (@test false; 1)
            a = offerInstall(io, items[1], :macos; which = fakeWhich("brew"), runner,
                ask = noAsk)
            out = String(take!(io))
            @test a == "later" && isempty(ran)
            @test occursin("sudo brew install --cask mactex-no-gui", out)
            @test occursin("administrator rights", out)
            # Windows has no route for TeX Live: the manual text as a note
            a = offerInstall(io, items[1], :windows; which = fakeWhich("winget"), runner,
                ask = noAsk)
            @test a == "later" && isempty(ran)
            @test occursin("install-tl", String(take!(io)))
            # a route whose manager is missing falls back to the manual text
            a = offerInstall(io, items[1], :linux; which = fakeWhich(), runner,
                ask = noAsk)
            out = String(take!(io))
            @test a == "later" && isempty(ran)
            @test occursin("No package manager found", out) &&
                  occursin("texlive packages", out)
            # a runnable route (winget, no admin): Yes or No, only the Yes runs it
            term = items[2]
            prompts = Vector{String}[]
            ask(pick) = (p, c) -> (push!(prompts, c); pick)
            a = offerInstall(io, term, :windows; which = fakeWhich("winget"), runner,
                ask = ask(2))  # No
            @test a == "no" && isempty(ran)
            a = offerInstall(io, term, :windows; which = fakeWhich("winget"), runner,
                ask = ask(0))  # menu cancelled
            @test a == "later" && isempty(ran)
            a = offerInstall(io, term, :windows; which = fakeWhich("winget"), runner,
                ask = ask(1))  # Yes
            @test a == "yes" && length(ran) == 1
            @test all(==(["Yes", "No"]), prompts)
            @test ran[1] == Cmd(["/fake/bin/winget", "install", "--id",
                "Microsoft.WindowsTerminal", "-e"])
            # a failing install is "later", not "yes"
            a = offerInstall(io, term, :windows; which = fakeWhich("winget"),
                runner = c -> false, ask = ask(1))
            @test a == "later"
        end
        @testset "answers are remembered in install.json" begin
            d = mktempdir()
            e = placeEnv(d)
            file = installFile(; env = e, home = d)
            ran = Cmd[]
            runner = c -> (push!(ran, c); true)
            env0 = Dict{String,String}()
            asks = String[]
            run1(picks; kw...) = checkDependencies(IOBuffer(); env = e, home = d,
                os = :windows, which = fakeWhich("winget"), runner, dims = big,
                detect = (i, en, w, dm) -> SetupWizard._detect(i, env0, w, dm),
                ask = (p, c) -> (push!(asks, p); popfirst!(picks)), kw...)
            # before the first setup there is no file: nothing is written
            run1([2]; items)  # sixel: No (TeX Live is a note: no question)
            @test !isfile(file) && isempty(ran)
            # the folder of install.json exists once set up
            # (folders that can be made: the apply below makes them)
            h = joinpath(d, "h")
            i = Install(; home = h, structureCache = joinpath(d, "s"), threads = 2)
            writeInstall(file, i)
            empty!(asks)
            # latex: Windows has no route (a note); sixel: winget route, Yes
            run1([1])
            @test length(asks) == 1
            @test readDepAnswers(file) == Dict("latex" => "later", "sixel" => "yes")
            @test length(ran) == 1
            back = readInstall(file)
            @test back.threads == 2 && back.home == h  # other fields kept
            @test occursin("\"dep.latex\": \"later\"", read(file, String))
            # asked again for a missing item after "yes" (sixel is still not detected here)
            empty!(asks)
            run1([2])  # sixel: No
            @test length(asks) == 1
            @test readDepAnswers(file) == Dict("latex" => "later", "sixel" => "no")
            # the first run does not ask "no" again
            empty!(asks)
            run1(Int[]; firstRun = true)
            @test isempty(asks)
            # the menu asks "no" again
            empty!(asks)
            run1([2])
            @test length(asks) == 1
            # a "never" stored by an older version is still honoured, never asked
            @test saveDepAnswers(Dict("latex" => "never", "sixel" => "never");
                env = e, home = d)
            empty!(asks)
            run1(Int[])
            @test isempty(asks)
            # applying a setup again keeps the answers (Repair uses the current ones)
            cur = readInstall(file)
            applyInstall(cur, d; env = e, home = d)
            @test readDepAnswers(file) == Dict("latex" => "never", "sixel" => "never")
        end
        @testset "an old install.json still reads" begin
            d = mktempdir()
            f = joinpath(d, "install.json")
            write(
                f,
                """
           {
               "home": "/h",
               "cache": "/c",
               "structureCache": "/s",
               "desktop": true,
               "threads": 4,
               "opens": "cli"
           }
           """,
            )
            i = readInstall(f)
            @test i !== nothing && i.opens == "cli" && i.threads == 4 && i.desktop
            @test isempty(i.deps)
            # the old `cache` key is ignored and not written back
            out = joinpath(d, "out.json")
            writeInstall(out, i)
            @test !occursin("\"cache\"", read(out, String))
            @test readInstall(out) == i
            @test isempty(readDepAnswers(f)) && isempty(readDepAnswers(f * ".none"))
            # an unknown answer word is ignored, a known one is read
            write(
                f,
                "{\"home\":\"/h\",\"cache\":\"/c\",\"structureCache\":\"/s\"," *
                "\"dep.latex\":\"bogus\",\"dep.sixel\":\"no\"}",
            )
            @test readDepAnswers(f) == Dict("sixel" => "no")
        end
        @testset "rollback restores install.json with its answers" begin
            d = mktempdir()
            e = placeEnv(d)
            file = installFile(; env = e, home = d)
            i = Install(;
                home = joinpath(d, "h"),
                structureCache = joinpath(d, "s"),
                deps = Dict("latex" => "never"),
            )
            writeInstall(file, i)
            journal = Function[]
            applyInstall(
                Install(; home = joinpath(d, "h2"), structureCache = joinpath(d, "s")), d;
                env = e, home = d, journal)
            @test isempty(readDepAnswers(file))
            rollback!(journal)
            @test readInstall(file) == i
        end
    end

    @testset "clock" begin
        S = SetupWizard
        tm(h, m, sec, wday) = Libc.TmStruct(sec, m, h, 27, 10, 126, wday, 0, 0)
        @test formatClock(tm(14, 3, 22, 5); offsetMinutes = 60, zone = "CET") ==
              "Fri, 27 Nov 2026, 14:03:22-CET (UTC+01:00)"
        @test formatClock(tm(0, 0, 0, 0); offsetMinutes = -330, zone = "X") ==
              "Sun, 27 Nov 2026, 00:00:00-X (UTC-05:30)"
        @test formatClock(tm(23, 59, 59, 3); offsetMinutes = 0, zone = "UTC") ==
              "Wed, 27 Nov 2026, 23:59:59-UTC (UTC+00:00)"
        @test formatClock(tm(9, 5, 7, 6); offsetMinutes = 60) ==
              "Sat, 27 Nov 2026, 09:05:07 (UTC+01:00)"
        # the offset from the C library agrees with a known date arithmetic
        @test S._daysFromCivil(1970, 1, 1) == 0 && S._daysFromCivil(2000, 3, 1) == 11017
        @test S.localOffsetMinutes(0) % 15 == 0 && abs(S.localOffsetMinutes()) <= 14 * 60
        # the zone: a short name is kept, a long (Windows) one dropped, a failure is empty
        @test S.localZoneName(0; format = (f, t) -> "CET\n") == "CET"
        @test S.localZoneName(0; format = (f, t) -> "Central European Standard Time") == ""
        @test S.localZoneName(0; format = (f, t) -> error("no")) == ""
        # the width fits the longest text, the frame is one string with save and restore
        w = S.clockWidth("CET")
        @test w == ncodeunits("Wed, 27 Nov 2026, 23:59:59-CET (UTC+01:00)")
        f = S.clockFrame("Fri, 27 Nov 2026, 14:03:22-CET (UTC+01:00)", 24, 80, w)
        @test startswith(f, "\e7\e[24;$(80 - w)H") && endswith(f, "\e8")
        @test occursin("H" * "Fri, 27 Nov 2026, 14:03:22-CET (UTC+01:00)", f)
        @test occursin(
            "  Fri, 27 Nov 2026, 14:03:22 (UTC+01:00)",
            S.clockFrame("Fri, 27 Nov 2026, 14:03:22 (UTC+01:00)", 24, 80, w),
        )
        @test occursin(" "^w, S.clockFrame("", 24, 80, w; blank = true))
        # the writer on a buffer with a fake size; time and zone are given
        out = IOBuffer()
        fake =
            (sz) -> startClock(out; size = () -> sz, zone = "CET", interval = 3600,
                now = () -> (tm(14, 3, 22, 5), 60))
        c = fake((24, 80))
        @test clockTick!(c)
        @test occursin("Fri, 27 Nov 2026, 14:03:22-CET (UTC+01:00)", String(take!(out)))
        # paused: nothing is written (the line is cleared once), resumed: it ticks again
        pauseClock!(c)
        cleared = String(take!(out))
        @test occursin("\e7", cleared) && !occursin("Friday", cleared)
        @test !clockTick!(c) && isempty(take!(out))
        resumeClock!(c)
        @test clockTick!(c)
        take!(out)
        # a terminal too small: not drawn, and what was drawn is cleared
        c.size = () -> (9, 80)
        @test !clockTick!(c) && !c.drawn
        take!(out)
        c.size = () -> (24, 59)
        @test !clockTick!(c) && isempty(take!(out))
        # stopping ends the task, clears the line, is idempotent, and nothing ticks after
        c.size = () -> (24, 80)
        @test clockTick!(c)
        take!(out)
        stopClock!(c)
        @test istaskdone(c.task) && !c.drawn
        @test occursin("\e7", String(take!(out)))
        stopClock!(c)
        @test !clockTick!(c) && isempty(take!(out))
        stopClock!(nothing)
        # the task ticks by itself on a short interval, and stops at once
        out2 = IOBuffer()
        c2 = startClock(out2; size = () -> (24, 80), zone = "", interval = 0.05,
            now = () -> (tm(1, 2, 3, 4), 0))
        sleep(0.4)
        stopClock!(c2)
        @test istaskdone(c2.task)
        @test count("Thu, 27 Nov 2026, 01:02:03 (UTC+00:00)", String(take!(out2))) >= 2
        # no clock without a terminal or on a dumb one; _quiet pauses the active clock
        @test !S.clockWanted(IOBuffer(), Dict("TERM" => "xterm"))
        c3 = fake((24, 80))
        S.ACTIVE_CLOCK[] = c3
        S._quiet() do
            @test c3.paused
        end
        @test !c3.paused
        S.ACTIVE_CLOCK[] = nothing
        stopClock!(c3)
        @test S._quiet(() -> 7) == 7
    end
    @testset "icon" begin
        S = SetupWizard
        @test allequal(length.(S.ICON_CELLS))
        @test length(S.ICON_CELLS) <= 5 && length(S.ICON_CELLS[1]) <= 10
        @test all(c -> haskey(S.ICON_RGB, c) && haskey(S.ICON_256, c), join(S.ICON_CELLS))
        for truecolor in (true, false)
            drawn = sprint(io -> S.drawIcon(io; color = true, truecolor))
            @test count('\n', drawn) == length(S.ICON_CELLS)
            @test isempty(strip(replace(drawn, r"\e\[[0-9;]*m" => "")))  # spaces only
            @test !occursin('▀', drawn)
            @test occursin(truecolor ? "48;2;" : "48;5;", drawn)
        end
        # no colour: plain text, no escape codes, an ASCII box
        plain = sprint(io -> S.drawIcon(io; color = false))
        @test !occursin('\e', plain) && occursin("BAYSOL", plain) && isascii(plain)
        @test count('\n', plain) == length(S.ICON_PLAIN)
        # a buffer is not a terminal, NO_COLOR and a dumb terminal turn the colour off
        @test !S.useColor(IOBuffer(), Dict{String,String}())
        @test sprint(io -> S.drawIcon(io)) == plain
    end
end
