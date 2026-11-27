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

"The items of the check."
function defaultItems()::Vector{DepItem}
    allOS = [:windows, :macos, :linux]
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
    return [latex, sixel, color, size]
end

# ---- the detectors ---------------------------------------------------------------------

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

"The detector of `item`, chosen by its id."
function _detect(item::DepItem, env, which, dims::Tuple{Int,Int})::Detection
    item.id == "latex" && return _detectLatex(which)
    item.id == "sixel" && return _detectSixel(env, which)
    item.id == "truecolor" && return _detectTruecolor(env)
    item.id == "size" && return _detectSize(dims)
    return Detection(false, "")
end

"""
    scanDependencies(items; os, env, which, dims, detect) -> Vector{DepResult}

Looks at every item. An item that does not apply to `os` is not detected (`applicable` is
false). `env`, `which` and `dims` (rows, columns) can be faked by a test.
"""
function scanDependencies(items::Vector{DepItem} = defaultItems();
    os::Symbol = Platform.os(),
    env = ENV, which = Platform.which, dims::Tuple{Int,Int} = displaysize(stdout),
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
            threads = i.threads, opens = i.opens, deps = answers),
    )
    return true
end

# ---- the offer -------------------------------------------------------------------------

"The text of a route as the user would type it (`sudo` first when it needs rights)."
function routeText(r::Route)::String
    return join([(r.admin ? ["sudo"] : String[]); r.manager; r.args], " ")
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

"Asks which of `choices` (the number picked, below 1 when the menu was cancelled)."
_askChoice(prompt::AbstractString, choices::Vector{String})::Int =
    request(prompt, RadioMenu(choices))

"""
    offerInstall(io, item, os; which, runner, ask) -> String

Offers to install a missing `item` and returns the answer to remember: `"yes"` (the
command ran and succeeded), `"later"` (not now, or it failed), `"no"` or `"never"`.
The command only runs when the user picks Install now, only when the package manager is
found and the command needs no administrator rights; otherwise the command or the manual
text is shown. `runner(cmd) -> Bool` runs it (a test passes one that only records).
"""
function offerInstall(io::IO, item::DepItem, os::Symbol; which = Platform.which,
    runner = _runCommand, ask = _askChoice)::String
    route = pickRoute(item, os, which)
    manual = manualText(item, os)
    println(io, item.name, ": ", item.why)
    canRun = false
    if route === nothing
        any(r -> r.os == os, item.routes) &&
            println(io, "  No package manager found for it on this system.")
        isempty(manual) || println(io, "  ", manual)
    elseif route.admin
        println(io, "  This needs administrator rights, so BAYSOL does not run it. Run:")
        println(io, "    ", routeText(route))
        isempty(manual) || println(io, "  ", manual)
    else
        println(io, "  Command: ", routeText(route))
        canRun = true
    end
    names =
        canRun ? ["Install now", "Not now", "No", "Never ask again"] :
        ["Not now", "No", "Never ask again"]
    answers = canRun ? ["install", "later", "no", "never"] : ["later", "no", "never"]
    pick = ask("Install " * item.name * "?", names)::Int
    (pick < 1 || pick > length(answers)) && return "later"
    answers[pick] == "install" || return answers[pick]
    route === nothing && return "later"  # unreachable: canRun implies a route
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
(`"dep.<id>"`): `never` is never asked again; `no` is not asked again at the first run
(`firstRun`) but is when the user asks for the check from the menu; `later` and a missing
item after `yes` are asked again. Info items are only reported.
"""
function checkDependencies(io::IO = stdout; env = ENV, home = homedir(),
    firstRun::Bool = false, os::Symbol = Platform.os(), which = Platform.which,
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
