# SPDX-License-Identifier: LGPL-3.0-or-later

# The buffer of a project: `buffer.json`, which the terminal interface writes
# (concentrations in mM as typed). `load_buffer` reads it into the `Vector{Solute}` that
# `seed_model` takes (mol/L). The schema is the one of test/fixtures/buffer/buffer.json,
# which the interface's tests and buffer.test.jl share. Only the shape of the file is
# checked here (a key that is missing or of the wrong type, a concentration not above 0,
# a list of the wrong length); the ranges of the numbers (electrons above 0, a finite
# volume, a chain of at least 2 units) are what `ρₑ` refuses, and it is left to. A
# missing file is an error: a run on pure water by accident is worse than a stop.
# Part of the module `BAYSOLRun` (`run-project.jl`). The file also
# holds the pH of the buffer and its standard uncertainty, `"pH"` and `"sigma-pH"` next to
# `solutes` (the interface shows the second one as σ): both or neither, `load_buffer_ph`
# reads them (and insists they are there, since a run needs them).

using BAYSOL.BulkElectronDensity: NonBiological, Polymer, Protein, DNA, RNA, CustomNonBio,
    CustomPolymer, CUSTOM_POLYMER_MAX_UNITS

"""
The error [`load_buffer`](@ref) throws when `buffer.json` is missing, cannot be read or
holds an invalid row; `problems` has a line for each. Part of `BAYSOLRun`.

# Exceptions
This type is the exception; the fit that asked for the buffer must not go on.
"""
struct InvalidBufferError <: Exception
    problems::Vector{String}
end

function Base.showerror(io::IO, e::InvalidBufferError)
    n = length(e.problems)
    println(io, "InvalidBufferError: the buffer is not valid (", n, " problem",
        n == 1 ? "" : "s", "); nothing was started:")
    for p in e.problems
        println(io, "  - ", p)
    end
    print(io, "Fix the buffer in the BAYSOL terminal interface.")
end

# The limits of the pH and of its uncertainty. They are the numbers of
# tui/assets/data/buffer_conditions.json, which the interface checks what is typed
# against (buffer.test.jl compares the two). Guardrails of the file, not settings.
const BUFFER_PH_MIN = 0.0
const BUFFER_PH_MAX = 14.0
const BUFFER_SIGMA_PH_MIN = 0.0
const BUFFER_SIGMA_PH_MAX = 14.0
# The optional temperature of the buffer (°C), `"temperature"` next to the pH.
const BUFFER_TEMPERATURE_MIN = 0.0
const BUFFER_TEMPERATURE_MAX = 100.0

const _CUSTOM_NONBIO = "custom-nonbio"
const _CUSTOM_POLYMER = "custom-polymer"

# What a key may hold. A `Bool` is not a number here (it is one in Julia).
_isnum(x) = x isa Real && !(x isa Bool)
_isint(x) = x isa Integer && !(x isa Bool)
_isname(x) = x isa AbstractString && !isempty(strip(x))
_isnumvec(x) = x isa AbstractVector && all(_isnum, x)

# `row[key]` if it passes `ok`, else a problem is recorded and `nothing` returned.
function _field(row, key::Symbol, ok, what::AbstractString, where_, problems)
    if !haskey(row, key)
        push!(problems, "$where_: `$key` is missing (expected $what)")
        return nothing
    end
    v = row[key]
    ok(v) || push!(problems, "$where_: `$key` is $(repr(v)), expected $what")
    return ok(v) ? Some(v) : nothing
end

# The value of an optional key (`null` or a number): `Some(nothing)`, `Some(x)` or nothing.
function _optional(row, key::Symbol, where_, problems)
    ok(x) = x === nothing || _isnum(x)
    return _field(row, key, ok, "a number or null", where_, problems)
end

# The concentration and uncertainty of a row, in mol/L; `nothing` when invalid.
function _concentration(row, where_, problems)
    m = _field(row, :mM, _isnum, "a number of mM", where_, problems)
    s = _field(row, Symbol("sigma-mM"), _isnum, "a number of mM", where_, problems)
    ok = true
    if m !== nothing && !(something(m) > 0)
        push!(problems, "$where_: `mM` is $(something(m)), it must be above 0")
        ok = false
    end
    if s !== nothing && something(s) < 0
        push!(problems, "$where_: `sigma-mM` is $(something(s)), it must not be negative")
        ok = false
    end
    (m === nothing || s === nothing || !ok) && return nothing
    return (Float64(something(m)) / 1000, Float64(something(s)) / 1000)
end

function _custom_unit(u, where_, problems)
    if !(u isa AbstractDict)
        push!(problems, "$where_: is not an object")
        return nothing
    end
    z = _field(u, :z, x -> _isint(x), "an integer", where_, problems)
    slope = _field(u, :slope, _isnum, "a number", where_, problems)
    σ = _optional(u, :sigma, where_, problems)
    (z === nothing || slope === nothing || σ === nothing) && return nothing
    s = something(σ)
    return (Int(something(z)), Float64(something(slope)),
        s === nothing ? nothing : Float64(s))
