# SPDX-License-Identifier: LGPL-3.0-or-later

# Sampler diagnostics on any SASBDB fitting test, without rerunning its fit or report.
# Normally started through `bysl fits diagnose`, which checks the arguments first:
#
#   bysl fits diagnose --<part> [options] ID[:tag] ...
#
# or directly:
#
#   julia --project=test/fitting_tests dev/scripts/diagnose.jl \
#       --<part> [options] ID[:tag] ...
#
# Parts (the work is done by dev/src/seed-diagnostics.jl;
# the options are listed by `bysl fits diagnose --help`):
#   --report     MAP starts, Hessian, NUTS step size and depth,
#                Laplace agreement, modes, gradient error
#   --residuals  are the residuals at the MAP white (lag-1 and runs
#                z) and the reduced χ², on the fitted grid and on the
#                measured grid (the MAP search only; no sampling)
#   --chains     every chain of `infer`: start, mode, divergences, step size, and each
#                divergent draw (which chains the divergences come from); --retry 1
#                looks at the rerun `infer` does when R̂ is above the limit
#
# `ID` is a folder under test/fitting_tests/ (SASDTK5); `tag` picks one run of a script that
# has several (fit3_model1); scripts with a single run take no tag. How the Seed is
# obtained is in dev/src/fit-seed.jl.

using Printf
using BAYSOL
include(joinpath(@__DIR__, "..", "src", "seed-diagnostics.jl"))
using .SeedDiagnostics
include(joinpath(@__DIR__, "..", "src", "fit-seed.jl"))

# `--key value` options and positional `ID[:tag]` specs.
function parse_cli(args)
    opts = Dict{String,String}()
    specs = String[]
    i = 1
    while i ≤ length(args)
        if startswith(args[i], "--")
            i < length(args) || error("option $(args[i]) needs a value")
            opts[args[i][3:end]] = args[i+1]
            i += 2
        else
            push!(specs, args[i])
            i += 1
        end
    end
    return opts, specs
end

# The residuals of the MAP fit, normalized by the errors: lag-1 autocorrelation
# (0 for white residuals) and the runs-test z (0 for white) with the reduced χ²,
# on the fitted grid and, for a binned fit, on the measured grid (the grid CRYSOL
# and FoXS evaluate). Nothing is sampled: the MAP search of the fit is enough.
function residual_report(out, seed; label)
    Fit = BAYSOL.Inference
    sp = Fit._samplingSpace(seed)
    ξ = Fit.Ξ(sp.μ .+ sp.σ .* sp.ẑ, seed.pr)
    ŷ, wfit, _ = Fit.profiledCorrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
    pred = Fit.wlsPredict(wfit, ŷ)
    r = (seed.wls.iObs .- pred) .* sqrt.(seed.wls.weights)
    rs = BAYSOL.Shannon.residualStructure(r)
    println(
        out,
        @sprintf("%s: fitted grid   %4d points  lag-1 %+.3f  runs z %+.2f  χ²_red %.4g",
            label, length(r), rs.lag1, rs.runsZ, sum(abs2, r) / (length(r) - 3))
    )
    sh = seed.shannon
    if sh !== nothing && sh.rebin > 0
        r_raw = (sh.iRaw .- BAYSOL.Shannon.modelOnRaw(sh, pred)) ./ sh.σ_raw
        rr = BAYSOL.Shannon.residualStructure(r_raw)
        println(
            out,
            @sprintf("%s: measured grid %4d points  lag-1 %+.3f  runs z %+.2f  χ²_red %.4g",
                label, length(r_raw), rr.lag1, rr.runsZ,
                sum(abs2, r_raw) / (length(r_raw) - 3))
        )
    end
end

function main(args)
    if isempty(args)
        println("usage: julia --project=test/fitting_tests dev/scripts/diagnose.jl ",
            (
                "--report|--residuals|--chains " *
                "[--out FILE] [--seeds 1,2,3] [--retry 1] " *
                "[--samples N] [--adapt N] ID[:tag] ..."
            ),
        )
        return
    end
    cmd, rest = args[1], args[2:end]
    cmd in ("--report", "--residuals", "--chains") ||
        error(
            (
            "unknown part $cmd (--report | --residuals | --chains)"
        ),
        )
    cmd = cmd[3:end]
    opts, specs = parse_cli(rest)
    isempty(specs) && error("give at least one ID[:tag]")
    n_default = BAYSOL.Pipeline.N_ADAPT + BAYSOL.Pipeline.N_DRAWS
    nSamples = parse(Int, get(opts, "samples", string(n_default)))
    nAdapt = parse(Int, get(opts, "adapt", string(BAYSOL.Pipeline.N_ADAPT)))
    # (the seeds of --chains are 64-bit: a report's `rngSeed` is a UInt64)
    chain_seeds = parse.(Int128, split(get(opts, "seeds", "7"), ","))
    out = haskey(opts, "out") ? open(opts["out"], "w") : stdout
    try
        for spec in specs
            id, tag =
                occursin(':', spec) ? String.(split(spec, ":"; limit = 2)) : (spec, "")
            seed, reference, label = load_fit_seed(id, tag)
            if cmd == "report"
                diagnose(out, seed; label, reference, nSamples, nAdapt)
            elseif cmd == "chains"
                for s in chain_seeds
                    chain_report(out, seed; label, nSamples, nAdapt, rngSeed = s,
                        rerun = get(opts, "retry", "0") == "1")
                end
            else
                residual_report(out, seed; label)
            end
            flush(out)
        end
    finally
        out === stdout || close(out)
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
