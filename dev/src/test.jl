# SPDX-License-Identifier: LGPL-3.0-or-later

# Runs the tests of the dev tools (dev/test/test-*.jl, Julia's `Test`).
module TestTool

using ..Common

const WHO = "bysl test"

const USAGE = """
Runs the tests of the dev tools (dev/test/test-*.jl).

    bysl test [NAME ...]

    NAME        run the test files whose name contains it (default: all)

Runs in a fresh Julia process; no fit or benchmark runs.
"""

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    pkg = in_root("dev")
    return run_cmd([find_julia(), "--startup-file=no", "--project=" * joinpath(pkg, "test"),
        joinpath(pkg, "test", "runtests.jl"), argv]) ? 0 : 1
end

end
