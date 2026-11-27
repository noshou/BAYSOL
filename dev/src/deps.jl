# SPDX-License-Identifier: LGPL-3.0-or-later

# The developer toolchain check: what working on BAYSOL needs, what this machine has, and
# how to get the rest. Every item says where it applies (`oses`, or `unavailable` with the
# reason), how to detect it, and the install command or route per system. The report prints
# the commands; `--install NAME` and `--yes` run them through a runner that a test replaces.
# There is no prompt anywhere (the daemon forwards no input), and a command that needs an
# administrator is shown, never run.
module Deps

using ..Common
using ..Platform: Platform
using ..PkgTool: PkgTool
using ..Pmv: Pmv
using ..Plots: Plots

const WHO = "bysl deps"

const USAGE = """
What a developer needs, what this machine has, and how to install the rest.

    bysl deps [--install NAME]... [--yes]

    (no option) print the report and the install command of each missing item
    --install   install one item (repeat the option for more); names are in the report
    --yes       install every missing REQUIRED item that applies to this system

States: ok; MISSING (required, absent); missing (optional, absent); n/a (not for this
system); unavailable (cannot work on this system, never offered). A command that needs an
administrator (sudo) is printed for you to run, never run by the tool. There are no
prompts. Exit status 1 if a required item is missing at the end, 2 for a wrong command line.
"""

"""
How to install an item on one system: the `commands` (each an argument list, run in `dir`
or the current folder), whether they need an `admin`istrator, and a `route` text for what
no command does (or a note to read with the command).
"""
struct Plan
    commands::Vector{Vector{String}}
    admin::Bool
    dir::Union{Nothing,String}
    route::String
end
Plan(; commands = Vector{String}[], admin = false, dir = nothing, route = "") =
    Plan(commands, admin, dir, route)

"""
One thing a developer needs: its `name`, what it is for (`what`), whether it is `required`,
the systems it applies to (`oses`, empty for all), those where it cannot work at all
(`unavailable`, system => reason), the `detect` function (no arguments, returns
`(ok, detail)`) and the install `plan` function (system => [`Plan`](@ref)).
"""
struct Item
    name::String
    what::String
    required::Bool
    oses::Vector{Symbol}
    unavailable::Dict{Symbol,String}
    detect::Function
    plan::Function
end
Item(
    name,
    what,
    required,
    detect,
    plan;
    oses = Symbol[],
    unavailable = Dict{Symbol,String}(),
) =
    Item(name, what, required, oses, unavailable, detect, plan)

# --- detectors

# The version number `rx` finds in what `exe args...` prints, or "" (never an error).
function version_of(exe, args...; rx = r"\d+(?:\.\d+)+")::String
    out = try
        read(
            pipeline(ignorestatus(Cmd([exe, args...])); stdin = devnull, stderr = devnull),
            String)
    catch
        ""
    end
    m = match(rx, out)
    return m === nothing ? "" : m.match
end

"""
    detect_program(names...; version = nothing, hints = String[]) -> (ok, detail)

Whether one of the programs `names` is on the PATH (with its version, from the argument
list `version`), else, when it sits in one of the folders `hints` (where an installer puts
it without touching the PATH), the way to say so.
"""
function detect_program(names::AbstractString...; version = nothing, hints = String[])
    for n in names
        exe = Platform.which(n)
        exe === nothing && continue
        v = version === nothing ? "" : version_of(exe, version...)
        return true, isempty(v) ? exe : string(v, "  ", exe)
    end
    for dir in hints, n in names
        file = joinpath(dir, Platform.exe(n))
        isfile(file) && return false, "installed at $file but not on the PATH"
    end
    return false, "not on the PATH"
end

# `Platform.which`, then the `.cmd` script of that name: with Julia 1.12 an extensionless
# `npm` shell script beside `npm.cmd` (the Windows layout of Node) hides the script.
which_script(name) =
    something(Platform.which(name), Platform.which(name * ".cmd"), Some(nothing))

