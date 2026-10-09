# SPDX-License-Identifier: LGPL-2.1-or-later

# Sampler diagnostics on any SASBDB fitting test, without rerunning its fit or report. Normally started
# through the Tcl front end, which checks the arguments first:
#
#   tclsh test/utils/diagnose.tcl --<part> [options] ID[:tag] ...
#
# or directly:
#
#   julia --project=test/fitting_tests test/utils/diagnose.jl --<part> [options] ID[:tag] ...
#
# Parts (the work is done by test/utils/seed_diagnostics.jl; the options are listed in diagnose.tcl):
#   --report     MAP starts, Hessian, NUTS step size and depth, Laplace agreement, modes, gradient error
#   --ablate     χ² with one shared shell contrast / δρ₁=δρ₂ + δρ₃ / the full model
#   --residuals  are the residuals at the MAP white (lag-1 and runs z) and the reduced χ², on the fitted grid and on the
#                measured grid (the MAP search only; no sampling)
#   --warmup     how short can the warm-up be and how many draws are enough
#   --tolerance  NUTS at several c1 profiling tolerances and RNG seeds (is the tolerance tight enough?)
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

# The residuals of the MAP fit, normalized by the errors: lag-1 autocorrelation (0 for white residuals) and the runs-test
# z (0 for white) with the reduced χ², on the fitted grid and, for a binned fit, on the measured grid (the grid CRYSOL
# and FoXS evaluate). Nothing is sampled: the MAP search of the fit is enough.
function residual_report(out, seed; label)
    Fit = BAYSOL.Fitting
    sp = Fit._sampling_space(seed, Fit.PROFILE())
    ξ = Fit.Ξ(sp.μ .+ sp.σ .* sp.ẑ, seed.pr)
    ŷ, wfit, _ = Fit.profiled_corrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
    pred = Fit.wls_predict(wfit, ŷ)
    r = (seed.wls.I_obs .- pred) .* sqrt.(seed.wls.weights)
    rs = BAYSOL.Shannon.residual_structure(r)
    println(out, @sprintf("%s: fitted grid   %4d points  lag-1 %+.3f  runs z %+.2f  χ²_red %.4g",
                          label, length(r), rs.lag1, rs.runs_z, sum(abs2, r) / (length(r) - 3)))
    sh = seed.shannon
    if sh !== nothing && sh.rebin > 0
        r_raw = (sh.I_raw .- BAYSOL.Shannon.model_on_raw(sh, pred)) ./ sh.σ_raw
        rr = BAYSOL.Shannon.residual_structure(r_raw)
        println(out, @sprintf("%s: measured grid %4d points  lag-1 %+.3f  runs z %+.2f  χ²_red %.4g",
                              label, length(r_raw), rr.lag1, rr.runs_z, sum(abs2, r_raw) / (length(r_raw) - 3)))
    end
end

function main(args)
    if isempty(args)
        println("usage: julia --project=test/fitting_tests test/utils/diagnose.jl ",
            "--report|--ablate|--residuals|--warmup|--tolerance [--out FILE] [--tols 1e-5,1e-8] [--seeds 1,2,3] [--samples N] [--adapt N] ID[:tag] ...")
        return
    end
    cmd, rest = args[1], args[2:end]
    cmd in ("--report", "--ablate", "--residuals", "--warmup", "--tolerance") ||
        error("unknown part $cmd (--report | --ablate | --residuals | --warmup | --tolerance)")
    cmd = cmd[3:end]
    opts, specs = parse_cli(rest)
    isempty(specs) && error("give at least one ID[:tag]")
    n_samples = parse(Int, get(opts, "samples", string(BAYSOL.Report.DEFAULT_N_SAMPLES))); n_adapt = parse(Int, get(opts, "adapt", string(BAYSOL.Report.DEFAULT_N_ADAPT)))
    tols = Tuple(parse.(Float64, split(get(opts, "tols", "1e-5,1e-8"), ",")))
    rngs = Tuple(parse.(Int, split(get(opts, "seeds", "7"), ",")))
    out = haskey(opts, "out") ? open(opts["out"], "w") : stdout
    try
        for spec in specs
            id, tag = occursin(':', spec) ? String.(split(spec, ":"; limit = 2)) : (spec, "")
            seed, reference, label = load_fit_seed(id, tag; makie = !(cmd in ("residuals", "warmup")))
            if cmd == "report"
                diagnose(out, seed; label, reference, n_samples, n_adapt)
            elseif cmd == "tolerance"
                tolerance_sweep(out, seed; label, tols, rng_seeds = rngs, n_samples, n_adapt)
            elseif cmd == "warmup"
                warmup_study(out, seed; label, rng_seeds = rngs)
            elseif cmd == "residuals"
                residual_report(out, seed; label)
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
