# SPDX-License-Identifier: LGPL-3.0-or-later

# The dev tools of BAYSOL. Every tool is a module with a `run(args)::Int` entry point; the
# registry below maps the tool's name (`bysl fmt`) to it, and a tool with subcommands
# (`bysl harvest solutes`) dispatches to nested modules.
module Dev

include("Common.jl")
include("Report.jl")
include("Fmt.jl")
include("Harvest.jl")
include("Results.jl")
include("Cache.jl")
include("Checks.jl")
include("Fits.jl")
include("Extract.jl")
include("Plots.jl")
include("Vis.jl")
include("Test.jl")
include("Server.jl")


"""
The tasks: name => (module, one-line description), in the order `bysl help` lists them.
"""
const TASKS = [
    "fmt" =>
        (Fmt, "Format the code, re-wrap prose, check the layout (--check, --lines)"),
    "harvest" =>
        (Harvest, "Regenerate the harvested files: defaults, solutes, pmv-mean"),
    "results" => (Results, "Run-log results: table, compare"),
    "precommit" =>
        (Checks.Precommit, "Every check before a commit (--quick: only the fast ones)"),
    "unit" => (
        Checks.Unit,
        "The Julia unit suite (names pick the files: bysl unit shannon wls)",
    ),
    "docs" => (Checks.Docs, "Build the documentation site (strict, about a minute)"),
    "cache" => (Cache, "The cache of the programs the tools start: list, clear"),
    "fits" => (Fits, "The fitting tests: run, list, diagnose, profile"),
    "extract" => (Extract, "Regenerate bundled data: formfactor, components"),
    "plots" => (Plots, "LaTeX figures: render, fonts"),
    "vis" => (Vis, "The visual checks of the geometry code"),
    "test" =>
        (TestTool, "The tests of the dev tools (names pick the files: bysl test fmt)"),
]

"""
    main(task, args) -> Int

Runs the tool `task` with the argument list `args` and returns its exit status; a
[`Common.ToolError`](@ref) is printed as a message on stderr with its own status.
"""
function main(task::AbstractString, args::AbstractVector{<:AbstractString})::Int
    table = Dict(TASKS)
    if task in ("help", "--help", "-h", "")
        for (name, (_, doc)) in TASKS
            println(rpad(name, 20), " ", doc)
        end
        return 0
    end
    try
        haskey(table, task) ||
            Common.fail("bysl", "unknown task $task (bysl help lists them)")
        tool, _ = table[task]
        rest, env = Common.take_threads(String.(args))
        return Common.with(Common.EXTRA_ENV => env) do
            something(tool.run(rest), 0)
        end
    catch err
        # a reader that closed the pipe (`| head`) ends the command quietly
        err isa Base.IOError && err.code == Base.UV_EPIPE && return 0
        err isa Common.ToolError || rethrow()
        isempty(err.message) || println(stderr, err.message)
        return err.status
    finally
        flush(stdout)
        flush(stderr)
    end
end


include("Precompile.jl")

end
