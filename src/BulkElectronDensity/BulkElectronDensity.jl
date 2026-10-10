# SPDX-License-Identifier: LGPL-2.1-or-later

"""
The bulk electron density of the buffer, and nothing else is public: [`ρₑ`](@ref)
takes the buffer's [`Solute`](@ref)s (concentrations with uncertainties), the pH
and the temperature and returns the electron density of the solution and its
propagated standard deviation. Underneath are the partial molar volumes of the
solutes at infinite dilution (V0, cm³/mol; per-class backends for proteins, DNA,
RNA and non-biological solutes) and the density of water, which are internal.
"""
module BulkElectronDensity

using ..PhysicalConstants: STANDARD_TEMPERATURE_C, AVOGADRO, WATER_MOLAR_MASS,
    WATER_DENSITY_UNCERTAINTY,
    WATER_ELECTRONS, ANGSTROM3_PER_LITER, CM3_PER_LITER,
    KELL_DENSITY_NUM, KELL_DENSITY_DEN, BACKBONE_ELECTRONS
using ..Runtime: KeyedCache
using JSON3: JSON3
using FastClosures: @closure

export Solute, Protein, NonBiological, DNA, RNA, DEFAULT_TEMPERATURE_C, ρₑ


"""
Temperature, °C, at which the bundled partial-molar-volume tables are tabulated
(see BulkElectronDensity/README.md: 298.15 K unless a source says otherwise): the
standard reference temperature,
[`STANDARD_TEMPERATURE_C`](@ref BAYSOL.Utils.PhysicalConstants.STANDARD_TEMPERATURE_C).
"""
const PMV_REFERENCE_TEMPERATURE_C = STANDARD_TEMPERATURE_C

"""
Fractional partial-molar-volume expansibility, K⁻¹: an upper bound on
(∂ϕ°/∂T)/ϕ° used to widen a solute's 25 °C ϕ° uncertainty when the sample is at
another temperature

    `σ_T` = `PMV_FRACTIONAL_EXPANSIBILITY` · ϕ°
          · |t − [`PMV_REFERENCE_TEMPERATURE_C`](@ref)|.

Derived from the multi-temperature series bundled with the tables
(15-35 °C: sugars, ureas and glycolurils in `sources/extracted_pmv_candidates.tsv`;
18-40 °C: Chalikian et al. 2001's nucleobases/nucleosides, 10.1016/S0301-4622(01)00200-9,
the `other-T` rows of nonbiological.tsv): across those 42 solutes the fractional
expansibility spans 0.44-2.96 × 10⁻³ K⁻¹ (median 0.82 × 10⁻³), so 3.0 × 10⁻³
covers every one of them. No electrolyte has multi-temperature data in the
tables, so this bound is unverified for salts.
"""
const PMV_FRACTIONAL_EXPANSIBILITY = 3.0e-3

"""
Peptide-bond backbone unit (-CH2CONH-, "glycyl") partial molar volume at 25 °C,
(value, uncertainty) in cm³·mol⁻¹, added once per residue by the protein PMV
backend. Protein.json's per-residue entries (A, V, L, ... and G's zero) are
side-chain-only increments relative to glycine (Lee et al. 2008's own
convention), not absolute residue volumes. Source: Protein.tsv CH2CONH row,
10.1039/9781782627043-00542.
"""
const BACKBONE_PMV = (37.4, 0.1)

"""
Default solution temperature, °C, for [`ρₑ`](@ref)'s bulk electron density calculation. Pass
the sample's real temperature instead whenever it is known: water's density is evaluated at
it exactly, and the solutes' 25 °C partial molar volumes get a widened uncertainty (see
[`PMV_FRACTIONAL_EXPANSIBILITY`](@ref)). Defaults to the standard reference temperature,
[`STANDARD_TEMPERATURE_C`](@ref `BAYSOL.Utils.PhysicalConstants.STANDARD_TEMPERATURE_C`),
the same temperature the PMV tables are given at, so the default never widens their
uncertainty.
"""
const DEFAULT_TEMPERATURE_C = STANDARD_TEMPERATURE_C