# Folders of the system's installers (empty where the variable does not exist).
program_files() = [get(ENV, "ProgramFiles", ""), get(ENV, "ProgramW6432", "")]

function detect_julia()
    note =
        VERSION.major == 1 && VERSION.minor == 12 ? "" :
        "  (BAYSOL is developed on 1.12)"
    return true, string(VERSION, note)
end

function detect_node()
    exe = Platform.which("node")
    exe === nothing && return false, "not on the PATH"
    v = version_of(exe, "--version")
    isempty(v) && return false, "$exe does not report a version"
    major = parse(Int, first(split(v, '.')))
    major >= 24 || return false, "node $v (needs >= 24)  $exe"
    which_script("npm") === nothing && return false, "node $v but no npm on the PATH"
    return true, "node $v  $exe"
end

function detect_modules()
    dir = joinpath(Common.root(), "node_modules")
    return isdir(dir), isdir(dir) ? dir : "no node_modules in $(Common.root())"
end

detect_memory() = begin
    info = PkgTool.parse_meminfo(read("/proc/meminfo", String))
    mib = (get(info, "MemTotal", 0) + get(info, "SwapTotal", 0)) ÷ 1024
    (mib >= 24_000, "$(mib ÷ 1024) GiB of RAM + swap (juliac peaks near 22 GiB)")
end

function detect_rdkit()
    for (id, m) in Base.loaded_modules
        id.name == "RDKit_jll" || continue
        ok = Base.invokelatest(m.is_available)
        return ok, ok ? "RDKit_jll $(pkgversion(m))" : "RDKit_jll loads but has no library"
    end
    return false, "RDKit_jll is not loaded (dev/ not instantiated?)"
end

function detect_amber()
    home = Pmv.Config.amber_home()
    exe = joinpath(home, "bin", "rism3d.snglpnt")
    return isfile(exe), isfile(exe) ? home : "no rism3d.snglpnt under $home"
end

# --- TeX: the minimum that BAYSOL's plots need (all optional)
#
# Evidence, from the code (paths from the repository root; PGFPlotsX 1.6 in the depot):
#   engine    src/pipeline/results.jl:991-1007 (`_engineKwargs`): with a font, `lualatex`,
#             else `xelatex`; `pdflatex` only for `font = nothing` or a compiler path that
#             is set (results.jl:986); the default font is set (params.jl:226-232)
#   document  PGFPlotsX `\documentclass[tikz,border=..]{standalone}` (tikzdocument.jl:135,
#             119) and its preamble `\usepackage{pgfplots}`, `\pgfplotsset{compat=newest}`
#             and the pgfplots libraries groupplots, polar, smithchart, statistics,
#             dateplot, ternary (build.jl:94-103); BAYSOL adds `\usepgfplotslibrary{
#             fillbetween}` (results.jl:432), `\definecolor`, `\pagecolor`, `\color`
#             (results.jl:435-442; xcolor, loaded by tikz) and, with a font,
#             `\usepackage{unicode-math}`, `\setmainfont`, `\setmathfont` (results.jl:444)
#   fonts     "TeX Gyre PagellaX" and "TeX Gyre Pagella Math" (params.jl:226, 232), found
#             with `luaotfload-tool --no-reload --find=NAME` (results.jl:404-419,
#             dev/src/plots.jl `Fonts.available`)
#   converter PNG: pdftocairo or pdftoppm; SVG: pdftocairo or pdf2svg (PGFPlotsX
#             build.jl:140, 188); `bysl plots render --type svg|png|jpeg` needs pdftocairo
#             (dev/src/plots.jl:79, 102); `bysl pkg` renders with lualatex and pdftocairo
#             (pkg.jl:1016). No dvisvgm, no tikz library (`\usetikzlibrary`) is used.

