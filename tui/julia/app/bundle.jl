# SPDX-License-Identifier: LGPL-3.0-or-later

# What the entry of the packaged app does around the fit: where the bundle is, the
# environment the other programs and the package read, the threads, and the start of the
# terminal interface. Only the standard library and the two packages of the entry.

# The one place that detects the system (`platform.jl` of the repository), by way of the
# setup wizard that holds it, so that the entry includes no file of its own.
const Platform = SetupWizard.Platform

"""
    bundleDir() -> String

The folder of the running executable (the bundle): `BAYSOL_BUNDLE` when it names a folder,
else the folder `julia_bin` of the runtime names, with links resolved (the PATH link of the
setup points into the bundle).
"""
function bundleDir()::String
    named = strip(get(ENV, "BAYSOL_BUNDLE", ""))
    isdir(named) && return String(named)
    return dirname(realpath(unsafe_string(Base.JLOptions().julia_bin)))
end

"The version line of `Project.toml` at `root`: `v<version> <release_name>`."
function _versionLine(root::AbstractString = dirname(dirname(dirname(@__DIR__))))::String
    file = joinpath(root, "Project.toml")
    isfile(file) || return "unknown"
    toml = read(file, String)
    function field(k)
        m = match(Regex("^$k\\s*=\\s*\"([^\"]*)\"", "m"), toml)
        return m === nothing ? "?" : m[1]
    end
    return "v" * field("version") * " " * field("release_name")
end

"The git revision this executable was built from: `bysl pkg` gives it at build time."
const BUILD_REVISION = strip(get(ENV, "BAYSOL_BUILD_REVISION", ""))

noLaunch() = !isempty(get(ENV, "BAYSOL_NO_LAUNCH", ""))

"""
    prepareEnvironment(bundle)

Sets what the fit and the other programs read, unless the caller set it already: the
one Python executable (`BAYSOL_PYTOOLS`), the
revision of a build (`BAYSOL_REVISION`, [`BUILD_REVISION`](@ref)), the folders of
`install.json` (`BAYSOL_HOME`, `BAYSOL_CACHE`) and `BAYSOL_BUNDLE` itself.
"""
function prepareEnvironment(bundle::AbstractString)::Nothing
    function setDefault(name, value)
        isempty(strip(get(ENV, name, ""))) && !isempty(value) && (ENV[name] = value)
        return nothing
    end
    setDefault("BAYSOL_BUNDLE", bundle)
    pytools = joinpath(bundle, "lib", "pytools", Platform.exe("baysol-pytools"))
    isfile(pytools) && setDefault("BAYSOL_PYTOOLS", pytools)
    setDefault("BAYSOL_REVISION", BUILD_REVISION)
    i = SetupWizard.readInstall(SetupWizard.installFile())
    if i !== nothing
        setDefault("BAYSOL_HOME", i.home)
        setDefault("BAYSOL_CACHE", i.structureCache)
        setDefault("BAYSOL_THREADS", string(i.threads))
    end
    return nothing
end

"""
    withThreads(f, bundle, args) -> Int

Runs `f()` when this process has the threads a fit needs; a compiled executable
takes no `--threads` flag, so with one thread and no `JULIA_NUM_THREADS` the same
command is started again with the variable set (`BAYSOL_THREADS`, else the number
of CPU threads, at most 8, and at most 4 under Rosetta 2: with 8 threads Julia's
stop-the-world for the garbage collector hung for ever in `thread_get_state` of
Rosetta, in 2 of 5 interface runs of a build). The exit status.
"""
function withThreads(f, bundle::AbstractString, args::Vector{String})::Int
    if Threads.nthreads() == 1 && isempty(get(ENV, "JULIA_NUM_THREADS", ""))
        n = something(tryparse(Int, get(ENV, "BAYSOL_THREADS", "")),
            clamp(Sys.CPU_THREADS, 1, Platform.isrosetta() ? 4 : 8))
        n > 1 || return f()
        exe = unsafe_string(Base.JLOptions().julia_bin)
        proc = run(ignorestatus(addenv(Cmd([exe; args]), "JULIA_NUM_THREADS" => string(n))))
        return proc.exitcode
    end
    return f()
end

"""
    startTui(bundle, args) -> Int

Runs `baysol-tui` of the bundle with the terminal; the exit status. The interface starts
fits as `baysol run-tui ...` of this same executable.
"""
function startTui(bundle::AbstractString, args::Vector{String})::Int
    tui = joinpath(bundle, Platform.exe("baysol-tui"))
    if !isfile(tui)
        println(stderr, "baysol: the terminal interface is missing: $tui")
        return 1
    end
    return run(ignorestatus(Cmd([tui; args]))).exitcode
end

"""
    afterSetup(bundle, status) -> Int

What follows the wizard: the interface or a shell when the user chose to launch
one. The status `UNINSTALLED` goes on as it is when the interface started the
wizard (`noLaunch()`, the interface sets `BAYSOL_NO_LAUNCH`), because the
interface quits on it; for a user who ran `baysol setup` it is 0, a success.
"""
function afterSetup(bundle::AbstractString, status::Integer)::Int
    status == SetupWizard.LAUNCH_TUI && return startTui(bundle, String[])
    status == SetupWizard.LAUNCH_CLI && return startShell(bundle)
    status == SetupWizard.UNINSTALLED && return noLaunch() ? Int(status) : 0
    return Int(status)
end

"A shell with the bundle on its `PATH` and the usage printed: what a CLI icon opens."
function startShell(bundle::AbstractString)::Int
    print(USAGE)
    shell = Platform.shell()
    path = bundle * Platform.PATH_SEP * get(ENV, "PATH", "")
    return run(ignorestatus(addenv(Cmd([shell]), "PATH" => path))).exitcode
end

"What the launcher (`baysol` alone, the icon) starts: the choice of `install.json`."
function launchChosen(bundle::AbstractString)::Int
    i = SetupWizard.readInstall(SetupWizard.installFile())
    cli = i !== nothing && i.opens == "cli"
    return cli ? startShell(bundle) : startTui(bundle, String[])
end
