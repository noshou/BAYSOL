# SPDX-License-Identifier: LGPL-2.1-or-later

# Sampler diagnostics on any SASBDB fitting test, without rerunning its fit or report. Normally started
# through the Tcl front end, which checks the arguments first:
#
#   tclsh test/utils/diagnose.tcl <command> [options] ID[:tag] ...
#
# or directly:
#
#   julia --project=test/fitting_tests test/utils/diagnose.jl <command> [options] ID[:tag] ...
#
# Commands (the work is done by test/utils/seed_diagnostics.jl):
#   report     MAP starts, Hessian, NUTS step size and depth, Laplace agreement, modes, gradient error
#   tolerance  NUTS at several c1 profiling tolerances and RNG seeds (is the tolerance tight enough?)
#   ablate     χ² with one shared shell contrast / δρ₁=δρ₂ + δρ₃ / the full model
#
# Options:  --out FILE   write here instead of stdout
#           --tols 1e-5,1e-8     c1 tolerances for `tolerance`
#           --seeds 1,2,3        RNG seeds for `tolerance`
#           --samples N --adapt N   NUTS iterations (default 2000 / 1000)
#
# `ID` is a folder under test/fitting_tests/ (SASDBS6); `tag` picks one run of a script that has several
# (fit2_model3); scripts with a single run take no tag. SASDMZ9 and SASDJ72 take model1|model2(|model3).
# How the Seed is obtained is in test/utils/fit_seed.jl.

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
            opts[args[i][3:end]] = args[i+1]; i += 2
        else
            push!(specs, args[i]); i += 1
        end
    end
    return opts, specs
end

function main(args)
    if isempty(args)
        println("usage: julia --project=test/fitting_tests test/utils/diagnose.jl ",
            "report|tolerance|ablate [--out FILE] [--tols 1e-5,1e-8] [--seeds 1,2,3] [--samples N] [--adapt N] ID[:tag] ...")
        return
    end
    cmd, rest = args[1], args[2:end]
    cmd in ("report", "tolerance", "ablate") || error("unknown command $cmd (report | tolerance | ablate)")
    opts, specs = parse_cli(rest)
    isempty(specs) && error("give at least one ID[:tag]")
    n_samples = parse(Int, get(opts, "samples", "2000")); n_adapt = parse(Int, get(opts, "adapt", "1000"))
    tols = Tuple(parse.(Float64, split(get(opts, "tols", "1e-5,1e-8"), ",")))
    rngs = Tuple(parse.(Int, split(get(opts, "seeds", "7"), ",")))
    out = haskey(opts, "out") ? open(opts["out"], "w") : stdout
    try
        for spec in specs
            id, tag = occursin(':', spec) ? String.(split(spec, ":"; limit = 2)) : (spec, "")
            seed, reference, label = load_fit_seed(id, tag)
            if cmd == "report"
                diagnose(out, seed; label, reference, n_samples, n_adapt)
            elseif cmd == "tolerance"
                tolerance_sweep(out, seed; label, tols, rng_seeds = rngs, n_samples, n_adapt)
            else
                a = shell_contrast_ablation(seed)
                println(out, @sprintf("%s  M1(shared d)=%.3f [d=%.2f c1=%.3f]   M2(δρ₁=δρ₂, δρ₃)=%.3f [d12=%.2f d3=%.2f c1=%.3f]   M3(full MAP)=%.3f [c1=%.3f]",
                    label, a.M1.chi2, a.M1.d, a.M1.c1, a.M2.chi2, a.M2.d12, a.M2.d3, a.M2.c1, a.M3.chi2, a.M3.c1))
            end
            flush(out)
        end
    finally
        out === stdout || close(out)
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
