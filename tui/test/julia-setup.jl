# SPDX-License-Identifier: LGPL-3.0-or-later

# Shared baseline of the Julia tests in this folder (`*.test.jl`): the setup of the unit
# tests, and the module `BAYSOLRun` of `src/store/run-project.jl` loaded once into `Main`
# (the runner of the unit tests includes every file into one process; a standalone run,
# `julia --project=test tui/test/buffer.test.jl`, loads it as well).
include(joinpath(@__DIR__, "..", "..", "test", "unit_tests", "testsetup.jl"))

if !isdefined(Main, :BAYSOLRun)
    include(joinpath(@__DIR__, "..", "src", "store", "run-project.jl"))
end