# ---------------------------------------------------------------------------
#   Solutes of the buffer
# ---------------------------------------------------------------------------

"""
Solutes of the *buffer*: the solution the macromolecule is dissolved in, i.e.
what the buffer blank that was subtracted from the sample contains.

**Do not list the measured macromolecule itself.** Buffer-subtracted SAXS
measures contrast against the buffer, so the solvent electron density ρₑ is the
buffer's. Other copies of the measured species are separate scatterers (their
correlations show up as a structure factor, not as a uniform background
density), and the volume they displace in the sample cell only changes the
buffer-subtraction baseline, which the flat background correction absorbs. A
`Protein`/`DNA`/`RNA` solute is only correct for a genuine buffer component
that the blank also contained (e.g. a carrier protein).
"""
abstract type Solute end

"A protein buffer component (not the measured species; see [`Solute`](@ref))."
struct Protein <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"A non-biological buffer component (salt, buffering agent, cosolute, ...)."
struct NonBiological <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"A DNA buffer component (not the measured species; see [`Solute`](@ref))."
struct DNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"An RNA buffer component (not the measured species; see [`Solute`](@ref))."
struct RNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

# ---------------------------------------------------------------------------
#   Constants, caches and data tables (used by CalcDensity.jl and PMV.jl)
# ---------------------------------------------------------------------------

"Memoized water electron bulk density"
const _ρₑ_w_cache = KeyedCache{Int64,Tuple{Float64,Float64}}()

"""key => ((pH condition, `ionized_key`), `neutral_key`)"""
const _protein_ionization::Dict{String,Tuple{Tuple{Float64,String},String}} = JSON3.read(
    read(joinpath(@__DIR__, "Protein", "ionization.json"), String),
    Dict{String,Tuple{Tuple{Float64,String},String}},
)

""" key => (`electron_count`, `partial_molar_volume`, uncertainty). `electron_count` is a
side-chain-only increment relative to glycine (see [`BACKBONE_ELECTRONS`](@ref)), and is
identical between a group's "-neutral" and "-acidic"/"-basic" forms since deprotonation
only removes a bare proton (no electron). """
const _Protein::Dict{String,Tuple{Int64,Float64,Float64}} = JSON3.read(
    read(joinpath(@__DIR__, "Protein", "protein.json"), String),
    Dict{String,Tuple{Int64,Float64,Float64}},
)

""" maps ambiguity codes to the two amino acids. Average must be taken. """
const _wildcards = Dict("B" => ("D", "N"), "J" => ("L", "I"), "Z" => ("E", "Q"))

"""
Memoized protein partial molar volume, keyed by
`(sequence, pH, σ_pH)`: the result depends on all three
"""
const _ϕ°_p_cache = KeyedCache{Tuple{String,Float64,Float64},Tuple{Int64,Float64,Float64}}()

# The two JSON tables below are read into `const`s at precompile time; declare
# them as dependencies so editing them invalidates the precompile cache
# (otherwise stale values/keys keep being served after a table edit).
include_dependency(joinpath(@__DIR__, "NonBiological", "nonbiological.json"))
include_dependency(joinpath(@__DIR__, "NonBiological", "common_to_iupac.json"))

""" iupac name => (electron count, pmv, uncertainty) """
const _solutes::Dict{String,Tuple{Int64,Float64,Union{Float64,Nothing}}} =
    JSON3.read(
        read(joinpath(@__DIR__, "NonBiological", "nonbiological.json"), String),
        Dict{String,Tuple{Int64,Float64,Union{Float64,Nothing}}},
    )

""" common name => iupac name """
const COMMON_TO_IUPAC::Dict{String,String} = JSON3.read(
    read(joinpath(@__DIR__, "NonBiological", "common_to_iupac.json"), String),
    Dict{String,String},
)

"Memoized non-biological solute partial molar volume, keyed by iupac name"
const _ϕ°_s_cache = KeyedCache{String,Tuple{Int64,Float64,Float64}}()

