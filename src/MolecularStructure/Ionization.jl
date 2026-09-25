# SPDX-License-Identifier: LGPL-2.1-or-later

# Henderson-Hasselbalch fractional charge (and its delta-method uncertainty
# under a solution-pH uncertainty σ_pH) for ionizable protein groups, driven
# by real per-residue-instance pKa predictions (e.g. from PROPKA) rather than
# a fixed per-residue-type lookup table. This file is pure/offline: it
# consumes already-parsed pKa records as plain data and does no subprocess or
# CondaPkg I/O of its own.

using JSON3: JSON3

# ---------------------------------------------------------------------------
#                    ionizable-group charge topology
# ---------------------------------------------------------------------------

"""
One ionizable chemical group's charge topology: whether it's charged when
protonated ("base") or deprotonated ("acid"), and how its full ±1 charge
splits across its constituent atoms (fractions summing to 1.0).
"""
const _ChargeGroup = NamedTuple{(:type, :atoms), Tuple{String, Dict{String, Float64}}}

""" resname (or PROPKA terminus label "N+"/"C-") => charge topology,
from Grimsley/Scholtz/Pace 2009 (<https://doi.org/10.1002/pro.19>) side-chain pKa
groups plus PROPKA's own N-/C-terminus group-labeling convention. """
const _CHARGE_TOPOLOGY::Dict{String, _ChargeGroup} = JSON3.read(
    read(joinpath(@__DIR__, "charge_topology.json"), String),
    Dict{String, _ChargeGroup}
)

# ---------------------------------------------------------------------------
#                 Henderson-Hasselbalch + delta-method math
# ---------------------------------------------------------------------------

"""
    _fraction_protonated(pH::Real, pKa::Real) -> Real

Henderson-Hasselbalch fraction of a **base** group's titratable atoms that
are protonated (and therefore, for a base, charged) at solution pH:

f = 1 / (1 + 10^(pH - pKa))

f -> 1 for pH ≪ pKa (fully protonated/charged), f -> 0 for pH ≫ pKa,
and f == 0.5 at pH == pKa.
"""
_fraction_protonated(pH::Real, pKa::Real)::Real = 1 / (1 + 10^(pH - pKa))

"""
    _fraction_deprotonated(pH::Real, pKa::Real) -> Real

Henderson-Hasselbalch fraction of an **acid** group's titratable atoms that
are deprotonated (and therefore, for an acid, charged) at solution pH:

f = 1 / (1 + 10^(pKa - pH))

f -> 0 for pH ≪ pKa (fully protonated/neutral), f -> 1 for pH ≫ pKa,
and f == 0.5 at pH == pKa. Note this is exactly [`_fraction_protonated`](@ref)
with pH and pKa swapped, i.e. 1 - _fraction_protonated(pH, pKa).
"""
_fraction_deprotonated(pH::Real, pKa::Real)::Real = 1 / (1 + 10^(pKa - pH))

"""
    _group_charge(type::AbstractString, pH::Real, pKa::Real) -> Real

Signed fraction of a full ±1 charge carried by an ionizable group of the
given type ("acid" or "base") at solution pH, before splitting across
the group's atoms: +f (protonated fraction) for a base, -f (deprotonated
fraction) for an acid.
"""
function _group_charge(type::AbstractString, pH::Real, pKa::Real)::Real
    if type == "base"
        return _fraction_protonated(pH, pKa)
    elseif type == "acid"
        return -_fraction_deprotonated(pH, pKa)
    else
        throw(ArgumentError("unknown charge-group type $(repr(type)) (expected \"acid\" or \"base\")"))
    end
end

"""
    _σ_group_charge(type::AbstractString, pH::Real, pKa::Real, σ_pH::Real) -> Real

First-order (delta method) propagation of solution-pH uncertainty σ_pH
into the group-charge uncertainty. Writing f(pH) for either
[`_fraction_protonated`](@ref) or [`_fraction_deprotonated`](@ref) (they have
the same functional form up to pH ↔ pKa, d/dpH [1/(1+10^(±(pH-pKa)))] =
∓ln(10)·10^(±(pH-pKa))/(1+10^(±(pH-pKa)))² = ∓ln(10)·f·(1-f)), the delta
method gives:

σ_f = |df/dpH| · σ_pH = ln(10) · f · (1 - f) · σ_pH

which is the same magnitude for acid and base groups (the sign of df/dpH
differs between them, but it cancels once _group_charge's own ± sign is
applied and only the magnitude is propagated as a standard deviation).
"""
function _σ_group_charge(type::AbstractString, pH::Real, pKa::Real, σ_pH::Real)::Real
    f = type == "base"  ? _fraction_protonated(pH, pKa)   :
        type == "acid"  ? _fraction_deprotonated(pH, pKa) :
        throw(ArgumentError("unknown charge-group type $(repr(type)) (expected \"acid\" or \"base\")"))
    return log(10) * f * (1 - f) * σ_pH
end

