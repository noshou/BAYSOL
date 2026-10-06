# SPDX-License-Identifier: LGPL-2.1-or-later

# The two JSON tables below are read into `const`s at precompile time; declare
# them as dependencies so editing them invalidates the precompile cache
# (otherwise stale values/keys keep being served after a table edit).
include_dependency(joinpath(@__DIR__, "NonBiological", "nonbiological.json"))
include_dependency(joinpath(@__DIR__, "NonBiological", "common_to_iupac.json"))

""" iupac name => (electron count, pmv, uncertainty) """
const _solutes::Dict{String, Tuple{Int64, Float64, Union{Float64, Nothing}}} =
    JSON3.read(
    read(joinpath(@__DIR__, "NonBiological", "nonbiological.json"), String),
    Dict{String, Tuple{Int64, Float64, Union{Float64, Nothing}}}
)

""" common name => iupac name """
const COMMON_TO_IUPAC::Dict{String, String} = JSON3.read(
    read(joinpath(@__DIR__, "NonBiological", "common_to_iupac.json"), String),
    Dict{String, String}
)

"Memoized non-biological solute partial molar volume, keyed by iupac name"
const _ϕ°_s_cache = KeyedCache{String, Tuple{Int64, Float64, Float64}}()

"""
Look up a non-protein solute's IUPAC name from its common name via
`COMMON_TO_IUPAC` (case-insensitive). Returns (`iupac_name`, true) on a hit,
with `iupac_name` always lowercase regardless of the case `COMMON_TO_IUPAC`
happens to store its values in, or ("", false) if name has no mapping.
Private: the only caller is `_resolve_solute_name` below.
"""
function _common2iupac(name::AbstractString)::Tuple{String,Bool}
    iupac = get(COMMON_TO_IUPAC, lowercase(String(name)), nothing)
    return iupac === nothing ? ("", false) : (lowercase(iupac), true)
end

"""
name (lowercased) itself if it is already an nonbiological.json key,
else its `COMMON_TO_IUPAC` mapping via [`_common2iupac`](@ref) (already
lowercase), else name lowercased, unchanged otherwise (so ϕ° below
still throws its own ArgumentError rather than a KeyError from here).
`_solutes` is lowercase-keyed, so name is lowercased before every lookup
here regardless of the case the caller passed in. Mirrors AtomicRadii's
fallback-chain style.

# Arguments
- `name`: common or IUPAC solute name.
"""
function _resolve_solute_name(name::AbstractString)::String
    s = lowercase(String(name))
    haskey(_solutes, s) && return s
    iupac, ok = _common2iupac(s)
    return ok ? iupac : s
end

"""
Takes the IUPAC name of a solute and returns (electron count, pmv, uncertainty).
Private: name must already be an exact nonbiological.json key (see
[`ϕ°(::AbstractString)`](@ref), the public entry point, which resolves a
common name to its IUPAC form via [`_resolve_solute_name`](@ref) first).
"""
function _ϕ°_by_iupac_name(name::AbstractString)::Tuple{Int64, Float64, Float64}

    key = String(name)

    return @closure get!(_ϕ°_s_cache, key) do
        res = get(_solutes, name, nothing)

        # name is not mapped, throw error
        if res === nothing
            throw(ArgumentError("unknown solute: $name"))
        else
            # if uncertainty is unknown, assign average uncertainty
            if res[3] === nothing
                i = 0
                s = 0.0
                for k in keys(_solutes)
                    u = _solutes[k][3]
                    if u !== nothing
                        i += 1
                        s += u
                    end
                end
                s /= i
                (res[1], res[2], s)

            else
                (res[1], res[2], res[3])
            end
        end
    end
end

"""
Takes the common or IUPAC name of a solute (resolved via
[`_resolve_solute_name`](@ref), which is case-insensitive) and returns
(electron count, pmv, uncertainty).
"""
ϕ°(name::AbstractString)::Tuple{Int64, Float64, Float64} = _ϕ°_by_iupac_name(_resolve_solute_name(name))
