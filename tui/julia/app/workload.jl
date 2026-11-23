# SPDX-License-Identifier: LGPL-3.0-or-later

# Build time only (`BAYSOL_WORKLOAD` names a folder of project folders, `bysl pkg` makes
# it): the fits of those projects run once, with the outputs thrown away, so that the code
# of a real fit (the structure side, the sampler, the figures, the workbook, the log) is
# compiled into the executable instead of at the first run of a user. The lines of
# `BAYSOL_STATEMENTS` (a file of `precompile(...)` statements from `--trace-compile`)
# cover code the projects do not reach.

# The build process is already past its exit hooks, and a fit registers two of its own:
# allow that while the workload runs and drop them afterwards.
import LinearAlgebra
const _HOOKS = length(Base.atexit_hooks)
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

resize!(Base.atexit_hooks, _HOOKS)
Core.eval(Base, :(global _atexit_hooks_finished = true))