"""
A file a TeX installation must provide (found by `kpsewhich`) or a font, with the package
that brings it in each system's naming: TeX Live (`tlmgr`), Debian/Ubuntu (`apt`), Fedora
(`dnf`) and Arch (`pacman`). The apt names are checked against packages.debian.org (trixie
contents search); the dnf and pacman names follow the distributions' naming and are not
verified.
"""
struct TexReq
    file::String
    tlmgr::String
    apt::String
    dnf::String
    pacman::String
end

const TEX_PACKAGES = TexReq[
    TexReq("standalone.cls", "standalone", "texlive-latex-extra", "texlive-standalone",
        "texlive-latexextra"),
    TexReq("tikz.sty", "pgf", "texlive-pictures", "texlive-pgf", "texlive-pictures"),
    TexReq("pgfplots.sty", "pgfplots", "texlive-pictures", "texlive-pgfplots",
        "texlive-pictures"),
    TexReq("tikzlibraryfillbetween.code.tex", "pgfplots", "texlive-pictures",
        "texlive-pgfplots", "texlive-pictures"),
    TexReq("xcolor.sty", "xcolor", "texlive-latex-recommended", "texlive-xcolor",
        "texlive-latexrecommended"),
    TexReq("fontspec.sty", "fontspec", "texlive-latex-recommended", "texlive-fontspec",
        "texlive-latexrecommended"),
    TexReq("unicode-math.sty", "unicode-math", "texlive-latex-recommended",
        "texlive-unicode-math", "texlive-latexrecommended"),
    TexReq("lualatex-math.sty", "lualatex-math", "texlive-luatex",
        "texlive-lualatex-math", "texlive-luatex"),
]

"The two fonts of the default `PlotStyle` (params.jl:226, 232), by `fontspec` name."
const TEX_FONTS = TexReq[
    TexReq("TeX Gyre PagellaX", "newpx", "texlive-fonts-extra", "texlive-newpx",
        "texlive-fontsextra"),
    TexReq("TeX Gyre Pagella Math", "tex-gyre-math", "fonts-texgyre-math",
        "texlive-tex-gyre-math", "texlive-fontsextra"),
]

"The engines: lualatex (default, with luaotfload) and xelatex (the fallback)."
const TEX_ENGINES = TexReq[
    TexReq("lualatex", "luatex luaotfload", "texlive-latex-base texlive-luatex",
        "texlive-luatex texlive-luaotfload", "texlive-luatex"),
    TexReq("xelatex", "xetex", "texlive-xetex", "texlive-xetex", "texlive-xetex"),
]

const TEX_NOT_INSTALLED = "TeX not installed (optional)"

"""
What the TeX checks look at, replaceable in a test: `which(name)` (a path or nothing),
`kpse(file)` (does `kpsewhich` find it) and `font(name)` (does LuaLaTeX find the font).
"""
struct TexSystem
    which::Function
    kpse::Function
    font::Function
end

function kpse_finds(file)
    exe = Platform.which("kpsewhich")
    exe === nothing && return false
    out = try
        read(
            pipeline(ignorestatus(Cmd([exe, file])); stdin = devnull, stderr = devnull),
            String)
    catch
        ""
    end
    return !isempty(strip(out))
end

function font_found(name)
    Platform.which("luaotfload-tool") === nothing && return false
    return Plots.Fonts.available(name)
end

const TEX = Ref(TexSystem(Platform.which, kpse_finds, font_found))

tex_has(name) = TEX[].which(name) !== nothing

"TeX is on this machine when `kpsewhich` or an engine is."
tex_installed() = any(tex_has, ("kpsewhich", "lualatex", "xelatex", "pdflatex"))

"The `lualatex`/`xelatex` that is present, in the order BAYSOL tries them."
tex_engines() = [e.file for e in TEX_ENGINES if tex_has(e.file)]

tex_missing_packages() = [r for r in TEX_PACKAGES if !TEX[].kpse(r.file)]
tex_missing_fonts() = [r for r in TEX_FONTS if !TEX[].font(r.file)]

