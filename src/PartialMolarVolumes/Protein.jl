# SPDX-License-Identifier: LGPL-2.1-or-later

"""key => ((pH condition, `ionized_key`), `neutral_key`)"""
const _protein_ionization::Dict{String, Tuple{Tuple{Float64, String}, String}} = JSON3.read(
    read(joinpath(@__DIR__, "Protein", "ionization.json"), String),
    Dict{String, Tuple{Tuple{Float64, String}, String}}
)

""" key => (`electron_count`, `partial_molar_volume`, uncertainty). `electron_count` is a
side-chain-only increment relative to glycine (see [`BACKBONE_ELECTRONS`](@ref)), and is
identical between a group's "-neutral" and "-acidic"/"-basic" forms since deprotonation
only removes a bare proton (no electron). """
const _Protein::Dict{String, Tuple{Int64, Float64, Float64}} = JSON3.read(
    read(joinpath(@__DIR__, "Protein", "protein.json"), String),
    Dict{String, Tuple{Int64, Float64, Float64}}
)

""" maps ambiguity codes to the two amino acids. Average must be taken. """
const _wildcards = Dict("B" => ("D", "N"), "J" => ("L", "I"), "Z" => ("E", "Q"))

"Memoized protein partial molar volume, keyed by `(sequence, pH, σ_pH)`: the result depends on all three"
const _ϕ°_p_cache = KeyedCache{Tuple{String, Float64, Float64}, Tuple{Int64, Float64, Float64}}()

"""
Normalizes any residue lookup (ionizable or not) to (`electron_count`, pmv, variance),
so every call site in ρₑ accumulates uniformly. Non-ionizable residues have no
pH dependence, so `σ_pH` contributes nothing for them.
"""
function _residue_var(res::AbstractString, pH::Real; σ_pH::Real = 0.0)::Tuple{Int64, Float64, Float64}
    if haskey(_protein_ionization, res)
        return _titrated(res, _protein_ionization, _Protein, pH; σ_pH)
    else
        e, pmv, u = _Protein[res]
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
function ϕ°(pH::Real, seq::AbstractString; σ_pH::Real = 0.0)::Tuple{Int64, Float64, Float64}

    # don't need all of these, but best to fail early and loudly
    if (isempty(seq))
        throw(ArgumentError("Sequence is empty!"))
    end

    key = (String(seq), Float64(pH), Float64(σ_pH))

    return @closure get!(_ϕ°_p_cache, key) do

        # initialize accumulators
        sqr_unc = 0.0
        ϕ° = 0.0
        z_i = 0
        any_real = false

        for aa in string.(collect(seq))

            # placeholds, skip (no backbone unit either)
            if (aa == "*" || aa == "X")
                continue
            end

            any_real = true

            # every real residue contributes one shared peptide backbone unit,
            # on top of which the side-chain increment below sits
            ϕ° += BACKBONE_PMV[1]
            sqr_unc += BACKBONE_PMV[2]^2
            z_i += BACKBONE_ELECTRONS

            # need to be averaged between two residues
            if (haskey(_wildcards, aa))

                res1, res2 = _wildcards[aa]
                res1_e, res1_pmv, res1_var = _residue_var(res1, pH; σ_pH)
                res2_e, res2_pmv, res2_var = _residue_var(res2, pH; σ_pH)

                # final uncertainty is the variance of the two
                sqr_unc += (res1_var + res2_var) / 4
                ϕ° += (res1_pmv + res2_pmv) / 2
                # rounded: electron counts are integers, average of two need not be
                z_i += round(Int64, (res1_e + res2_e) / 2)


            # ionizable residue, need to get correct key
            elseif (haskey(_protein_ionization, aa))
                e, pmv, var = _titrated(aa, _protein_ionization, _Protein, pH; σ_pH)
                ϕ° += pmv
                sqr_unc += var
                z_i += e

            # regular amino acid
            elseif (haskey(_Protein, aa))
                e, pmv, u = _Protein[aa]
                ϕ° += pmv
                sqr_unc += u^2
                z_i += e

            # unknown/illegal char
            else
                throw(ArgumentError("unknown amino acid residue: $aa"))
            end
        end

        # chain formation releases waters but leaves the two open termini short
        # one water's worth of capping atoms - add it back once, not per residue.
        # Only for an actual chain: an all-placeholder "sequence" formed no
        # peptide bonds at all, so there are no termini to cap.
        any_real && (z_i += WATER_ELECTRONS)   

        # cache and return result
        (z_i, ϕ°, sqrt(sqr_unc))

    end
end
