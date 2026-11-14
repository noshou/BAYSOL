# SPDX-License-Identifier: LGPL-3.0-or-later

# Partial molar volumes at infinite dilution, ϕ° (cm³·mol⁻¹, with uncertainty),
# of protein sequences: the side-chain tables `protein.json` and
# `ionization.json`, the ambiguity codes (B, J, Z), and the per-sequence sum with
# the shared peptide backbone unit and the titration of the ionizable side chains
# (`_titrated`, titration.jl). Internal: only `ρₑ` (calc-density.jl) uses it.

"""key => ((pH condition, `ionizedKey`), `neutralKey`)"""
const _PROTEIN_IONIZATION::Dict{String,Tuple{Tuple{Float64,String},String}} = JSON3.read(
    read(joinpath(@__DIR__, "ionization.json"), String),
    Dict{String,Tuple{Tuple{Float64,String},String}},
)

""" key => (`electron_count`, `partial_molar_volume`, uncertainty). `electron_count` is a
side-chain-only increment relative to glycine (see [`BACKBONE_ELECTRONS`](@ref)), and is
identical between a group's "-neutral" and "-acidic"/"-basic" forms since deprotonation
only removes a bare proton (no electron). """
const _PROTEIN::Dict{String,Tuple{Int64,Float64,Float64}} = JSON3.read(
    read(joinpath(@__DIR__, "protein.json"), String),
    Dict{String,Tuple{Int64,Float64,Float64}},
)

""" maps ambiguity codes to the two amino acids. Average must be taken. """
const _WILDCARDS = Dict("B" => ("D", "N"), "J" => ("L", "I"), "Z" => ("E", "Q"))

"""
Memoized protein partial molar volume, keyed by
`(sequence, pH, σ_pH)`: the result depends on all three
"""
const _ϕ°_p_cache = KeyedCache{Tuple{String,Float64,Float64},Tuple{Int64,Float64,Float64}}()

"""
Normalizes any residue lookup (ionizable or not) to (`electron_count`, pmv, variance),
so every call site in ρₑ accumulates uniformly. Non-ionizable residues have no
pH dependence, so `σ_pH` contributes nothing for them.
"""
function _residueVar(
    res::AbstractString,
    pH::Real;
    σ_pH::Real = 0.0,
)::Tuple{Int64,Float64,Float64}
    if haskey(_PROTEIN_IONIZATION, res)
        return _titrated(res, _PROTEIN_IONIZATION, _PROTEIN, pH; σ_pH)
    else
        e, pmv, u = _PROTEIN[res]
        return e, pmv, u^2
    end
end

"""
takes a sequence of one-letter amino acid codes at a pH and returns the estimated
partial molar volume at inifinit dilution (total electron count, partial molar volume,
uncertainty). `σ_pH` is the standard uncertainty on pH, propagated by the delta
method through each ionizable residue's titration term (see `_titrated`). The
result is memoized per `(seq, pH, σ_pH)`, so a repeated call with the same three
arguments is free and a call at another pH or `σ_pH` is computed afresh.
"""
function ϕ°(pH::Real, seq::AbstractString; σ_pH::Real = 0.0)::Tuple{Int64,Float64,Float64}

    # don't need all of these, but best to fail early and loudly
    if (isempty(seq))
        throw(ArgumentError("Sequence is empty!"))
    end

    key = (String(seq), Float64(pH), Float64(σ_pH))

    return @closure get!(_ϕ°_p_cache, key) do

        # initialize accumulators
        sqrUnc = 0.0
        ϕ° = 0.0
        zI = 0
        anyReal = false

        for aa in string.(collect(seq))

            # placeholds, skip (no backbone unit either)
            if (aa == "*" || aa == "X")
                continue
            end

            anyReal = true

            # every real residue contributes one shared peptide backbone unit,
            # on top of which the side-chain increment below sits
            ϕ° += BACKBONE_PMV[1]
            sqrUnc += BACKBONE_PMV[2]^2
            zI += BACKBONE_ELECTRONS

            # need to be averaged between two residues
            if (haskey(_WILDCARDS, aa))

                res1, res2 = _WILDCARDS[aa]
                res1E, res1Pmv, res1Var = _residueVar(res1, pH; σ_pH)
                res2E, res2Pmv, res2Var = _residueVar(res2, pH; σ_pH)

                # final uncertainty is the variance of the two
                sqrUnc += (res1Var + res2Var) / 4
                ϕ° += (res1Pmv + res2Pmv) / 2
                # rounded: electron counts are integers, average of two need not be
                zI += round(Int64, (res1E + res2E) / 2)

                # ionizable residue, need to get correct key
            elseif (haskey(_PROTEIN_IONIZATION, aa))
                e, pmv, var = _titrated(aa, _PROTEIN_IONIZATION, _PROTEIN, pH; σ_pH)
                ϕ° += pmv
                sqrUnc += var
                zI += e

                # regular amino acid
            elseif (haskey(_PROTEIN, aa))
                e, pmv, u = _PROTEIN[aa]
                ϕ° += pmv
                sqrUnc += u^2
                zI += e

                # unknown/illegal char
            else
                throw(ArgumentError("unknown amino acid residue: $aa"))
            end
        end

        # chain formation releases waters but leaves the two open termini short
        # one water's worth of capping atoms - add it back once, not per residue.
        # Only for an actual chain: an all-placeholder "sequence" formed no
        # peptide bonds at all, so there are no termini to cap.
        anyReal && (zI += WATER_ELECTRONS)

        # cache and return result
        (zI, ϕ°, sqrt(sqrUnc))

    end
end
