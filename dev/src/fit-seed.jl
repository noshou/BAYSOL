# SPDX-License-Identifier: LGPL-3.0-or-later

# The `Seed` of a fitting test, built without fitting it. Included
# by the developer tools in this directory (`diagnose.jl`,
# `child.jl`); not part of the package and not needed to use BAYSOL.
#
# Every script in test/fitting_tests/<ID>/ has a `seed<Id>(...)` function that
# builds the `Seed` its `run<Id>(...)` then samples. That split exists only for
# these tools; a user reading a script as an example can skip `seed<Id>`. The
# scripts also run their fit at top level, so `load_fit_seed` reads a script only
# up to its first top-level run statement and evaluates that part in a fresh
# module, which defines the functions and constants without running anything.

# the fixtures, unpacked from their archives on demand (the same code `bysl fixtures` uses)
isdefined(@__MODULE__, :FixtureStore) || include(joinpath(@__DIR__, "fixture-store.jl"))

# Scripts whose `seed*` entry point is not `seed<Id>(run)` (RUNS) or
# `seed<Id>()` (single run): id => (module, tag) -> Seed. No fitting test needs one now
# (SASDMZ9 and SASDJ72, which did, were removed with the ensemble fits).
const SEED_ENTRY_OVERRIDES = Dict{String,Function}()

"""
    load_fit_seed(id, tag = ""; seed_options = (;))
        -> (seed, reference, label)

The `Seed` that `test/fitting_tests/<id>/<id>.jl` builds for run `tag`,
plus the depositor's reference curve for it (`nothing` if the script
has none) as the `reference` argument of `SeedDiagnostics.diagnose`.

# Keywords
- `seed_options = (;)`: keywords added to the script's
    `BAYSOL.seedModel` call, e.g. `(; rebin = 8)` or `(; rebin = nothing)`
    to try another binning without editing the script.

# Returns
- `(seed::Inference.Seed, reference, label::String)`.

# Exceptions
- `ErrorException` if the script has no recognizable entry
    point, `tag` names no run, or the folder is missing.
"""
function load_fit_seed(
    id::AbstractString,
    tag::AbstractString = "";
    seed_options::NamedTuple = (;),
)
    # the scripts read their fixtures through `fixtureDir` (test/fitting_tests/common.jl),
    # which looks in $BAYSOL_FIXTURES: unpack the archive for the duration of the call
    info = load_fit_seed_info(id, tag; seed_options)
    return info.seed, info.reference, info.label
end

"""
    load_fit_seed_info(id, tag = ""; seed_options = (;))
        -> (; seed, reference, label, fitFile, software, fitHeader)

[`load_fit_seed`](@ref) with what else the script says about the depositor's fit:
`fitFile`, the name of its `.fit` file; `software`, the `software` field of the run
(`nothing` for a script without a `RUNS` table or a run without the field); and
`fitHeader`, the first three lines of the `.fit` file (`""` if the file is missing).
A script with a single run in `RUNS` also accepts `tag = ""`.

# Returns
- The named tuple above.

# Exceptions
- As for [`load_fit_seed`](@ref).
"""
function load_fit_seed_info(
    id::AbstractString,
    tag::AbstractString = "";
    seed_options::NamedTuple = (;),
)
    return FixtureStore.with_fixture(id) do _
        _load_fit_seed(id, tag, seed_options, true)
    end
end

"""
    load_fit_header(id, tag = "") -> (; fitFile, software, fitHeader)

The part of [`load_fit_seed_info`](@ref) that needs no structure work: the script's
constants are evaluated but the `Seed` is not built (no hydrogenation). `fitFile`,
`software` and `fitHeader` are as there.

# Returns
- The named tuple above.

# Exceptions
- As for [`load_fit_seed`](@ref).
"""
function load_fit_header(id::AbstractString, tag::AbstractString = "")
    info = FixtureStore.with_fixture(id) do _
        _load_fit_seed(id, tag, (;), false)
    end
    return (; info.fitFile, info.software, info.fitHeader)
end

