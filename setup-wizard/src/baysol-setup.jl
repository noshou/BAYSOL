# SPDX-License-Identifier: LGPL-3.0-or-later

# The setup wizard of BAYSOL (`baysol setup`): a welcome page, the folders of the user's
# data and caches, the options that depend on a path (desktop entry, PATH link), and the
# uninstall (the app only, or the data as well). It is independent of the terminal
# interface and of the fitting code: standard library only (`REPL.TerminalMenus` for the
# menus), so it starts at once. Install-time facts live in `install.json`, apart from
# `settings.json` (settings are runtime things). A change is read by the interface when
# it is started again.

module BAYSOLSetup

using REPL.TerminalMenus: RadioMenu, MultiSelectMenu, request
using REPL.Terminals: TTYTerminal, raw!

export clearCache, openFolder, fileManagerCommands, shellCommand, drawIcon, needsSetup,
    hasProject, check, cleanPath, Install, defaultInstall,
    installFile, manifestFile, readManifest, readInstall, writeInstall, applyInstall,
    rollback!, uninstall, runWizard,
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
What the wizard decides. `home` is the BAYSOL folder (projects), `cache` the shared
cache, `structureCache` the cache of the structure preparation (what the fit reads as
`BAYSOL_CACHE`); `desktop` says whether the entry in the application menu is made,
`desktopIcon` whether the launcher is also put on the Desktop, `taskbarPin` whether it is
pinned to the taskbar or dock, and `pathLink` whether the link on the PATH is made;
`threads` is the default number of threads of a fit; `opens` says what the launcher
(the icon, or `baysol` alone) starts: `"tui"` (the terminal interface) or `"cli"` (a shell
with the command line ready).
"""
Base.@kwdef struct Install
    home::String
    cache::String
    structureCache::String
    desktop::Bool = false
    desktopIcon::Bool = false
    taskbarPin::Bool = false
    pathLink::Bool = false
    threads::Int = defaultThreads()
    opens::String = "tui"
end

# ---- the folders of the system (XDG on Linux, the usual ones elsewhere) ---------------

_env(env, name) = (v = strip(get(env, name, "")); isabspath(v) ? v : nothing)

"The data folder of the system: where `baysol/` (the projects) goes by default."
function dataHome(; env = ENV, home = homedir())
    Sys.iswindows() && return something(_env(env, "LOCALAPPDATA"),
        joinpath(home, "AppData", "Local"))
    Sys.isapple() && return joinpath(home, "Library", "Application Support")
    return something(_env(env, "XDG_DATA_HOME"), joinpath(home, ".local", "share"))
end

"The cache folder of the system."
function cacheHome(; env = ENV, home = homedir())
    Sys.iswindows() && return something(_env(env, "LOCALAPPDATA"),
        joinpath(home, "AppData", "Local"))
    Sys.isapple() && return joinpath(home, "Library", "Caches")
    return something(_env(env, "XDG_CACHE_HOME"), joinpath(home, ".cache"))
end

"The folder of `install.json`: the configuration folder of the system, never the data."
function configHome(; env = ENV, home = homedir())
    Sys.iswindows() && return something(_env(env, "APPDATA"),
        joinpath(home, "AppData", "Roaming"))
    Sys.isapple() && return joinpath(home, "Library", "Application Support")
    return something(_env(env, "XDG_CONFIG_HOME"), joinpath(home, ".config"))
end

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

The defaults: the projects in the data folder of the system, the caches in its cache folder.

# Returns
An [`Install`](@ref) with no desktop entry and no PATH link.

# Exceptions
None.
"""
defaultInstall(; env = ENV, home = homedir()) = Install(;
    home = joinpath(dataHome(; env, home), "baysol"),
    cache = joinpath(cacheHome(; env, home), "baysol", "_cache"),
    structureCache = joinpath(cacheHome(; env, home), "baysol", "_structures"),
)

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
        "home" => _quote(i.home), "cache" => _quote(i.cache),
        "structureCache" => _quote(i.structureCache),
        "desktop" => string(i.desktop), "desktopIcon" => string(i.desktopIcon),
        "taskbarPin" => string(i.taskbarPin), "pathLink" => string(i.pathLink),
        "threads" => string(i.threads), "opens" => _quote(i.opens),
    ]
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
    (h, c, s) = (str("home"), str("cache"), str("structureCache"))
    any(isnothing, (h, c, s)) && return nothing
    t = match(r"\"threads\"\s*:\s*(\d+)", text)
    return Install(; home = h, cache = c, structureCache = s,
        desktop = bool("desktop"), desktopIcon = bool("desktopIcon"),
        taskbarPin = bool("taskbarPin"), pathLink = bool("pathLink"),
        threads = t === nothing ? defaultThreads() : parse(Int, t[1]),
        opens = str("opens") in ("tui", "cli") ? str("opens") : "tui")
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
    return i === nothing || any(isempty ∘ strip, (i.home, i.cache, i.structureCache))