function detect_tex_engine()
    tex_installed() || return false, TEX_NOT_INSTALLED
    found = tex_engines()
    if isempty(found)
        only_pdf =
            tex_has("pdflatex") ?
            " (pdflatex only compiles with font = nothing)" : ""
        return false,
        "incomplete: no lualatex or xelatex on the PATH$only_pdf; the default font " *
        "needs lualatex (default) or xelatex"
    end
    note =
        "lualatex is the default" * (
            "lualatex" in found ? "" : " (not found: xelatex is the fallback)")
    luaotf =
        "lualatex" in found && !tex_has("luaotfload-tool") ?
        "; no luaotfload-tool, so `bysl plots fonts` cannot check fonts" : ""
    return true,
    string(join(found, ", "), "  (", note, "; pdflatex only for font = ",
        "nothing)", luaotf)
end

function detect_tex_packages()
    tex_installed() || return false, TEX_NOT_INSTALLED
    tex_has("kpsewhich") ||
        return false, "incomplete: TeX has no kpsewhich, so the packages cannot be checked"
    miss = tex_missing_packages()
    isempty(miss) && return true,
    "all $(length(TEX_PACKAGES)) found: " *
    join(r.file for r in TEX_PACKAGES)
    return false, "incomplete: missing " * join((r.file for r in miss), ", ")
end

function detect_tex_fonts()
    tex_installed() || return false, TEX_NOT_INSTALLED
    tex_has("luaotfload-tool") || return false,
    "incomplete: no luaotfload-tool (as `bysl plots fonts`), so the fonts cannot be " *
    "checked"
    miss = tex_missing_fonts()
    isempty(miss) && return true, join((r.file for r in TEX_FONTS), ", ") * " found"
    return false,
    "incomplete: missing " * join((r.file for r in miss), ", ") *
    " (a font installed since the last database build needs " *
    "`luaotfload-tool --update`)"
end

detect_converter() = detect_program("pdftocairo"; version = ("-v",))

# --- TeX install routes (text only: a TeX install is never run)

"The words of every item of `reqs` that `get` names, once each, in order."
tex_names(get, reqs) = unique(vcat((split(get(r)) for r in reqs)...))

tex_tlmgr(reqs) = "tlmgr install " * join(tex_names(r -> r.tlmgr, reqs), " ")

"The package-manager lines of Linux for `reqs`."
tex_linux_lines(reqs) = [
    "apt:    sudo apt-get install " * join(tex_names(r -> r.apt, reqs), " "),
    "dnf:    sudo dnf install " * join(tex_names(r -> r.dnf, reqs), " "),
    "pacman: sudo pacman -S " * join(tex_names(r -> r.pacman, reqs), " "),
    "or, for a TeX Live from tug.org: sudo " * tex_tlmgr(reqs),
]

const TEX_ALL = vcat(TEX_ENGINES[1:1], TEX_PACKAGES, TEX_FONTS)

"The minimal install from nothing, as text, for `os`."
function tex_full_route(os)
    list = tex_tlmgr(TEX_ALL)
    lines = if os == :windows
        [
            "TeX Live: run install-tl-windows.exe (tug.org/texlive/windows.html), " *
            "pick scheme-basic (or scheme-small), then in an administrator shell:",
            "    $list",
            "or MiKTeX (https://miktex.org): small installer, installs the missing " *
            "packages on the fly (set it to do so without asking); give it the fonts " *
            "newpx and tex-gyre-math",
            "TeX Live's full scheme is large (several GB, not needed); " *
            "sizes of the minimal route are unverified"]
    elseif os == :macos
        [
            "brew install --cask basictex   (BasicTeX; MacTeX is much bigger; " *
            "mactex-no-gui is large)",
            "sudo tlmgr update --self",
            "sudo $list"]
    else
        tex_linux_lines(TEX_ALL)
    end
    return join(vcat(lines, "converter (PNG/SVG/JPEG only): see pdftocairo"), "\n    ")
