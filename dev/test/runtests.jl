# SPDX-License-Identifier: LGPL-3.0-or-later

# The tests of the dev tools: `julia --project=dev dev/test/runtests.jl [NAME ...]` (or
# `bysl test [NAME ...]`).
using Test

include("helpers.jl")

names = ARGS
files = sort(filter(f -> startswith(f, "test-") && endswith(f, ".jl"), readdir(@__DIR__)))
files = filter(f -> isempty(names) || any(n -> occursin(n, f), names), files)
isempty(files) && (println(stderr, "bysl test: no test file matches"); exit(2))

@testset "dev tools" begin
    for f in files
        @testset "$f" include(joinpath(@__DIR__, f))
    end
end