"""
    _group_protonated(type::AbstractString, pH::Real, pKa::Real) -> Bool

Whether an ionizable group of type carries its exchangeable/titratable
hydrogen atom(s) at solution pH. For a base, protonated ⟺ charged; for an acid, protonated ⟺ neutral.
Both cases reduce to the same rule applied to the group's fraction ([`_fraction_protonated`](@ref)
for a base, [`_fraction_deprotonated`](@ref) for an acid): charged ⟺ fraction > 0.5, and
protonated is charged for a base or !charged for an acid. Therefore, a group sitting exactly
at its own pKa (fraction == 0.5) always rounds to its uncharged state for both types.
"""
function _group_protonated(type::AbstractString, pH::Real, pKa::Real)::Bool
    if type == "base"
        return _fraction_protonated(pH, pKa) > 0.5
    elseif type == "acid"
        return !(_fraction_deprotonated(pH, pKa) > 0.5)
    else
        throw(ArgumentError("unknown charge-group type $(repr(type)) (expected \"acid\" or \"base\")"))
    end
end

"""
    _atom_charge(split::Real, type::AbstractString, pH::Real, pKa::Real) -> Real

A single atom's signed charge contribution: its split fraction of the
group's [`_group_charge`](@ref).
"""
_atom_charge(split::Real, type::AbstractString, pH::Real, pKa::Real)::Real =
    split * _group_charge(type, pH, pKa)

"""
    _σ_atom_charge(split::Real, type::AbstractString, pH::Real, pKa::Real, σ_pH::Real) -> Real

A single atom's charge-uncertainty contribution: its split fraction of the
group's [`_σ_group_charge`](@ref).
"""
_σ_atom_charge(split::Real, type::AbstractString, pH::Real, pKa::Real, σ_pH::Real)::Real =
    split * _σ_group_charge(type, pH, pKa, σ_pH)

# ---------------------------------------------------------------------------
#                          pKa record matching
# ---------------------------------------------------------------------------

"""
    _matching_atoms(residues, rec) -> Vector{Tuple{Int,Float64}}

Every atom index in residues that belongs to the residue instance named by
a single pKa record rec (with resname, resnum, chain fields), paired
with its topology split fraction. Empty if rec's group isn't in
[`_CHARGE_TOPOLOGY`](@ref), or no atom in residues matches.

For an ordinary side-chain group (anything other than "N+"/"C-"), a
match requires (resname, resnum, chain) equality with rec, and only atoms
named in the topology's atoms map are collected.

For a terminus group (resname literally "N+" or "C-", PROPKA's group-labeling convention), 
the residue's own resname is never "N+"/"C-". A terminus record is matched by (resnum, chain), 
looking only for the specific backbone atom(s) the topology names for
that terminus ("N" for N+; "O"/"OXT" for C-), regardless of what
residues.resname says at that position.
"""
function _matching_atoms(residues, rec)::Vector{Tuple{Int,Float64}}
    group = get(_CHARGE_TOPOLOGY, String(rec.resname), nothing)
    group === nothing && return Tuple{Int,Float64}[]

    is_terminus = rec.resname == "N+" || rec.resname == "C-"
    n = length(residues.resname)
    out = Tuple{Int,Float64}[]
    @inbounds for i in 1:n
        residues.resnum[i] == rec.resnum && residues.chain[i] == rec.chain || continue
        is_terminus || residues.resname[i] == rec.resname || continue
        split = get(group.atoms, residues.atomname[i], nothing)
        split === nothing && continue
        push!(out, (i, split))
    end
    return out
end

# ---------------------------------------------------------------------------
#                            Ionization
# ---------------------------------------------------------------------------

"""
Per-atom ionization state of a protein Molecule, derived from real
per-residue-instance pKa predictions via Henderson-Hasselbalch,
with σ_pH propagated into σ_charge by the delta method.
"""
struct Ionization
    charge     :: Vector{Float64}
    σ_charge   :: Vector{Float64}
    protonated :: Vector{Bool}
end

"""
    Ionization(residues::Residues, pKa_records, pH::Real, σ_pH::Real) -> Ionization

Build a dense, per-atom [`Ionization`](@ref) for residues from a collection
of already-parsed pKa records .

Each record is matched to its topology-table atoms via [`_matching_atoms`](@ref)
(handling the "N+"/"C-" terminus special case), and every matched atom
gets [`_atom_charge`](@ref)/[`_σ_atom_charge`](@ref)/[`_group_protonated`](@ref)
applied. An atom with no matching record (or a record with no entry in the
charge topology) is left at charge = σ_charge = 0.0, protonated = false.
A pKa record that matches no atom in residues is silently skipped.
"""
function Ionization(residues::Residues, pKa_records, pH::Real, σ_pH::Real)::Ionization
    n = length(residues.resname)
    charge     = zeros(Float64, n)
    σ_charge   = zeros(Float64, n)
    protonated = falses(n)

    for rec in pKa_records
        group = get(_CHARGE_TOPOLOGY, String(rec.resname), nothing)
        group === nothing && continue
        type = group.type
        is_protonated = _group_protonated(type, pH, rec.pKa)
        for (i, split) in _matching_atoms(residues, rec)
            charge[i]     = _atom_charge(split, type, pH, rec.pKa)
            σ_charge[i]   = _σ_atom_charge(split, type, pH, rec.pKa, σ_pH)
            protonated[i] = is_protonated
        end
    end

    return Ionization(charge, σ_charge, protonated)
end