end

"A folder as the user typed it: `~` expanded, made absolute and normal."
function cleanPath(text::AbstractString; home = homedir())
    t = strip(text)
    t == "~" && return home
    startswith(t, "~/") && (t = joinpath(home, t[3:end]))
    isabspath(t) || (t = joinpath(home, t))  # a relative name is under the home folder
    p = normpath(t)
    return length(p) > 1 ? rstrip(p, '/') : p
end

# ---- the path-dependent install options -----------------------------------------------

"""
The icon file at the root of the bundle: `baysol.ico` on Windows, `baysol.icns` elsewhere
(`bysl pkg` packs it from the hand-made PNG sizes of `icons/`, nothing is resized).
On Linux the wizard unpacks the sizes of the `.icns` into the user's `hicolor` theme.
"""
const ICON_FILE = Sys.iswindows() ? "baysol.ico" : "baysol.icns"

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

"The PNG signature, which starts every PNG entry of an `.icns`."
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
       Sys.which("gtk-update-icon-cache") !== nothing
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
    pngs = [
        p for p in iconPngs(joinpath(bundle, ICON_FILE)) if haskey(HICOLOR_SIZES, first(p))
    ]
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
    isdir(dir) && Sys.which("update-desktop-database") !== nothing || return nothing
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
        Sys.isapple() ? joinpath(home, "Applications") :
        joinpath(something(_env(env, "XDG_DATA_HOME"),
            joinpath(home, ".local", "share")), "applications")
    startMenu = joinpath(something(_env(env, "APPDATA"),
        joinpath(home, "AppData", "Roaming")),
        "Microsoft", "Windows", "Start Menu", "Programs")
    return (desktop = joinpath(apps, "baysol.desktop"),
        icon = joinpath(desktopDir(; env, home), "BAYSOL.desktop"),
        link = joinpath(home, ".local", "bin", "baysol"),
        app = joinpath(home, "Applications", "BAYSOL.app"),
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
    Sys.islinux() || return fallback
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
    Sys.which("gsettings") === nothing && return nothing
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
the only desktop done: KDE, macOS and Windows are told to pin by hand (untested elsewhere).
"""
function _pin!(journal, env)
    if !Sys.islinux()
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

"Removes the pin again (an uninstall); returns a line, or `nothing` if there was none."
function _unpin()
    Sys.islinux() || return nothing
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

partition3(line) = (a = split(line, '\t'; limit = 2); length(a) == 2 ?
                                   (a[1], "\t", a[2]) : (line, "", ""))

"Writes `made` to `file`, with what an earlier manifest already named (no duplicates)."
function _writeManifest(file, made)
    old = ["$(k)\t$(p)" for (k, p) in readManifest(file)]
    mkpath(dirname(file))
    write(file, join(unique([old; made]), "\n") * "\n")
    return file
end

"""
Removes what `entries` name: files (a link only if it points into `bundle`), then the
folders, deepest first, and only when they are empty. Nothing else is touched. Returns the
log and the entries it kept (a link that points elsewhere).
"""
function _removeManifest(entries, bundle)
    log, kept = String[], Pair{String,String}[]
    for (kind, path) in entries
        kind == "file" || continue
        if islink(path)
            startswith(readlink(path), bundle) || (push!(kept, kind => path); continue)
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
        </dict>
        </plist>
        """
end

"""
Makes `BAYSOL.app` at `app` (macOS; untested): `Contents/Info.plist` naming the icon, the
`.icns` copied from `icns` into `Contents/Resources`, and a small script in
`Contents/MacOS` that opens the bundle's `BAYSOL.command` in Terminal. Every file and
folder is noted in `made`. Returns a line to say what was done.
"""
function _installMacApp!(journal, made, bundle, app, icns)
    _madeDir!(made, journal, joinpath(app, "Contents", "MacOS"))
    _madeDir!(made, journal, joinpath(app, "Contents", "Resources"))
    plist = _madeFile!(made, joinpath(app, "Contents", "Info.plist"))
    write(plist, infoPlist())
    exe = _madeFile!(made, joinpath(app, "Contents", "MacOS", "BAYSOL"))
    command = joinpath(bundle, "BAYSOL.command")
    write(exe, "#!/bin/zsh\nexec /usr/bin/open -a Terminal \"$command\"\n")
    chmod(exe, 0o755)
    if isfile(icns)
        res = _madeFile!(made, joinpath(app, "Contents", "Resources", ICON_NAME * ".icns"))
        cp(icns, res; force = true)
    end
    return "app bundle $app (macOS, untested)"
end

"""
Makes the shortcut `lnk` to `target` with the icon `ico` (Windows; untested) through
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
(Windows; untested). `makeShortcut(lnk, target, ico, workdir)` creates the `.lnk`. Every
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
    return "start menu shortcut $lnk (Windows, untested)"
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

Makes the folders, writes `install.json` and, if asked, the entry in the application menu,
the icon on the Desktop, the taskbar pin and the link on the PATH. Every step pushes how to
undo it onto `journal`; [`rollback!`](@ref) runs them. The entries are only written for
Linux, the pin only for GNOME there (macOS and Windows: untested, the wizard says so and
skips them). A pin needs the menu entry, so it writes that too.

# Returns
A line for each thing done or skipped.

# Exceptions
An `IOError` if a folder or file cannot be written.
"""
function applyInstall(i::Install, bundle::AbstractString; env = ENV, home = homedir(),
    journal::Vector{Function} = Function[])
    log = String[]
    made = String[]  # the manifest lines of the icons and entries
    for d in (i.home, i.cache, i.structureCache)
        _mkpath!(journal, d)
        push!(log, "folder $d")
    end
    t = targets(; env, home)
    icon = ICON_FALLBACK
    entries = i.desktop || i.taskbarPin
    if Sys.islinux() && (entries || i.desktopIcon)
        installed, line = _installIcons!(journal, made, bundle; env, home)
        installed && (icon = ICON_NAME)
        push!(log, line)
    end
    if entries
        if Sys.islinux()
            _madeDir!(made, journal, dirname(t.desktop))
            _backup!(journal, t.desktop)
            write(_madeFile!(made, t.desktop), desktopEntry(bundle; icon))
            _refreshEntries(dirname(t.desktop))
            push!(log, "menu entry $(t.desktop)")
        elseif Sys.isapple()
            _madeDir!(made, journal, dirname(t.app))
            push!(
                log,
                _installMacApp!(journal, made, bundle, t.app,
                    joinpath(bundle, ICON_FILE)),
            )
        elseif Sys.iswindows()
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
        if Sys.islinux() && isdir(dirname(t.icon))
            _backup!(journal, t.icon)
            write(_madeFile!(made, t.icon), desktopEntry(bundle; icon))
            chmod(t.icon, 0o755)  # the desktops start an executable entry
            # GNOME also wants it marked as trusted; other desktops ignore the attribute
            Sys.which("gio") === nothing || try
                run(
                    pipeline(`gio set $(t.icon) metadata::trusted true`;
                        stdout = devnull, stderr = devnull),
                )
            catch
            end
            push!(log, "desktop icon $(t.icon)")
        elseif Sys.islinux()
            push!(log, "desktop icon skipped (no folder $(dirname(t.icon)))")
        else
            push!(log, "desktop icon skipped (Linux only, untested elsewhere)")
        end
    end
    i.taskbarPin && push!(log, _pin!(journal, env))
    if i.pathLink
        if Sys.isunix()
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
_exe(name) = Sys.iswindows() ? name * ".exe" : name

"""
The start script of the bundle on this system
(`bysl pkg` writes it; the menu entry runs `baysol`).
"""
const LAUNCHER_FILE =
    Sys.iswindows() ? "baysol.cmd" : Sys.isapple() ? "BAYSOL.command" : "baysol.sh"

"The files of the bundle the launcher and the entry need (a repair cannot restore them)."
const BUNDLE_FILES = (_exe("baysol"), _exe("baysol-tui"), LAUNCHER_FILE,
    joinpath("lib", "pytools", _exe("baysol-pytools")), ICON_FILE)

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
    for (what, d) in (("projects", i.home), ("cache", i.cache),
        ("structure cache", i.structureCache))
        if isempty(strip(d))
            push!(fixable, "the $what folder is blank in install.json")
        elseif !isdir(d)
            push!(fixable, "the $what folder is missing: $d")
        elseif !Sys.iswindows() && !(uperm(d) & 0x02 != 0)
            push!(fixable, "the $what folder is not writable: $d")
        end
    end
    t = targets(; env, home)
    launcher = joinpath(bundle, "baysol")
    if Sys.isapple() && (i.desktop || i.taskbarPin) && !isdir(t.app)
        push!(fixable, "the app bundle is missing: $(t.app)")
    elseif Sys.iswindows() && (i.desktop || i.taskbarPin) && !isfile(t.lnk)
        push!(fixable, "the Start Menu shortcut is missing: $(t.lnk)")
    end
    for (on, file, what) in ((i.desktop || i.taskbarPin, t.desktop, "menu entry"),
        (i.desktopIcon, t.icon, "desktop icon"))
        on && Sys.islinux() || continue
        if !isfile(file)
            push!(fixable, "the $what is missing: $file")
        elseif !occursin("Exec=\"$launcher\"", read(file, String))
            push!(fixable, "the $what points to another bundle: $file")
        end
    end
    if Sys.islinux() && (i.desktop || i.taskbarPin || i.desktopIcon)
        sizes = [first(p) for p in iconPngs(joinpath(bundle, ICON_FILE))]
        gone = [f for f in iconFiles(sizes; env, home) if !isfile(f)]
        isempty(gone) || push!(
            fixable,
            "icon sizes are missing: $(length(gone)) in $(hicolorDir(; env, home))",
        )
    end
    if i.pathLink
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
    uninstall(bundle; data, i, env, home) -> Vector{String}

Removes the app side: the icons, menu entry, app bundle or shortcut, Desktop
icon and PATH link that the install manifest names (a link only if it points
into `bundle`; nothing the manifest does not name), the taskbar pin, the
manifest, `install.json`, the bundle folder and the cache folders (only if they
carry the marker or are empty). The projects folder stays unless `data = true`.

# Returns
A line for each thing removed or kept.

# Exceptions
An `IOError` if something cannot be removed.
"""
function uninstall(bundle::AbstractString; data::Bool = false,
    i::Union{Install,Nothing} = nothing, env = ENV, home = homedir())
    log = String[]
    cfg = installFile(; env, home)
    i = something(i, readInstall(cfg), defaultInstall(; env, home))
    t = targets(; env, home)
    mf = manifestFile(; env, home)
    # the icons and entries: exactly what the manifest names, and nothing else
    lines, kept = _removeManifest(readManifest(mf), bundle)
    append!(log, lines)
    if Sys.islinux()
        _refreshIcons(; env, home)
        _refreshEntries(dirname(t.desktop))
    end
    pin = _unpin()
    pin === nothing || push!(log, pin)
    for c in (i.cache, i.structureCache)
        if _ours(c)
            rm(c; recursive = true)
            push!(log, "removed $c")
        elseif isdir(c)
            push!(log, "kept $c (not marked as BAYSOL's)")
        end
    end
    if data
        isdir(i.home) && (rm(i.home; recursive = true); push!(log, "removed $(i.home)"))
    else
        push!(log, "kept the projects: $(i.home)")
    end
    if isempty(kept)
        isfile(mf) && (rm(mf); push!(log, "removed $mf"))
    else
        write(mf, join(["$k\t$p" for (k, p) in kept], "\n") * "\n")  # for a later uninstall
    end
    isfile(cfg) && (rm(cfg); push!(log, "removed $cfg"))
    isdir(bundle) && (rm(bundle; recursive = true); push!(log, "removed $bundle"))
    return log
end

# ---- the folders: open one, clear a cache
# -------------------------------------------------

"""
    clearCache(dir) -> String

Empties the cache folder `dir` (the folder itself stays), only if it is BAYSOL's: it holds
the `CACHE_TAG` marker or is empty. The projects folder has no such function on purpose.

# Returns
A line that says what happened.

# Exceptions
An `IOError` if something cannot be removed.
"""
function clearCache(dir::AbstractString)
    isdir(dir) || return "no folder $dir"
    _ours(dir) || return "kept $dir (not marked as BAYSOL's)"
    n = 0
    for f in readdir(dir; join = true)
        basename(f) == CACHE_TAG && continue
        rm(f; recursive = true, force = true)
        n += 1
    end
    return "cleared $dir ($n entries)"
end

"""
    fileManagerCommands() -> Vector{Cmd}

The commands to try, in order, to open a folder in the file manager of this system (the
folder is appended): `xdg-open` then `gio open` on Linux, `open` on macOS, `explorer` on
Windows. Only those found on the PATH are listed.
"""
function fileManagerCommands()
    names =
        Sys.isapple() ? [["open"]] :
        Sys.iswindows() ? [["explorer"]] :
        [["xdg-open"], ["gio", "open"]]
    return [
        Cmd([Sys.which(n[1]), n[2:end]...]) for n in names if Sys.which(n[1]) !== nothing
    ]
end

"""
    shellCommand(; env) -> Cmd

The user's shell: `\$SHELL` (else `/bin/sh`) on Linux and macOS, `%COMSPEC%` (else
`cmd.exe`) on Windows.
"""
function shellCommand(; env = ENV)
    Sys.iswindows() && return Cmd([something(_env(env, "COMSPEC"), "cmd.exe")])
    return Cmd([something(_env(env, "SHELL"), "/bin/sh")])
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
        if !process_running(p) && !success(p) && !Sys.iswindows()
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

# ---- the icon: 32 x 32 pixels of three colours, drawn as half blocks (32 x 16 cells) --

"The icon at 32 x 32, one letter a pixel: k black, p pink, t teal."
const ICON = (
    "pppppppppppppppppppppppppppppppp",
    "pppppppppppppppppppppppppppppppp",
    "ppppkkkkkkkkkkkkkkkkkkkkkkkkpppp",
    "ppppkkkkkkkkkkkkkkkkkkkkkkkkpppp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkttttttttkkkkkkkkkkkkpp",
    "ppkkkkkkkkttttttttkkkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttttttttkkkkkkkkkkkkpp",
    "ppkkkkkkkkttttttttkkkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttkkkkkkttkkkkkkkkkkpp",
    "ppkkkkkkkkttttttttkkkkkkkkkkkkpp",
    "ppkkkkkkkkttttttttkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppkkkkkkkkkkkkkkkkkkkkkkkkkkkkpp",
    "ppppkkkkkkkkkkkkkkkkkkkkkkkkpppp",
    "ppppkkkkkkkkkkkkkkkkkkkkkkkkpppp",
    "pppppppppppppppppppppppppppppppp",
    "pppppppppppppppppppppppppppppppp",
)

"The colours of the letters: truecolor (RGB), and the nearest of the 256 colours."
const ICON_RGB = Dict('k' => (0, 0, 0), 'p' => (255, 97, 126), 't' => (0, 255, 204))
const ICON_256 = Dict('k' => 16, 'p' => 204, 't' => 49)

"The icon halved: each 2 x 2 block of pixels averaged, so the edges blend (16 x 16)."
function _halved()
    px(y, x) = ICON_RGB[ICON[y][x]]
    block(y, x) = (px(y, x), px(y, x + 1), px(y + 1, x), px(y + 1, x + 1))
    return [
        sum(collect, block(y, x)) ./ 4
        for y in 1:2:length(ICON), x in 1:2:length(ICON[1])
    ]
end

"""
    drawIcon(io; truecolor) -> Nothing

