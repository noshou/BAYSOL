# SPDX-License-Identifier: LGPL-2.1-or-later

# Sampler diagnostics on any SASBDB fitting test, without rerunning its fit or report:
#
#   julia --project=test/fitting_tests test/fitting_tests/diagnose.jl <command> [options] ID[:tag] ...
#
# Commands (the work is done by test/fixtures/functions/seed_diagnostics.jl):
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
# (fit2_model3); scripts with a single run take no tag. SASDMZ9 takes model1|model2|model3. A folder's
# script is `<ID>.jl`, or its only .jl file (SASDA52/SASDA52_fit1.jl).
#
# How the Seed is obtained: each fitting script is read up to its first top-level run statement, so
# nothing is fitted, and its `BAYSOL.run_model(...)` call is replaced by a capture of the `Seed` it
# builds. The seed is therefore exactly what that script would sample (buffer, pH, temperature, lMax, q range).

using Printf
using BAYSOL
include(joinpath(@__DIR__, "..", "fixtures", "functions", "seed_diagnostics.jl"))
using .SeedDiagnostics

struct CapturedSeed <: Exception
    seed::Any
end
capture_seed(s) = throw(CapturedSeed(s))

# Scripts whose entry point is not `run_<id>(run)` / `run_<id>()`: tag => thunk(mod).
const SASDMZ9_LMAX = Dict("model1" => 48, "model2" => 35, "model3" => 35)   # the script's LMAX1-3
const ENTRY_OVERRIDES = Dict{String,Function}(
    "SASDMZ9" => (mod, tag) -> Core.eval(mod, :(run_sasdmz9_model(
        joinpath(_FIXTURE_DIR, $("SASDMZ9_fit1_$(tag).pdb")), $(SASDMZ9_LMAX[tag])))),
)

"""
    load_fit_seed(id, tag = "") -> (seed, reference, label)

The `Seed` that `test/fitting_tests/<id>/<id>.jl` builds for run `tag`, plus the depositor's reference
curve for it (`nothing` if the script has none) as the `reference` argument of `SeedDiagnostics.diagnose`.

# Returns
- `(seed::Fitting.Seed, reference, label::String)`.

# Exceptions
- `ErrorException` if the script has no recognizable entry point, `tag` names no run, or it never
    reaches `BAYSOL.run_model`.
"""
function load_fit_seed(id::AbstractString, tag::AbstractString = "")
    dir = joinpath(@__DIR__, id)
    isdir(dir) || error("no fitting test folder $dir")
    scripts = filter(f -> endswith(f, ".jl"), readdir(dir))
    script = (id * ".jl") in scripts ? id * ".jl" : length(scripts) == 1 ? only(scripts) :
        error("$dir: expected $id.jl or a single script, found $scripts")
    path = joinpath(dir, script)
    src = read(path, String)
    # stop before the first top-level statement that runs a fit: `for run in RUNS`, or an assignment from a
    # `run_*(` call (`result, ... = run_x()`), or a bare `result1, ... =` whose call is on the next line
    m = match(r"^(for run in RUNS|result\d*,|[^\s#][^\n]*=\s*run_\w+\()"m, src)
    m === nothing && error("$path: found no top-level run statement to stop before")
    src = replace(src[1:m.offset-1], "BAYSOL.run_model(s, n_samples, n_adapt; l = PROFILE())" => "CAPTURE_SEED(s)")
    mod = Module(Symbol("Fit_", id))
    Core.eval(mod, :(const CAPTURE_SEED = $capture_seed))
    Core.eval(mod, :(include(p::AbstractString) = Base.include($mod, p)))
    Base.include_string(mod, src, path)

    runs = isdefined(mod, :RUNS) ? Core.eval(mod, :RUNS) : nothing
    entry = Symbol("run_", lowercase(splitext(script)[1]))   # SASDBS6.jl -> run_sasdbs6, SASDA52_fit1.jl -> run_sasda52_fit1
    seed = nothing
    try
        if haskey(ENTRY_OVERRIDES, id)
            ENTRY_OVERRIDES[id](mod, tag)
        elseif runs !== nothing
            run = only(filter(r -> r.tag == tag, runs))
            Base.invokelatest(Core.eval(mod, entry), run)
        elseif isdefined(mod, entry)
            Base.invokelatest(Core.eval(mod, entry))
        else
            error("$path: no `$entry` entry point; add an ENTRY_OVERRIDES method for $id")
        end
    catch e
        e isa CapturedSeed ? (seed = e.seed) : rethrow()
    end
    seed === nothing && error("$path: the entry point never reached BAYSOL.run_model")

    reference = nothing
    fit_file, scale, col = if runs !== nothing
        r = only(filter(r -> r.tag == tag, runs)); (r.fit, r.fit_scale, r.fit_col)
    else
        ("$(id)_fit1.fit", 1.0, 4)   # CRYSOL .fit layout: q, I_exp, σ, I_fit
    end
    fit_path = joinpath(@__DIR__, "..", "fixtures", "experiments", id, fit_file)
    if id != "SASDMZ9" && isfile(fit_path) && isdefined(mod, :fit_subset)
        fc = Base.invokelatest(Core.eval(mod, :_read_fit), fit_path, scale, col)
        q, I, σ = Base.invokelatest(Core.eval(mod, :fit_subset))
        fc === nothing || (reference = (; q, I, σ, q_ref = fc[1], I_ref = fc[2]))
    end
    return seed, reference, isempty(tag) ? id : "$id:$tag"
end

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
        println("usage: julia --project=test/fitting_tests test/fitting_tests/diagnose.jl ",
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
