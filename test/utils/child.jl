# SPDX-License-Identifier: LGPL-2.1-or-later

# The measured process of the cold/steady benchmark (see the Benchmarks section of README.md). Do not run by hand: bench.tcl starts it in a
# fresh process, in the right environment, and collects the JSON it prints.
#
#   julia --project=<repo> child.jl <repo> <ID[:tag]> [n_samples n_adapt]
#
# It does the same fit twice in one process. The first is the "first fit" (JIT included); the second is
# "steady state" (everything compiled). Plotting is skipped (`makie = false`), so GLMakie is never loaded.

using JSON3
const T_PROC = time()
const REPO, SPEC = ARGS[1], ARGS[2]
const N_SAMPLES = length(ARGS) ≥ 3 ? parse(Int, ARGS[3]) : 2000
const N_ADAPT = length(ARGS) ≥ 4 ? parse(Int, ARGS[4]) : 1000

t_using = @elapsed using BAYSOL
t_tool = @elapsed include(joinpath(REPO, "test", "utils", "fit_seed.jl"))
id, tag = occursin(':', SPEC) ? String.(split(SPEC, ":"; limit = 2)) : (String(SPEC), "")

function one_fit()
    local seed
    seed_s = @elapsed (seed, _, _) = load_fit_seed(id, tag; makie = false)
    run_s = @elapsed redirect_stderr(devnull) do
        BAYSOL.run_model(seed, N_SAMPLES, N_ADAPT)
    end
    st = seed.timing.stages
    return Dict{String,Any}(
        "seed_s" => seed_s, "run_s" => run_s, "total_s" => seed_s + run_s,
        "stage_name" => [s.name for s in st], "stage_depth" => [s.depth for s in st],
        "stage_seconds" => [s.seconds for s in st], "stage_compile" => [s.compile for s in st],
        "stage_gc" => [s.gc for s in st],
        "n_atoms" => seed.fw.n_atoms, "n_q" => length(seed.fw.qvals), "lMax" => seed.fw.lMax,
    )
end

first_fit = one_fit()
second_fit = one_fit()
JSON3.write(stdout, Dict{String,Any}(
    "using_baysol_s" => t_using, "tooling_load_s" => t_tool, "process_s" => time() - T_PROC,
    "first" => first_fit, "second" => second_fit,
))