end

"The install lines for the missing `reqs` when TeX is there, for `os`."
function tex_missing_route(os, reqs)
    isempty(reqs) && return ""
    os == :linux && return join(tex_linux_lines(reqs), "\n    ")
    return string(os == :macos ? "sudo " : "", tex_tlmgr(reqs),
        os == :windows ? "   (MiKTeX: its package manager installs them)" : "")
end

function tex_plan(which)
    return function (os)
        which == :engine && return Plan(;
            route = tex_installed() ?
                    tex_missing_route(os, TEX_ENGINES[1:1]) :
                    tex_full_route(os))
        tex_installed() || return Plan(; route = "see the tex-engine route above")
        miss = which == :packages ? tex_missing_packages() : tex_missing_fonts()
        route = tex_missing_route(os, miss)
        which == :fonts && !isempty(route) &&
            (route *= "\n    then: luaotfload-tool --update")
        return Plan(; route)
    end
end

converter_plan(os) = per(os;
    windows = Plan(;
        route = "poppler for Windows (e.g. scoop install poppler); the winget id is " *
                "unverified",
    ),
    macos = brew("poppler"),
    linux = apt("poppler-utils"; route = "dnf/pacman: poppler-utils / poppler"))

# --- install plans

winget(id; route = "") = Plan(; route,
    commands = [["winget", "install", "--id", id, "-e", "--accept-package-agreements",
        "--accept-source-agreements"]])
brew(pkgs...; route = "") = Plan(; route, commands = [["brew", "install", pkgs...]])
apt(pkgs...; route = "") = Plan(; route, admin = true,
    commands = [["sudo", "apt-get", "install", "-y", pkgs...]])

# One plan per system, `route`-only elsewhere.
function per(os; windows = Plan(), macos = Plan(), linux = Plan())
    os == :windows && return windows
    os == :macos && return macos
    return linux
end

julia_plan(os) = Plan(;
    route = os == :windows ?
            "winget install --id Julialang.Juliaup -e, then juliaup add 1.12" :
            "curl -fsSL https://install.julialang.org | sh, then juliaup add 1.12",
)

node_plan(os) = per(os;
    windows = winget("OpenJS.NodeJS"; route = "check `node --version` shows 24 or newer"),
    macos = brew("node"; route = "check `node --version` shows 24 or newer"),
    linux = Plan(;
        route = "Node 24 or newer: https://nodejs.org/en/download (or nvm install 24)",
    ))

uv_plan(os) = per(os;
    windows = winget("astral-sh.uv"), macos = brew("uv"),
    linux = Plan(;
        commands = [["sh", "-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"]],
        route = "the official installer; puts uv in ~/.local/bin"))

function amber_plan(os)
    conda = something(Platform.which("mamba"), Platform.which("conda"),
        Platform.which("micromamba"), Some(nothing))
    conda === nothing &&
        return Plan(;
            route = "install Miniforge (https://conda-forge.org/download), then " *
                    "conda create -n amber26 -c conda-forge ambertools",
        )
    return Plan(; route = "installs to ~/.conda/envs/amber26 (or set AMBERHOME)",
        commands = [[basename(conda), "create", "-y", "-n", "amber26", "-c", "conda-forge",
            "ambertools"]])
end