""" key => (`electron_count`, V0, uncertainty). Strict Float64 uncertainty
(not Union{Float64,Nothing} like `_solutes`, since no RNA/DNA entry has
a missing uncertainty) — matches `_Protein`'s type, required by `_titrated`. """
const _DNA::Dict{String,Tuple{Int64,Float64,Float64}} =
    JSON3.read(
        read(joinpath(@__DIR__, "DNA", "dna.json"), String),
        Dict{String,Tuple{Int64,Float64,Float64}},
    )

""" key => (`electron_count`, V0, uncertainty). Strict Float64 uncertainty
(not Union{Float64,Nothing} like `_solutes`, since no RNA/DNA entry has
a missing uncertainty) — matches `_Protein`'s type, required by `_titrated`. """
const _RNA::Dict{String,Tuple{Int64,Float64,Float64}} =
    JSON3.read(
        read(joinpath(@__DIR__, "RNA", "rna.json"), String),
        Dict{String,Tuple{Int64,Float64,Float64}},
    )

""" key => ((pKa, `ionized_key`), `neutral_key`), same shape as `_protein_ionization`. """
const _DNA_ionization::Dict{String,Tuple{Tuple{Float64,String},String}} = JSON3.read(
    read(joinpath(@__DIR__, "DNA", "ionization.json"), String),
    Dict{String,Tuple{Tuple{Float64,String},String}},
)

""" key => ((pKa, `ionized_key`), `neutral_key`), same shape as `_protein_ionization`. """
const _RNA_ionization::Dict{String,Tuple{Tuple{Float64,String},String}} = JSON3.read(
    read(joinpath(@__DIR__, "RNA", "ionization.json"), String),
    Dict{String,Tuple{Tuple{Float64,String},String}},
)

"""
Memoized DNA partial molar volume, keyed by
`(sequence, pH, σ_pH)`: the result depends on all three
"""
const _ϕ°_d_cache = KeyedCache{Tuple{String,Float64,Float64},Tuple{Int64,Float64,Float64}}()

"""
Memoized RNA partial molar volume, keyed by
`(sequence, pH, σ_pH)`: the result depends on all three
"""
const _ϕ°_r_cache = KeyedCache{Tuple{String,Float64,Float64},Tuple{Int64,Float64,Float64}}()

"Maps IUPAC nucleotide ambiguity codes to the bases they average over."
const _wildcards_nuc = Dict(
    "R" => Dict("DNA" => ["A", "G"], "RNA" => ["A", "G"]),          # puRine
    "Y" => Dict("DNA" => ["C", "T"], "RNA" => ["C", "U"]),          # pYrimidine
    "S" => Dict("DNA" => ["G", "C"], "RNA" => ["G", "C"]),          # Strong (3 H-bonds)
    "W" => Dict("DNA" => ["A", "T"], "RNA" => ["A", "U"]),          # Weak (2 H-bonds)
    "K" => Dict("DNA" => ["G", "T"], "RNA" => ["G", "U"]),          # Keto
    "M" => Dict("DNA" => ["A", "C"], "RNA" => ["A", "C"]),          # aMino
    "B" => Dict("DNA" => ["C", "G", "T"], "RNA" => ["C", "G", "U"]),     # not A
    "D" => Dict("DNA" => ["A", "G", "T"], "RNA" => ["A", "G", "U"]),     # not C
    "H" => Dict("DNA" => ["A", "C", "T"], "RNA" => ["A", "C", "U"]),     # not G
    "V" => Dict("DNA" => ["A", "C", "G"], "RNA" => ["A", "C", "G"]),     # not T/U
    "N" => Dict("DNA" => ["A", "C", "G", "T"], "RNA" => ["A", "C", "G", "U"]), # aNy
)

include("CalcDensity.jl")   # water first: `_H2O_V0_25C` below needs its density

# Defined after CalcDensity.jl because its initializer calls `_kell_density`.
"Bulk water molar volume at the PMV reference temperature (25 °C), cm³·mol⁻¹,
from the same Kell equation as `_ρₑ_w` (≈ 18.0686)."
const _H2O_V0_25C =
    WATER_MOLAR_MASS / _kell_density(PMV_REFERENCE_TEMPERATURE_C) * CM3_PER_LITER

include("PMV.jl")

end # module BulkElectronDensity
