# SPDX-License-Identifier: LGPL-3.0-or-later

"""
One way to install an item with a package manager: the program `manager` (found with
`Platform.which`) run with `args`, on the system `os`. `admin` says the command needs
administrator rights (`sudo` on Linux and macOS casks), so it is shown and not run.
"""
struct Route
    os::Symbol
    manager::String
    args::Vector{String}
    admin::Bool
end

"""
What is checked. `level` is `:required`, `:optional` or `:info` (a fact, nothing to
install); `oses` are the systems it applies to (`Platform.os()` symbols); `hint` says the
detector can only guess; `routes` are the package-manager routes in order of preference and
`manual` the text for a system without one (or without the manager).
"""
struct DepItem
    id::String
    name::String
    level::Symbol
    oses::Vector{Symbol}
    why::String
    hint::Bool
    routes::Vector{Route}
    manual::Vector{Pair{Symbol,String}}
end

"What a detector found: whether, and a path, a version or the reason for a guess."
struct Detection
    found::Bool
    detail::String
end

"One line of the report: the item, whether it applies here, and what was found."
struct DepResult
    item::DepItem
    applicable::Bool
    found::Bool
    detail::String
end

"The answers that are remembered in `install.json`, and what each means."
const DEP_ANSWERS = ("yes", "no", "later", "never")

"The LaTeX engines BAYSOL can compile plots with (`lualatex` and `xelatex` first)."
const LATEX_ENGINES = ("lualatex", "xelatex", "pdflatex")

"The terminal size the interface needs (columns, rows): `minColumns` and `minRows`."
const MIN_TERMINAL = (80, 24)

"The font (PostScript name) and size (points) that the check suggests for Terminal.app."
const MAC_FONT = ("Menlo-Regular", 14)

"AppleScript: the profile of the front Terminal window (the one the wizard runs in)."
const MAC_PROFILE = "settings set (name of current settings of front window)"

"AppleScript that reads the font and size of the front Terminal window."
const MAC_FONT_READ =
    "tell application \"Terminal\" to get (font name of $MAC_PROFILE) & \" \" & " *
    "(font size of $MAC_PROFILE)"

"AppleScript that gives that profile the suggested font and size."
const MAC_FONT_SET =
    "tell application \"Terminal\" to tell $MAC_PROFILE to set " *
    "{font name, font size} to {\"$(MAC_FONT[1])\", $(MAC_FONT[2])}"

