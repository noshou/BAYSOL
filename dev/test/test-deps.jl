# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl deps`: which items apply on which system, the report and its exit status,
# the install command of each system, and the installer with a runner that never installs.

using Test
using Dev
using Dev: Platform
using .Main.Helpers

const D = Dev.Deps

byname(name) = only(filter(i -> i.name == name, D.ITEMS))

# Detectors that say every item is present, except those in `absent`.
probes(; absent = String[]) =
    Dict(
        i.name => (() -> (!(i.name in absent), i.name in absent ? "not found" : "found"))
        for i in D.ITEMS
    )

function survey_text(os; absent = String[])
    rows = D.survey(os; probes = probes(; absent))
    io = IOBuffer()
    status = D.report(io, os, rows)
    return status, String(take!(io)), rows
end

# A TeX installation that is not real: `have` programs on the PATH, `kpse` files found,
# `fonts` found by luaotfload-tool.
TexSys(; have = String[], kpse = String[], fonts = String[]) =
    D.TexSystem(n -> n in have ? "/fake/$n" : nothing, f -> f in kpse, f -> f in fonts)

function with_tex(f, sys)
    old = D.TEX[]
    D.TEX[] = sys
    try
        return f()
    finally
        D.TEX[] = old
    end
end

const ALL_FILES = [r.file for r in D.TEX_PACKAGES]
const ALL_FONTS = [r.file for r in D.TEX_FONTS]
const FULL = TexSys(have = ["kpsewhich", "lualatex", "luaotfload-tool"], kpse = ALL_FILES,
    fonts = ALL_FONTS)

# probes that say every non-TeX item is present
non_tex() = Dict(
    i.name => (() -> (true, "x")) for i in D.ITEMS if !startswith(i.name, "tex-")
)

@testset "items are gated by system" begin
    states(os) = Dict(i.name => s for (i, s, _) in D.survey(os; probes = probes()))
    win, mac, lin = states(:windows), states(:macos), states(:linux)
    @test win["rdkit"] == :unavailable && win["ambertools"] == :unavailable
    @test mac["rdkit"] == :ok && lin["rdkit"] == :ok && lin["ambertools"] == :ok
    @test win["patchelf"] == :na && mac["patchelf"] == :na && lin["patchelf"] == :ok
    @test win["memory"] == :na && mac["memory"] == :na && lin["memory"] == :ok
    # an item that cannot work is never missing, whatever its detector says
    s = D.survey(:windows; probes = probes(absent = ["rdkit", "ambertools", "patchelf"]))
    @test Dict(i.name => st for (i, st, _) in s)["rdkit"] == :unavailable
    reason = Dict(i.name => d for (i, _, d) in s)["rdkit"]
    @test says(reason, "unavailable on this OS", "pmv tools are skipped")
    # required or optional decides MISSING or missing
    s = D.survey(:linux; probes = probes(absent = ["git", "tex-engine", "llvm-strip"]))
    st = Dict(i.name => x for (i, x, _) in s)
    @test st["git"] == :missing && st["tex-engine"] == :optional &&
          st["llvm-strip"] == :optional
    @test byname("julia").required == false
    @test all(
        n -> byname(n).required,
        ["git", "node", "npm-packages", "7z", "uv", "curl",
            "tar", "gcc", "memory"],
    )
end

@testset "report and exit status" begin
    status, text, _ = survey_text(:linux)
    @test status == 0 && says(text, "bysl deps: linux", "ok  ", "julia", "git", "7z")
    @test !occursin("to install what is missing", text)

    status, text, _ = survey_text(:linux; absent = ["git", "tex-engine"])
    @test status == 1
    @test says(text, "MISSING", "missing", "to install what is missing", "git:",
        "sudo apt-get install -y git", "needs an administrator", "tex-engine:")

    # only an optional item missing: exit status 0
    status, text, _ = with_tex(TexSys()) do
        survey_text(:macos; absent = ["tex-engine", "llvm-strip"])
    end
    @test status == 0 &&
          says(text, "brew install --cask basictex", "brew install llvm")

    status, text, _ = survey_text(:windows; absent = ["git", "7z", "gcc", "tar"])
    @test status == 1
    @test says(
        text,
        "winget install --id Git.Git",
        "winget install --id 7zip.7zip",
        "the tools find it in C:\\Program Files\\7-Zip",
    )
    @test !occursin("sudo", text) && !occursin("brew", text)
    @test !occursin("gcc:", text) && says(text, "fetched by juliac")
    @test D.state(byname("gcc"), :linux; probe = () -> (false, "x"))[1] == :missing
    # Windows never offers an install for RDKit or AmberTools
    status, text, _ = survey_text(:windows; absent = ["rdkit", "ambertools"])
    @test status == 0 && says(text, "unavailable", "the pmv tools are skipped")
    @test !occursin(r"rdkit:|ambertools:", text) && !occursin("conda", text)
    # a program that is installed but not on the PATH gets no second install
    rows = D.survey(
        :windows;
        probes = Dict(
            "7z" =>
                () -> (false, "installed at C:\\x\\7z.exe but not on the PATH"),
        ),
    )
    io = IOBuffer()
    D.report(io, :windows, rows)
    @test says(String(take!(io)), "add its folder to the PATH") &&
          !occursin("winget install --id 7zip.7zip", String(take!(io)))
