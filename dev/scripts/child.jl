# SPDX-License-Identifier: LGPL-3.0-or-later

# The measured process of the cold/steady benchmark (see the Benchmarks
# section of README.md). Do not run by hand: `bysl fits bench` starts it in a fresh
# process, in the right environment, and collects the JSON it prints.
#
#   julia --project=<repo> child.jl <repo> <ID[:tag]> [nSamples nAdapt]
#
# Without nSamples and nAdapt the fit uses whatever `runModel`
# defaults to in <repo>, so the benchmark follows the code it
# measures; the iterations actually used are recorded in the result.
#
# It does the same fit twice in one process. The first is the "first fit"
# (JIT included); the second is "steady state" (everything compiled).

using JSON3
const T_PROC = time()
const REPO, SPEC = ARGS[1], ARGS[2]
# (nSamples, nAdapt), or the defaults
const ITERATIONS = length(ARGS) ≥ 4 ? (parse(Int, ARGS[3]), parse(Int, ARGS[4])) : nothing

# Every fit runs with this `rngSeed`, in the first and the
# steady fit alike: the MAP search, the extra chains it may start and every chain depend on
# the seed, so a fresh seed each time measures a different amount of work from one run to
# the next (about one run in six of the removed SASDBS6:fit2_model3 found a second mode
# and started two more chains, which cost 60 to 90 %). The same seed in two revisions is
# the same work.
const RNG_SEED = 1

t_using = @elapsed using BAYSOL
t_tool  = @elapsed include(joinpath(REPO, "dev", "src", "fit-seed.jl"))
id, tag = occursin(':', SPEC) ? String.(split(SPEC, ":"; limit = 2)) : (String(SPEC), "")

function one_fit()
    local seed
    seedS = @elapsed (seed, _, _) = load_fit_seed(id, tag)
    runS = @elapsed redirect_stderr(devnull) do
        ITERATIONS === nothing ? BAYSOL.runModel(seed; rngSeed = RNG_SEED) :
        BAYSOL.runModel(seed, ITERATIONS...; rngSeed = RNG_SEED)
    end
    st = seed.timing.stages
    return Dict{String,Any}(
        "seedS" => seedS, "runS" => runS, "totalS" => seedS + runS,
        "stageName" => [s.name for s in st], "stageDepth" => [s.depth for s in st],
        "stageSeconds" => [s.seconds for s in st],
        "stageCompile" => [s.compile for s in st],
        "stageGc" => [s.gc for s in st],
        "nSamples" => seed.timing.info["nSamples"],
        "nAdapt" => seed.timing.info["nAdapt"],
        "nChains" => get(seed.timing.info, "nChains", 1), "rngSeed" => RNG_SEED,
        "nAtoms" => seed.fw.nAtoms, "nQ" => length(seed.fw.qvals),
        "lMax" => seed.fw.lMax,
        "nQRaw" => length(seed.shannon.qRaw), "rebin" => seed.shannon.rebin,
        "D" => seed.shannon.D,
    )
end

first_fit = one_fit()
second_fit = one_fit()
JSON3.write(
    stdout,
    Dict{String,Any}(
        "usingBaysolS" => t_using, "toolingLoadS" => t_tool,
        "processS" => time() - T_PROC,
        "first" => first_fit, "second" => second_fit,
    ),
)
