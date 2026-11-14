# SPDX-License-Identifier: LGPL-3.0-or-later

# Runs the unit-test suite:
#   julia --project=test dev/scripts/unittests.jl            # all of it
#   julia --project=test dev/scripts/unittests.jl shannon wls
#                                    # only the files whose name contains one of these
#
# Every ../test/unit-tests/units/test-*.jl is self-contained (each `include`s its own
# testsetup.jl and declares its own `using`s), so it can also be run on its own, e.g.:
#   julia --project=test test/unit-tests/units/test-atomicradii.jl
# The Julia that only the terminal interface needs lives in ../tui/src/store/*.jl, and its
# tests next to the TypeScript ones, ../tui/test/*.test.jl (kebab case, run the same way:
#   julia --project=test tui/test/run-project.test.jl).
#
# Layout: the tests are in ../test/unit-tests/units/, with the setup they share
# (testsetup.jl) beside them; the shared helpers are beside them in ../test/unit-tests/
# (floatcompare.jl, geometry.jl); the data the tests read is in ../test/fixtures/
# (sequences.jl, the protein/DNA/RNA sequences, sits with the molecules there).

using Test

# Every `test-*.jl` in units/, in name order, then every `*.test.jl` of the terminal
# interface's test folder, with the package-quality checks (Aqua, ExplicitImports, JET)
# last. A new test file is picked up by creating it in one of the two folders.
const UNITS_DIR = joinpath(@__DIR__, "..", "..", "test", "unit-tests", "units")
const TUI_TEST_DIR = joinpath(@__DIR__, "..", "..", "tui", "test")
const LAST = "test-quality.jl"
const TEST_FILES =
    let files = vcat(
            sort!(
                filter(
                    f -> startswith(f, "test-") && endswith(f, ".jl"),
                    readdir(UNITS_DIR),
                ),
            ),
            sort!(filter(f -> endswith(f, ".test.jl"), readdir(TUI_TEST_DIR))),
        )
        [filter(!=(LAST), files); filter(==(LAST), files)]
    end

"The path of the test file called `file` (in units/ or in the terminal interface's tests)."
test_path(file) =
    endswith(file, ".test.jl") ? joinpath(TUI_TEST_DIR, file) : joinpath(UNITS_DIR, file)

# Command-line words select files by substring;
# naming a word that matches no file is an error.
# A worker process of a parallel run gets its files in this variable (exact names).
const WORKER_FILES = "UNIT_WORKER_FILES"

const SELECTED =
    if haskey(ENV, WORKER_FILES)
        split(ENV[WORKER_FILES], ',')
    elseif isempty(ARGS)
        TEST_FILES
    else
        filter(f -> any(occursin(a, f) for a in ARGS), TEST_FILES)
    end
isempty(SELECTED) &&
    error("no test file in $UNITS_DIR or $TUI_TEST_DIR matches: $(join(ARGS, ", "))")

"""
How long each file takes alone, in seconds (measured; a file not listed takes 1 s): the
parallel run uses it to give each worker about the same work. `test-quality.jl` stays
last in its worker (it checks the package after the other files have loaded).
"""
const FILE_SECONDS = Dict(
    "test-sampler.jl" => 137, "run-project.test.jl" => 52,
    "settings-file.test.jl" => 51,
    "test-quality.jl" => 32, "test-modified-amino.jl" => 29, "test-plot.jl" => 26,
    "test-concurrency.jl" => 15, "test-seed-diagnostics.jl" => 15,
    "test-data-selection.jl" => 15, "test-allocations.jl" => 12,
    "test-setting-keywords.jl" => 11, "test-modified-nucleotides.jl" => 9,
    "test-nucleotide-fixtures.jl" => 7,
)

"""
The files shared out to `jobs` workers, longest first, each to the one with the least work.
"""
function share_out(files, jobs)
    groups = [String[] for _ in 1:jobs]
    load = zeros(Int, jobs)
    for file in sort(files; by = f -> -get(FILE_SECONDS, f, 1))
        k = argmin(load)
        push!(groups[k], file)
        load[k] += get(FILE_SECONDS, file, 1)
    end
    for group in groups  # the package checks come last in their worker
        sort!(group; by = f -> f == LAST ? 1 : 0)
    end
    return filter(!isempty, groups)
end

# The whole suite runs in `UNIT_JOBS` processes at once (default 2: each needs a few GB,
# and a run that names files stays in one process, as the concurrency tests need).
const JOBS = parse(Int, get(ENV, "UNIT_JOBS", "2"))

if !haskey(ENV, WORKER_FILES) && isempty(ARGS) && JOBS > 1
    groups = share_out(collect(SELECTED), JOBS)
    logs = [tempname() * ".log" for _ in groups]
    procs = map(zip(groups, logs)) do (group, log)
        env = copy(ENV)
        env[WORKER_FILES] = join(group, ',')
        run(
            pipeline(
                setenv(
                    `$(Base.julia_cmd()) --project=$(Base.active_project()) $(@__FILE__)`,
                    env,
                );
                stdout = log,
                stderr = log,
            );
            wait = false,
        )
    end
    for (k, proc) in enumerate(procs)
        wait(proc)
        println("=== unit tests, worker $k of $(length(procs)): ", join(groups[k], " "))
        print(read(logs[k], String))
    end
    failed = any(p -> !success(p), procs)
    foreach(log -> rm(log; force = true), logs)
    println(
        failed ? "unit tests: FAILED in at least one worker" :
        "unit tests: all workers passed",
    )
    exit(failed ? 1 : 0)
end

@testset "BAYSOL" begin
    for file in SELECTED
        include(test_path(file))
    end
end