end

@testset "install plans" begin
    for os in (:windows, :macos, :linux), item in D.ITEMS
        isempty(item.oses) || os in item.oses || continue
        plan = item.plan(os)
        @test all(c -> !isempty(c) && all(a -> a isa String, c), plan.commands)
        @test !plan.admin || any(c -> first(c) == "sudo", plan.commands)
        os == :linux || @test !any(c -> first(c) == "sudo", plan.commands)
    end
    @test byname("git").plan(:windows).commands[1][1:2] == ["winget", "install"]
    @test byname("git").plan(:macos).commands == [["brew", "install", "git"]]
    @test byname("git").plan(:linux).admin
    @test byname("npm-packages").plan(:linux).commands == [["npm", "ci"]]
    @test byname("npm-packages").plan(:windows).dir == Dev.Common.root()
    @test isempty(byname("node").plan(:linux).commands)
    @test occursin("nodejs.org", byname("node").plan(:linux).route)
    @test byname("memory").plan(:linux).route != ""
end

@testset "installer with a runner that does not install" begin
    ran = Vector{Vector{String}}()
    present = Ref(false)
    runner(cmd, dir) = (push!(ran, cmd); present[] = true; true)
    probe() = (present[], "x")
    ok_probe() = (true, "x")
    item(name; plan, required = true, kw...) =
        D.Item(name, "a thing", required, probe, plan; kw...)
    plan = _ -> D.Plan(; commands = [["tool", "install"], ["tool", "setup"]])
    io() = IOBuffer()

    # installs, runs the commands in order, checks again
    out = io()
    @test D.install!(out, item("a"; plan), :macos; runner, probe) == :installed
    @test ran == [["tool", "install"], ["tool", "setup"]]
    @test says(String(take!(out)), "\$ tool install", "installed")
    # already there: nothing runs
    empty!(ran)
    @test D.install!(io(), item("a"; plan), :macos; runner, probe = ok_probe) == :ok
    @test isempty(ran)
    # a failing command stops the item
    present[] = false
    @test D.install!(io(), item("a"; plan), :macos; runner = (c, d) -> false, probe) ==
          :failed
    # a command that ran but left the item absent
    @test D.install!(io(), item("a"; plan), :macos; runner = (c, d) -> true, probe) ==
          :failed
    # an administrator's command is shown, never run
    empty!(ran)
    sudo = _ -> D.Plan(; admin = true, commands = [["sudo", "apt-get", "install", "x"]])
    out = io()
    @test D.install!(out, item("a"; plan = sudo), :linux; runner, probe) == :admin
    @test isempty(ran) &&
          says(String(take!(out)), "run it yourself", "sudo apt-get install x")
    # a route without command
    route = _ -> D.Plan(; route = "do it by hand")
    out = io()
    @test D.install!(out, item("a"; plan = route), :linux; runner, probe) == :no_route
    @test isempty(ran) && says(String(take!(out)), "do it by hand")
    # an item for another system, and one that cannot work here, are never installed
    @test D.install!(io(), item("a"; plan, oses = [:linux]), :windows; runner, probe) == :na
    gone = item("a"; plan, unavailable = Dict(:windows => "never here"))
    @test D.install!(io(), gone, :windows; runner, probe) == :unavailable
    @test isempty(ran)
    # a program installed but not on the PATH is not installed again
    hint =
        D.Item("a", "x", true, () -> (false, "installed at C:\\x.exe but not on the PATH"),
            plan)
    @test D.install!(io(), hint, :windows; runner) == :no_route && isempty(ran)
