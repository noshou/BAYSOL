# SPDX-License-Identifier: LGPL-3.0-or-later

# The setup wizard of BAYSOL (`baysol setup`): a welcome page, the folders of the user's
# data and caches, the options that depend on a path (desktop entry, PATH link), and the
# uninstall (the app only, or the data as well). It is independent of the terminal
# interface and of the fitting code: standard library only (`REPL.TerminalMenus` for the
# menus), so it starts at once. Install-time facts live in `install.json`, apart from
# `settings.json` (settings are runtime things). A change is read by the interface when
# it is started again.

module SetupWizard

using REPL.TerminalMenus: RadioMenu, MultiSelectMenu, request
using REPL.Terminals: TTYTerminal, raw!

include(joinpath(@__DIR__, "..", "..", "platform.jl"))
include(joinpath(@__DIR__, "dependencies.jl"))  # the optional-dependency check

export formatClock, startClock, stopClock!, pauseClock!, resumeClock!, clockTick!,
    parseYesNo, parseThreads, describeInstall, startNow, advancedMenu,
    clearCache, openFolder, fileManagerCommands, shellCommand, drawIcon, needsSetup,
    hasProject, check, cleanPath, Install, defaultInstall,
    installFile, manifestFile, readManifest, readInstall, writeInstall, applyInstall,
    rollback!, uninstall, runWizard,
    DepItem, Route, DepResult, defaultItems, scanDependencies, dependencyReport,
    checkDependencies, offerInstall, readDepAnswers, saveDepAnswers,
    LAUNCH_TUI, LAUNCH_CLI, UNINSTALLED

"The marker file of a cache folder (the one the interface writes)."
const CACHE_TAG = "CACHEDIR.TAG"

"The exit status of the wizard when the user chose to start the terminal interface."
const LAUNCH_TUI = 20

"The exit status when the user chose the command line (the launcher shows its help)."
const LAUNCH_CLI = 21

"The exit status after an uninstall: the app is gone, so a caller must not carry on."
const UNINSTALLED = 22

"The word the user types to confirm that all the data is deleted."
const CONFIRM_WORD = "delete"

"The threads a fit uses by default: the machine's, at most `MAX_THREADS` (one per chain)."
const MAX_THREADS = 8
defaultThreads() = clamp(Sys.CPU_THREADS, 1, MAX_THREADS)

"""
The sixel terminals of macOS that the icon can open, in order of preference: the id in
`install.json`, the name, the app, and the arguments of `open` after `-a <app>` that run
`\$command`. kitty, Ghostty and Warp are not here: they draw no sixel.
"""
const MAC_TERMINALS = (
    (id = "iterm2", name = "iTerm2", app = "iTerm.app", args = "\"\$command\""),
    (id = "wezterm", name = "WezTerm", app = "WezTerm.app",
        args = "-n --args start -- \"\$command\""),
)

"What `terminal` of an [`Install`](@ref) can be."
const MAC_TERMINAL_IDS = ("auto", "terminal", (t.id for t in MAC_TERMINALS)...)

"""
What the wizard decides. `home` is the BAYSOL folder (projects), `structureCache` THE cache
folder (the structures that later runs reuse; what the fit reads as `BAYSOL_CACHE`; the
wizard calls it the cache folder, the JSON key keeps its old name); `desktop` says whether
the entry in the application menu is made, `desktopIcon` whether the launcher is also put
on the Desktop, `taskbarPin` whether it is pinned to the taskbar or dock, and `pathLink`
whether the link on the PATH is made; `threads` is the default number of threads of a fit;
`opens` says what the launcher (the icon, or `baysol` alone) starts: `"tui"` (the terminal
interface) or `"cli"` (a shell with the command line ready). `terminal` is the terminal
that the icon of macOS opens: `"auto"` (the first sixel terminal that is installed, else
Terminal), `"terminal"` or an id of `MAC_TERMINALS`. `deps` holds the answers about the
optional dependencies (`id => "yes" | "no" | "later" | "never"`, see `dependencies.jl`; no
question gives `never` any more, but an `install.json` of an older version that holds it is
still read and honoured); an `install.json` without them reads as no answers.
"""
Base.@kwdef struct Install
    home::String
    structureCache::String
    desktop::Bool = false
    desktopIcon::Bool = false
    taskbarPin::Bool = false
    pathLink::Bool = false
    threads::Int = defaultThreads()
    opens::String = "tui"
    terminal::String = "auto"
    deps::Dict{String,String} = Dict{String,String}()
end

# the answers are a Dict (mutable), which the default `==` of a struct compares by identity
Base.:(==)(a::Install, b::Install) =
    a.home == b.home && a.structureCache == b.structureCache &&
    a.desktop == b.desktop && a.desktopIcon == b.desktopIcon &&
    a.taskbarPin == b.taskbarPin && a.pathLink == b.pathLink &&
    a.threads == b.threads && a.opens == b.opens && a.terminal == b.terminal &&
    a.deps == b.deps

# ---- the folders of the system (XDG on Linux, the usual ones elsewhere) ---------------

_env(env, name) = (v = strip(get(env, name, "")); isabspath(v) ? v : nothing)

"The data folder of the system: where `baysol/` (the projects) goes by default."
dataHome(; env = ENV, home = homedir()) = Platform.data_home(; env, home)

"The folder of `install.json`: the configuration folder of the system, never the data."
configHome(; env = ENV, home = homedir()) = Platform.config_home(; env, home)

"""
    installFile(; env, home) -> String

The path of `install.json`.

# Returns
The file, `<configuration folder>/baysol/install.json`.

# Exceptions
None.
"""
installFile(; env = ENV, home = homedir()) =
    joinpath(configHome(; env, home), "baysol", "install.json")

"""
    defaultInstall(; env, home) -> Install

The defaults: the projects in the data folder of the system, the cache in its cache
folder. Where the system has one folder for both (Windows: `%LOCALAPPDATA%`), the cache
would land inside the projects folder (`...\\baysol\\_structures`), so it goes to the
sibling `baysol-cache` instead; the projects folder stays where earlier installs put
it. The rule is `Platform.cache_dir`, the one default of the whole project.

# Returns
An [`Install`](@ref) with the application menu entry and, except on Windows, the PATH
link switched on (a plain Enter at the first setup gives an icon and a `baysol` command);
the Desktop icon and the taskbar pin are off.

# Exceptions
None.
"""
function defaultInstall(; env = ENV, home = homedir())
    return Install(; home = joinpath(dataHome(; env, home), "baysol"),
        structureCache = Platform.default_structure_cache(; env, home),
        desktop = true, pathLink = Platform.os() != :windows)
end

"Whether `path` is `dir` or inside it (compared on normal paths, any case on Windows)."
_within(path::AbstractString, dir::AbstractString) = Platform.within(path, dir)

# ---- install.json: a flat object of strings and booleans ------------------------------

_quote(s::AbstractString) = "\"" * replace(s, "\\" => "\\\\", "\"" => "\\\"") * "\""

"""
    writeInstall(file, install)

Writes `install` as a flat JSON object, atomically (a temporary file renamed over it).

# Returns
`file`.

# Exceptions
An `IOError` if the folder cannot be made or written.
"""
function writeInstall(file::AbstractString, i::Install)
    mkpath(dirname(file))
    rows = [
        "home" => _quote(i.home),
        "structureCache" => _quote(i.structureCache),
        "desktop" => string(i.desktop), "desktopIcon" => string(i.desktopIcon),
        "taskbarPin" => string(i.taskbarPin), "pathLink" => string(i.pathLink),
        "threads" => string(i.threads), "opens" => _quote(i.opens),
        "terminal" => _quote(i.terminal),
    ]
    for k in sort!(collect(keys(i.deps)))
        push!(rows, "dep.$k" => _quote(i.deps[k]))
    end
    tmp = file * ".tmp"
    write(tmp, "{\n" * join(["    \"$k\": $v" for (k, v) in rows], ",\n") * "\n}\n")
    mv(tmp, file; force = true)
    return file
end