function _load_fit_seed(
    id::AbstractString,
    tag::AbstractString,
    seed_options::NamedTuple,
    build::Bool,
)
    fit_dir = joinpath(@__DIR__, "..", "..", "test", "fitting_tests")
    dir = joinpath(fit_dir, id)
    isdir(dir) || error("no fitting test folder $dir")
    scripts = filter(f -> endswith(f, ".jl"), readdir(dir))
    script =
        (id * ".jl") in scripts ? id * ".jl" :
        length(scripts) == 1 ? only(scripts) :
        error("$dir: expected $id.jl or a single script, found $scripts")
    path = joinpath(dir, script)
    src = read(path, String)

    # stop before the first top-level statement that runs a fit: a loop over the runs
    # or models, or an assignment from a `run*(` call (`result, ... = runX()`), or
    # a bare `result1, ... =` whose call is on the next line
    m = match(
        r"^(for (?:run|model) in (?:RUNS|\()|result\d*,|[^\s#][^\n]*=\s*run[A-Z]\w*\()"m,
        src,
    )
    m === nothing && error("$path: found no top-level run statement to stop before")
    src = src[1:(m.offset-1)]

    # the script's `BAYSOL.seedModel(...)` call gets
    # `seed_options` appended (a no-op when there are none)
    src = replace(src, "BAYSOL.seedModel(" => "_seed_model(")
    mod = Module(Symbol("Fit_", id))
    Core.eval(mod, :(include(p::AbstractString) = Base.include($mod, p)))
    Core.eval(
        mod,
        :(
            _seed_model(args...; kw...) =
                BAYSOL.seedModel(args...; kw..., $seed_options...)
        ),
    )
    Base.include_string(mod, src, path)

    runs = isdefined(mod, :RUNS) ? Core.eval(mod, :RUNS) : nothing
    # SASDTK5.jl -> seedSasdtk5, SASDA52_fit1.jl -> seedSasda52Fit1
    entry =
        Symbol("seed", join(uppercasefirst.(lowercase.(split(splitext(script)[1], "_")))))
    built =
        !build ? nothing :
        if haskey(SEED_ENTRY_OVERRIDES, id)
            SEED_ENTRY_OVERRIDES[id](mod, tag)
        elseif runs !== nothing
            run = _run_of(runs, tag)
            Base.invokelatest(Core.eval(mod, entry), run)
        elseif isdefined(mod, entry)
            Base.invokelatest(Core.eval(mod, entry))
        else
            error(
                "$path: no `$entry` entry point; add a SEED_ENTRY_OVERRIDES method for $id",
            )
        end
    seed = build ? built[1] : nothing   # every seed* returns (seed, (qFit, I_fit, σ_fit))

    reference = nothing
    software = nothing
    fit_file, scale, col = if runs !== nothing
        r = _run_of(runs, tag)
        software = get(r, :software, nothing)
        (r.fit, r.fitScale, r.fitCol)
    else
        # SASDWJ4_fit2.jl -> SASDWJ4_fit2.fit; a script without a fit suffix is fit1
        stem = splitext(script)[1]
        fit_name = occursin("_fit", stem) ? stem : id * "_fit1"
        ("$fit_name.fit", 1.0, 4)   # CRYSOL .fit layout: q, I_exp, σ, I_fit
    end
    fitPath = joinpath(FixtureStore.resolve(id)[1], fit_file)
    header = isfile(fitPath) ? join(first(readlines(fitPath), 3), "\n") : ""
    if build && isfile(fitPath) && isdefined(mod, :fitSubset)
        fc = Base.invokelatest(Core.eval(mod, :_readFit), fitPath, scale, col)
        q, I, σ = Base.invokelatest(Core.eval(mod, :fitSubset))
        fc === nothing || (reference = (; q, I, σ, qRef = fc[1], iRef = fc[2]))
    end
    label = isempty(tag) ? id : "$id:$tag"
    return (; seed, reference, label, fitFile = fit_file, software, fitHeader = header)
end

# The run of `RUNS` with this tag; the only run when `tag` is empty and there is one.
function _run_of(runs, tag)
    found = filter(r -> r.tag == tag, runs)
    isempty(found) && isempty(tag) && length(runs) == 1 && return only(runs)
    return only(found)
end