"The items of the check."
function defaultItems()::Vector{DepItem}
    allOS = [:windows, :macos, :linux]
    brew = DepItem("brew", "Homebrew", :optional, [:macos],
        "Only to install optional things such as iTerm2 from here; " *
        "BAYSOL works without it.",
        false, Route[], [:macos => "By hand: https://brew.sh"])
    latex = DepItem("latex", "LaTeX engine (TeX Live)", :optional, allOS,
        "Only renders plots to PDF. It is large (gigabytes); BAYSOL works without it.",
        false,
        [Route(:macos, "brew", ["install", "--cask", "mactex-no-gui"], true),
            Route(:linux, "apt",
                ["install", "texlive-latex-recommended",
                    "texlive-latex-extra", "texlive-pictures", "texlive-luatex",
                    "texlive-xetex"], true),
            Route(:linux, "dnf",
                ["install", "texlive-scheme-basic", "texlive-luatex",
                    "texlive-xetex"], true),
            Route(:linux, "pacman",
                ["-S", "texlive-basic", "texlive-latex",
                    "texlive-xetex"], true)],
        [
            :windows =>
                "No winget package of TeX Live. Install it with install-tl " *
                "(https://tug.org/texlive/windows.html), or MiKTeX " *
                "(https://miktex.org/download) as a smaller alternative; " *
                "lualatex or xelatex must be on the PATH afterwards.",
            :macos =>
                "Install MacTeX (https://tug.org/mactex/), or the smaller " *
                "BasicTeX (brew install --cask basictex, then add the packages " *
                "the plots use with tlmgr).",
            :linux =>
                "Install the texlive packages of your distribution " *
                "(lualatex or xelatex on the PATH); https://tug.org/texlive/."])
    sixel = DepItem("sixel", "Sixel terminal (rendered figures in the interface)",
        :optional, allOS,
        "Only for rendered figures in the interface; it falls back to Unicode plots. " *
        "This is a hint: the interface asks your terminal itself when it starts.",
        true,
        [
            Route(:windows, "winget",
                ["install", "--id", "Microsoft.WindowsTerminal", "-e"],
                false),
            Route(:macos, "brew", ["install", "--cask", "iterm2"], false),
            Route(:linux, "apt", ["install", "foot"], true),
            Route(:linux, "dnf", ["install", "foot"], true),
            Route(:linux, "pacman", ["-S", "foot"], true)],
        [
            :windows =>
                "Use a recent Windows Terminal (check its release notes for " *
                "sixel) or WezTerm (https://wezfurlong.org/wezterm/).",
            :macos =>
                "Use iTerm2 (https://iterm2.com) or WezTerm " *
                "(https://wezfurlong.org/wezterm/).",
            :linux =>
                "Use foot, WezTerm or a recent Konsole; check the terminal's " *
                "documentation for sixel."])
    color = DepItem("truecolor", "Truecolor terminal", :info, allOS,
        "COLORTERM says truecolor (or Windows Terminal); the interface needs no install.",
        true, Route[], Pair{Symbol,String}[])
    size = DepItem("size", "Terminal of at least 80 x 24", :info, allOS,
        "The interface asks for 80 columns and 24 rows; resize the window if it is " *
        "smaller.", false, Route[], Pair{Symbol,String}[])
    font = DepItem("font", "Terminal font", :optional, [:macos],
        "Terminal's default font, SF Mono, can draw the logo, borders and text roughly. " *
        "Menlo $(MAC_FONT[2]) pt (part of macOS) is suggested. It changes the Terminal " *
        "profile of this window, for every window that uses it.",
        false, [Route(:macos, "osascript", ["-e", MAC_FONT_SET], false)],
        [
            :macos =>
                "By hand, or to undo: Terminal > Settings > Profiles > Text > Font " *
                "(the default is SF Mono 11 pt).",
        ])
    spacing = DepItem("spacing", "Terminal character and line spacing", :optional,
        [:macos],
        "Spacing other than 1.0 can leave gaps in the logo and borders.",
        false, Route[],
        [
            :macos =>
                "In Terminal > Settings > Profiles, pick this window's profile, " *
                "then Text: " *
                "set character spacing and line spacing to 1.0.",
        ])
    return [brew, latex, sixel, color, size, font, spacing]
end

"""
Where the program `name` is (`Platform.which`), or `nothing`. On macOS also Homebrew in its
own folders (an app opened from Finder does not have them on the PATH) and an app
(`iTerm.app`) in the application folders.
"""
function _find(name::AbstractString)::Union{String,Nothing}
    p = Platform.which(name)::Union{String,Nothing}
    (p === nothing && Platform.ismacos()) || return p
    places =
        name == "brew" ? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] :
        endswith(name, ".app") ?
        ["/Applications/$name", joinpath(homedir(), "Applications", name)] :
        String[]
    k = findfirst(ispath, places)
    return k === nothing ? nothing : places[k]
end

# ---- the detectors ---------------------------------------------------------------------

"Homebrew, on the PATH or in its own folders (`_find`)."
function _detectBrew(which)::Detection
    p = which("brew")::Union{String,Nothing}
    return p === nothing ? Detection(false, "not installed") : Detection(true, p)
end

"The first LaTeX engine on the PATH (`which` is `Platform.which`, or a stand-in)."
function _detectLatex(which)::Detection
    for engine in LATEX_ENGINES
        p = which(engine)::Union{String,Nothing}
        p === nothing || return Detection(true, string(engine, ": ", p))
    end
    return Detection(false, "no lualatex, xelatex or pdflatex on the PATH")
end