"""
The items of the toolchain, in the order of the report.
"""
const ITEMS = Item[
    Item("julia", "Julia 1.12, runs everything (informational)", false, detect_julia,
        julia_plan),
    Item("git", "history, the pre-commit checks, the revision in a build", true,
        () -> detect_program("git"; version = ("--version",)),
        os -> per(os;
            windows = winget("Git.Git"),
            macos = brew("git"),
            linux = apt("git"),
        )),
    Item("node", "Node >= 24 and npm, for the terminal interface and its tests", true,
        detect_node, node_plan),
    Item("npm-packages", "node_modules of the checkout (`npm ci`)", true,
        detect_modules,
        _ -> Plan(; commands = [["npm", "ci"]], dir = Common.root())),
    Item("7z",
        "7-Zip on the PATH, for the tests and the fixture archives " *
        "(the build itself uses the npm 7zip-bin)", true,
        () -> detect_program("7z", "7zz"; hints = joinpath.(program_files(), "7-Zip")),
        os -> per(os;
            windows = winget("7zip.7zip";
                route = "the tools find it in C:\\Program Files\\7-Zip; add it to the " *
                        "PATH for other programs",
            ),
            macos = brew("sevenzip"; route = "provides 7zz"),
            linux = apt("p7zip-full"))),
    Item("uv", "the Python tools of the build (propka, pdb2pqr)", true,
        () -> detect_program("uv"; version = ("--version",)), uv_plan),
    Item("curl", "downloads in the build", true,
        () -> detect_program("curl"; version = ("--version",)),
        os -> per(os;
            windows = winget("cURL.cURL"; route = "curl.exe is part of Windows 10/11"),
            macos = brew("curl"; route = "curl is part of macOS"),
            linux = apt("curl"))),
    Item("tar", "unpacking in the build", true,
        () -> detect_program("tar"; version = ("--version",)),
        os -> per(os;
            windows = Plan(; route = "tar.exe (bsdtar) is part of Windows 10/11"),
            macos = Plan(; route = "tar is part of macOS"), linux = apt("tar"))),
    Item("gcc", "a C compiler (`bysl pkg` preflight; juliac links with it)", true,
        () -> detect_program("gcc"; version = ("--version",),
            hints = joinpath.(program_files(), "mingw64", "bin")),
        os -> per(os;
            windows = winget("BrechtSanders.WinLibs.POSIX.UCRT";
                route = "MinGW-w64 gcc; open a new shell afterwards so the PATH is updated",
            ),
            macos = Plan(; commands = [["xcode-select", "--install"]],
                route = "the command line tools; gcc is Apple's clang"),
            linux = apt("build-essential"))),
    Item("llvm-strip",
        "LLVM's strip, the one strip tool of `bysl pkg` (without it the " *
        "build warns and leaves files unstripped)", false,
        () -> detect_program("llvm-strip"; version = ("--version",),
            hints = joinpath.(program_files(), "LLVM", "bin")),
        os -> per(os;
            windows = winget("LLVM.LLVM";
                route = "the tools find it in C:\\Program Files\\LLVM\\bin; add it " *
                        "to the PATH for other programs",
            ),
            macos = brew(
                "llvm";
                route = "keg-only: add \$(brew --prefix llvm)/bin to the PATH",
            ),
            linux = apt("llvm"))),
    Item("patchelf",
        "sets the RUNPATH of the Linux build (comes with the build's venv; " *
        "informational)", false,
        () -> detect_program("patchelf"; version = ("--version",)),
        os -> apt("patchelf"); oses = [:linux]),
    Item("memory", "RAM + swap >= 24 GiB (`bysl pkg` preflight)", true, detect_memory,
        _ -> Plan(;
            route = "add swap: sudo fallocate -l 16G /swapfile && sudo chmod 600 " *
                    "/swapfile && sudo mkswap /swapfile && sudo swapon /swapfile",
        );
        oses = [:linux]),
    Item("rdkit", "RDKit (RDKit_jll through RDKitMinimalLib), for the pmv tools", false,
        detect_rdkit,
        _ -> Plan(; dir = Common.root(),
            commands = [[
                find_julia(),
                "--project=dev",
                "-e",
                "using Pkg; Pkg.instantiate()",
            ]]);
        unavailable = Dict(
            :windows =>
                "unavailable on this OS; the pmv tools are skipped " *
                "(RDKit_jll's library exports none of the functions " *
                "RDKitMinimalLib calls)",
        )),
    Item("ambertools", "AmberTools 3D-RISM, for `bysl pmv run` and `batch`", false,
        detect_amber, amber_plan;
        unavailable = Dict(
            :windows =>
                "unavailable on this OS (AmberTools has no Windows " *
                "build); pmv run and batch are skipped",
        )),
    Item("tex-engine",
        "lualatex (default) or xelatex for the plots' default font; pdflatex only with " *
        "font = nothing (optional, TeX is not needed otherwise)", false,
        detect_tex_engine, tex_plan(:engine)),
    Item("tex-packages",
        "LaTeX files of the figures: standalone, tikz, pgfplots (+ fillbetween), xcolor, " *
        "fontspec, unicode-math, lualatex-math (optional)", false,
        detect_tex_packages, tex_plan(:packages)),
    Item("tex-fonts",
        "TeX Gyre PagellaX and TeX Gyre Pagella Math, the default figure font " *
        "(optional)", false, detect_tex_fonts, tex_plan(:fonts)),
    Item("pdftocairo",
        "poppler's pdftocairo, for PNG, SVG and JPEG figures (`plots render --type`; " *
        "optional)", false, detect_converter, converter_plan),
]

