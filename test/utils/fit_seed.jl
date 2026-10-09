# SPDX-License-Identifier: LGPL-2.1-or-later

# The `Seed` of a fitting test, built without fitting it. Included by the developer tools in this
# directory (`diagnose.jl`, `child.jl`); not part of the package and not needed to use BAYSOL.
#
# Every script in test/fitting_tests/<ID>/ has a `seed_<id>(...)` function that builds the `Seed` its
# `run_<id>(...)` then samples. That split exists only for these tools; a user reading a script as an
# example can skip `seed_<id>`. The scripts also run their fit at top level, so `load_fit_seed` reads
# a script only up to its first top-level run statement and evaluates that part in a fresh module,
# which defines the functions and constants without running anything.

# Scripts whose `seed_*` entry point is not `seed_<id>(run)` (RUNS) or `seed_<id>()` (single run):
# id => (module, tag) -> Seed. SASDMZ9 builds three models from one function; SASDJ72 takes a model Symbol.
const SEED_ENTRY_OVERRIDES = Dict{String,Function}(
    "SASDMZ9" => (mod, tag) -> Core.eval(mod, :(seed_sasdmz9_model(
        joinpath(_FIXTURE_DIR, $("SASDMZ9_fit1_$(tag).pdb"))))),
    "SASDJ72" => (mod, tag) -> Core.eval(mod, :(seed_sasdj72($(QuoteNode(Symbol(tag)))))),
)

"""
    load_fit_seed(id, tag = ""; seed_options = (;), makie = true) -> (seed, reference, label)

The `Seed` that `test/fitting_tests/<id>/<id>.jl` builds for run `tag`, plus the depositor's reference
curve for it (`nothing` if the script has none) as the `reference` argument of `SeedDiagnostics.diagnose`.

# Keywords
- `makie = true`: set `false` to skip the script's `using GLMakie` (the figure functions then can't be called);
    the benchmark driver uses this to stay in the package's own environment.
- `seed_options = (;)`: keywords added to the script's `BAYSOL.seed_model` call, e.g. `(; rebin = 8)` or
    `(; rebin = nothing)` to try another binning without editing the script.

# Returns
- `(seed::Inference.Seed, reference, label::String)`.

# Exceptions
- `ErrorException` if the script has no recognizable entry point, `tag` names no run, or the folder is missing.
"""
function load_fit_seed(id::AbstractString, tag::AbstractString = ""; seed_options::NamedTuple = (;), makie::Bool = true)
    fit_dir = joinpath(@__DIR__, "..", "fitting_tests")
    dir = joinpath(fit_dir, id)
    isdir(dir) || error("no fitting test folder $dir")
    scripts = filter(f -> endswith(f, ".jl"), readdir(dir))
    script = (id * ".jl") in scripts ? id * ".jl" : length(scripts) == 1 ? only(scripts) :
        error("$dir: expected $id.jl or a single script, found $scripts")
    path = joinpath(dir, script)
    src = read(path, String)

    # stop before the first top-level statement that runs a fit: a loop over the runs or models, or an
    # assignment from a `run_*(` call (`result, ... = run_x()`), or a bare `result1, ... =` whose call is on
    # the next line
    m = match(r"^(for (?:run|model) in (?:RUNS|\()|result\d*,|[^\s#][^\n]*=\s*run_\w+\()"m, src)
    m === nothing && error("$path: found no top-level run statement to stop before")
    src = src[1:m.offset-1]
    makie || (src = replace(src, r"^using GLMakie[^\n]*\n"m => ""))   # plotting is not needed to build a seed

    # the script's `BAYSOL.seed_model(...)` call gets `seed_options` appended (a no-op when there are none)
    src = replace(src, "BAYSOL.seed_model(" => "_seed_model(")
    mod = Module(Symbol("Fit_", id))
    Core.eval(mod, :(include(p::AbstractString) = Base.include($mod, p)))
    Core.eval(mod, :(_seed_model(args...; kw...) = BAYSOL.seed_model(args...; kw..., $seed_options...)))
    Base.include_string(mod, src, path)

    runs = isdefined(mod, :RUNS) ? Core.eval(mod, :RUNS) : nothing
    entry = Symbol("seed_", lowercase(splitext(script)[1]))   # SASDBS6.jl -> seed_sasdbs6, SASDA52_fit1.jl -> seed_sasda52_fit1
    built = if haskey(SEED_ENTRY_OVERRIDES, id)
        SEED_ENTRY_OVERRIDES[id](mod, tag)
    elseif runs !== nothing
        run = only(filter(r -> r.tag == tag, runs))
        Base.invokelatest(Core.eval(mod, entry), run)
    elseif isdefined(mod, entry)
        Base.invokelatest(Core.eval(mod, entry))
    else
        error("$path: no `$entry` entry point; add a SEED_ENTRY_OVERRIDES method for $id")
    end
    seed = built[1]   # every seed_* returns (seed, (q_fit, I_fit, σ_fit))

    reference = nothing
    fit_file, scale, col = if runs !== nothing
        r = only(filter(r -> r.tag == tag, runs)); (r.fit, r.fit_scale, r.fit_col)
    else
        ("$(id)_fit1.fit", 1.0, 4)   # CRYSOL .fit layout: q, I_exp, σ, I_fit
    end
    fit_path = joinpath(fit_dir, "..", "fixtures", "experiments", id, fit_file)
    if id != "SASDMZ9" && isfile(fit_path) && isdefined(mod, :fit_subset)
        fc = Base.invokelatest(Core.eval(mod, :_read_fit), fit_path, scale, col)
        q, I, σ = Base.invokelatest(Core.eval(mod, :fit_subset))
        fc === nothing || (reference = (; q, I, σ, q_ref = fc[1], I_ref = fc[2]))
    end
    return seed, reference, isempty(tag) ? id : "$id:$tag"
end