"""
    readInstall(file) -> Union{Install, Nothing}

Reads an `install.json` written by [`writeInstall`](@ref).

# Returns
The [`Install`](@ref), or `nothing` if the file is missing or unreadable (a damaged file is
treated as no file; the wizard then offers the defaults).

# Exceptions
None.
"""
function readInstall(file::AbstractString)
    isfile(file) || return nothing
    text = read(file, String)
    str(k) = (m = match(Regex("\"$k\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""), text);
        m === nothing ? nothing : replace(m[1], r"\\(.)" => s"\1"))
    bool(k) = (
        m = match(Regex("\"$k\"\\s*:\\s*(true|false)"), text);
        m !== nothing &&
            m[1] == "true"
    )
    # an older file may still hold a `cache` key: it is ignored, and not written back
    (h, s) = (str("home"), str("structureCache"))
    any(isnothing, (h, s)) && return nothing
    t = match(r"\"threads\"\s*:\s*(\d+)", text)
    deps = Dict{String,String}()
    for m in eachmatch(r"\"dep\.([a-z0-9]+)\"\s*:\s*\"(yes|no|later|never)\"", text)
        deps[String(m[1])] = String(m[2])
    end
    return Install(; home = h, structureCache = s,
        desktop = bool("desktop"), desktopIcon = bool("desktopIcon"),
        taskbarPin = bool("taskbarPin"), pathLink = bool("pathLink"),
        threads = t === nothing ? defaultThreads() : parse(Int, t[1]),
        opens = str("opens") in ("tui", "cli") ? str("opens") : "tui",
        terminal = str("terminal") in MAC_TERMINAL_IDS ? str("terminal") : "auto", deps)
end

"""
    needsSetup(; env, home) -> Bool

Whether BAYSOL has not been set up yet: no `install.json`, or a blank folder in it.

# Returns
`true` if the wizard should run before the interface.

# Exceptions
None.
"""
function needsSetup(; env = ENV, home = homedir())
    i = readInstall(installFile(; env, home))
    return i === nothing || any(isempty ∘ strip, (i.home, i.structureCache))
end

"A folder as the user typed it: `~` expanded, made absolute and normal."
function cleanPath(text::AbstractString; home = homedir())
    t = strip(text)
    t == "~" && return home
    any(c -> startswith(t, "~$c"), Platform.DIR_SEPARATORS) &&
        (t = joinpath(home, t[3:end]))
    isabspath(t) || (t = joinpath(home, t))  # a relative name is under the home folder
    p = normpath(t)
    # no trailing separator, but a root (`/`, `C:\`) keeps its own
    q = rstrip(p, Platform.DIR_SEPARATORS)
    return isempty(splitdrive(q)[2]) ? p : q
end

# ---- the path-dependent install options -----------------------------------------------

"""
The icon at the root of the bundle: `baysol.ico` on Windows, `baysol.icns` on macOS (the
hand-made `icons/icon.icns` as it is) and the folder `icons` on Linux, where `bysl pkg`
copies the hand-made PNG sizes as `icons/hicolor/<size>/baysol.png`, nothing is resized.
On Linux the wizard copies those files into the user's `hicolor` theme.
"""
const ICON_FILE =
    Platform.iswindows() ? "baysol.ico" : Platform.ismacos() ? "baysol.icns" : "icons"

"""
The `.icns` an older Linux bundle carries instead of the `icons` folder; the wizard still
unpacks the sizes of it ([`iconPngs`](@ref)) when the folder is missing.
"""
const LEGACY_ICNS = "baysol.icns"

"The icon name of the desktop entries; the theme finds the size that fits."
const ICON_NAME = "baysol"

"The icon name of the entries when the bundle has no PNG sizes to install."
const ICON_FALLBACK = "application-x-executable"

"The `hicolor` folder of each pixel size the theme lists (1024 is the `@2` of 512)."
const HICOLOR_SIZES = Dict(
    16 => "16x16", 22 => "22x22", 24 => "24x24", 32 => "32x32", 48 => "48x48",
    64 => "64x64", 128 => "128x128", 256 => "256x256", 512 => "512x512",
    1024 => "512x512@2",
)

"The PNG signature, which starts every PNG entry of an `.icns` and every PNG file."
const PNG_SIGNATURE = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

"""
    iconPngs(icns) -> Vector{Pair{Int,Vector{UInt8}}}

The PNG images of an `.icns` file as `pixels => bytes`, one per size (the first entry of a
size wins; an entry that is not a square PNG is skipped).

# Returns
The images, empty when the file is missing or not an `.icns`.

# Exceptions
None.
"""
function iconPngs(icns::AbstractString)::Vector{Pair{Int,Vector{UInt8}}}
    out = Pair{Int,Vector{UInt8}}[]
    isfile(icns) || return out
    d = read(icns)
    (length(d) >= 8 && d[1:4] == codeunits("icns")) || return out
    be(at) = Int(ntoh(only(reinterpret(UInt32, d[at:(at+3)]))))
    i = 9
    while i + 7 <= length(d)
        n = be(i + 4)
        n < 8 && break
        body = d[(i+8):min(i+n-1, length(d))]
        if length(body) >= 24 && body[1:8] == PNG_SIGNATURE
            w = Int(ntoh(only(reinterpret(UInt32, body[17:20]))))
            h = Int(ntoh(only(reinterpret(UInt32, body[21:24]))))
            w == h && !any(p -> first(p) == w, out) && push!(out, w => body)
        end
        i += n
    end
    return sort!(out; by = first)
end

"""
    bundleIcons(bundle) -> Vector{Pair{Int,Vector{UInt8}}}

The icon sizes of `bundle` as `pixels => PNG bytes`, smallest first: the files
`icons/hicolor/<size>/baysol.png` (a folder the theme lists, see `HICOLOR_SIZES`), or, in an
older bundle without that folder, the entries of its `baysol.icns` ([`iconPngs`](@ref)).

# Returns
The images, empty when the bundle has neither.

# Exceptions
None.
"""
function bundleIcons(bundle::AbstractString)::Vector{Pair{Int,Vector{UInt8}}}
    root = joinpath(bundle, ICON_FILE, "hicolor")
    isdir(root) || return iconPngs(joinpath(bundle, LEGACY_ICNS))
    out = Pair{Int,Vector{UInt8}}[]
    for (px, folder) in HICOLOR_SIZES
        file = joinpath(root, folder, ICON_NAME * ".png")
        isfile(file) || continue
        bytes = read(file)
        length(bytes) >= 8 && bytes[1:8] == PNG_SIGNATURE && push!(out, px => bytes)
    end
    return sort!(out; by = first)
end

"The `hicolor` theme folder of the user."
hicolorDir(; env = ENV, home = homedir()) =
    joinpath(dataHome(; env, home), "icons", "hicolor")

"The files of the icon in `hicolor` for the pixel sizes `sizes`."
iconFiles(sizes; env = ENV, home = homedir()) = [
    joinpath(hicolorDir(; env, home), HICOLOR_SIZES[px], "apps", ICON_NAME * ".png")
    for px in sizes if haskey(HICOLOR_SIZES, px)
]

"Tells the desktops about changed icons: a stale cache would hide them."
function _refreshIcons(; env = ENV, home = homedir())
    dir = hicolorDir(; env, home)
    isdir(dir) || return nothing
    try
        # utimes with no times sets both to now: the desktops see the folder changed
        ccall(:utimes, Cint, (Cstring, Ptr{Cvoid}), dir, C_NULL)
    catch
    end
    if isfile(joinpath(dir, "icon-theme.cache")) &&
       Platform.which("gtk-update-icon-cache") !== nothing
        try
            run(pipeline(`gtk-update-icon-cache -q -t -f $dir`; stderr = devnull))
        catch
        end
    end
    return nothing
end

"""
Puts the sizes of the bundle's icon into the user's `hicolor` theme (Linux), each file
exactly as it is in the bundle, and returns whether any went in, with a line to say so.
Every file and folder is undone by `journal` and noted in `made` (the manifest).
"""
function _installIcons!(journal, made, bundle; env = ENV, home = homedir())
    pngs = [p for p in bundleIcons(bundle) if haskey(HICOLOR_SIZES, first(p))]
    if isempty(pngs)
        return false, "icon: no PNG sizes in $ICON_FILE, the entries use a generic icon"
    end
    files = iconFiles(first.(pngs); env, home)
    for (file, (_, bytes)) in zip(files, pngs)
        _madeDir!(made, journal, dirname(file))
        _backup!(journal, file)
        write(_madeFile!(made, file), bytes)
    end
    _refreshIcons(; env, home)
    return true, "icon: $(length(files)) sizes in $(hicolorDir(; env, home))"
end

"""
Tells the desktops about a changed folder of entries (`update-desktop-database`, when the
program is installed; a missing one is ignored).
"""
function _refreshEntries(dir::AbstractString)
    isdir(dir) && Platform.which("update-desktop-database") !== nothing || return nothing
    try
        run(pipeline(`update-desktop-database -q $dir`; stderr = devnull))
    catch
    end
    return nothing
end

"The desktop entry of a bundle: absolute paths, as the specification asks."
function desktopEntry(bundle::AbstractString; icon::AbstractString = ICON_NAME)
    return """
        [Desktop Entry]
        Type=Application
        Name=BAYSOL
        Icon=$icon
        Comment=Bayesian CRYSOL
        Exec="$(joinpath(bundle, "baysol"))"
        Path=$(homedir())
        Terminal=true
        Categories=Science;
        """
end

"The places the options write to (so a test can point them into a temporary folder)."
function targets(; env = ENV, home = homedir())
    apps =
        Platform.ismacos() ? joinpath(home, "Applications") :
        joinpath(something(_env(env, "XDG_DATA_HOME"),
            joinpath(home, ".local", "share")), "applications")
    startMenu = joinpath(something(_env(env, "APPDATA"),
        joinpath(home, "AppData", "Roaming")),
        "Microsoft", "Windows", "Start Menu", "Programs")
    return (desktop = joinpath(apps, "baysol.desktop"),
        icon = joinpath(desktopDir(; env, home), "BAYSOL.desktop"),
        link = joinpath(home, ".local", "bin", "baysol"),
        app = joinpath(home, "Applications", "BAYSOL.app"),
        macIcon = joinpath(desktopDir(; env, home), "BAYSOL.app"),
        lnk = joinpath(startMenu, "BAYSOL.lnk"),
        ico = joinpath(dirname(installFile(; env, home)), "baysol.ico"))
end

"""
    desktopDir(; env, home) -> String

The Desktop folder: on Linux the `XDG_DESKTOP_DIR` of `user-dirs.dirs` (the name can be
localised), else `~/Desktop`; the same `~/Desktop` on macOS and Windows.

# Returns
The folder (it may not exist).

# Exceptions
None.
"""
function desktopDir(; env = ENV, home = homedir())
    fallback = joinpath(home, "Desktop")
    Platform.islinux() || return fallback
    file = joinpath(configHome(; env, home), "user-dirs.dirs")
    isfile(file) || return fallback
    m = match(r"^\s*XDG_DESKTOP_DIR=\"([^\"]+)\"\s*$"m, read(file, String))
    m === nothing && return fallback
    d = replace(m[1], "\$HOME" => home)
    return isabspath(d) ? d : fallback
end

# ---- the taskbar pin: GNOME's favourites (the one desktop with a stable interface) -----

"The id of the entry in the application menu, which is what a pin refers to."
const PIN_ID = "baysol.desktop"

"Whether this session is GNOME (the pin is only made there)."
_gnome(env) = occursin("GNOME", uppercase(get(env, "XDG_CURRENT_DESKTOP", "")))

"The favourites of GNOME as a list, or `nothing` if `gsettings` cannot say."
function _favorites()
    Platform.which("gsettings") === nothing && return nothing
    try
        text = read(pipeline(`gsettings get org.gnome.shell favorite-apps`;
            stderr = devnull), String)
        return String[m[1] for m in eachmatch(r"'([^']*)'", text)]
    catch
        return nothing
    end
end

"Sets the favourites of GNOME to `list`."
function _setFavorites(list)
    value = "[" * join(["'$x'" for x in list], ", ") * "]"
    run(`gsettings set org.gnome.shell favorite-apps $value`)
end

"`list` with `id` added (once, at the end)."
_pinned(list, id) = id in list ? list : [list; id]

"`list` without `id`."
_unpinned(list, id) = filter(!=(id), list)

"""
Pins the entry to the taskbar where that is possible and says what was done. GNOME is
the only desktop done: KDE, macOS and Windows are told to pin by hand.
"""
function _pin!(journal, env)
    if !Platform.islinux()
        return "taskbar pin skipped (Linux with GNOME only; pin it by hand)"
    elseif !_gnome(env)
        return "taskbar pin skipped (not GNOME; open the menu entry, right click, pin it)"
    end
    old = _favorites()
    old === nothing && return "taskbar pin skipped (gsettings is not available)"
    if PIN_ID in old
        return "taskbar pin already there"
    end
    _setFavorites(_pinned(old, PIN_ID))
    push!(journal, () -> _setFavorites(old))
    return "pinned to the taskbar"
end

"The `CFBundleIdentifier` of `BAYSOL.app`, which names its Dock entry."
const MAC_BUNDLE_ID = "org.baysol.app"

"The property list of the Dock, where its entries are kept."
_dockPlist(home = homedir()) =
    joinpath(home, "Library", "Preferences", "com.apple.dock.plist")

"The program that reads and edits a property list on macOS."
const PLIST_BUDDY = "/usr/libexec/PlistBuddy"

"The command that prints the applications of the Dock (`Print :persistent-apps`)."
_dockPrint(plist) = Cmd([PLIST_BUDDY, "-c", "Print :persistent-apps", plist])

"The command that deletes the Dock entry number `n` (counted from 0)."
_dockDelete(plist, n::Integer) =
    Cmd([PLIST_BUDDY, "-c", "Delete :persistent-apps:$n", plist])

"""
The numbers (from 0) of the Dock entries of BAYSOL in the text `PlistBuddy`
printed for `persistent-apps`: an entry is a `Dict` one level inside the `Array`,
and it is BAYSOL's when its `bundle-identifier` is [`MAC_BUNDLE_ID`](@ref).
"""
function _dockIndices(text::AbstractString)::Vector{Int}
    found = Int[]
    n = -1
    for line in eachline(IOBuffer(text))
        if occursin(r"^    Dict \{\s*$", line)
            n += 1
        elseif n >= 0 && occursin(r"^\s*bundle-identifier = (.*?)\s*$", line) &&
               strip(split(line, "="; limit = 2)[2]) == MAC_BUNDLE_ID
            push!(found, n)
        end
    end
    return found
end

"""
Removes every Dock entry of BAYSOL (macOS), highest number first, and restarts the Dock so
that it shows the change. `capture(cmd)` returns the output of a command, `exec(cmd)` runs
one (a test passes recorders). Returns a line, or `nothing` when there was no entry or the
list cannot be read.
"""
function _unpinDock(; plist = _dockPlist(), capture = c -> read(c, String),
    exec = c -> run(c; wait = true))
    isfile(plist) || return nothing
    text = try
        capture(pipeline(_dockPrint(plist); stderr = devnull))
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    found = _dockIndices(text)
    isempty(found) && return nothing
    for n in reverse(found)
        exec(_dockDelete(plist, n))
    end
    try
        exec(Cmd(["/usr/bin/killall", "Dock"]))
    catch e
        e isa InterruptException && rethrow()
    end
    return "removed BAYSOL from the Dock"
end

"Removes the pin again (an uninstall); returns a line, or `nothing` if there was none."
function _unpin(home = homedir())
    Platform.ismacos() && return _unpinDock(; plist = _dockPlist(home))
    Platform.islinux() || return nothing
    old = _favorites()
    (old === nothing || !(PIN_ID in old)) && return nothing
    _setFavorites(_unpinned(old, PIN_ID))
    return "unpinned from the taskbar"
end

"Makes `dir` and its parents; what is newly made is removed again by the undo."
function _mkpath!(journal, dir)
    isdir(dir) && return nothing
    top = dir
    while !isdir(dirname(top)) && dirname(top) != top
        top = dirname(top)
    end
    mkpath(dir)
    push!(journal, () -> rm(top; recursive = true, force = true))
    return top
end

"Notes what is at `path` (nothing, a file, a link), so the undo can put it back."
function _backup!(journal, path)
    if islink(path)
        target = readlink(path)
        push!(journal, () -> (rm(path; force = true); symlink(target, path)))
    elseif isfile(path)
        text = read(path)
        push!(journal, () -> write(path, text))
    else
        push!(journal, () -> rm(path; force = true))
    end
end

# ---- the install manifest and the entries of macOS and Windows -------------------------

"""
The file name of the install manifest, beside `install.json`: one line for each file or
folder the wizard made for the icons and entries (`file<TAB>path`, `dir<TAB>path`).
Uninstall removes what the manifest names and nothing else.
"""
const MANIFEST_FILE = "install-manifest.txt"

"The manifest file of this user."
manifestFile(; env = ENV, home = homedir()) =
    joinpath(dirname(installFile(; env, home)), MANIFEST_FILE)

"Notes a made file in `made` (a list of manifest lines) and returns its path."
_madeFile!(made, path) = (push!(made, "file\t" * path); path)

"Makes `dir` as [`_mkpath!`](@ref) does and notes the folders that are new in `made`."
function _madeDir!(made, journal, dir)
    new = String[]  # every level that does not exist yet, so the removal is level by level
    d = dir
    while !isdir(d) && dirname(d) != d
        push!(new, d)
        d = dirname(d)
    end
    _mkpath!(journal, dir)
    append!(made, "dir\t" .* new)
    return nothing
end

"""
    readManifest(file) -> Vector{Pair{String,String}}

The lines of an install manifest as `kind => path` (`"file"` or `"dir"`); empty if the
file is missing. Lines of another shape are skipped.

# Returns
The entries, in file order.

# Exceptions
None.
"""
function readManifest(file::AbstractString)::Vector{Pair{String,String}}
    out = Pair{String,String}[]
    isfile(file) || return out
    for line in eachline(file)
        kind, sep, path = partition3(line)
        isempty(sep) && continue
        kind in ("file", "dir") && isabspath(path) && push!(out, kind => path)
    end
    return out
end

partition3(line) = (
    a = split(
        line,
        '\t';
        limit = 2,
    );
    length(a) == 2 ? (a[1], "\t", a[2]) : (line, "", "")
)

"Writes `made` to `file`, with what an earlier manifest already named (no duplicates)."
function _writeManifest(file, made)
    old = ["$(k)\t$(p)" for (k, p) in readManifest(file)]
    mkpath(dirname(file))
    write(file, join(unique([old; made]), "\n") * "\n")
    return file
end

"""
Removes what `entries` name: files (a link only if it points into `bundle` or is a link to
the app bundle `app`), then the
folders, deepest first, and only when they are empty. Nothing else is touched. Returns the
log and the entries it kept (a link that points elsewhere).
"""
function _removeManifest(entries, bundle, app = nothing)
    log, kept = String[], Pair{String,String}[]
    for (kind, path) in entries
        kind == "file" || continue
        if islink(path)
            target = readlink(path)
            startswith(target, bundle) || target == app ||
                (push!(kept, kind => path); continue)
        elseif !isfile(path)
            continue
        end
        rm(path; force = true)
        push!(log, "removed $path")
    end
    dirs = sort([p for (k, p) in entries if k == "dir"]; by = length, rev = true)
    for d in dirs
        if isdir(d) && isempty(readdir(d))
            rm(d)
            push!(log, "removed $d")
        end
    end
    return log, kept
end

"""
The `Info.plist` of the app bundle in `~/Applications` (macOS). `icon` is the name of the
`.icns` in `Contents/Resources`, `exe` the script in `Contents/MacOS`.
The architectures are
named because a script has none: without them Apple Silicon starts it under Rosetta.
"""
function infoPlist(; icon::AbstractString = ICON_NAME, exe::AbstractString = "BAYSOL")
    return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>BAYSOL</string>
            <key>CFBundleDisplayName</key><string>BAYSOL</string>
            <key>CFBundleIdentifier</key><string>org.baysol.app</string>
            <key>CFBundleExecutable</key><string>$exe</string>
            <key>CFBundleIconFile</key><string>$icon</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>NSHighResolutionCapable</key><true/>
            <key>LSArchitecturePriority</key>
            <array><string>arm64</string><string>x86_64</string></array>
        </dict>
        </plist>
        """
end

"""
The script in `Contents/MacOS` of the app bundle; the path is quoted for the shell. It looks
for the terminal when it runs, so one that is installed or removed later is noticed;
Terminal is what is left.
"""
function _macAppScript(bundle::AbstractString, terminal::AbstractString = "auto")::String
    command = Base.shell_escape_posixly(joinpath(bundle, "BAYSOL.command"))
    lines = ["#!/bin/zsh", "command=$command"]
    for t in MAC_TERMINALS
        terminal in ("auto", t.id) || continue
        push!(lines,
            "for app in /Applications/$(t.app) \"\$HOME\"/Applications/$(t.app); do",
            "    [[ -d \$app ]] && /usr/bin/open -a \"\$app\" $(t.args) && exit 0",
            "done")
    end
    push!(lines, "exec /usr/bin/open -a Terminal \"\$command\"")
    return join(lines, "\n") * "\n"
end

"The choices of the terminal on macOS as `id => text`, given the `found` (installed) ids."
function _terminalChoices(found)::Vector{Pair{String,String}}
    here = [t for t in MAC_TERMINALS if t.id in found]
    return ["auto" => "Automatic"; [t.id => t.name for t in here];
        "terminal" => "Terminal (no rendered figures)"]
end

"""
Makes `BAYSOL.app` at `app` (macOS): `Contents/Info.plist` naming the icon, the
`.icns` copied from `icns` into `Contents/Resources`, and a small script in
`Contents/MacOS` that opens the bundle's `BAYSOL.command` in `terminal`. Every file and
folder is noted in `made`. Returns a line to say what was done.
"""
function _installMacApp!(journal, made, bundle, app, icns, terminal = "auto")
    _madeDir!(made, journal, joinpath(app, "Contents", "MacOS"))
    _madeDir!(made, journal, joinpath(app, "Contents", "Resources"))
    plist = _madeFile!(made, joinpath(app, "Contents", "Info.plist"))
    _backup!(journal, plist)
    write(plist, infoPlist())
    exe = _madeFile!(made, joinpath(app, "Contents", "MacOS", "BAYSOL"))
    _backup!(journal, exe)
    write(exe, _macAppScript(bundle, terminal))
    chmod(exe, 0o755)
    if isfile(icns)
        res = _madeFile!(made, joinpath(app, "Contents", "Resources", ICON_NAME * ".icns"))
        _backup!(journal, res)
        cp(icns, res; force = true)
    end
    return "app bundle $app"
end

"Whether `link` is the Desktop icon of macOS: a link to the app bundle `app`."
_isMacIcon(link, app)::Bool = islink(link) && readlink(link) == app

"""
Makes the Desktop icon of macOS: `link`, a link to the app bundle `app`. Something else of
that name is left alone, and a refusal (macOS asks before a terminal may write to the
Desktop) does not fail the setup. Returns a line to say what was done.
"""
function _installMacIcon!(journal, made, link, app)::String
    isdir(dirname(link)) || return "desktop icon skipped (no folder $(dirname(link)))"
    try
        if !_isMacIcon(link, app)
            (islink(link) || ispath(link)) &&
                return "desktop icon skipped (something else is at $link)"
            symlink(app, link)
            push!(journal, () -> _isMacIcon(link, app) && rm(link))
        end
    catch e
        e isa Base.IOError || rethrow()
        return "desktop icon skipped (macOS refused; allow Terminal the Desktop folder " *
               "in System Settings > Privacy & Security > Files & Folders, then Repair)"
    end
    _madeFile!(made, link)
    return "desktop icon $link"
end

"""
Makes the shortcut `lnk` to `target` with the icon `ico` (Windows) through
PowerShell's `WScript.Shell`; the paths travel in environment variables, so no quoting.
"""
function _makeShortcut(lnk, target, ico, workdir)
    script =
        "\$s = (New-Object -ComObject WScript.Shell).CreateShortcut(\$env:BAYSOL_LNK);" *
        "\$s.TargetPath = \$env:BAYSOL_TARGET; \$s.IconLocation = \$env:BAYSOL_ICO;" *
        "\$s.WorkingDirectory = \$env:BAYSOL_DIR; \$s.Save()"
    cmd = addenv(`powershell -NoProfile -NonInteractive -Command $script`,
        "BAYSOL_LNK" => lnk, "BAYSOL_TARGET" => target, "BAYSOL_ICO" => ico,
        "BAYSOL_DIR" => workdir)
    run(pipeline(cmd; stdout = devnull))
    return nothing
end

"""
Puts the `.ico` of the bundle at `icoDest` and a Start Menu shortcut `lnk` to `baysol.exe`
(Windows). `makeShortcut(lnk, target, ico, workdir)` creates the `.lnk`. Every
file is noted in `made`. Returns a line to say what was done.
"""
function _installWindows!(journal, made, bundle, lnk, icoDest, ico;
    makeShortcut = _makeShortcut, home = homedir())
    _madeDir!(made, journal, dirname(icoDest))
    _madeDir!(made, journal, dirname(lnk))
    if isfile(ico)
        cp(ico, _madeFile!(made, icoDest); force = true)
    end
    makeShortcut(_madeFile!(made, lnk), joinpath(bundle, "baysol.exe"),
        isfile(ico) ? icoDest : joinpath(bundle, "baysol.exe"), home)
    return "start menu shortcut $lnk"
end

"""
    rollback!(journal) -> Nothing

Undoes the steps of an [`applyInstall`](@ref) in reverse order (a step that cannot be
undone is skipped) and empties the journal.

# Returns
`nothing`.

# Exceptions
None.
"""
function rollback!(journal::Vector{Function})
    for undo in reverse(journal)
        try
            undo()
        catch
        end
    end
    empty!(journal)
    return nothing
end

"""
    applyInstall(i, bundle; env, home, journal) -> Vector{String}

Makes the folders, writes `install.json` and, if asked, the entry in the application
menu, the icon on the Desktop, the taskbar pin and the link on the PATH. Every step
pushes how to undo it onto `journal`; [`rollback!`](@ref) runs them. The entries are
only written for Linux, the pin only for GNOME there (macOS and Windows: the wizard
skips it), except the app bundle and Desktop icon of macOS and the Start Menu
shortcut of Windows. A pin needs the menu entry, so it writes that too.

# Returns
A line for each thing done or skipped.

# Exceptions
An `IOError` if a folder or file cannot be written.
"""
function applyInstall(i::Install, bundle::AbstractString; env = ENV, home = homedir(),
    journal::Vector{Function} = Function[])
    log = String[]
    made = String[]  # the manifest lines of the icons and entries
    for d in (i.home, i.structureCache)
        _mkpath!(journal, d)
        push!(log, "folder $d")
    end
    t = targets(; env, home)
    icon = ICON_FALLBACK
    # the Desktop icon of macOS is a link to the app bundle, so it needs that
    entries = i.desktop || i.taskbarPin || (Platform.ismacos() && i.desktopIcon)
    if Platform.islinux() && (entries || i.desktopIcon)
        installed, line = _installIcons!(journal, made, bundle; env, home)
        installed && (icon = ICON_NAME)
        push!(log, line)
    end
    if entries
        if Platform.islinux()
            _madeDir!(made, journal, dirname(t.desktop))
            _backup!(journal, t.desktop)
            write(_madeFile!(made, t.desktop), desktopEntry(bundle; icon))
            _refreshEntries(dirname(t.desktop))
            push!(log, "menu entry $(t.desktop)")
        elseif Platform.ismacos()
            _madeDir!(made, journal, dirname(t.app))
            push!(
                log,
                _installMacApp!(journal, made, bundle, t.app,
                    joinpath(bundle, ICON_FILE), i.terminal),
            )
        elseif Platform.iswindows()
            push!(
                log,
                _installWindows!(journal, made, bundle, t.lnk, t.ico,
                    joinpath(bundle, ICON_FILE); home),
            )
        else
            push!(log, "menu entry skipped (not supported on this system)")
        end
    end
    if i.desktopIcon
        if Platform.islinux() && isdir(dirname(t.icon))
            _backup!(journal, t.icon)
            write(_madeFile!(made, t.icon), desktopEntry(bundle; icon))
            chmod(t.icon, 0o755)  # the desktops start an executable entry
            # GNOME also wants it marked as trusted; other desktops ignore the attribute
            Platform.which("gio") === nothing || try
                run(
                    pipeline(`gio set $(t.icon) metadata::trusted true`;
                        stdout = devnull, stderr = devnull),
                )
            catch
            end
            push!(log, "desktop icon $(t.icon)")
        elseif Platform.islinux()
            push!(log, "desktop icon skipped (no folder $(dirname(t.icon)))")
        elseif Platform.ismacos()
            push!(log, _installMacIcon!(journal, made, t.macIcon, t.app))
        else
            push!(log, "desktop icon skipped (Linux and macOS only)")
        end
    end
    i.taskbarPin && push!(log, _pin!(journal, env))
    if i.pathLink
        if Platform.isunix()
            _madeDir!(made, journal, dirname(t.link))
            _backup!(journal, t.link)
            islink(t.link) && rm(t.link)
            symlink(joinpath(bundle, "baysol"), t.link)
            _madeFile!(made, t.link)
            push!(log, "link $(t.link)")
        else
            push!(log, "PATH link skipped (not supported on this system)")
        end
    end
    cfg = installFile(; env, home)
    _mkpath!(journal, dirname(cfg))
    _backup!(journal, cfg)
    mf = manifestFile(; env, home)
    _backup!(journal, mf)
    _writeManifest(mf, made)
    push!(log, "wrote " * writeInstall(cfg, i))  # last: no install.json means not done
    return log
end

# ---- an existing project folder ---------------------------------------------------------

"""
    hasProject(dir) -> Bool

Whether `dir` already is a BAYSOL folder: it holds `projects/` or a `settings.json`.

# Returns
`true` for a folder an earlier install (or the interface) made.

# Exceptions
None.
"""
hasProject(dir::AbstractString) =
    isdir(joinpath(dir, "projects")) || isfile(joinpath(dir, "settings.json"))

# ---- is the install whole? ---------------------------------------------------------------

"The file name of an executable on this system."
_exe(name) = Platform.exe(name)

"""
The start script of the bundle on this system
(`bysl pkg` writes it; the menu entry runs `baysol`).
"""
const LAUNCHER_FILE =
    Platform.iswindows() ? "baysol.cmd" :
    Platform.ismacos() ? "BAYSOL.command" : "baysol.sh"

"""
The files of the bundle the launcher and the entry need (a repair cannot restore them). The
icon is one of them except on Linux, where the entries fall back to a generic icon (an
older bundle has the `.icns` instead of the `icons` folder).
"""
const BUNDLE_FILES = (_exe("baysol"), _exe("baysol-tui"), LAUNCHER_FILE,
    joinpath("lib", "pytools", _exe("baysol-pytools")),
    (Platform.islinux() ? () : (ICON_FILE,))...)

"Whether the script of the app bundle `app` (macOS) starts `bundle`."
function _isMacAppOf(app::AbstractString, bundle::AbstractString,
    terminal::AbstractString = "auto")::Bool
    script = joinpath(app, "Contents", "MacOS", "BAYSOL")
    return isfile(script) && read(script, String) == _macAppScript(bundle, terminal)
end

"""
    check(bundle; env, home) -> NamedTuple

Looks for what is wrong with the install. `fixable` lists what `applyInstall`
puts right (`install.json`, folders, the menu entry, the Desktop icon, the
PATH link); `missing` lists bundle files that only a reinstall brings back.

# Returns
`(fixable = Vector{String}, missing = Vector{String})`, both empty if all is well.

# Exceptions
None.
"""
function check(bundle::AbstractString; env = ENV, home = homedir())
    fixable, missing = String[], String[]
    cfg = installFile(; env, home)
    i = readInstall(cfg)
    if i === nothing
        push!(
            fixable,
            isfile(cfg) ? "install.json is damaged: $cfg" :
            "install.json is missing: $cfg",
        )
        i = defaultInstall(; env, home)
    end
    for (what, d) in (("projects", i.home), ("cache", i.structureCache))
        if isempty(strip(d))
            push!(fixable, "the $what folder is blank in install.json")
        elseif !isdir(d)
            push!(fixable, "the $what folder is missing: $d")
        elseif !Platform.iswindows() && !(uperm(d) & 0x02 != 0)
            push!(fixable, "the $what folder is not writable: $d")
        end
    end
    t = targets(; env, home)
    launcher = joinpath(bundle, "baysol")
    macApp = Platform.ismacos() && (i.desktop || i.taskbarPin || i.desktopIcon)
    if macApp && !isdir(t.app)
        push!(fixable, "the app bundle is missing: $(t.app)")
    elseif macApp && !_isMacAppOf(t.app, bundle, i.terminal)
        push!(fixable, "the app bundle starts another bundle or terminal: $(t.app)")
    elseif Platform.iswindows() && (i.desktop || i.taskbarPin) && !isfile(t.lnk)
        push!(fixable, "the Start Menu shortcut is missing: $(t.lnk)")
    end
    Platform.ismacos() && i.desktopIcon && !_isMacIcon(t.macIcon, t.app) &&
        push!(fixable, "the desktop icon is missing: $(t.macIcon)")
    for (on, file, what) in ((i.desktop || i.taskbarPin, t.desktop, "menu entry"),
        (i.desktopIcon, t.icon, "desktop icon"))
        on && Platform.islinux() || continue
        if !isfile(file)
            push!(fixable, "the $what is missing: $file")
        elseif !occursin("Exec=\"$launcher\"", read(file, String))
            push!(fixable, "the $what points to another bundle: $file")
        end
    end
    if Platform.islinux() && (i.desktop || i.taskbarPin || i.desktopIcon)
        sizes = [first(p) for p in bundleIcons(bundle)]
        gone = [f for f in iconFiles(sizes; env, home) if !isfile(f)]
        isempty(gone) || push!(
            fixable,
            "icon sizes are missing: $(length(gone)) in $(hicolorDir(; env, home))",
        )
    end
    if i.pathLink && Platform.isunix()  # the link is only made there (see applyInstall)
        if !islink(t.link)
            push!(fixable, "the PATH link is missing: $(t.link)")
        elseif readlink(t.link) != launcher
            push!(fixable, "the PATH link points elsewhere: $(t.link)")
        end
    end
    for f in BUNDLE_FILES
        ispath(joinpath(bundle, f)) || push!(missing, "the bundle lacks $f")
    end
    return (; fixable, missing)
end

# ---- uninstall ------------------------------------------------------------------------

"A cache folder is only deleted if BAYSOL made it: it holds the cache marker or is empty."
_ours(dir) = isdir(dir) && (isfile(joinpath(dir, CACHE_TAG)) || isempty(readdir(dir)))

"""
Removes the cache folder of the system, `Platform.cache_dir` (`<cache home>/baysol`, or
`baysol-cache` where data and caches share a folder), with what is left in it besides the
structure cache. Only that known folder, and only when its name is one of those two and it
does not contain a `protect`ed folder or the user's home. Returns a line, or `nothing`.
"""
function _removeCacheRoot(; env = ENV, home = homedir(), protect::Vector{String} = String[])
    dir = Platform.cache_dir(; env, home)
    isdir(dir) || return nothing
    basename(dir) in ("baysol", "baysol-cache") || return "kept $dir (not named for BAYSOL)"
    for p in [home; protect]
        isempty(strip(p)) && continue
        _within(p, dir) && return "kept $dir (it holds $p)"
    end
    rm(dir; recursive = true)
    return "removed $dir"
end

"""
Removes the empty `settings.json` (`{}`) that the interface writes into the projects folder
at its first start, so a folder without projects is not left with it. Nothing else of the
projects folder is touched. Whether it was removed.
"""
function _removeEmptySettings(home::AbstractString)::Bool
    file = joinpath(home, "settings.json")
    isfile(file) || return false
    occursin(r"^\{\s*\}\s*$", read(file, String)) || return false
    rm(file)
    return true
end

"""
Removes `Platform.tmp_dir()` (`<tmp>/baysol`) if it is empty (every process takes its own
folder out when it ends; a folder of a process that still runs, the interface that started
the wizard, is not touched). Returns a line, or `nothing`.
"""
function _removeTmp(; base = tempdir())
    dir = Platform.tmp_dir(; base)
    isdir(dir) && !islink(dir) && isempty(readdir(dir)) || return nothing
    rm(dir)
    return "removed $dir"
end

"""
    uninstall(bundle; data, i, env, home, tmp) -> Vector{String}

Removes the app side: the icons, menu entry, app bundle or shortcut, Desktop icon and
PATH link that the install manifest names (a link only if it points into `bundle`;
nothing the manifest does not name), the taskbar pin, the manifest, `install.json`,
the configuration folder if it is empty, the bundle folder, the cache folders (the
structure cache only if it carries the marker or is empty, then the rest of
`Platform.cache_dir`) and the empty `<tmp>/baysol` (`tmp` is the temporary folder).
The Dock entry of BAYSOL goes too on macOS. The projects folder stays unless
`data = true`, but the empty `settings.json` the interface made in it does not.

# Returns
A line for each thing removed or kept.

# Exceptions
An `IOError` if something cannot be removed.
"""
function uninstall(bundle::AbstractString; data::Bool = false,
    i::Union{Install,Nothing} = nothing, env = ENV, home = homedir(), tmp = tempdir())
    log = String[]
    cfg = installFile(; env, home)
    i = something(i, readInstall(cfg), defaultInstall(; env, home))
    t = targets(; env, home)
    mf = manifestFile(; env, home)
    # the icons and entries: exactly what the manifest names, and nothing else
    lines, kept = _removeManifest(readManifest(mf), bundle, t.app)
    append!(log, lines)
    if Platform.islinux()
        _refreshIcons(; env, home)
        _refreshEntries(dirname(t.desktop))
    end
    pin = _unpin(home)
    pin === nothing || push!(log, pin)
    c = i.structureCache
    cacheKept = false
    if _ours(c)
        rm(c; recursive = true)
        push!(log, "removed $c")
    elseif isdir(c)
        push!(log, "kept $c (not marked as BAYSOL's)")
        cacheKept = true
    end
    # the rest of BAYSOL's own cache folder (`_cache`, downloads): only that known folder
    if !cacheKept
        line = _removeCacheRoot(; env, home, protect = [i.home, bundle])
        line === nothing || push!(log, line)
    end
    if data
        isdir(i.home) && (rm(i.home; recursive = true); push!(log, "removed $(i.home)"))
    else
        _removeEmptySettings(i.home) &&
            push!(log, "removed the empty settings of $(i.home)")
        push!(log, "kept the projects: $(i.home)")
    end
    if isempty(kept)
        isfile(mf) && (rm(mf); push!(log, "removed $mf"))
    else
        mkpath(dirname(mf))  # on macOS it is the projects folder, which `data` removed
        write(mf, join(["$k\t$p" for (k, p) in kept], "\n") * "\n")  # for a later uninstall
    end
    isfile(cfg) && (rm(cfg); push!(log, "removed $cfg"))
    # the configuration folder, when nothing else is in it (never the projects folder)
    cfgDir = dirname(cfg)
    if isdir(cfgDir) && isempty(readdir(cfgDir)) && !_within(i.home, cfgDir) &&
       !_within(cfgDir, i.home)
        rm(cfgDir)
        push!(log, "removed $cfgDir")
    end
    isdir(bundle) && push!(log,
        _removeBundle(bundle, String[i.home, i.structureCache, dirname(cfg)]))
    gone = _removeTmp(; base = tmp)
    gone === nothing || push!(log, gone)
    return log
end

"""
Why `bundle` must not be deleted, or `nothing` if it may be: it has to be an absolute,
normal path of at least two levels (never a root), a folder that holds the program
(`baysol` or `baysol.exe`, so it is a bundle and not some folder), and it must neither be
nor contain the user's home folder or any of `protect` (projects, caches, configuration).
"""
function _bundleRefusal(
    bundle::AbstractString,
    protect::Vector{String},
)::Union{String,Nothing}
    isabspath(bundle) || return "the path is not absolute"
    normpath(bundle) == bundle || return "the path is not in normal form"
    isempty(splitdir(dirname(bundle))[2]) && return "it is a root folder or directly in one"
    isdir(bundle) || return "it is not a folder"
    (isfile(joinpath(bundle, "baysol")) || isfile(joinpath(bundle, "baysol.exe"))) ||
        return "it holds no baysol program, so it is not a bundle"
    for p in [homedir(); protect]
        isempty(strip(p)) && continue
        _within(p, bundle) && return "it contains $p"
    end
    return nothing
end

"""
The command that removes `bundle` once this process has ended (Windows). The path travels
in the environment variable `BAYSOL_GONE`, never in the script text, so no quoting or
injection is possible whatever the name holds (spaces, quotes, `\$`, non-ASCII).
"""
function _cleanupCommand(bundle::AbstractString)::Cmd
    script =
        "Start-Sleep -Seconds 3; Remove-Item -LiteralPath \$env:BAYSOL_GONE " *
        "-Recurse -Force -ErrorAction SilentlyContinue"
    cmd = addenv(`powershell -NoProfile -NonInteractive -Command $script`,
        "BAYSOL_GONE" => String(bundle))
    return Cmd(cmd; detach = true, dir = dirname(bundle))
end

function _spawnCleanup(cmd::Cmd)::Nothing
    run(pipeline(cmd; stdin = devnull, stdout = devnull, stderr = devnull); wait = false)
    return nothing
end

"""
Removes the bundle folder once [`_bundleRefusal`](@ref) finds nothing against it (else it
is kept and the line says why). On Windows the running program (`baysol.exe`, the
libraries it loaded) and a shell standing in the folder cannot be deleted, so what stays is
removed by a detached PowerShell a moment after this process has ended (`spawn` starts it;
a test passes a recorder). Returns the line for the log.
"""
function _removeBundle(bundle::AbstractString, protect::Vector{String} = String[];
    spawn = _spawnCleanup)
    why = _bundleRefusal(bundle, protect)
    why === nothing || return "kept $bundle ($why)"
    try
        rm(bundle; recursive = true)
        return "removed $bundle"
    catch
        Platform.iswindows() || rethrow()
    end
    try  # the folder must not be this process's own working directory
        _within(pwd(), bundle) && cd(dirname(bundle))
    catch
    end
    try
        spawn(_cleanupCommand(bundle))::Nothing
    catch e
        return "could not remove $bundle (" * sprint(showerror, e) * "); delete it by hand"
    end
    return "$bundle is in use; it is removed when BAYSOL has exited"
end

# ---- the folders: open one, clear a cache
# -------------------------------------------------

"""
    clearCache(dir) -> String

Empties the cache folder `dir` (the folder itself stays), only if it is BAYSOL's: it holds
the `CACHE_TAG` marker or is empty. The projects folder has no such function on purpose.

# Returns
A line that says what happened. An entry that cannot be removed (Windows will not delete a
library that a running BAYSOL has loaded, e.g. under `native/`) does not stop the rest: it
is kept and named in the line.
"""
function clearCache(dir::AbstractString; remove = _removeEntry)
    isdir(dir) || return "no folder $dir"
    _ours(dir) || return "kept $dir (not marked as BAYSOL's)"
    n = 0
    busy = String[]
    for f in readdir(dir; join = true)
        basename(f) == CACHE_TAG && continue
        try
            remove(f)::Nothing
            n += 1
        catch
            push!(busy, basename(f))
        end
    end
    line = "cleared $dir ($n entries)"
    isempty(busy) ||
        (line *= "; kept " * join(busy, ", ") * " (in use? close BAYSOL and try again)")
    return line
end

_removeEntry(path::AbstractString)::Nothing = rm(path; recursive = true, force = true)

"""
    fileManagerCommands() -> Vector{Cmd}

The commands to try, in order, to open a folder in the file manager of this system (the
folder is appended): `xdg-open` then `gio open` on Linux, `open` on macOS, `explorer` on
Windows. Only those found on the PATH are listed.
"""
function fileManagerCommands()
    names =
        Platform.ismacos() ? [["open"]] :
        Platform.iswindows() ? [["explorer"]] :
        [["xdg-open"], ["gio", "open"]]
    return [
        Cmd([Platform.which(n[1]), n[2:end]...]) for
        n in names if Platform.which(n[1]) !== nothing
    ]
end

"""
    shellCommand(; env) -> Cmd

The user's shell: `\$SHELL` (else `/bin/sh`) on Linux and macOS, `%COMSPEC%` (else
`cmd.exe`) on Windows.
"""
function shellCommand(; env = ENV)
    return Cmd([Platform.shell(; env)])
end

"How long to wait for the file manager to fail before assuming it worked (seconds)."
const FILE_MANAGER_WAIT = 2.0

"""
    openFolder(dir; io, managers, shell) -> Bool

Opens `dir` the way the terminal interface does: the file manager is started detached (the
first of `managers` that does not fail within `FILE_MANAGER_WAIT` seconds), then the user's
`shell` runs in `dir` on this terminal until it exits (a program cannot change the
directory of the shell that started it). False if `dir` does not exist; `shell = nothing`
starts none.
"""
function openFolder(dir::AbstractString; io::IO = stdout, managers = fileManagerCommands(),
    shell = shellCommand())
    isdir(dir) || (println(io, "No folder $dir"); return false)
    started = false
    for m in managers
        p = try
            run(
                pipeline(Cmd(`$m $dir`; detach = true); stdout = devnull, stderr = devnull);
                wait = false)
        catch
            continue
        end
        for _ in 1:round(Int, FILE_MANAGER_WAIT*20)
            process_running(p) || break
            sleep(0.05)
        end
        if !process_running(p) && !success(p) && !Platform.iswindows()
            continue
        end
        started = true
        break
    end
    started || println(io, "No file manager could be started.")
    if shell !== nothing
        println(io, "BAYSOL: shell in ", dir, " (type exit to return)")
        try
            run(Cmd(shell; dir))
        catch e
            println(io, "Could not start a shell: ", sprint(showerror, e))
        end
    end
    return true
end

# ---- the icon: 10 x 5 cells of coloured spaces ----------------------------------------

"The colours of the letters: truecolor (RGB), and the nearest of the 256 colours."
const ICON_RGB = Dict('k' => (0, 0, 0), 'p' => (255, 97, 126), 't' => (0, 255, 204))
const ICON_256 = Dict('k' => 16, 'p' => 204, 't' => 49)

"""
The icon at 10 x 5 cells, one letter a cell: k black, p pink, t teal (a B). A cell is about
twice as high as wide, so the icon is roughly square. It is drawn with coloured spaces
only, which every terminal fills the same way (no glyph, no font quirks).
"""
const ICON_CELLS = (
    "pkktttkkkp",
    "pkktkktkkp",
    "pkktttkkkp",
    "pkktkktkkp",
    "pkktttkkkp",
)

"The icon without colour: a small box with the name (3 rows, 10 columns)."
const ICON_PLAIN = ("+--------+", "| BAYSOL |", "+--------+")

"""
    useColor(io, env) -> Bool

Whether the icon is drawn in colour: `io` is a terminal, `NO_COLOR` is not set (to a
non-empty value, the convention of no-color.org) and `TERM` is not `dumb`.

# Returns
The answer.

# Exceptions
None.
"""
useColor(io::IO = stdout, env = ENV) =
    io isa Base.TTY && isempty(get(env, "NO_COLOR", "")) && get(env, "TERM", "") != "dumb"

"""
    drawIcon(io; color, truecolor) -> Nothing

Draws the icon ([`ICON_CELLS`](@ref)) with coloured spaces, two spaces of indent; truecolor
where the terminal says so (`COLORTERM`), else the nearest of the 256 colours. With `color`
false (not a terminal, `NO_COLOR`, no colour: [`useColor`](@ref)) it prints
[`ICON_PLAIN`](@ref), a box with the name, and no escape codes.

# Returns
`nothing`.

# Exceptions
None.
"""
function drawIcon(io::IO = stdout; color::Bool = useColor(io),
    truecolor::Bool = get(ENV, "COLORTERM", "") in ("truecolor", "24bit"))
    if !color
        foreach(row -> println(io, "  ", row), ICON_PLAIN)
        return nothing
    end
    bg = truecolor ? c -> "48;2;" * join(ICON_RGB[c], ';') : c -> "48;5;$(ICON_256[c])"
    for row in ICON_CELLS
        print(io, "  ")
        last = nothing
        for c in row
            c == last || print(io, "\e[", bg(c), "m")
            print(io, ' ')
            last = c
        end
        println(io, "\e[0m")
    end
    return nothing
end

# ---- the live clock ------------------------------------------------------------------

"The least terminal the clock is drawn on: rows and columns."
const CLOCK_MIN_ROWS = 10
const CLOCK_MIN_COLS = 60

"The days of the week, `Libc.TmStruct.wday` (0 is Sunday) counting from 0."
const MONTHS =
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const WEEKDAYS =
    ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")

"""
    formatClock(tm; offsetMinutes, zone) -> String

The clock text, the same as the interface's clock:
`Fri, 27 Nov 2026, 14:03:22-CET (UTC+01:00)` (24-hour time). `tm` is the
local broken-down time (`Libc.TmStruct`), `offsetMinutes` the offset of
local time from UTC, `zone` the abbreviation of the zone. Without a zone
only the offset is shown: `Fri, 27 Nov 2026, 14:03:22 (UTC+01:00)`.

# Returns
The text.

# Exceptions
None.
"""
function formatClock(tm::Libc.TmStruct; offsetMinutes::Integer, zone::AbstractString = "")
    two(n) = lpad(string(n), 2, '0')
    sign = offsetMinutes < 0 ? '-' : '+'
    m = abs(Int(offsetMinutes))
    offset = string("(UTC", sign, two(div(m, 60)), ':', two(rem(m, 60)), ')')
    time = string(two(tm.hour), ':', two(tm.min), ':', two(tm.sec))
    day = WEEKDAYS[mod(Int(tm.wday), 7)+1]
    date = string(two(tm.mday), ' ', MONTHS[mod(Int(tm.month), 12)+1], ' ', 1900 + tm.year)
    return isempty(zone) ? string(day, ", ", date, ", ", time, ' ', offset) :
           string(day, ", ", date, ", ", time, '-', zone, ' ', offset)
end

# the days since 1970-01-01 of a civil date (proleptic Gregorian; Howard Hinnant's rule)
function _daysFromCivil(y::Integer, m::Integer, d::Integer)::Int
    y -= m <= 2
    era = fld(y, 400)
    yoe = y - era * 400
    doy = div(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1
    return era * 146097 + yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy - 719468
end

"""
    localOffsetMinutes(t) -> Int

The offset of local time from UTC, in minutes, at the epoch time `t` (seconds): the local
broken-down time read as if it were UTC, minus `t`. It needs no time-zone database and
works on every system.

# Returns
The offset, for example 60 for UTC+01:00.

# Exceptions
None.
"""
function localOffsetMinutes(t::Real = time())::Int
    tm = Libc.TmStruct(t)
    local_ =
        _daysFromCivil(tm.year + 1900, tm.month + 1, tm.mday) * 86400 +
        tm.hour * 3600 + tm.min * 60 + tm.sec
    return round(Int, (local_ - floor(t)) / 60)
end

"""
    localZoneName(t; format) -> String

The abbreviation of the local zone at `t` (`CET`, `EST`), as the C library's `%Z` gives
it; empty when it is not a short name (Windows gives the long name, `Central European
Standard Time`, which is dropped: the clock then shows the offset only). `format` is the
formatter (a test passes its own).

# Returns
The abbreviation, or an empty string.

# Exceptions
None.
"""
function localZoneName(t::Real = time(); format = Libc.strftime)::String
    name = try
        strip(format("%Z", t))
    catch
        ""
    end
    return occursin(r"^[A-Za-z0-9+-]{1,10}$", name) ? String(name) : ""
end

"""
The width the clock text is padded to: this zone, a two-digit
offset (every weekday, month and day is the same width).
"""
clockWidth(zone::AbstractString) =
    ncodeunits(
        formatClock(Libc.TmStruct(0, 0, 0, 1, 0, 100, 3, 0, 0); offsetMinutes = 0,
            zone),
    )

"""
    clockFrame(text, rows, cols, width; blank) -> String

One string that draws the clock: save the cursor (`ESC 7`), move to the last row, at the
right edge (the last column stays free, so the terminal never scrolls), write `text`
padded on the left to `width` (spaces with `blank`, which clears it), restore the cursor
(`ESC 8`). One string, so one write.

# Returns
The string.

# Exceptions
None.
"""
function clockFrame(text::AbstractString, rows::Integer, cols::Integer, width::Integer;
    blank::Bool = false)::String
    col = max(1, cols - width)
    body = blank ? " "^width : lpad(text, width)
    return string("\e7\e[", rows, ';', col, 'H', body, "\e8")
end

"""
The clock: where it writes (`io`), the zone, the size and time sources (functions, so a
test can fake them), the `lock` it shares with the wizard (a tick takes it, and so does
[`pauseClock!`](@ref)), whether it is paused, drawn or stopping, and its task and timer.
"""
mutable struct WizardClock
    io::IO
    zone::String
    size::Function
    now::Function
    interval::Float64
    lock::ReentrantLock
    paused::Bool
    drawn::Bool
    stopping::Bool
    task::Union{Task,Nothing}
    timer::Union{Timer,Nothing}
end

"""
    clockTick!(c) -> Bool

Draws the clock once, under its lock: nothing while it is paused or stopping; on a terminal
shorter than `CLOCK_MIN_ROWS` or narrower than `CLOCK_MIN_COLS` it only clears what was
drawn before (the terminal may have been resized).

# Returns
Whether the clock was drawn.

# Exceptions
None.
"""
function clockTick!(c::WizardClock)::Bool
    return lock(c.lock) do
        (c.paused || c.stopping) && return false
        rows, cols = c.size()
        width = clockWidth(c.zone)
        if rows < CLOCK_MIN_ROWS || cols < CLOCK_MIN_COLS
            c.drawn && _clearClock(c, rows, cols)
            return false
        end
        tm, offset = c.now()
        write(
            c.io,
            clockFrame(formatClock(tm; offsetMinutes = offset, zone = c.zone),
                rows, cols, width),
        )
        flush(c.io)
        c.drawn = true
        return true
    end
end

# blanks the clock's place (under the lock); the terminal may have shrunk since it was drawn
function _clearClock(c::WizardClock, rows = c.size()[1], cols = c.size()[2])
    rows >= 1 && cols >= 1 &&
        write(c.io, clockFrame("", rows, cols, clockWidth(c.zone); blank = true))
    flush(c.io)
    c.drawn = false
    return nothing
end

"""
    pauseClock!(c) / resumeClock!(c)

Pauses the clock and clears its line, or lets it tick again. The wizard pauses it where a
program of another kind owns the terminal (a file manager's shell, an installer that asks
for a password, a subprocess), because a tick there could corrupt what that program draws
or reads. At a menu or a typed prompt the clock keeps ticking: a tick is one write that
saves and restores the cursor.

# Returns
`nothing`.

# Exceptions
None.
"""
function pauseClock!(c::WizardClock)
    lock(c.lock) do
        c.paused = true
        c.drawn && _clearClock(c)
    end
    return nothing
end
function resumeClock!(c::WizardClock)
    lock(c.lock) do
        c.paused = false
    end
    return nothing
end

"The clock of the running wizard, which [`_quiet`](@ref) pauses (`nothing`: no clock)."
const ACTIVE_CLOCK = Ref{Union{WizardClock,Nothing}}(nothing)

"Runs `f` with the clock paused (when there is one), and resumes it afterwards."
function _quiet(f)
    c = ACTIVE_CLOCK[]
    c === nothing && return f()
    pauseClock!(c)
    try
        return f()
    finally
        resumeClock!(c)
    end
end

"""
    clockWanted(io, env) -> Bool

Whether a clock may run on `io`: it is a terminal and `TERM` is not `dumb`. (Colour plays
no part: the clock uses none.)

# Returns
The answer.

# Exceptions
None.
"""
clockWanted(io::IO = stdout, env = ENV) = io isa Base.TTY && get(env, "TERM", "") != "dumb"

"""
    startClock(io; size, now, zone, interval) -> Union{WizardClock,Nothing}

Starts the clock task: once a second (on the second) it calls [`clockTick!`](@ref).

# Returns
The [`WizardClock`](@ref), which [`stopClock!`](@ref) ends.

# Exceptions
None.
"""
function startClock(io::IO = stdout; size = () -> displaysize(io),
    now = () -> (t = time(); (Libc.TmStruct(t), localOffsetMinutes(t))),
    zone::AbstractString = localZoneName(), interval::Real = 1.0)::WizardClock
    c = WizardClock(io, String(zone), size, now, Float64(interval), ReentrantLock(),
        false, false, false, nothing, nothing)
    c.task = errormonitor(@async begin
        while true
            # wake on the second, not a second after the last tick (no drift)
            delay = c.interval == 1.0 ? 1.005 - time() % 1 : c.interval
            t = Timer(delay)
            lock(c.lock) do
                c.stopping || (c.timer = t)
            end
            c.stopping && (close(t); break)
            try
                wait(t)
            catch  # closed by stopClock!
            end
            c.stopping && break
            clockTick!(c)
        end
    end)
    return c
end

"""
    stopClock!(c)

Stops the clock on every exit path: no more ticks, the task ends (it is waited for), and
the line is cleared. Safe to call twice and with `nothing`.

# Returns
`nothing`.

# Exceptions
None.
"""
stopClock!(::Nothing) = nothing
function stopClock!(c::WizardClock)
    lock(c.lock) do
        c.stopping && return
        c.drawn && _clearClock(c)
        c.stopping = true
        c.timer === nothing || close(c.timer)
    end
    c.task === nothing || wait(c.task)
    return nothing
end

# ---- the wizard -----------------------------------------------------------------------

"""
Applies `i` and prints what was done; on an error or ^c everything written is undone.
Returns whether it went through.
"""
function _apply(io, i, bundle; env, home)
    journal = Function[]
    try
        _show(io, _quiet(() -> applyInstall(i, bundle; env, home, journal)))
        return true
    catch e
        rollback!(journal)
        println(
            io,
            e isa InterruptException ? "Interrupted; all undone." :
            "Failed, all undone: " * sprint(showerror, e),
        )
        return false
    end
end

"""
The entries of the shortcuts menu for the system `os`: the field of [`Install`](@ref) each
one sets and its text. macOS has no pin (only GNOME's is done; drag BAYSOL to the Dock
there). Windows has no PATH link: a link is a symlink (a privilege
there), and editing the user's `PATH` in the registry from here would risk the whole
variable (`setx` cuts it at 1024 characters and turns `%VARS%` into fixed text), so the
item is not offered; the Start Menu shortcut starts BAYSOL instead.
"""
function shortcutChoices(os::Symbol = Platform.os())::Vector{Pair{Symbol,String}}
    link = :pathLink => "PATH link"
    os == :macos && return [:desktop => "Applications entry (BAYSOL.app)",
        :desktopIcon => "Desktop icon", link]
    items = [:desktop => "Application menu entry", :desktopIcon => "Desktop icon",
        :taskbarPin => "Pin to taskbar (GNOME)"]
    os == :windows || push!(items, link)
    return items
end

"""
    startNow(io, i; ask) -> Int

After a setup or a repair: `Start BAYSOL now? (Yes/No)`. Yes starts what `i.opens` says.

# Returns
`LAUNCH_CLI` when `i.opens` is `"cli"`, else `LAUNCH_TUI`, after a Yes; 0 after a No.

# Exceptions
`InterruptException` on ^c at the question.
"""
function startNow(io::IO, i::Install; ask = _askYesNo)::Int
    ask(io, "Start BAYSOL now?", true) || return 0
    return i.opens == "cli" ? LAUNCH_CLI : LAUNCH_TUI
end

"Prints the lines of a log, each after `mark`."
_show(io, lines, mark = "  ") = foreach(l -> println(io, mark, l), lines)

"""
Reads one line from the terminal in raw mode, echoing it itself: Backspace edits, Enter
ends it, and ^c or ^d on an empty line throws `InterruptException` (the plain
`readline` of Julia crashes when it is interrupted on a terminal).
"""
function _readLine(io)
    term = TTYTerminal(get(ENV, "TERM", "dumb"), stdin, io, io)
    text = Char[]
    raw!(term, true)
    try
        while true
            c = read(stdin, Char)
            if c in ('\r', '\n')
                break
            elseif c == '\x03' || (c == '\x04' && isempty(text))
                throw(InterruptException())
            elseif c in ('\x7f', '\b')
                isempty(text) || (pop!(text); print(io, "\b \b"))
            elseif c == '\x1b'  # an arrow or other key: drop its sequence
                while bytesavailable(stdin) > 0
                    d = read(stdin, Char)
                    (isletter(d) || d == '~') && break
                end
            elseif !iscntrl(c)
                push!(text, c)
                print(io, c)
            end
        end
    finally
        raw!(term, false)
    end
    println(io)
    return strip(String(text))
end

"Asks for a text, with a default shown and taken on an empty line."
function _ask(io, question, default)
    println(io, question, ":")
    print(io, "[", default, "] ")
    answer = _readLine(io)
    return isempty(answer) ? default : answer
end

function _welcome(io)
    drawIcon(io)
    println(
        io,
        """

BAYSOL setup
Folders and shortcuts.
Restart BAYSOL to apply.
""",
    )
end

"""
    parseYesNo(text, default) -> Union{Bool,Nothing}

One answer to a question. `y` and `yes` are true, `n` and `no` false (any case); an empty
line takes `default`.

# Returns
The answer, or `nothing` when `text` is anything else (the caller asks again).

# Exceptions
None.
"""
function parseYesNo(text::AbstractString, default::Bool)::Union{Bool,Nothing}
    t = lowercase(strip(text))
    isempty(t) && return default
    t in ("y", "yes") && return true
    t in ("n", "no") && return false
    return nothing
end

"""
    parseThreads(text, default) -> Int

The threads per fit typed by the user: a whole number, at most 256 (and at least 1); an
empty or unreadable line takes `default`.

# Returns
The number of threads.

# Exceptions
None.
"""
function parseThreads(text::AbstractString, default::Integer)::Int
    n = tryparse(Int, strip(text))
    return clamp(something(n, Int(default)), 1, 256)
end

"""
    _askYesNo(io, question, default; read) -> Bool

Asks `question` as a Yes/No question, the default shown and taken on Enter. Anything but
yes, y, no, n or an empty line is refused and asked again. Every question of the wizard
is asked this way. `read` is the line reader (a test passes its own).

# Returns
The answer.

# Exceptions
`InterruptException` on ^c or ^d at the question (with the default reader).
"""
function _askYesNo(io::IO, question::AbstractString, default::Bool = true;
    read = _readLine)::Bool
    while true
        print(io, question, " (Yes/No) [", default ? "Yes" : "No", "] ")
        answer = parseYesNo(read(io), default)
        answer === nothing || return answer
        println(io, "Please answer Yes or No.")
    end
end

"`i` with the fields in `changes` replaced (an [`Install`](@ref) is immutable)."
function _copy(i::Install; changes...)::Install
    fields = Dict{Symbol,Any}(f => getfield(i, f) for f in fieldnames(Install))
    merge!(fields, Dict{Symbol,Any}(changes))
    return Install(; fields...)
end

"The terminals of macOS that are installed (ids of `MAC_TERMINALS`)."
_foundTerminals() = [x.id for x in MAC_TERMINALS if _find(x.app) !== nothing]

"""
    describeInstall(io, i; os, found)

Prints the settings of `i` as plain lines: the folders, the threads, what the icon opens,
the terminal (macOS, when one besides Terminal is installed, `found`) and the shortcuts
that are on.

# Returns
`nothing`.

# Exceptions
None.
"""
function describeInstall(io::IO, i::Install; os::Symbol = Platform.os(),
    found::Vector{String} = os == :macos ? _foundTerminals() : String[])
    println(io, "  projects    ", i.home)
    println(io, "  cache       ", i.structureCache)
    println(io, "  threads     ", i.threads)
    println(io, "  icon opens  ", uppercase(i.opens))
    if os == :macos && !isempty(found)
        ts = Dict(_terminalChoices(found))
        println(io, "  terminal    ", ts[haskey(ts, i.terminal) ? i.terminal : "auto"])
    end
    i.desktop && println(io, "  shortcut    ",
        os == :macos ? "Applications entry (BAYSOL.app)" : "application menu entry")
    i.desktopIcon && println(io, "  shortcut    Desktop icon")
    i.taskbarPin && println(io, "  shortcut    taskbar pin")
    i.pathLink && println(io, "  shortcut    PATH link")
    return nothing
end

"""
    editInstall(io, cur; lockHome, home) -> Install

The only inputs of the wizard that are not Yes or No: the folders (the printed default is
taken on Enter), the threads (a number, the default on Enter) and one checklist of
shortcuts with the current ones ticked. `lockHome` skips the projects folder (an existing
BAYSOL folder was found: only one can exist). What the icon opens and the terminal are
not asked here (Advanced).

# Returns
The edited [`Install`](@ref).

# Exceptions
`InterruptException` on ^c.
"""
function editInstall(io::IO, cur::Install; lockHome::Bool = false, home = homedir())
    h = cur.home
    if !lockHome
        h = cleanPath(_ask(io, "Projects folder", cur.home); home)
        hasProject(h) && println(io, "Found one there; only one can exist; using it.")
    end
    s = cleanPath(_ask(io, "Cache folder", cur.structureCache); home)
    n = parseThreads(_ask(io, "Threads per fit", string(cur.threads)), cur.threads)
    choices = shortcutChoices()
    ticked = [k for (k, c) in enumerate(choices) if getfield(cur, first(c))]
    picked = request("Shortcuts (Enter ticks, then d):",
        MultiSelectMenu(last.(choices); selected = ticked))
    on = Set(first(choices[k]) for k in picked)
    offered = first.(choices)
    keep(f) = f in offered ? f in on : getfield(cur, f)  # not offered here: unchanged
    return _copy(cur; home = h, structureCache = s, threads = n,
        desktop = keep(:desktop), desktopIcon = keep(:desktopIcon),
        taskbarPin = keep(:taskbarPin), pathLink = keep(:pathLink))
end

"""
    setupFlow(io, cur, bundle; lockHome, env, home) -> Union{Install,Nothing}

Set up or change: the settings as plain lines, `Change any of these? (Yes/No)` (Yes walks
[`editInstall`](@ref), No keeps them), then `Apply? (Yes/No)`. Nothing is written before
the Apply.

# Returns
The applied [`Install`](@ref), or `nothing` after a No or a failed apply (undone).

# Exceptions
`InterruptException` on ^c.
"""
function setupFlow(io::IO, cur::Install, bundle::AbstractString; lockHome::Bool = false,
    env = ENV, home = homedir())
    if lockHome
        println(io, "Found a BAYSOL folder:")
        println(io, "  ", cur.home)
        println(io, "Only one can exist; using it.")
    end
    println(io, "Settings:")
    describeInstall(io, cur)
    i = cur
    if _askYesNo(io, "Change any of these?", false)
        i = editInstall(io, cur; lockHome, home)
        println(io, "Will set up:")
        describeInstall(io, i)
    end
    if _askYesNo(io, "Apply?", true)
        if _apply(io, i, bundle; env, home)
            println(io, "Done.")
            return i
        end
        return nothing
    end
    println(io, "Nothing written.")
    return nothing
end

"""
    advancedMenu(io, bundle; launch, env, home) -> Int

Everything that is not needed for a first start: repair, the dependency check, the folders
(open, clear the cache), what the icon opens and the terminal. A menu of steps that comes
back after each one until Back; the questions in it are Yes or No.

# Returns
0, or `LAUNCH_TUI` / `LAUNCH_CLI` after a repair when the user answered Yes to starting.

# Exceptions
`InterruptException` on ^c.
"""
function advancedMenu(io::IO, bundle::AbstractString; launch::Bool = true, env = ENV,
    home = homedir())::Int
    while true
        file = installFile(; env, home)
        cur = something(readInstall(file), defaultInstall(; env, home))
        pick = request("Advanced:",
            RadioMenu(["Repair", "Check dependencies", "Folders",
                "What the icon opens and the terminal", "Back"]))
        if pick == 1
            found = check(bundle; env, home)
            _show(io, found.fixable, "  ! ")
            _show(io, found.missing, "  ? ")
            if isempty(found.fixable)
                println(io, isempty(found.missing) ? "All fine." : "Reinstall for ? files.")
            elseif _askYesNo(io, "Repair now?", true) && _apply(io, cur, bundle; env, home)
                println(io, "Repaired.")
                launch && (s = startNow(io, cur); s != 0 && return s)
            end
        elseif pick == 2
            _quiet(() -> checkDependencies(io; env, home))
        elseif pick == 3
            dirs = [cur.home, cur.structureCache]
            what = request("Folders:",
                RadioMenu(["Open projects", "Open cache", "Clear cache", "Back"]))
            if 1 <= what <= 2
                _quiet(() -> openFolder(dirs[what]; io))
            elseif what == 3
                println(io, "Empties ", dirs[2])
                _askYesNo(io, "Clear the cache?", false) ?
                println(io, clearCache(dirs[2])) : println(io, "Nothing removed.")
            end
        elseif pick == 4
            tui = _askYesNo(io,
                "Open the terminal interface when BAYSOL starts? (No: a shell)",
                cur.opens != "cli")
            terminal = cur.terminal
            found = Platform.ismacos() ? _foundTerminals() : String[]
            if !isempty(found)  # else there is nothing to choose
                ts = _terminalChoices(found)
                k = request("The icon opens it in:", RadioMenu(last.(ts));
                    cursor = something(findfirst(x -> first(x) == terminal, ts), 1))
                k < 1 && throw(InterruptException())
                terminal = first(ts[k])
            end
            i = _copy(cur; opens = tui ? "tui" : "cli", terminal)
            println(io, "Will set up:")
            describeInstall(io, i; found)
            if _askYesNo(io, "Apply?", true)
                _apply(io, i, bundle; env, home) && println(io, "Done.")
            else
                println(io, "Nothing written.")
            end
        else
            return 0
        end
    end
end

"""
    runWizard(bundle; io, env, home, firstRun, launch, advanced, clock) -> Int

The interactive wizard: welcome, then at the first run a short linear flow (the defaults
as plain lines, `Change any of these? (Yes/No)`, `Apply? (Yes/No)`, `Start BAYSOL now?
(Yes/No)`; the dependency check does not run). Later visits show a menu of four: Set up
(or Change), Advanced (repair, dependencies, folders, what the icon opens and the
terminal), Uninstall, Quit; it comes back after each step until Quit. Every question is
Yes or No; the only other inputs are the folders and threads (a default that Enter
takes) and one checklist of shortcuts. `advanced` opens the Advanced menu first. With
`launch` it asks `Start BAYSOL now?` after a setup or a repair. With `clock` (on a terminal
of at least 10 x 60, not `TERM=dumb`) a live clock ticks in the last row, stopped on every
exit path; it is paused where a subprocess owns the terminal.

# Returns
The exit status: 0, `LAUNCH_TUI` or `LAUNCH_CLI` (a Yes to starting), `UNINSTALLED` after
an uninstall, 130 after ^c, or 1 if the input is not a terminal.

# Exceptions
None; a failure of a step is printed.
"""
function runWizard(bundle::AbstractString = get(ENV, "BAYSOL_BUNDLE", pwd());
    io::IO = stdout, env = ENV, home = homedir(), firstRun::Bool = false,
    launch::Bool = true, advanced::Bool = false, clock::Bool = true)
    if !(stdin isa Base.TTY)
        println(io, "Needs a terminal.")
        return 1
    end
    _welcome(io)
    ck = clock && clockWanted(io, env) ? startClock(io) : nothing
    ACTIVE_CLOCK[] = ck
    try
        started = 0  # what the start question chose; set inside the loop, read after it
        removed = false  # an uninstall ran
        initial = true
        while true
            file = installFile(; env, home)
            saved = readInstall(file)
            choice =
                firstRun ? 1 :
                initial && advanced ? 2 :
                request("Choose:",
                    RadioMenu([saved === nothing ? "Set up" : "Change", "Advanced",
                        "Uninstall", "Quit"]))
            initial = false
            (choice < 1 || choice == 4) && break  # Quit, or the menu was aborted
            cur = something(saved, defaultInstall(; env, home))
            gone = false
            try
                if choice == 1
                    lock = hasProject(cur.home) && saved === nothing
                    i = setupFlow(io, cur, bundle; lockHome = lock, env, home)
                    i === nothing || (started = launch ? startNow(io, i) : 0)
                elseif choice == 2
                    started = advancedMenu(io, bundle; launch, env, home)
                elseif choice == 3
                    what = request("Uninstall:",
                        RadioMenu(["App and caches (your projects stay)",
                            "Everything, projects too (no undo)", "Back"]))
                    if what == 1
                        if _askYesNo(io, "Remove the app and its caches?", false)
                            _show(io, _quiet(() -> uninstall(bundle; i = cur, env, home)))
                            gone = true
                        else
                            println(io, "Nothing removed.")
                        end
                    elseif what == 2
                        println(io, "Deletes your projects too.")
                        println(io, "Type \"$CONFIRM_WORD\", or anything else to cancel:")
                        if _readLine(io) == CONFIRM_WORD
                            _show(
                                io,
                                _quiet(
                                    () ->
                                        uninstall(bundle; data = true, i = cur, env, home),
                                ),
                            )
                            gone = true
                        else
                            println(io, "Cancelled.")
                        end
                    end
                end
            catch e
                if e isa InterruptException  # ^c at a prompt: nothing was written yet
                    println(io, "\nCancelled; nothing written.")
                    return 130
                end
                println(io, "Failed: ", sprint(showerror, e))
                return 1
            end
            removed |= gone
            (firstRun || gone || started != 0) && break  # setup once at the first run
        end
        return removed ? UNINSTALLED : started
    finally  # every exit path: ^c, an error, an uninstall, a normal end
        stopClock!(ck)
        ACTIVE_CLOCK[] = nothing
    end
end

end # module