# --- states

const FETCHED = Dict(
    "gcc" =>
        "fetched by juliac (MinGW-w64 artifact) and Nuitka, nothing to install; needs " *
        "the network",
    "tar" => "not needed here (the Node archive is a zip, unpacked with 7-Zip)")

"""
    state(item, os; probe = item.detect) -> (state, detail)

`:ok`, `:missing` (required and absent), `:optional` (optional and absent), `:na` (the
item is not for `os`) or `:unavailable` (it cannot work on `os`; `detail` is the reason).
`probe` replaces the detector.
"""
function state(item::Item, os::Symbol; probe = item.detect)
    haskey(item.unavailable, os) && return :unavailable, item.unavailable[os]
    isempty(item.oses) || os in item.oses || return :na, ""
    # the build programs are those of the preflight of `bysl pkg`, which knows the system
    item.name in ("uv", "curl", "tar", "gcc") &&
        !(item.name in PkgTool.preflight_programs(os)) &&
        return :na, get(FETCHED, item.name, "not needed on this system")
    ok, detail = probe()
    ok && return :ok, detail
    return (item.required ? :missing : :optional), detail
end

"""
    survey(os; items = ITEMS, probes = Dict()) -> Vector

The `(item, state, detail)` of every item; `probes` maps an item name to a detector that
replaces the real one.
"""
survey(os::Symbol; items = ITEMS, probes = Dict()) =
    [
        (item, state(item, os; probe = get(probes, item.name, item.detect))...) for
        item in items
    ]

const LABELS = Dict(:ok => "ok", :missing => "MISSING", :optional => "missing",
    :na => "n/a", :unavailable => "unavailable")

# The command line as typed.
command_text(cmd) = join([occursin(r"[\s|;]", a) ? "\"$a\"" : a for a in cmd], " ")

"""
    report(io, os, rows) -> Int

Prints the survey `rows` and, for each missing item, how to install it on `os`; returns 1 if
a required item is missing, else 0.
"""
function report(io::IO, os::Symbol, rows)
    println(io, "bysl deps: ", os, " ", Platform.arch())
    w = maximum(length(r[1].name) for r in rows)
    for (item, st, detail) in rows
        println(io, rpad(LABELS[st], 12), rpad(item.name, w + 2),
            item.required ? "required  " : "optional  ",
            isempty(detail) ? item.what : detail)
    end
    todo = [r for r in rows if r[2] in (:missing, :optional)]
    if !isempty(todo)
        println(io, "\nto install what is missing:")
        for (item, st, detail) in todo
            plan = item.plan(os)
            println(io, "  ", item.name, ":")
            if startswith(detail, "installed at")
                println(io, "    add its folder to the PATH (a new shell may be needed)")
                continue
            end
            for c in plan.commands
                println(io, "    ", command_text(c),
                    plan.admin ? "    (needs an administrator: run it yourself)" : "")
            end
            isempty(plan.route) || println(io, "    ", plan.route)
            isempty(plan.commands) && isempty(plan.route) &&
                println(io, "    (no route known for this system)")
        end
    end
    return any(r -> r[2] == :missing, rows) ? 1 : 0