end

# The solute of one row, or `nothing` with the problems recorded.
function _solute(row, i::Int, problems)
    where_ = "solute $i"
    if !(row isa AbstractDict)
        push!(problems, "$where_: is not an object")
        return nothing
    end
    kind = get(row, :kind, nothing)
    if kind isa AbstractString
        where_ = "solute $i ($kind)"
    end
    custom = kind in (_CUSTOM_NONBIO, _CUSTOM_POLYMER)
    if !(kind in ("nonbiological", "polymer", "dna", "rna", "protein") || custom)
        push!(problems, "$where_: unknown `kind` $(repr(kind))")
        return nothing
    end
    np = length(problems)
    conc = _concentration(row, where_, problems)
    if !custom
        a = _field(row, :arg, _isname, "a non-empty string", where_, problems)
        (a === nothing || conc === nothing || length(problems) > np) && return nothing
        T = Dict("nonbiological" => NonBiological, "polymer" => Polymer, "dna" => DNA,
            "rna" => RNA, "protein" => Protein)[kind]
        return T(conc[1], conc[2], String(something(a)))
    end
    name = _field(row, :custom, _isname, "a non-empty string", where_, problems)
    if kind == _CUSTOM_NONBIO
        z = _field(row, :z, _isint, "an integer", where_, problems)
        v = _field(row, :pmv, _isnum, "a number", where_, problems)
        σ = _optional(row, Symbol("sigma-pmv"), where_, problems)
        (conc === nothing || name === nothing || length(problems) > np) && return nothing
        s = something(σ)
        return CustomNonBio(conc[1], conc[2], String(something(name)), Int(something(z)),
            Float64(something(v)), s === nothing ? nothing : Float64(s))
    end
    units = _field(row, :units, x -> x isa AbstractVector, "a list of units", where_,
        problems)
    counts = _field(row, :counts, _isnumvec, "a list of numbers", where_, problems)
    ze = _field(row, Symbol("z-ends"), _isint, "an integer", where_, problems)
    v0 = _field(row, Symbol("pmv-ends"), _isnum, "a number", where_, problems)
    σe = _optional(row, Symbol("sigma-ends"), where_, problems)
    parsed = nothing
    if units !== nothing
        us = something(units)
        if !(1 <= length(us) <= CUSTOM_POLYMER_MAX_UNITS)
            push!(
                problems,
                "$where_: `units` has $(length(us)) entries, " *
                "expected 1 to $CUSTOM_POLYMER_MAX_UNITS",
            )
        else
            parsed = [
                _custom_unit(u, "$where_ unit $k", problems) for (k, u) in enumerate(us)
            ]
            if counts !== nothing && length(something(counts)) != length(us)
                push!(
                    problems,
                    "$where_: `counts` has $(length(something(counts))) " *
                    "entries but there are $(length(us)) units",
                )
            end
        end
    end
    (conc === nothing || name === nothing || length(problems) > np || parsed === nothing) &&
        return nothing
    s = something(σe)
    return CustomPolymer(conc[1], conc[2], String(something(name)),
        Float64[x for x in something(counts)], Int[u[1] for u in parsed],
        Float64[u[2] for u in parsed],
        Union{Nothing,Float64}[u[3] for u in parsed],
        Int(something(ze)), Float64(something(v0)), s === nothing ? nothing : Float64(s))
end

# The pH and σ_pH of a buffer object (`nothing` when the file has neither); the problems
# are recorded when only one is there or a value is not a number within its limits.
function _conditions(content, problems)
    # the temperature is optional and not needed here (a run takes it as an argument);
    # a bad one still makes the buffer invalid, as it does for the interface
    haskey(content, :temperature) && _field(content, :temperature,
        x -> _isnum(x) && BUFFER_TEMPERATURE_MIN <= x <= BUFFER_TEMPERATURE_MAX,
        "a number from $(BUFFER_TEMPERATURE_MIN) to $(BUFFER_TEMPERATURE_MAX)",
        "buffer", problems)
    has_ph = haskey(content, :pH)
    has_σ = haskey(content, Symbol("sigma-pH"))
    (has_ph || has_σ) || return nothing
    ph = _field(content, :pH, x -> _isnum(x) && BUFFER_PH_MIN <= x <= BUFFER_PH_MAX,
        "a number from $(BUFFER_PH_MIN) to $(BUFFER_PH_MAX)", "buffer", problems)
    σ = _field(content, Symbol("sigma-pH"),
        x -> _isnum(x) && BUFFER_SIGMA_PH_MIN <= x <= BUFFER_SIGMA_PH_MAX,
        "a number from $(BUFFER_SIGMA_PH_MIN) to $(BUFFER_SIGMA_PH_MAX)", "buffer",
        problems)
    (ph === nothing || σ === nothing) && return nothing
    return (pH = Float64(something(ph)), σ_pH = Float64(something(σ)))
end

