# SPDX-License-Identifier: LGPL-3.0-or-later

# Sampler diagnostics on any SASBDB fitting test, without rerunning its fit or report.
# Normally started through the Babashka front end, which checks the arguments first:
#
#   bb diagnose --<part> [options] ID[:tag] ...
#
# or directly:
#
#   julia --project=test/fitting_tests dev/diagnose.jl \
#       --<part> [options] ID[:tag] ...
#
# Parts (the work is done by dev/seed_diagnostics.jl;
# the options are listed in dev/diagnose.clj):
#   --report     MAP starts, Hessian, NUTS step size and depth,
#                Laplace agreement, modes, gradient error
#   --residuals  are the residuals at the MAP white (lag-1 and runs
#                z) and the reduced χ², on the fitted grid and on the
#                measured grid (the MAP search only; no sampling)
#   --chains     every chain of `infer`: start, mode, divergences, step size, and each
#                divergent draw (which chains the divergences come from); --retry 1
#                looks at the rerun `infer` does when R̂ is above the limit
#
# `ID` is a folder under test/fitting_tests/ (SASDBS6); `tag` picks one run of a script that
# has several (fit2_model3); scripts with a single run take no tag. SASDMZ9 and SASDJ72 take
# model1|model2(|model3). How the Seed is obtained is in dev/fit_seed.jl.

using Printf
using BAYSOL
include(joinpath(@__DIR__, "seed_diagnostics.jl"))
using .SeedDiagnostics
include(joinpath(@__DIR__, "fit_seed.jl"))

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
    sp = Fit._sampling_space(seed)
    ξ = Fit.Ξ(sp.μ .+ sp.σ .* sp.ẑ, seed.pr)
    ŷ, wfit, _ = Fit.profiled_corrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
    pred = Fit.wls_predict(wfit, ŷ)
    r = (seed.wls.I_obs .- pred) .* sqrt.(seed.wls.weights)
    rs = BAYSOL.Shannon.residual_structure(r)
    println(
        out,
        @sprintf("%s: fitted grid   %4d points  lag-1 %+.3f  runs z %+.2f  χ²_red %.4g",
            label, length(r), rs.lag1, rs.runs_z, sum(abs2, r) / (length(r) - 3))
    )
    sh = seed.shannon
    if sh !== nothing && sh.rebin > 0
        r_raw = (sh.I_raw .- BAYSOL.Shannon.model_on_raw(sh, pred)) ./ sh.σ_raw
        rr = BAYSOL.Shannon.residual_structure(r_raw)
        println(
            out,
            @sprintf("%s: measured grid %4d points  lag-1 %+.3f  runs z %+.2f  χ²_red %.4g",
                label, length(r_raw), rr.lag1, rr.runs_z,
                sum(abs2, r_raw) / (length(r_raw) - 3))
        )
    end
end

function main(args)
    if isempty(args)
        println("usage: julia --project=test/fitting_tests dev/diagnose.jl ",
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
    n_samples = parse(Int, get(opts, "samples", string(BAYSOL.Pipeline.DEFAULT_N_SAMPLES)))
    n_adapt = parse(Int, get(opts, "adapt", string(BAYSOL.Pipeline.DEFAULT_N_ADAPT)))
    # (the seeds of --chains are 64-bit: a report's `rng_seed` is a UInt64)
    chain_seeds = parse.(Int128, split(get(opts, "seeds", "7"), ","))
    out = haskey(opts, "out") ? open(opts["out"], "w") : stdout
    try
        for spec in specs
            id, tag =
                occursin(':', spec) ? String.(split(spec, ":"; limit = 2)) : (spec, "")
            seed, reference, label = load_fit_seed(id, tag)
            if cmd == "report"
                diagnose(out, seed; label, reference, n_samples, n_adapt)
            elseif cmd == "chains"
                for s in chain_seeds
                    chain_report(out, seed; label, n_samples, n_adapt, rng_seed = s,
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
