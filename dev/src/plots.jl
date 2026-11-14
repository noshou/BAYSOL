# SPDX-License-Identifier: LGPL-3.0-or-later

# The LaTeX side of the figures: rendering the `.tex` figures of a folder (`bysl plots
# render`) and asking the TeX Live installation which fonts they can use (`bysl plots
# fonts`).
module Plots

using ..Common

module Render

using ...Common

const WHO = "bysl plots render"

const USAGE = """
Renders the .tex figures of a folder.

    bysl plots render DIR [--recursive] [--type pdf|svg|png|jpeg]

    --recursive include subfolders
    --type      output format (default pdf; the others need pdftocairo)

Needs lualatex or xelatex. A failed file is reported and the others still run.
"""

"The --type values: pdftocairo's flag and the extension of what it writes."
const TYPES = Dict("pdf" => nothing, "svg" => ("-svg", "svg"), "png" => ("-png", "png"),
    "jpeg" => ("-jpeg", "jpg"))

"The .tex files of `dir` (and of its subfolders if `rec`), sorted."
function find_tex(dir, rec)
    found = String[]
    if rec
        for (d, _, files) in walkdir(dir), f in files
            endswith(f, ".tex") && push!(found, joinpath(d, f))
        end
    else
        for f in readdir(dir)
            p = joinpath(dir, f)
            endswith(f, ".tex") && isfile(p) && push!(found, p)
        end
    end
    return sort(found)
end

"The path of the first of `names` on the PATH; an error that says what to install."
function find_program(names, hint)
    for n in names
        p = Sys.which(n)
        p === nothing || return p
    end
    throw(ToolError("could not find $(join(names, " or ")) on the PATH; $hint", 1))
end

"""
Compiles `file` in its own folder and, if `conversion` is `(flag, ext)`, converts the PDF
(and removes it).
"""
function render(engine, conversion, file)
    dir = dirname(abspath(file))
    fname = basename(file)
    base = first(splitext(fname))
    ok(cmd...) = success(
        pipeline(Cmd(Cmd(collect(string.(cmd))); dir,
            ignorestatus = true); stdout = devnull, stderr = devnull),
    )
    ok(engine, "-interaction=nonstopmode", "-halt-on-error", fname) ||
        return "LaTeX failed (see $base.log)"
    for ext in (".aux", ".log")
        rm(joinpath(dir, base * ext); force = true)
    end
    conversion === nothing && return nothing
    flag, ext = conversion
    # svg takes the output's name; png and jpeg take its name without the extension, and
    # only they accept -singlefile (without it they number the page: a-1.png)
    target = flag == "-svg" ? ["$base.$ext"] : ["-singlefile", base]
    ok("pdftocairo", flag, "$base.pdf", target...) || return "pdftocairo failed"
    rm(joinpath(dir, base * ".pdf"))
    return nothing
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, flags, specs) = split_args(WHO, ["--type"], ["--recursive"], argv)
    type = isempty(opts) ? "pdf" : last(last(opts))
    length(specs) == 1 ||
        fail(WHO, "give one directory: DIR [--recursive] [--type pdf|svg|png|jpeg]")
    dir = only(specs)
    isdir(dir) || fail(WHO, "$dir: not a directory")
    haskey(TYPES, type) || fail(WHO,
        "unknown --type $type (one of: $(join(sort(collect(keys(TYPES))), ", ")))")
    engine = find_program(["lualatex", "xelatex"],
        "install TeX Live (Linux), MacTeX (macOS) or MiKTeX (Windows)")
    conversion = TYPES[type]
    conversion === nothing ||
        find_program(["pdftocairo"], "install poppler (poppler-utils)")
    failed = Tuple{String,String}[]
    for file in find_tex(dir, !isempty(flags))
        problem = render(engine, conversion, file)
        println(problem === nothing ? "ok    " : "FAILED", " ", file)
        problem === nothing || push!(failed, (file, problem))
    end
    println(length(failed), " failed")
    for (file, problem) in failed
        println(stderr, file, ": ", problem)
    end
    return isempty(failed) ? 0 : 1
end

end

module Fonts

using ...Common

const WHO = "bysl plots fonts"

const USAGE = """
Asks TeX Live which fonts the figures can use.

    bysl plots fonts NAME [NAME ...]
    bysl plots fonts --list

    NAME        a fontspec name; prints true or false (exit 1 if any is false)
    --list      every installed font family, math fonts first

Uses luaotfload-tool; a newly installed font needs `luaotfload-tool --update` first.
"""

# The output of a command whose failure does not matter, stderr dropped.
quiet(cmd::Cmd) = read(pipeline(ignorestatus(cmd); stderr = devnull), String)

"Whether LuaLaTeX finds the font `family`. `--no-reload` keeps a miss from rebuilding."
function available(family::AbstractString)::Bool
    out = quiet(`luaotfload-tool --no-reload $("--find=" * family)`)
    return occursin("found!", out)
end

"""
Every installed font family, sorted: from `fc-list`, whose names are the ones to write (a
family can have several, separated by commas), or else from LuaLaTeX's index, whose names
are lower case without spaces (which [`available`](@ref) accepts as well).
"""
function families()::Vector{String}
    if Sys.which("fc-list") !== nothing
        names = String[]
        for line in split(quiet(`fc-list : family`), '\n')
            append!(names, strip.(split(line, ',')))
        end
        return sort(unique(filter(!isempty, names)))
    end
    lines = split(quiet(`luaotfload-tool --no-reload --list=\* --fields=familyname`), '\n')
    names = strip.(lines)
    return sort(unique(filter(n -> !isempty(n) && !occursin("<none>", n), names)))
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; flags, specs) = split_args(WHO, String[], ["--list"], argv)
    Sys.which("luaotfload-tool") === nothing && fail(WHO,
        "luaotfload-tool not found: it comes with TeX Live, " *
        "and without it no font can be checked")
    if !isempty(flags) && !isempty(specs)
        fail(WHO, "give font names or --list, not both")
    elseif !isempty(flags)
        ismath(n) = occursin("math", lowercase(n))
        installed = families()
        println("math fonts (the second entry of a (text, math) pair)")
        foreach(n -> println("  ", n), filter(ismath, installed))
        println("\nfont families (the text font)")
        foreach(n -> println("  ", n), filter(!ismath, installed))
        return 0
    elseif isempty(specs)
        fail(WHO, "give one or more font names, or --list")
    end
    results = [(font, available(font)) for font in specs]
    for (font, ok) in results
        println(font, ": ", ok)
    end
    return all(last, results) ? 0 : 1
end

end

const SUBS = [
    "render" => (Render, "render a folder's .tex figures to pdf, svg, png or jpeg"),
    "fonts" => (Fonts, "is a font available to LaTeX? / list the fonts"),
]

const SUMMARY = "The LaTeX figures.\n\n    bysl plots SUBCOMMAND [options]"

"`bysl plots`: the subcommand `render` or `fonts` and its options."
run(argv::Vector{String})::Int = dispatch("bysl plots", SUMMARY, SUBS, argv)

end