end

@testset "--install and --yes choose the items" begin
    ran = Vector{Vector{String}}()
    runner(cmd, dir) = (push!(ran, cmd); true)
    p = probes(absent = ["git", "uv", "pdftocairo", "tex-engine", "gcc"])
    # --yes: the missing required ones that have a command; the optional one is left alone
    out = IOBuffer()
    status = D.run_install(out, :macos, String[], true; runner, probes = p)
    text = String(take!(out))
    @test ["brew", "install", "git"] in ran && ["brew", "install", "uv"] in ran
    @test ["xcode-select", "--install"] in ran
    @test !any(c -> "poppler" in c, ran)
    # the fake runner installs nothing, so the required items are still missing
    @test status == 1 && says(text, "the command ran but", "to install what is missing")
    # --install NAME: that one, optional or not
    empty!(ran)
    D.run_install(IOBuffer(), :macos, ["pdftocairo"], false; runner, probes = p)
    @test ran == [["brew", "install", "poppler"]]
    # a TeX install is never a command: only its route is printed
    empty!(ran)
    out = IOBuffer()
    with_tex(TexSys()) do
        D.run_install(out, :macos, ["tex-engine"], false; runner, probes = p)
    end
    @test isempty(ran) && says(String(take!(out)), "no command for this system")
    # a name that is not an item: a wrong command line
    @test_throws Dev.Common.ToolError D.run_install(IOBuffer(), :macos, ["nope"], false;
        runner, probes = p)
    # Linux with sudo: nothing runs
    empty!(ran)
    out = IOBuffer()
    D.run_install(out, :linux, String[], true; runner, probes = p)
    # only uv, which needs none
    @test !any(c -> first(c) == "sudo", ran) && length(ran) == 1
    @test says(String(take!(out)), "run it yourself")
    # Windows: RDKit is never installed, even when named
    empty!(ran)
    out = IOBuffer()
    D.run_install(
        out,
        :windows,
        ["rdkit"],
        false;
        runner,
        probes = probes(absent = ["rdkit"]),
    )
    @test isempty(ran) && says(String(take!(out)), "the pmv tools are skipped")
end

@testset "bysl deps command line" begin
    @test run_tool("deps", "--help")[1] == 0
    @test run_tool("deps", "--bogus")[1] == 2
    @test run_tool("deps", "extra")[1] == 2
    status, out = run_tool("deps", "--install", "no-such-item")
    @test status == 2 && says(out, "no item named no-such-item")
    # the real report of this machine: only detectors run, nothing is installed
    status, out = run_tool("deps")
    @test status in (0, 1) && says(out, "bysl deps: $(Platform.os())", "julia", "git", "7z")
    @test (status == 1) == occursin(r"^MISSING"m, out)
    @test occursin(string(VERSION), out)
    Platform.iswindows() && @test says(out, "unavailable", "the pmv tools are skipped")
end

