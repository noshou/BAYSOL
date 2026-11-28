# SPDX-License-Identifier: LGPL-3.0-or-later

# The entry of the packaged app: `baysol`, one executable built by `bysl pkg` with
# `juliac`. It is the launcher of the other two (`baysol-tui`, `baysol-pytools`), the
# command line (`baysol run`), what the terminal interface starts for a fit (`baysol
# run-tui`) and the setup wizard (`baysol setup`). Nothing in it knows the checkout it was
# built in: every file it needs is found beside the executable.
#
#   <bundle>/baysol  baysol-tui  julia/ (the libraries)  lib/pytools/  the icon
#   the launcher
#
# When `BAYSOL_WORKLOAD` names a folder at build time, the file `workload.jl` runs the
# projects in it, so the code of a real fit is compiled into the executable.

using BAYSOLRun
using SetupWizard

include("bundle.jl")

"The version line: `v<version> <release name>`, read from `Project.toml` at build time."
const VERSION_LINE = _versionLine()

const USAGE = """
baysol $VERSION_LINE

usage: baysol                  the terminal interface (the setup on the first start)
       baysol tui              the terminal interface
       baysol run PROJECT --temperature T [options]
                               a fit of a project folder (baysol run --help)
       baysol setup            the setup wizard: folders, shortcuts, uninstall
       baysol setup --advanced the wizard, in Advanced (repair, dependencies, folders)
       baysol version
"""

"""
    baysolMain(args) -> Int

The command of `args`; the exit status.
"""
function baysolMain(args::Vector{String})::Int
    bundle = bundleDir()
    prepareEnvironment(bundle)
    cmd = isempty(args) ? "" : args[1]
    rest = args[2:end]
    if cmd in ("version", "--version", "-V")
        println(VERSION_LINE)
        return 0
    elseif cmd in ("help", "--help", "-h")
        print(USAGE)
        return 0
    elseif cmd == "run"
        return withThreads(bundle, args) do
            BAYSOLRun.runProjectCli(rest; io = stderr)
        end
    elseif cmd == "run-tui"  # the interface's own call: project, temperature, run folder
        if length(rest) != 3
            println(stderr, "usage: baysol run-tui PROJECT T RUNDIR")
            return 2
        end
        return withThreads(bundle, args) do
            BAYSOLRun.runProject(rest[1]; temperature = parse(Float64, rest[2]),
                ui = :tui, runDir = rest[3])
            0
        end
    elseif cmd == "setup"
        return afterSetup(bundle,
            SetupWizard.runWizard(bundle; launch = !noLaunch(),
                advanced = "--advanced" in rest))
    elseif cmd == "tui"
        return startTui(bundle, rest)
    elseif cmd == ""
        needsSetup() && return afterSetup(bundle,
            SetupWizard.runWizard(bundle; firstRun = true, launch = !noLaunch()))
        return launchChosen(bundle)
    end
    println(stderr, "baysol: unknown command $cmd\n")
    print(stderr, USAGE)
    return 2
end

function @main(args::Vector{String})
    code = 1
    try
        code = baysolMain(args)
    catch e
        e isa InterruptException && (code = 130)
        if !(e isa InterruptException)
            showerror(stderr, e, catch_backtrace())
            println(stderr)
        end
    end
    flush(stdout)
    flush(stderr)
    return code
end

if !isempty(get(ENV, "BAYSOL_WORKLOAD", ""))
    include("workload.jl")
end