"""
Whether the terminal probably draws sixel, from the environment only. The interface
(`tui/src/store/sixel-detect.ts`) asks the terminal (a Primary Device Attributes reply
with attribute 4, and a cell size in pixels); a Julia program cannot do that without
fighting the interface for the keyboard, so this is a hint from the variables of the
terminals known to draw sixel, and from terminals installed but not in use.
"""
function _detectSixel(env, which)::Detection
    program = get(env, "TERM_PROGRAM", "")
    term = get(env, "TERM", "")
    if haskey(env, "WT_SESSION")
        return Detection(true, "Windows Terminal (sixel needs a recent version)")
    elseif program == "iTerm.app" || program == "WezTerm" ||
           haskey(env, "WEZTERM_EXECUTABLE")
        return Detection(true, "probably " * (isempty(program) ? "WezTerm" : program))
    elseif occursin("foot", term) || occursin("sixel", term) || startswith(term, "mlterm")
        return Detection(true, "TERM=$term")
    elseif haskey(env, "KONSOLE_VERSION")
        return Detection(true, "Konsole (sixel needs a recent version)")
    end
    for t in MAC_TERMINALS
        which(t.app)::Union{String,Nothing} === nothing || return Detection(true,
            "$(t.name) is installed; start BAYSOL from it for rendered figures")
    end
    for name in ("wezterm", "foot", "konsole")
        (which(name)::Union{String,Nothing}) === nothing && continue
        return Detection(
            false,
            "$name is installed but this terminal is not known to " *
            "draw sixel; start BAYSOL from $name",
        )
    end
    return Detection(false, "this terminal is not known to draw sixel")
end

"Truecolor: `COLORTERM` is `truecolor` or `24bit` (as the icon uses), or Windows Terminal."
function _detectTruecolor(env)::Detection
    c = get(env, "COLORTERM", "")
    (c == "truecolor" || c == "24bit") && return Detection(true, "COLORTERM=$c")
    haskey(env, "WT_SESSION") && return Detection(true, "Windows Terminal")
    return Detection(false, "COLORTERM is not truecolor or 24bit")
end

"The size of the terminal against the interface's minimum (`dims` is rows, columns)."
function _detectSize(dims::Tuple{Int,Int})::Detection
    rows, cols = dims
    ok = cols >= MIN_TERMINAL[1] && rows >= MIN_TERMINAL[2]
    return Detection(ok, "$cols x $rows")
end

"""
The font and size of the front Terminal window (`SFMono-Regular 11`), `nothing` on failure.
"""
function _macFont(osascript::AbstractString)::Union{String,Nothing}
    try
        cmd = Cmd([osascript, "-e", MAC_FONT_READ])
        return String(strip(read(pipeline(cmd; stderr = devnull), String)))
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

"""
Whether the font needs no change: only SF Mono in Terminal.app is told to change. Another
terminal, and a font that cannot be read, are left alone. `read` is `_macFont` or a
stand-in.
"""
function _detectFont(env, which; read = _macFont)::Detection
    get(env, "TERM_PROGRAM", "") == "Apple_Terminal" ||
        return Detection(true, "not Terminal.app")
    exe = which("osascript")::Union{String,Nothing}
    font = exe === nothing ? nothing : read(exe)::Union{String,Nothing}
    (font === nothing || isempty(font)) && return Detection(true, "could not be read")
    return Detection(!startswith(font, "SFMono"), font)
end

"AppleScript that reads the name of the front Terminal window's profile."
const MAC_PROFILE_READ =
    "tell application \"Terminal\" to " *
    "get name of current settings of front window"

"""
The character and line spacing in the property list `xml` of a Terminal profile. A profile
leaves out the spacing that was never changed, which is 1.
"""
function _parseSpacing(xml::AbstractString)::Tuple{Float64,Float64}
    value(key) = begin
        m = match(Regex("<key>$key</key>\\s*<(?:real|integer)>([^<]+)<"), xml)
        m === nothing ? 1.0 : parse(Float64, m[1]::AbstractString)
    end
    return value("FontWidthSpacing"), value("FontHeightSpacing")
end

"""
The spacing of the front Terminal window's profile, as Terminal has saved it; `nothing` when
it cannot be read. Nothing is written.
"""
function _macSpacing(which)::Union{Tuple{Float64,Float64},Nothing}
    tools = map(which, ("osascript", "defaults", "plutil"))
    any(isnothing, tools) && return nothing
    osascript, defaults, plutil = tools
    try
        quiet(cmd) = pipeline(cmd; stderr = devnull)
        profile = strip(read(quiet(`$osascript -e $MAC_PROFILE_READ`), String))
        isempty(profile) && return nothing
        path = "Window Settings." * replace(profile, "." => "\\.")  # a dot parts the path
        plist = read(quiet(`$defaults export com.apple.Terminal -`))
        extract = quiet(`$plutil -extract $path xml1 -o - -`)
        return _parseSpacing(read(pipeline(extract; stdin = IOBuffer(plist)), String))
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

