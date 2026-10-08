# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs the full unit-test suite:
#   julia --project=test test/run/unittests.jl
#
# Every ../unit_tests/units/test_*.jl is self-contained (each `include`s its own testsetup.jl and declares
# its own `using`s), so it can also be run on its own, e.g.:
#   julia --project=test test/unit_tests/units/test_atomicradii.jl
#
# Layout: the tests are in ../unit_tests/units/, with the setup they share (testsetup.jl) beside them;
# the shared helpers are in ../utils/ (floatcompare.jl, geometry.jl); the data the tests read is in
# ../fixtures/ (sequences.jl, the protein/DNA/RNA sequences, sits with the molecules there).

using Test

# Every `test_*.jl` in units/, in name order, with the package-quality checks (Aqua, ExplicitImports,
# JET) last. A new test file is picked up by creating it in units/.
const UNITS_DIR = joinpath(@__DIR__, "..", "unit_tests", "units")
const LAST = "test_quality.jl"
const TEST_FILES = let files = sort!(filter(f -> startswith(f, "test_") && endswith(f, ".jl"), readdir(UNITS_DIR)))
    [filter(!=(LAST), files); filter(==(LAST), files)]
end

@testset "BAYSOL" begin
    for file in TEST_FILES
        include(joinpath(UNITS_DIR, file))
    end
end
