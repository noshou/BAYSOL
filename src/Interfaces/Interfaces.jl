# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Swappable-backend interfaces. Declares the backend markers (`RadiiSource`,
`FormFactorSource`, `PartialMolarVolumeSource`) and their generic functions
then encapsulates them as child submodules:

    -   `AtomicRadii` — atomic/ionic radii from a bundled SQLite file
        (`AtomicRadiiSource <: RadiiSource`, extends [`lookup`](@ref)).

    -   `FormFactor` — X-ray form factors from Waasmaier-Kirfel and Chantler tables
        (`FormFactorSourceTables <: FormFactorSource`, extends
        [`form_factor_table`](@ref) / [`form_factors`](@ref) /
        [`form_factor_log`](@ref)).

    -   `PartialMolarVolumes` — protein/solute partial molar volumes and bulk
        solvent electron density from bundled JSON tables
        (`PMVSrcTables <: PartialMolarVolumeSource`, extends
        [`ϕ°`](@ref) / [`ρₑ_w`](@ref)).
"""
module Interfaces

export  RadiiSource, FormFactorSource, PartialMolarVolumeSource,
        AtomicRadiiSource, FormFactorSourceTables, PMVSrcTables,
        FormFactorError, lookup, form_factor_table, form_factors, form_factor_log,
        ϕ°, ρₑ_w

#----------------------------------------------------------
#                        RadiiSource
#----------------------------------------------------------

"A source of atomic/ionic radii. Implement [`lookup`](@ref) for a concrete subtype."
abstract type RadiiSource end

"""
    lookup(src::RadiiSource, ions) -> Vector{Tuple{String,Union{Float64,Nothing}}}

Resolve each ion/element string to a radius in Å, or `nothing` if unknown. One
entry per input, in input order.

# Arguments
- `src`: the radii backend to query.
- `ions`: ion/element strings, e.g. `["fe3+", "o2-", "fe"]`.
"""
function lookup end

#----------------------------------------------------------
#                       FormFactorSource
#----------------------------------------------------------

"A form-factor backend. See `FormFactor` for the reference implementation."
abstract type FormFactorSource end

"""
    form_factor_table([src::FormFactorSource,] energy::Real, ions, qvals) -> FF

Build a form-factor container for `ions` at one `energy` over the `qvals` grid.

# Arguments
- `src`: the form-factor backend to query (optional).
- `energy`: photon energy in eV.
- `ions`: vector of ion strings.
- `qvals`: vector of q values in Å⁻¹.
"""
function form_factor_table end

"""
    form_factors(t, ions, qvals) -> Matrix{ComplexF64}

Per-ion form-factor rows from a container `t` previously built by
[`form_factor_table`](@ref), as a `(length(ions), length(qvals))` matrix: row
`i` is the row for `ions[i]`, columns aligned to `qvals` in input order. Pass
the per-atom ion vector and the result is exactly the `f_atoms` matrix
[`compute_B_lm`](@ref) takes — no mapping step in between.

The queried `qvals` must be grid points of `t`, and every `ions[i]` must be
present in `t`; either violation throws [`FormFactorError`](@ref).

# Arguments
    - `t`: form-factor container from [`form_factor_table`](@ref).
    - `ions`: ion strings to fetch, one per output row.
    - `qvals`: vector of q values; each must match a grid point of `t` exactly.
"""
function form_factors end

"""
    form_factor_log(t) -> Vector{String}

Construction-time diagnostics for the container `t` built by
[`form_factor_table`](@ref) — one line per ion the backend could not resolve
in full, in the order they were encountered.

# Arguments
- `t`: form-factor container from [`form_factor_table`](@ref).
"""
function form_factor_log end

#----------------------------------------------------------
#                   PartialMolarVolumeSource
#----------------------------------------------------------

"A partial-molar-volume backend. See `PartialMolarVolumes` for the reference implementation."
abstract type PartialMolarVolumeSource end

"""
    ρₑ_w([src::PartialMolarVolumeSource,] t::Real) -> Tuple{Float64,Float64}

Bulk electron density of pure water at temperature `t` (°C), in e·Å⁻³, as
`(ρₑ, uncertainty)`.

# Arguments
- `src`: the partial-molar-volume backend to query (optional).
- `t`: temperature in °C.
"""
function ρₑ_w end

"""
    ϕ°([src::PartialMolarVolumeSource,] pH::Real, seq::AbstractString; σ_pH::Real = 0.0)                  -> Tuple{Int64,Float64,Float64}
    ϕ°([src::PartialMolarVolumeSource,] isDNA::Bool, pH::Real, seq::AbstractString; σ_pH::Real = 0.0)     -> Tuple{Int64,Float64,Float64}
    ϕ°([src::PartialMolarVolumeSource,] name::AbstractString)                                             -> Tuple{Int64,Float64,Float64}

Partial molar volume at infinite dilution, as `(electron_count, v0_cm3_per_mol, uncertainty_cm3_per_mol)`,
for a protein/peptide sequence (one-letter codes) at solution `pH`, for a DNA/RNA sequence
(one-letter or IUPAC ambiguity codes) at solution `pH`, or for a solute by IUPAC `name`.
The extra leading `isDNA::Bool` on the nucleotide form is what disambiguates it from the
protein form by arity — amino-acid and nucleotide one-letter codes collide (e.g. `"A"` is
both alanine and adenine), so the two forms cannot be told apart by `seq` alone.

# Arguments
- `src`: the partial-molar-volume backend to query (optional).
- `pH`/`seq`: solution pH and one-letter-code sequence, for a protein or nucleotide.
- `isDNA`: `true` for a DNA sequence, `false` for RNA — nucleotide form only; selects
    both the `A/T/G/C` vs `A/U/G/C` alphabet and which backend table gets queried.
- `σ_pH`: standard uncertainty on `pH`, propagated into the returned uncertainty
    via the delta method (protein/nucleotide forms only; ignored for the solute-by-name form).
- `name`: common or IUPAC solute name, for a non-protein, non-nucleotide solute.
"""
function ϕ° end

#----------------------------------------------------------
#                     Backend submodules
#----------------------------------------------------------

include("AtomicRadii/AtomicRadii.jl")
include("FormFactor/FormFactor.jl")
include("PartialMolarVolumes/PMV.jl")

using .AtomicRadii: AtomicRadii, AtomicRadiiSource
using .FormFactor: FormFactor, FormFactorSourceTables, FormFactorError
using .PartialMolarVolumes: PartialMolarVolumes, PMVSrcTables

end # module