"""
Whether the spacing is 1.0 both ways. Another terminal, and a spacing that cannot be read,
are left alone. `read` is `_macSpacing` or a stand-in.
"""
function _detectSpacing(env, which; read = _macSpacing)::Detection
    get(env, "TERM_PROGRAM", "") == "Apple_Terminal" ||
        return Detection(true, "not Terminal.app")
    got = read(which)::Union{Tuple{Float64,Float64},Nothing}
    got === nothing && return Detection(true, "could not be read")
    ok = all(x -> isapprox(x, 1; atol = 1e-4), got)
    w, h = round.(got; digits = 4)
    return Detection(ok, "character $w, line $h")
end

"The detector of `item`, chosen by its id."
function _detect(item::DepItem, env, which, dims::Tuple{Int,Int})::Detection
    item.id == "brew" && return _detectBrew(which)
    item.id == "latex" && return _detectLatex(which)
    item.id == "sixel" && return _detectSixel(env, which)
    item.id == "truecolor" && return _detectTruecolor(env)
    item.id == "size" && return _detectSize(dims)
    item.id == "font" && return _detectFont(env, which)
    item.id == "spacing" && return _detectSpacing(env, which)
    return Detection(false, "")
end

"""
    scanDependencies(items; os, env, which, dims, detect) -> Vector{DepResult}

Looks at every item. An item that does not apply to `os` is not detected (`applicable` is
false). `env`, `which` and `dims` (rows, columns) can be faked by a test.
"""
function scanDependencies(items::Vector{DepItem} = defaultItems();
    os::Symbol = Platform.os(),
    env = ENV, which = _find, dims::Tuple{Int,Int} = displaysize(stdout),
    detect = _detect)::Vector{DepResult}
    out = DepResult[]
    for item in items
        if !(os in item.oses)
            push!(out, DepResult(item, false, false, ""))
            continue
        end
        d = detect(item, env, which, dims)::Detection
        push!(out, DepResult(item, true, d.found, d.detail))
    end
    return out
end

# ---- the report ------------------------------------------------------------------------

"The words of the status column for one result."
function _status(r::DepResult)::String
    r.applicable || return "not applicable"
    r.found && return r.item.hint ? "present (hint)" : "present"
    r.item.id in ("font", "spacing") && return "suggestion"
    r.item.level == :required && return "MISSING (required)"
    r.item.level == :optional && return "missing (optional)"
    return "no"
end

"""
    dependencyReport(io, results)

Prints one line for each result: the status, the name and what was found, then the reason
for what is missing.
"""
function dependencyReport(io::IO, results::Vector{DepResult})
    println(io, "Dependencies outside the bundle (the bundle carries Julia, Node, 7-Zip")
    println(io, "and the Python tools itself):")
    for r in results
        line = string("  ", rpad(_status(r), 18), r.item.name)
        r.applicable && !isempty(r.detail) && (line *= string(" - ", r.detail))
        println(io, line)
        r.applicable && !r.found && println(io, "      ", r.item.why)
    end
    return nothing
end

# ---- the answers in install.json -------------------------------------------------------

"The remembered answers (`id => answer`) of the `install.json` at `file`; empty if none."
function readDepAnswers(file::AbstractString)::Dict{String,String}
    i = readInstall(file)
    return i === nothing ? Dict{String,String}() : copy(i.deps)
end

"""
Writes `answers` into the `install.json` of this user, keeping every other field. Returns
false (writing nothing) when there is no valid `install.json` yet: answers are kept from
the first setup on, since the file marks a finished setup.
"""
function saveDepAnswers(answers::Dict{String,String}; env = ENV, home = homedir())::Bool
    file = installFile(; env, home)
    i = readInstall(file)
    i === nothing && return false
    writeInstall(
        file,
        Install(; home = i.home,
            structureCache = i.structureCache, desktop = i.desktop,
            desktopIcon = i.desktopIcon, taskbarPin = i.taskbarPin, pathLink = i.pathLink,
            threads = i.threads, opens = i.opens,
            terminal = i.terminal, deps = answers),
    )
    return true