Draws the icon at 16 x 8 character cells: the 32 x 32 pixels averaged to 16 x 16 (the edges
blend) and drawn with `▀` (the upper pixel is the foreground, the lower one the background).

# Returns
`nothing`.

# Exceptions
None.
"""
function drawIcon(io::IO = stdout;
    truecolor::Bool = get(ENV, "COLORTERM", "") in ("truecolor", "24bit"))
    cube(v) = round(Int, v / 255 * 5)
    code(c) =
        truecolor ? join(round.(Int, c), ';') :
        string(16 + 36cube(c[1]) + 6cube(c[2]) + cube(c[3]))
    fg(c) = truecolor ? "\e[38;2;$(code(c))m" : "\e[38;5;$(code(c))m"
    bg(c) = truecolor ? "\e[48;2;$(code(c))m" : "\e[48;5;$(code(c))m"
    img = _halved()
    for y in 1:2:size(img, 1)
        print(io, "  ")
        last = nothing
        for x in 1:size(img, 2)
            cell = (img[y, x], img[y+1, x])
            cell == last || print(io, fg(cell[1]), bg(cell[2]))  # only when it changes
            print(io, "▀")
            last = cell
        end
        println(io, "\e[0m")
    end
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
        _show(io, applyInstall(i, bundle; env, home, journal))
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

"After a setup: what to start now. Returns 0 (nothing), `LAUNCH_TUI` or `LAUNCH_CLI`."
function _launchMenu()
    pick = request("Launch:", RadioMenu(["TUI", "CLI", "Quit"]))
    return pick == 1 ? LAUNCH_TUI : pick == 2 ? LAUNCH_CLI : 0
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
    runWizard(bundle; io, env, home, firstRun, launch) -> Int

The interactive wizard: welcome, then a menu (set up or change, repair, uninstall) that
comes back after each step (a cancel included) until Quit. With `launch` it asks, after a
setup or a repair, what to start now.

# Returns
The exit status: 0, `LAUNCH_TUI` or `LAUNCH_CLI` (the choice of the launch question),
`UNINSTALLED` after an uninstall, 130 after ^c, or 1 if the input is not a terminal.

# Exceptions
None; a failure of a step is printed.
"""
function runWizard(bundle::AbstractString = get(ENV, "BAYSOL_BUNDLE", pwd());
    io::IO = stdout, env = ENV, home = homedir(), firstRun::Bool = false,
    launch::Bool = true)
    if !(stdin isa Base.TTY)
        println(io, "Needs a terminal.")
        return 1
    end
    _welcome(io)
    started = 0  # what the launch question chose; set inside the loop, read after it
    removed = false  # an uninstall ran
    while true
        choice =
            firstRun ? 1 :
            request("Choose:",
                RadioMenu(["Set up or change", "Repair", "Folders", "Uninstall", "Quit"]))
        (choice < 1 || choice == 5) && break  # Quit, or the menu was aborted
        cur = something(readInstall(installFile(; env, home)), defaultInstall(; env, home))
        gone = false
        try
            if choice == 1
                if hasProject(cur.home) && readInstall(installFile(; env, home)) === nothing
                    h = cur.home
                    println(io, "Found a BAYSOL folder:")
                    println(io, "  ", h)
                    println(io, "Only one can exist; using it.")
                else
                    h = cleanPath(_ask(io, "Projects folder", cur.home); home)
                    hasProject(h) && println(io,
                        "Found one there; only one can exist; using it.")
                end
                c = cleanPath(_ask(io, "Cache folder", cur.cache); home)
                s = cleanPath(_ask(io, "Structure cache", cur.structureCache); home)
                n = tryparse(Int, _ask(io, "Threads per fit", string(cur.threads)))
                n = clamp(something(n, cur.threads), 1, 256)
                o = request("The icon opens:", RadioMenu(["TUI", "CLI (a shell)"]))
                o < 1 && throw(InterruptException())
                opts = request("Shortcuts (Enter, then d):",
                    MultiSelectMenu([
                        "Application menu entry", "Desktop icon",
                        "Pin to taskbar (GNOME)", "PATH link",
                    ]),
                )
                i = Install(; home = h, cache = c, structureCache = s,
                    desktop = 1 in opts, desktopIcon = 2 in opts,
                    taskbarPin = 3 in opts, pathLink = 4 in opts, threads = n,
                    opens = o == 2 ? "cli" : "tui")
                println(io, "Will set up:")
                println(io, "  projects   ", i.home)
                println(io, "  cache      ", i.cache)
                println(io, "  structures ", i.structureCache)
                println(io, "  threads    ", i.threads)
                println(io, "  icon opens ", uppercase(i.opens))
                i.desktop && println(io, "  application menu entry")
                i.desktopIcon && println(io, "  desktop icon")
                i.taskbarPin && println(io, "  taskbar pin")
                i.pathLink && println(io, "  PATH link")
                if request("Apply?", RadioMenu(["Apply", "Cancel"])) == 1
                    if _apply(io, i, bundle; env, home)
                        println(io, "Done.")
                        started = launch ? _launchMenu() : 0
                    end
                else
                    println(io, "Nothing written.")
                end
            elseif choice == 2
                found = check(bundle; env, home)
                _show(io, found.fixable, "  ! ")
                _show(io, found.missing, "  ? ")
                if isempty(found.fixable)
                    println(io,
                        isempty(found.missing) ? "All fine." : "Reinstall for ? files.")
                elseif request("Repair:", RadioMenu(["Repair now", "Cancel"])) == 1
                    if _apply(io, cur, bundle; env, home)
                        println(io, "Repaired.")
                        started = launch ? _launchMenu() : 0
                    end
                end
            elseif choice == 3
                dirs = [("projects", cur.home), ("cache", cur.cache),
                    ("structure cache", cur.structureCache)]
                pick = request(
                    "Folders:",
                    RadioMenu([
                        "Open projects", "Open cache", "Open structure cache",
                        "Clear cache", "Clear structure cache", "Back"]),
                )
                if 1 <= pick <= 3
                    openFolder(dirs[pick][2]; io)
                elseif pick == 4 || pick == 5
                    d = dirs[pick-2][2]
                    println(io, "Empties ", d)
                    request("Clear?", RadioMenu(["Clear", "Cancel"])) == 1 ?
                    println(io, clearCache(d)) : println(io, "Nothing removed.")
                end
            elseif choice == 4
                while true  # a cancel of the confirmation comes back to this menu
                    what = request(
                        "Uninstall:",
                        RadioMenu([
                            "App and caches", "Everything (no undo)", "Cancel"]),
                    )
                    if what == 1
                        _show(io, uninstall(bundle; i = cur, env, home))
                        gone = true
                    elseif what == 2
                        println(io, "Deletes your projects too.")
                        println(io, "Type \"$CONFIRM_WORD\", or anything else to cancel:")
                        if _readLine(io) == CONFIRM_WORD
                            _show(io,
                                uninstall(bundle; data = true, i = cur, env, home))
                            gone = true
                        else
                            println(io, "Cancelled.")
                            continue
                        end
                    end
                    break  # done, or Cancel: leave this menu
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
end

end # module
