# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs the unit-test suite:
#   julia --project=test dev/unittests.jl            # all of it
#   julia --project=test dev/unittests.jl shannon wls
#                                    # only the files whose name contains one of these
#
# Every ../test/unit_tests/units/test_*.jl is self-contained (each `include`s its own
# testsetup.jl and declares its own `using`s), so it can also be run on its own, e.g.:
#   julia --project=test test/unit_tests/units/test_atomicradii.jl
#
# Layout: the tests are in ../test/unit_tests/units/, with the setup they share
# (testsetup.jl) beside them; the shared helpers are in ../test/utils/
# (floatcompare.jl, geometry.jl); the data the tests read is in ../test/fixtures/
# (sequences.jl, the protein/DNA/RNA sequences, sits with the molecules there).

using Test

# Every `test_*.jl` in units/, in name order, with the package-quality checks (Aqua,
# ExplicitImports, JET) last. A new test file is picked up by creating it in units/.
const UNITS_DIR = joinpath(@__DIR__, "..", "test", "unit_tests", "units")
const LAST = "test_quality.jl"
const TEST_FILES =
    let files = sort!(
            filter(f -> startswith(f, "test_") && endswith(f, ".jl"), readdir(UNITS_DIR)),
        )
        [filter(!=(LAST), files); filter(==(LAST), files)]
    end

# Command-line words select files by substring;
# naming a word that matches no file is an error.
const SELECTED =
    isempty(ARGS) ? TEST_FILES : filter(f -> any(occursin(a, f) for a in ARGS), TEST_FILES)
isempty(SELECTED) && error("no test file in $UNITS_DIR matches: $(join(ARGS, ", "))")

@testset "BAYSOL" begin
    for file in SELECTED
        include(joinpath(UNITS_DIR, file))
    end
end
