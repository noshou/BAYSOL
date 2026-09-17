# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Per-ionizable-atom net fractional charge at physiological pH, keyed by
protein residue name + atom name, from a bundled JSON table.
"""
module ResidueNetCharge

import ..Interfaces
using  ..Interfaces: ResidueChargeSource
using  JSON3: JSON3

export ResidueNetChargeSourceTables, RESIDUE_NET_CHARGE

"Marker for the bundled-table backend."
struct ResidueNetChargeSourceTables <: ResidueChargeSource end

""" resname => (atomname => charge), from Grimsley/Scholtz/Pace 2009
(DOI `10.1002/pro.19`) folded-protein-average pKa values via
Henderson-Hasselbalch at pH 7.4. """
const RESIDUE_NET_CHARGE::Dict{String,Dict{String,Float64}} = JSON3.read(
    read(joinpath(@__DIR__, "residue_net_charge.json"), String),
    Dict{String,Dict{String,Float64}}
)

"""
    residue_charge(resname::AbstractString, atomname::AbstractString) -> Union{Float64,Nothing}

Net fractional charge of a single ionizable atom, or `nothing` if `resname`
has no entry in [`RESIDUE_NET_CHARGE`](@ref) or `atomname` isn't one of its
tracked ionizable atoms (e.g. a backbone atom, or a residue/atom this table
doesn't track).

# Arguments
- `resname`: protein residue name, e.g. `"ASP"`, `"HIS"`.
- `atomname`: PDB-style atom name within that residue, e.g. `"OD1"`.
"""
function residue_charge(resname::AbstractString, atomname::AbstractString)::Union{Float64,Nothing}
    atoms = get(RESIDUE_NET_CHARGE, String(resname), nothing)
    atoms === nothing && return nothing
    return get(atoms, String(atomname), nothing)
end

#----------------------------------------------------------
#                  Interfaces generics
#----------------------------------------------------------
# residue_charge is the stable API (declared in Interfaces.jl); only the
# backend (`src`, first argument) varies. The `src`-less form below defaults
# it to `ResidueNetChargeSourceTables()`, same convention as `form_factor_table`/`ϕ°`.

"""
    Interfaces.residue_charge(
        [src::ResidueNetChargeSourceTables,]
        resname::AbstractString,
        atomname::AbstractString
    ) -> Union{Float64,Nothing}

Net fractional charge of a single ionizable atom. Thin wrapper over the
local [`residue_charge`](@ref).
"""
Interfaces.residue_charge(
    ::ResidueNetChargeSourceTables,
    resname::AbstractString,
    atomname::AbstractString
)::Union{Float64,Nothing} = residue_charge(resname, atomname)

Interfaces.residue_charge(
    resname::AbstractString,
    atomname::AbstractString
)::Union{Float64,Nothing} = Interfaces.residue_charge(
    ResidueNetChargeSourceTables(), 
    resname, 
    atomname
)

end # module ResidueNetCharge
