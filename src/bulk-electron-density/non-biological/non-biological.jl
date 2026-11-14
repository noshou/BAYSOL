# SPDX-License-Identifier: LGPL-3.0-or-later

# Partial molar volumes at infinite dilution, ϕ° (cm³·mol⁻¹, with
# uncertainty), of the non-biological buffer solutes (salts, buffers, sugars,
# detergents, ...): the table `nonbiological.json` (the selection-rule winners
# of `nonbiological.tsv`) and the alias table `nonbio_lookup.json` (alias ->
# official IUPAC name). Internal: only `ρₑ` (calc-density.jl) uses it.

# The two JSON tables are read into `const`s at precompile time; declare
# them as dependencies so editing them invalidates the precompile cache
# (otherwise stale values/keys keep being served after a table edit).
include_dependency(joinpath(@__DIR__, "nonbiological.json"))
include_dependency(joinpath(@__DIR__, "nonbio_lookup.json"))

""" iupac name => (electron count, pmv, uncertainty) """
const _SOLUTES::Dict{String,Tuple{Int64,Float64,Union{Float64,Nothing}}} =
    JSON3.read(
        read(joinpath(@__DIR__, "nonbiological.json"), String),
        Dict{String,Tuple{Int64,Float64,Union{Float64,Nothing}}},
    )

""" common name => iupac name """
const NONBIO_LOOKUP::Dict{String,String} = JSON3.read(
    read(joinpath(@__DIR__, "nonbio_lookup.json"), String),
    Dict{String,String},
)

"Memoized non-biological solute partial molar volume, keyed by iupac name (the table's own
values: `NaN` for a missing uncertainty)"
const _ϕ°_s_cache = KeyedCache{String,Tuple{Int64,Float64,Float64}}()

"""
Look up a non-protein solute's IUPAC name from its common name via
`NONBIO_LOOKUP` (case-insensitive). Returns (`iupac_name`, true) on a hit,
with `iupac_name` always lowercase regardless of the case `NONBIO_LOOKUP`
happens to store its values in, or ("", false) if name has no mapping.
Private: the only caller is `_resolveSoluteName` below.
"""
function _common2target(name::AbstractString)::Tuple{String,Bool}
    iupac = get(NONBIO_LOOKUP, lowercase(String(name)), nothing)
    return iupac === nothing ? ("", false) : (lowercase(iupac), true)
end

"""
name (lowercased) itself if it is already an nonbiological.json key,
else its `NONBIO_LOOKUP` mapping via [`_common2target`](@ref) (already
lowercase), else name lowercased, unchanged otherwise (so ϕ° below
still throws its own ArgumentError rather than a KeyError from here).
`_SOLUTES` is lowercase-keyed, so name is lowercased before every lookup
here regardless of the case the caller passed in. Mirrors AtomicRadii's
fallback-chain style.

# Arguments
- `name`: common or IUPAC solute name.
"""
function _resolveSoluteName(name::AbstractString)::String
    s = lowercase(String(name))
    haskey(_SOLUTES, s) && return s
    iupac, ok = _common2target(s)
    return ok ? iupac : s
end

"""
Takes the IUPAC name of a solute and returns (electron count, pmv, uncertainty).
Private: name must already be an exact nonbiological.json key (see
[`ϕ°(::AbstractString)`](@ref), the public entry point, which resolves a
common name to its IUPAC form via [`_resolveSoluteName`](@ref) first).

The cache holds the table's own triple, `NaN` for an uncertainty the table does not
state; the uncertainty to use in its place, `fallback_σ`, is put in after the lookup. It
must not be in the cache: a value cached under the name alone would be served to every
later call, whatever `fallback_σ` it passed.
"""
function _ϕ°_by_iupac_name(
    name::AbstractString,
    fallback_σ::Real = NONBIO_MEAN_UNCERTAINTY,
)::Tuple{Int64,Float64,Float64}

    key = String(name)

    Z, v0, σ = @closure get!(_ϕ°_s_cache, key) do
        res = get(_SOLUTES, name, nothing)

        # name is not mapped, throw error
        if res === nothing
            throw(ArgumentError("unknown solute: $name"))
        else
            # a row that states no uncertainty is kept as NaN; see above
            (res[1], res[2], res[3] === nothing ? NaN : res[3])
        end
    end

    return (Z, v0, isnan(σ) ? Float64(fallback_σ) : σ)
end

"""
Takes the common or IUPAC name of a solute (resolved via
[`_resolveSoluteName`](@ref), which is case-insensitive) and returns
(electron count, pmv, uncertainty). A row of the table that states no uncertainty gets
`fallback_σ` (cm³·mol⁻¹), by default `NONBIO_MEAN_UNCERTAINTY`.
"""
ϕ°(
    name::AbstractString;
    fallback_σ::Real = NONBIO_MEAN_UNCERTAINTY,
)::Tuple{Int64,Float64,Float64} =
    _ϕ°_by_iupac_name(_resolveSoluteName(name), fallback_σ)
