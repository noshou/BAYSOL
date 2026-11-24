# SPDX-License-Identifier: LGPL-3.0-or-later

# Build time only (`BAYSOL_WORKLOAD` names a folder of project folders, `bysl pkg` makes
# it): the fits of those projects run once, with the outputs thrown away, so that the code
# of a real fit (the structure side, the sampler, the figures, the workbook, the log) is
# compiled into the executable instead of at the first run of a user. The lines of
# `BAYSOL_STATEMENTS` (a file of `precompile(...)` statements from `--trace-compile`)
# cover code the projects do not reach.

# The build process is already past its exit hooks, and a fit registers some of its own
# (`atexit` puts a new hook at the FRONT of the list): allow that while the workload runs,
# and put the list back as it was afterwards. A closure of the workload's still in the list
# keeps what it captured (a run's state, its tasks) reachable, and the system image cannot
# hold a `Task` ("Task cannot be serialized").
import LinearAlgebra
const _HOOKS = copy(Base.atexit_hooks)
Core.eval(Base, :(global _atexit_hooks_finished = false))

# The build process skips the `__init__` of the library packages (`*_jll`: no library is
# opened, a BLAS or Fortran call jumps to a null pointer): run them, in loading order, then
# the one of LinearAlgebra that forwards BLAS.
for m in Base.loaded_modules_order
    endswith(string(nameof(m)), "_jll") && isdefined(m, :__init__) && m.__init__()
end
LinearAlgebra.__init__()

try
    root = ENV["BAYSOL_WORKLOAD"]
    ENV["BAYSOL_CACHE"] = mktempdir()
    failed = String[]
    for name in sort(readdir(root))
        project = joinpath(root, name)
        isdir(project) || continue
        try
            BAYSOLRun.runProject(project; temperature = 20.0, ui = :tui, watchStdin = false,
                runDir = mkpath(joinpath(mktempdir(), "run")))
            BAYSOLRun.runProjectCli([project, "--temperature", "20", "--run-dir",
                mkpath(joinpath(mktempdir(), "cli"))])
        catch e
            msg = sprint(showerror, e, catch_backtrace())
            push!(failed, "workload $name failed: $msg")
        end
    end
    foreach(f -> println(Core.stderr, f), failed)
    statements = get(ENV, "BAYSOL_STATEMENTS", "")
    if isfile(statements)
        # every statement names its types with the package they come from: bind each
        # loaded package by its name, and count what compiled and what did not
        scope = Module(:Statements)
        for (id, m) in Base.loaded_modules
            isdefined(scope, Symbol(id.name)) || Core.eval(scope,
                :(const $(Symbol(id.name)) = $m))
        end
        good = bad = 0
        for line in eachline(statements)
            startswith(line, "precompile(") || continue
            try
                Core.eval(scope, Meta.parse(line)) === true ? (good += 1) : (bad += 1)
            catch
                bad += 1
            end
        end
        println(Core.stderr, "statements: $good compiled, $bad not")
    end
catch e
    println(Core.stderr, "workload aborted: ", sprint(showerror, e, catch_backtrace()))
end

# The system image cannot hold a live `Task` ("Task cannot be serialized"), and a global
# reaches two: `Distributed` (a dependency of BAYSOLRun) starts a task at load that waits on
# `any_gc_flag`, and the shared downloader of `Downloads` keeps curl timer and socket tasks
# after the workload's downloads. Stop the first, drop the second.
let dist = get(Base.loaded_modules,
        Base.PkgId(Base.UUID("8ba89e20-285c-5b6f-9357-94700520ee1b"), "Distributed"),
        nothing),
    dl = get(Base.loaded_modules,
        Base.PkgId(Base.UUID("f43a241f-c20a-4ad4-852c-f6b1247861c6"), "Downloads"),
        nothing)

    dl === nothing || (dl.DOWNLOADER[] = nothing)
    if dist !== nothing
        cond = dist.any_gc_flag
        # `errormonitor` prints the task's death: keep that out of the build log
        redirect_stderr(devnull) do
            while (t = cond.waitq.head) !== nothing
                schedule(t, InterruptException(); error = true)
                yield()
                sleep(0.05)
                cond.waitq.head === t && break
            end
        end
    end
end

empty!(Base.atexit_hooks)
append!(Base.atexit_hooks, _HOOKS)
Core.eval(Base, :(global _atexit_hooks_finished = true))
