# SPDX-License-Identifier: LGPL-2.1-or-later

""" key => (`electron_count`, V0, uncertainty). Strict Float64 uncertainty
(not Union{Float64,Nothing} like `_solutes`, since no RNA/DNA entry has
a missing uncertainty) — matches `_Protein`'s type, required by `_titrated`. """
const _DNA::Dict{String, Tuple{Int64, Float64, Float64}} =
    JSON3.read(
    read(joinpath(@__DIR__, "DNA", "dna.json"), String),
    Dict{String, Tuple{Int64, Float64, Float64}}
)

""" key => (`electron_count`, V0, uncertainty). Strict Float64 uncertainty
(not Union{Float64,Nothing} like `_solutes`, since no RNA/DNA entry has
a missing uncertainty) — matches `_Protein`'s type, required by `_titrated`. """
const _RNA::Dict{String, Tuple{Int64, Float64, Float64}} =
    JSON3.read(
    read(joinpath(@__DIR__, "RNA", "rna.json"), String),
    Dict{String, Tuple{Int64, Float64, Float64}}
)

""" key => ((pKa, `ionized_key`), `neutral_key`), same shape as `_protein_ionization`. """
const _DNA_ionization::Dict{String, Tuple{Tuple{Float64, String}, String}} = JSON3.read(
    read(joinpath(@__DIR__, "DNA", "ionization.json"), String),
    Dict{String, Tuple{Tuple{Float64, String}, String}}
)

""" key => ((pKa, `ionized_key`), `neutral_key`), same shape as `_protein_ionization`. """
const _RNA_ionization::Dict{String, Tuple{Tuple{Float64, String}, String}} = JSON3.read(
    read(joinpath(@__DIR__, "RNA", "ionization.json"), String),
    Dict{String, Tuple{Tuple{Float64, String}, String}}
)

"Memoized DNA partial molar volume, keyed by sequence"
const _ϕ°_d_cache = KeyedCache{String, Tuple{Int64, Float64, Float64}}()

"Memoized RNA partial molar volume, keyed by sequence"
const _ϕ°_r_cache = KeyedCache{String, Tuple{Int64, Float64, Float64}}()

"Maps IUPAC nucleotide ambiguity codes to the bases they average over."
const _wildcards_nuc = Dict(
    "R" => Dict("DNA" => ["A", "G"],           "RNA" => ["A", "G"]),          # puRine
    "Y" => Dict("DNA" => ["C", "T"],           "RNA" => ["C", "U"]),          # pYrimidine
    "S" => Dict("DNA" => ["G", "C"],           "RNA" => ["G", "C"]),          # Strong (3 H-bonds)
    "W" => Dict("DNA" => ["A", "T"],           "RNA" => ["A", "U"]),          # Weak (2 H-bonds)
    "K" => Dict("DNA" => ["G", "T"],           "RNA" => ["G", "U"]),          # Keto
    "M" => Dict("DNA" => ["A", "C"],           "RNA" => ["A", "C"]),          # aMino
    "B" => Dict("DNA" => ["C", "G", "T"],      "RNA" => ["C", "G", "U"]),     # not A
    "D" => Dict("DNA" => ["A", "G", "T"],      "RNA" => ["A", "G", "U"]),     # not C
    "H" => Dict("DNA" => ["A", "C", "T"],      "RNA" => ["A", "C", "U"]),     # not G
    "V" => Dict("DNA" => ["A", "C", "G"],      "RNA" => ["A", "C", "G"]),     # not T/U
    "N" => Dict("DNA" => ["A", "C", "G", "T"], "RNA" => ["A", "C", "G", "U"]) # aNy
)

"""
Resolves a single nucleotide letter (or IUPAC ambiguity code) to
(`electron_count`, pmv, variance), normalizing plain/ionizable/wildcard
lookups the same way `_residue_var` does for protein. isDNA selects which
value/ionization table pair to resolve against.

# Arguments
- `res`: one-letter nucleotide or ambiguity code (A/U/G/C or A/T/G/C,
    or any key of `_wildcards_nuc`).
- `isDNA`: true to resolve against `_DNA/_DNA_ionization`, false for
    `_RNA/_RNA_ionization`.
- `pH`: solution pH, forwarded to `_titrated` for ionizable residues.

# Keywords
- `σ_pH`: standard uncertainty on pH; default 0.0.

# Throws
- `ArgumentError` if res is not a recognized key.
"""
function _nuc_residue_var(
    res::AbstractString,
    isDNA::Bool,
    pH::Real;
    σ_pH::Real = 0.0
)::Tuple{Int64, Float64, Float64}

    value_dict = isDNA ? _DNA : _RNA
    ion_dict   = isDNA ? _DNA_ionization : _RNA_ionization

    if haskey(_wildcards_nuc, res)
        bases = _wildcards_nuc[res][isDNA ? "DNA" : "RNA"]
        return _wildcard_var(bases, @closure(b -> _nuc_residue_var(b, isDNA, pH; σ_pH)))
    elseif haskey(ion_dict, res)
        return _titrated(res, ion_dict, value_dict, pH; σ_pH)
    elseif haskey(value_dict, res)
        e, pmv, u = value_dict[res]
        return e, pmv, u^2
    else
        throw(ArgumentError("unknown $(isDNA ? "DNA" : "RNA") residue: $res"))
    end
end

"""
Partial molar volume at infinite dilution of a DNA/RNA sequence at a given
pH: takes a string of one-letter nucleotide codes (or IUPAC ambiguity
codes) and returns (total electron count, partial molar volume, uncertainty).
# Arguments
- `isDNA`: true for a DNA sequence, false for RNA.
- `pH`: solution pH the titration is evaluated at.
- `seq`: sequence of one-letter nucleotide/ambiguity codes. * is a
    no-op placeholder.

# Keywords
- `σ_pH`: standard uncertainty on pH, propagated through each ionizable
    residue's titration term via `_titrated`; default 0.0.

# Returns
`(electron_count, pmv, uncertainty)`

# Throws
- `ArgumentError` if seq is empty.
- `ArgumentError` (from `_nuc_residue_var`) if seq contains a character
    that isn't a valid residue, ambiguity code, or * for the selected
    isDNA alphabet.
"""
function ϕ°(
    isDNA::Bool, 
    pH::Real, 
    seq::AbstractString; 
    σ_pH::Real = 0.0
)::Tuple{Int64, Float64, Float64}

    if isempty(seq)
        throw(ArgumentError("Sequence is empty!"))
    end

    cache = isDNA ? _ϕ°_d_cache : _ϕ°_r_cache
    key = String(seq)

    return @closure get!(cache, key) do

        sqr_unc = 0.0
        ϕ_total = 0.0
        z_i = 0
        n_real = 0

        for nt in string.(collect(seq))

            # no-op placeholder, skip (no residue contribution at all)
            nt == "*" && continue

            n_real += 1
            e, pmv, var = _nuc_residue_var(nt, isDNA, pH; σ_pH)
            ϕ_total += pmv
            sqr_unc += var
            z_i += e
        end

        # Each per-letter value is a FREE (fully-hydrated) 5'-monophosphate,
        # unlike Protein's already-anhydrous backbone unit. Subtract per bond.
        n_bonds = max(n_real - 1, 0)
        z_i -= n_bonds * WATER_ELECTRONS
        ϕ_total -= n_bonds * _H2O_V0_25C

        (z_i, ϕ_total, sqrt(sqr_unc))
    end
end