end

# ---- the offer -------------------------------------------------------------------------

"The text of a route as the user would type it (`sudo` first when it needs rights)."
function routeText(r::Route)::String
    args = [occursin(' ', a) ? "'$a'" : a for a in r.args]
    return join([(r.admin ? ["sudo"] : String[]); r.manager; args], " ")
end

"The first route for `os` whose package manager is found, or `nothing`."
function pickRoute(item::DepItem, os::Symbol, which)::Union{Route,Nothing}
    for r in item.routes
        r.os == os && (which(r.manager)::Union{String,Nothing}) !== nothing && return r
    end
    return nothing
end

"The manual text of `item` for `os` (empty if there is none)."
function manualText(item::DepItem, os::Symbol)::String
    for (k, v) in item.manual
        k == os && return v
    end
    return ""
end

"Runs an install command and says whether it succeeded: the runner of a real install."
function _runCommand(cmd::Cmd)::Bool
    try
        run(cmd)
        return true
    catch
        return false
    end
end

"""
Asks a question of the check: Yes or No, typed like every other question of the wizard
(`choices` is always [`YES_NO`](@ref)). Returns 1 for Yes, 2 for No. ^c throws an
`InterruptException`, which ends the wizard as at any other question.
"""
_askChoice(prompt::AbstractString, choices::Vector{String})::Int =
    _askYesNo(stdout, prompt, false) ? 1 : 2

"The installer of Homebrew, as https://brew.sh gives it (it asks before it does anything)."
const BREW_INSTALL = Cmd([
    "/bin/bash",
    "-c",
    "script=\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/" *
    "install.sh) && exec /bin/bash -c \"\$script\"",
])

"Where iTerm2 is downloaded by hand."
const ITERM_PAGE = "https://iterm2.com/downloads.html"

"Runs Homebrew's installer; whether Homebrew is there afterwards."
function _installBrew(io::IO, which, runner)::Bool
    ok = runner(BREW_INSTALL)::Bool && (which("brew")::Union{String,Nothing}) !== nothing
    ok || println(io, "  Homebrew was not installed.")
    return ok
end

"What the user should know before Homebrew's installer runs."
function _brewNote(io::IO)
    println(io, "  Homebrew's own installer asks for your password, and it may download")
    println(io, "  Apple's Command Line Tools.")
    return nothing
end

"The two answers of every question: Yes or No."
const YES_NO = ["Yes", "No"]

"""
The answer to remember for a pick of [`YES_NO`](@ref): `"yes"`, `"no"`, and `"later"` when
the menu was cancelled.
"""
_yesNo(pick::Integer)::String = pick == 1 ? "yes" : pick == 2 ? "no" : "later"

"The offer of Homebrew (macOS). Returns the answer to remember."
function _offerBrew(io::IO, item::DepItem; which, runner, ask)::String
    _brewNote(io)
    println(io, "  ", manualText(item, :macos))
    answer = _yesNo(ask("Install Homebrew?", YES_NO)::Int)
    answer == "yes" || return answer
    _installBrew(io, which, runner) || return "later"
    println(io, "  Done.")
    return "yes"
end

"""
The offer of iTerm2 on a Mac without Homebrew: Homebrew and then iTerm2 after a Yes. The
download page of iTerm2 (no Homebrew needed) is named in the text. Nothing runs without
the Yes. Returns the answer to remember.
"""
function _offerITerm(io::IO, item::DepItem; which, runner, ask)::String
    println(io, "  Homebrew and iTerm2 are not installed.")
    _brewNote(io)
    println(io, "  Without Homebrew, download iTerm2 by hand: ", ITERM_PAGE)
    answer = _yesNo(ask("Install iTerm2 (Homebrew first)?", YES_NO)::Int)
    answer == "yes" || return answer
    _installBrew(io, which, runner) || return "later"
    brew = which("brew")::Union{String,Nothing}
    brew === nothing && return "later"
    ok = runner(Cmd([brew, "install", "--cask", "iterm2"]))::Bool
    println(
        io,
        ok ?
        "  Done. The BAYSOL icon now opens in iTerm2, " *
        "unless you chose another terminal." :
        "  Homebrew is installed, but iTerm2 could not be.",
    )
    return ok ? "yes" : "later"