@testset "TeX: the minimum for the plots" begin
    texstate(sys, os = :linux) = with_tex(sys) do
        Dict(i.name => (st, d) for (i, st, d) in D.survey(os; probes = non_tex()))
    end
    tex_items = ["tex-engine", "tex-packages", "tex-fonts"]
    # the list is the evidence-backed one
    @test ALL_FILES == ["standalone.cls", "tikz.sty", "pgfplots.sty",
        "tikzlibraryfillbetween.code.tex", "xcolor.sty", "fontspec.sty", "unicode-math.sty",
        "lualatex-math.sty"]
    @test ALL_FONTS == ["TeX Gyre PagellaX", "TeX Gyre Pagella Math"]

    # no TeX: every item optional, said so, and the exit status is not touched
    s = texstate(TexSys())
    for n in tex_items
        @test s[n] == (:optional, D.TEX_NOT_INSTALLED)
    end
    rows = with_tex(TexSys()) do
        D.survey(:linux; probes = non_tex())
    end
    @test D.report(IOBuffer(), :linux, rows) == 0
    @test all(!item.required for (item, _, _) in rows if startswith(item.name, "tex-"))

    # TeX with everything: ok
    s = texstate(FULL)
    @test all(n -> s[n][1] == :ok, tex_items)
    @test says(s["tex-engine"][2], "lualatex", "default")
    @test says(s["tex-packages"][2], "all 8 found", "pgfplots.sty")
    @test says(s["tex-fonts"][2], "TeX Gyre PagellaX", "found")

    # packages missing: incomplete and one ready-to-run line per package manager
    part = TexSys(have = ["kpsewhich", "lualatex", "luaotfload-tool"],
        kpse = setdiff(
            ALL_FILES,
            ["pgfplots.sty", "tikzlibraryfillbetween.code.tex",
                "unicode-math.sty"],
        ), fonts = ["TeX Gyre PagellaX"])
    s = texstate(part)
    @test s["tex-packages"][1] == :optional &&
          says(s["tex-packages"][2], "incomplete: missing pgfplots.sty", "unicode-math.sty")
    @test !occursin("tikz.sty", s["tex-packages"][2])
    @test says(s["tex-fonts"][2], "incomplete", "TeX Gyre Pagella Math")
    out = IOBuffer()
    status = with_tex(part) do
        D.report(out, :linux, D.survey(:linux; probes = non_tex()))
    end
    text = String(take!(out))
    @test status == 0
    @test says(text, "tlmgr install pgfplots unicode-math",
        "sudo apt-get install texlive-pictures texlive-latex-recommended",
        "sudo dnf install texlive-pgfplots texlive-unicode-math",
        "sudo pacman -S texlive-pictures texlive-latexrecommended",
        "tlmgr install tex-gyre-math", "luaotfload-tool --update")
    @test !occursin("tlmgr install standalone", text)
    # macOS and Windows: tlmgr (sudo on macOS), no apt
    mac = with_tex(part) do
        D.tex_plan(:packages)(:macos).route
    end
    @test mac == "sudo tlmgr install pgfplots unicode-math"
    win = with_tex(part) do
        D.tex_plan(:packages)(:windows).route
    end
    @test startswith(win, "tlmgr install pgfplots unicode-math") && !occursin("sudo", win)

    # engine: only pdflatex is incomplete; xelatex alone is enough
    s = texstate(TexSys(have = ["kpsewhich", "pdflatex"], kpse = ALL_FILES))
    @test s["tex-engine"][1] == :optional &&
          says(
        s["tex-engine"][2],
        "incomplete",
        "pdflatex only compiles with font = nothing",
    )
    s = texstate(TexSys(have = ["kpsewhich", "xelatex"], kpse = ALL_FILES))
    @test s["tex-engine"][1] == :ok && says(s["tex-engine"][2], "xelatex")
    # no luaotfload-tool: the fonts cannot be checked
    s = texstate(TexSys(have = ["kpsewhich", "lualatex"], kpse = ALL_FILES))
    @test s["tex-fonts"][1] == :optional && says(s["tex-fonts"][2], "cannot be checked")

    # the minimal install from nothing, per system (text, never a command)
    route(os) = with_tex(TexSys()) do
        D.tex_plan(:engine)(os)
    end
    lin = route(:linux)
    @test isempty(lin.commands) && !lin.admin
    @test says(lin.route, "sudo apt-get install texlive-latex-base texlive-luatex",
        "texlive-latex-extra", "texlive-pictures", "texlive-fonts-extra",
        "fonts-texgyre-math", "sudo dnf install", "sudo pacman -S",
        "tlmgr install luatex luaotfload standalone pgf")
    mac = route(:macos)
    @test isempty(mac.commands) &&
          says(mac.route, "brew install --cask basictex", "sudo tlmgr install",
        "MacTeX is much bigger")
    win = route(:windows)
    @test isempty(win.commands) &&
          says(win.route, "install-tl-windows.exe", "scheme-basic", "MiKTeX",
        "on the fly", "large")
    @test !occursin("apt", win.route) && !occursin("brew", win.route)
    # the other tex items point to the engine's route when TeX is absent
    @test with_tex(TexSys()) do
        D.tex_plan(:fonts)(:linux).route
    end == "see the tex-engine route above"
    # the converter has an ordinary install plan
    @test byname("pdftocairo").plan(:linux).commands ==
          [["sudo", "apt-get", "install", "-y", "poppler-utils"]]
    @test byname("pdftocairo").plan(:macos).commands == [["brew", "install", "poppler"]]
    @test all(n -> !byname(n).required,
        ["tex-engine", "tex-packages", "tex-fonts", "pdftocairo"])
end