# The parsed object of the buffer file `path`, or `nothing` with the problems recorded.
function _buffer_object(path, problems)
    if !isfile(path)
        push!(problems, "$path does not exist: BAYSOL does not guess a missing buffer")
        return nothing
    end
    content = try
        _read_json(read(path, String))
    catch e
        e isa InterruptException && rethrow()
        push!(
            problems,
            "$path cannot be read: " * (e isa ArgumentError ? e.msg : sprint(showerror, e)),
        )
        return nothing
    end
    if !(content isa AbstractDict) || !(get(content, :solutes, nothing) isa AbstractVector)
        push!(problems, "$path must hold an object with a `solutes` array")
        return nothing
    end
    return content
end

# The key two rows share when they are the same solute: the kind and the lower-cased name
# the terminal interface resolved (`arg`, or `custom` for a custom entry). A backstop: the
# interface refuses such a row itself, this catches a file written by hand.
function _same_solute_key(row)
    row isa AbstractDict || return nothing
    name = get(row, :arg, get(row, :custom, nothing))
    _isname(name) || return nothing
    return (get(row, :kind, nothing), lowercase(strip(name)))
end

# Warns of every problem and throws the error when there is one.
function _raise(problems)
    for p in problems
        @warn "invalid buffer: $p"
    end
    isempty(problems) || throw(InvalidBufferError(problems))
    return nothing
end

"""
    load_buffer(path) -> Vector{Solute}

The solutes of the buffer file `path` (a project's `buffer.json`), in file order, ready for
[`seed_model`](@ref): the concentrations and their uncertainties are in mM in the file and
come back in mol/L. A `"nonbiological"`, `"polymer"`, `"dna"`, `"rna"` or `"protein"` row
gives the solute of that name from its `arg`; a `"custom-nonbio"` or `"custom-polymer"`
row gives a `CustomNonBio` or `CustomPolymer` from its snapshot of the custom entry. The
ranges of the numbers are not checked here (`ρₑ` refuses an impossible one). A file
without solutes is accepted with a warning (pure water). The pH and `sigma-pH` of the file
are checked too when they are there (both or neither, numbers within the limits) but not
required: [`load_buffer_ph`](@ref) reads them.

# Returns
- A `Vector{Solute}`.

# Exceptions
- `InvalidBufferError` if the file is missing (BAYSOL does not guess a buffer), cannot be
  read, is not an object with a `solutes` array, or holds an invalid row (not an object, an
  unknown `kind`, a missing or mistyped key, `mM` not above 0, a negative or missing
  `sigma-mM`, an empty name, 1 to 4 `units` not respected, `counts` of another
  length), a solute that is there twice (`row 3: duplicate of row 1`), or a pH without
  `sigma-pH` (or the reverse) or out of its limits. A warning is printed for each
  problem first; row numbers start at 1.
"""
function load_buffer(path::AbstractString)
    problems = String[]
    solutes = Solute[]
    content = _buffer_object(path, problems)
    if content !== nothing
        first_row = Dict{Any,Int}()
        for (i, row) in enumerate(content[:solutes])
            s = _solute(row, i, problems)
            s === nothing || push!(solutes, s)
            key = _same_solute_key(row)
            key === nothing && continue
            if haskey(first_row, key)
                push!(problems, "row $i: duplicate of row $(first_row[key])")
            else
                first_row[key] = i
            end
        end
        _conditions(content, problems)
    end
    _raise(problems)
    isempty(solutes) && @warn "the buffer has no solutes: pure water"
    return solutes
end

"""
    load_buffer_ph(path) -> NamedTuple

The pH of the buffer file `path` and the standard uncertainty of it, `(pH, σ_pH)`, the
`"pH"` and `"sigma-pH"` the terminal interface keeps next to the solutes (it shows the
second as σ). They are the `pH` and `σ_pH` of [`seed_model`](@ref). The solute rows are
not read; [`load_buffer`](@ref) does that.

# Returns
- `(pH = ..., σ_pH = ...)`, both `Float64`.

# Exceptions
- `InvalidBufferError` if the file is missing, cannot be read, is not an object with a
  `solutes` array, has no pH (a run needs one), has only one of the two keys, or a value
  that is not a number within its limits (pH from $(BUFFER_PH_MIN) to $(BUFFER_PH_MAX),
  `sigma-pH` from $(BUFFER_SIGMA_PH_MIN) to $(BUFFER_SIGMA_PH_MAX)), or a `temperature`
  that is not a number from $(BUFFER_TEMPERATURE_MIN) to $(BUFFER_TEMPERATURE_MAX) °C
  (it is optional and not returned: the run takes it as an argument). A warning is
  printed for each problem first.
"""
function load_buffer_ph(path::AbstractString)
    problems = String[]
    content = _buffer_object(path, problems)
    conditions = nothing
    if content !== nothing
        conditions = _conditions(content, problems)
        if isempty(problems) && conditions === nothing
            push!(
                problems,
                "$path has no `pH` and `sigma-pH`: set the pH of the buffer " *
                "in the BAYSOL terminal interface",
            )
        end
    end
    _raise(problems)
    return conditions
end
