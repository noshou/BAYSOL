# SPDX-License-Identifier: LGPL-3.0-or-later

# The measured process of the cold/steady benchmark (see the Benchmarks
# section of README.md). Do not run by hand: bench.clj starts it in a fresh
# process, in the right environment, and collects the JSON it prints.
#
#   julia --project=<repo> child.jl <repo> <ID[:tag]> [n_samples n_adapt]
#
# Without n_samples and n_adapt the fit uses whatever `run_model`
# defaults to in <repo>, so the benchmark follows the code it
# measures; the iterations actually used are recorded in the result.
#
# It does the same fit twice in one process. The first is the "first fit"
# (JIT included); the second is "steady state" (everything compiled).

using JSON3
const T_PROC = time()
const REPO, SPEC = ARGS[1], ARGS[2]
# (n_samples, n_adapt), or the defaults
const ITERATIONS = length(ARGS) ≥ 4 ? (parse(Int, ARGS[3]), parse(Int, ARGS[4])) : nothing

# Every fit runs with this `rng_seed` (and the default `jitter_seed`), in the first and the
# steady fit alike: the MAP search, the extra chains it may start and every chain depend on
# the seed, so a fresh seed each time measures a different amount of work from one run to
# the next (about one run in six of SASDBS6:fit2_model3 finds a second mode and starts two
# more chains, which costs 60 to 90 %). The same seed in two revisions is the same work.
const RNG_SEED = 1

t_using = @elapsed using BAYSOL
t_tool  = @elapsed include(joinpath(REPO, "dev", "fit_seed.jl"))
id, tag = occursin(':', SPEC) ? String.(split(SPEC, ":"; limit = 2)) : (String(SPEC), "")

function one_fit()
    local seed
    seed_s = @elapsed (seed, _, _) = load_fit_seed(id, tag)
    run_s = @elapsed redirect_stderr(devnull) do
        ITERATIONS === nothing ? BAYSOL.run_model(seed; rng_seed = RNG_SEED) :
        BAYSOL.run_model(seed, ITERATIONS...; rng_seed = RNG_SEED)
    end
    st = seed.timing.stages
    return Dict{String,Any}(
        "seed_s" => seed_s, "run_s" => run_s, "total_s" => seed_s + run_s,
        "stage_name" => [s.name for s in st], "stage_depth" => [s.depth for s in st],
        "stage_seconds" => [s.seconds for s in st],
        "stage_compile" => [s.compile for s in st],
        "stage_gc" => [s.gc for s in st],
        "n_samples" => seed.timing.info["n_samples"],
        "n_adapt" => seed.timing.info["n_adapt"],
        "n_chains" => get(seed.timing.info, "n_chains", 1), "rng_seed" => RNG_SEED,
        "n_atoms" => seed.fw.n_atoms, "n_q" => length(seed.fw.qvals),
        "lMax" => seed.fw.lMax,
        "n_q_raw" => length(seed.shannon.q_raw), "rebin" => seed.shannon.rebin,
        "D" => seed.shannon.D,
    )
end

first_fit = one_fit()
second_fit = one_fit()
JSON3.write(
    stdout,
    Dict{String,Any}(
        "using_baysol_s" => t_using, "tooling_load_s" => t_tool,
        "process_s" => time() - T_PROC,
        "first" => first_fit, "second" => second_fit,
    ),
)
