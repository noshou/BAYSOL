# SPDX-License-Identifier: LGPL-3.0-or-later

# Partial molar volumes at infinite dilution, ϕ° (cm³·mol⁻¹, with uncertainty),
# of DNA and RNA sequences: the per-nucleotide tables `dna/dna.json` and
# `rna/rna.json`, their phosphate and base ionization tables (`ionization.json`),
# the IUPAC ambiguity codes, and the per-sequence sum with titration
# (`_titrated`, titration.jl). Internal: only `ρₑ` (calc-density.jl) uses it.

""" key => (`electron_count`, V0, uncertainty). Strict Float64 uncertainty
(not Union{Float64,Nothing} like `_SOLUTES`, since no RNA/DNA entry has
a missing uncertainty) — matches `_PROTEIN`'s type, required by `_titrated`. """
const _DNA::Dict{String,Tuple{Int64,Float64,Float64}} =
    JSON3.read(
        read(joinpath(@__DIR__, "dna", "dna.json"), String),
        Dict{String,Tuple{Int64,Float64,Float64}},
    )

""" key => (`electron_count`, V0, uncertainty). Strict Float64 uncertainty
(not Union{Float64,Nothing} like `_SOLUTES`, since no RNA/DNA entry has
a missing uncertainty) — matches `_PROTEIN`'s type, required by `_titrated`. """
const _RNA::Dict{String,Tuple{Int64,Float64,Float64}} =
    JSON3.read(
        read(joinpath(@__DIR__, "rna", "rna.json"), String),
        Dict{String,Tuple{Int64,Float64,Float64}},
    )

""" key => ((pKa, `ionizedKey`), `neutralKey`), same shape as `_PROTEIN_IONIZATION`. """
const _DNA_IONIZATION::Dict{String,Tuple{Tuple{Float64,String},String}} = JSON3.read(
    read(joinpath(@__DIR__, "dna", "ionization.json"), String),
    Dict{String,Tuple{Tuple{Float64,String},String}},
)

""" key => ((pKa, `ionizedKey`), `neutralKey`), same shape as `_PROTEIN_IONIZATION`. """
const _RNA_IONIZATION::Dict{String,Tuple{Tuple{Float64,String},String}} = JSON3.read(
    read(joinpath(@__DIR__, "rna", "ionization.json"), String),
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
const _WILDCARDS_NUC = Dict(
    "R" => Dict("DNA" => ["A", "G"], "RNA" => ["A", "G"]),           # puRine
    "Y" => Dict("DNA" => ["C", "T"], "RNA" => ["C", "U"]),           # pYrimidine
    "S" => Dict("DNA" => ["G", "C"], "RNA" => ["G", "C"]),           # Strong
    "W" => Dict("DNA" => ["A", "T"], "RNA" => ["A", "U"]),           # Weak
    "K" => Dict("DNA" => ["G", "T"], "RNA" => ["G", "U"]),           # Keto
    "M" => Dict("DNA" => ["A", "C"], "RNA" => ["A", "C"]),           # aMino
    "B" => Dict("DNA" => ["C", "G", "T"], "RNA" => ["C", "G", "U"]),      # not A
    "D" => Dict("DNA" => ["A", "G", "T"], "RNA" => ["A", "G", "U"]),      # not C
    "H" => Dict("DNA" => ["A", "C", "T"], "RNA" => ["A", "C", "U"]),      # not G
    "V" => Dict("DNA" => ["A", "C", "G"], "RNA" => ["A", "C", "G"]),      # not T/U
    "N" => Dict("DNA" => ["A", "C", "G", "T"], "RNA" => ["A", "C", "G", "U"]), # aNy
)

"""
Resolves a single nucleotide letter (or IUPAC ambiguity code) to
(`electron_count`, pmv, variance), normalizing plain/ionizable/wildcard
lookups the same way `_residueVar` does for protein. isDNA selects which
value/ionization table pair to resolve against.

# Arguments
- `res`: one-letter nucleotide or ambiguity code (A/U/G/C or A/T/G/C,
    or any key of `_WILDCARDS_NUC`).
- `isDNA`: true to resolve against `_DNA/_DNA_ionization`, false for
    `_RNA/_RNA_ionization`.
- `pH`: solution pH, forwarded to `_titrated` for ionizable residues.

# Keywords
- `σ_pH`: standard uncertainty on pH; default 0.0.

# Throws
- `ArgumentError` if res is not a recognized key.
"""
function _nucResidueVar(
    res::AbstractString,
    isDNA::Bool,
    pH::Real;
    σ_pH::Real = 0.0,
)::Tuple{Int64,Float64,Float64}

    valueDict = isDNA ? _DNA : _RNA
    ionDict   = isDNA ? _DNA_IONIZATION : _RNA_IONIZATION

    if haskey(_WILDCARDS_NUC, res)
        bases = _WILDCARDS_NUC[res][isDNA ? "DNA" : "RNA"]
        return _wildcardVar(bases, @closure(b -> _nucResidueVar(b, isDNA, pH; σ_pH)))
    elseif haskey(ionDict, res)
        return _titrated(res, ionDict, valueDict, pH; σ_pH)
    elseif haskey(valueDict, res)
        e, pmv, u = valueDict[res]
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
- `ArgumentError` (from `_nucResidueVar`) if seq contains a character
    that isn't a valid residue, ambiguity code, or * for the selected
    isDNA alphabet.
"""
function ϕ°(
    isDNA::Bool,
    pH::Real,
    seq::AbstractString;
    σ_pH::Real = 0.0,
)::Tuple{Int64,Float64,Float64}

    if isempty(seq)
        throw(ArgumentError("Sequence is empty!"))
    end

    cache = isDNA ? _ϕ°_d_cache : _ϕ°_r_cache
    key = (String(seq), Float64(pH), Float64(σ_pH))

    return @closure get!(cache, key) do

        sqrUnc = 0.0
        ϕ_total = 0.0
        zI = 0
        nReal = 0

        for nt in string.(collect(seq))

            # no-op placeholder, skip (no residue contribution at all)
            nt == "*" && continue

            nReal += 1
            e, pmv, var = _nucResidueVar(nt, isDNA, pH; σ_pH)
            ϕ_total += pmv
            sqrUnc += var
            zI += e
        end

        # Each per-letter value is a FREE (fully-hydrated) 5'-monophosphate,
        # unlike Protein's already-anhydrous backbone unit. Subtract per bond.
        nBonds = max(nReal - 1, 0)
        zI -= nBonds * WATER_ELECTRONS
        ϕ_total -= nBonds * _H2O_V0_25C

        (zI, ϕ_total, sqrt(sqrUnc))
    end
end