end

"""
    offerInstall(io, item, os; which, runner, ask) -> String

Offers to install a missing `item` and returns the answer to remember: `"yes"` (the
command ran and succeeded), `"later"` (the menu was cancelled, or it failed, or the item is
only a note), `"no"`. Every question is Yes or No. The command only runs on a Yes, only
when the package manager is found and the command needs no administrator rights. When no
answer could install the item (it needs administrator rights, has no package manager here,
or is a manual step) nothing is asked: the command or the instruction is shown as a note.
`runner(cmd) -> Bool` runs a command (a test passes one that only records).
"""
function offerInstall(io::IO, item::DepItem, os::Symbol; which = _find,
    runner = _runCommand, ask = _askChoice)::String
    route = pickRoute(item, os, which)
    manual = manualText(item, os)
    println(io, item.name, ": ", item.why)
    item.id == "brew" && return _offerBrew(io, item; which, runner, ask)
    item.id == "sixel" && os == :macos && route === nothing &&
        return _offerITerm(io, item; which, runner, ask)
    if item.id == "spacing"  # Terminal has no command for it: the steps are shown on a Yes
        answer = _yesNo(ask("Change the Terminal spacing?", YES_NO)::Int)
        answer == "yes" && println(io, "  ", manual)
        return answer
    end
    if route === nothing || route.admin  # no answer installs it: a note, not a question
        if route === nothing
            any(r -> r.os == os, item.routes) &&
                println(io, "  No package manager found for it on this system.")
        else
            println(io, "  Note: this needs administrator rights, so BAYSOL does not ",
                "run it. Run:")
            println(io, "    ", routeText(route))
        end
        isempty(manual) || println(io, "  ", manual)
        return "later"
    end
    font = item.id == "font"  # a setting, nothing is installed
    println(io, "  Command: ", routeText(route))
    font && println(io, "  ", manual)
    answer = _yesNo(
        ask(font ? "Change the Terminal font?" : "Install " * item.name * "?",
            YES_NO)::Int,
    )
    answer == "yes" || return answer
    exe = which(route.manager)::Union{String,Nothing}
    exe === nothing && return "later"
    ok = runner(Cmd([exe; route.args]))::Bool
    println(io, ok ? "  Done." : "  The command failed; nothing was changed by BAYSOL.")
    return ok ? "yes" : "later"
end

"""
    checkDependencies(io; env, home, firstRun, os, which, dims, runner, ask, items)
        -> Vector{DepResult}

Scans, prints the report and, for each missing item, offers to install it (a prompt for
each item, nothing without an explicit yes). The answers are remembered in `install.json`
(`"dep.<id>"`): a stored `never` (from an older version, no question gives it now) is never
asked again; `no` is not asked again at the first run
(`firstRun`) but is when the user asks for the check from the menu; `later` and a missing
item after `yes` are asked again. Info items are only reported.
"""
function checkDependencies(io::IO = stdout; env = ENV, home = homedir(),
    firstRun::Bool = false, os::Symbol = Platform.os(), which = _find,
    dims::Tuple{Int,Int} = displaysize(io), runner = _runCommand, ask = _askChoice,
    items::Vector{DepItem} = defaultItems(), detect = _detect)::Vector{DepResult}
    results = scanDependencies(items; os, env, which, dims, detect)
    dependencyReport(io, results)
    stored = readDepAnswers(installFile(; env, home))
    answers = copy(stored)
    for r in results
        (r.applicable && !r.found && r.item.level != :info) || continue
        before = get(answers, r.item.id, "")
        if before == "never" || (firstRun && before == "no")
            println(io, "  ", r.item.name, ": not asking (you answered \"", before, "\")")
            continue
        end
        answers[r.item.id] = offerInstall(io, r.item, os; which, runner, ask)
    end
    if answers != stored && !saveDepAnswers(answers; env, home)
        println(io, "  (answers are remembered once BAYSOL is set up)")
    end
    return results
end