end

# --- installing

"""
    default_runner(cmd, dir) -> Bool

Runs the argument list `cmd` in `dir` (or the current folder) with our terminal; true when
it succeeded. The program is looked up with `Platform.which`, which also finds the `.cmd`
scripts of Windows.
"""
function default_runner(cmd::Vector{String}, dir)::Bool
    c = copy(cmd)
    exe = which_script(c[1])
    exe === nothing && return (println(stderr, WHO, ": $(c[1]) is not on the PATH"); false)
    c[1] = exe
    return Common.with(Common.CMD_DIR => dir) do
        run_cmd(c)
    end
end

"""
    install!(io, item, os; runner = default_runner, probe = item.detect) -> Symbol

Installs `item` on `os` through `runner(cmd, dir)`: `:ok` (already there), `:installed`,
`:failed` (a command failed or the item is still absent), `:admin` (needs an administrator;
the command was printed, not run), `:no_route` (nothing to run; the route was printed),
`:na` or `:unavailable` (never offered).
"""
function install!(io::IO, item::Item, os::Symbol; runner = default_runner,
    probe = item.detect)::Symbol
    st, detail = state(item, os; probe)
    st == :unavailable && return (println(io, item.name, ": ", detail); :unavailable)
    st == :na && return (println(io, item.name, ": not for ", os); :na)
    st == :ok && return (println(io, item.name, ": already there"); :ok)
    startswith(detail, "installed at") && return (
        println(io, item.name, ": ", detail, "; add its folder to the PATH"); :no_route)
    plan = item.plan(os)
    if isempty(plan.commands)
        println(io, item.name, ": no command for this system. ", plan.route)
        return :no_route
    end
    if plan.admin
        println(io, item.name, ": needs an administrator, run it yourself:")
        foreach(c -> println(io, "    ", command_text(c)), plan.commands)
        return :admin
    end
    for c in plan.commands
        println(io, "\$ ", command_text(c))
        runner(c, plan.dir) ||
            return (println(io, item.name, ": the command failed"); :failed)
    end
    isempty(plan.route) || println(io, item.name, ": ", plan.route)
    state(item, os; probe)[1] == :ok &&
        return (println(io, item.name, ": installed"); :installed)
    println(io, item.name, ": the command ran but ", item.name,
        " is still not found (a new shell may be needed for the PATH)")
    return :failed
end

"""
    run_install(io, os, names, all; runner, probes) -> Int

Installs the items `names`, and with `all` every missing required item that applies; prints
what happened and returns 1 if a required item is still missing, else 0.
"""
function run_install(io::IO, os::Symbol, names, all::Bool; items = ITEMS,
    runner = default_runner, probes = Dict())
    byname = Dict(i.name => i for i in items)
    for n in names
        haskey(byname, n) || fail(
            WHO,
            "no item named $n (one of: " *
            join(getfield.(items, :name), ", ") * ")",
        )
    end
    chosen = Item[byname[n] for n in names]
    if all
        for (item, st, _) in survey(os; items, probes)
            st == :missing && !(item in chosen) && push!(chosen, item)
        end
    end
    for item in chosen
        install!(io, item, os; runner, probe = get(probes, item.name, item.detect))
    end
    println(io)
    return report(io, os, survey(os; items, probes))
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    a = split_args(WHO, ["--install"], ["--yes"], argv)
    isempty(a.specs) || fail(WHO, "unexpected argument $(first(a.specs))")
    names = [v for (k, v) in a.opts if k == "--install"]
    os = Platform.os()
    if isempty(names) && !("--yes" in a.flags)
        return report(stdout, os, survey(os))
    end
    return run_install(stdout, os, names, "--yes" in a.flags)
end

end
