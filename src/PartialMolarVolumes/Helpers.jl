# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Resolves the pH-dependent partial molar volume of an ionizable residue via
the sigmoidal titration formula V(pH) = V0 ∓ dV/(1+10^(±(pKa-pH))).

Generic over which value table is titrated: `_ionization` and `_dict` are
passed in rather than closed over, so the same function serves Protein's
`_ionization`/`_Protein` pair and any nucleotide ionization/residue-table
pair with the same shapes, without duplicating the titration math per
molecule kind.

`σ_pH`, the standard uncertainty on the measured pH, is propagated into
variance by the delta method: on either branch ∂pmv/∂pH = ∓dV·ln(10)·frac·(1-frac),
which has the same magnitude both ways, so its contribution is
(dV·ln(10)·frac·(1-frac)·`σ_pH`)², added in quadrature to the existing
parameter-uncertainty term. This is a local linear approximation: it
degrades away from the steepest part of the sigmoid only in the sense of
the higher-order terms it drops, but blows up fastest right at
pH == pKa, where the sigmoid is steepest and `σ_pH` is least negligible
relative to the curvature.

# Arguments
- `res`: residue code to look up in `_ionization` (e.g. a protein one-letter
    code, or a nucleotide letter/-nucleoside key); must be a key of `_ionization`.
- `_ionization`: res -> ((pKa, `ionized_key`), `neutral_key`) table, e.g.
    Protein's own ionization table or a nucleotide's.
- `_dict`: key -> (`electron_count`, V0, uncertainty) value table that
    `neutral_key/ionized_key` are resolved against. The ionized entry's
    `electron_count` is the *delta* relative to the neutral entry.

# Keywords
- `σ_pH`: standard uncertainty on pH, propagated by the delta method
    above; default 0.0 (no propagation).
"""
function _titrated(
    res::AbstractString, 
    _ionization::Dict{String, Tuple{Tuple{Float64, String}, String}},
    _dict::Dict{String, Tuple{Int64, Float64, Float64}},
    pH::Real; 
    σ_pH::Real = 0.0
)::Tuple{Int64, Float64, Float64}
    
    # get pKa and key of ionized residue; plain indexing throws Julia's own
    # KeyError(res) automatically if res is missing - no manual check needed
    (pKa, ionized_key), neutral_key = _ionization[res]

    # get values for neutral and ionized key
    e0, v0, u0 = _dict[neutral_key]
    de, dv, du = _dict[ionized_key]

    # determine if its basic or acidic (true if acidic)
    acidic = endswith(ionized_key, "acidic")
    
    # do titration formula
    frac = acidic ? 1 / (1 + 10.0^(pKa - pH)) : 1 / (1 + 10.0^(pH - pKa))
    pmv = acidic ? v0 - dv * frac : v0 + dv * frac
    dpmv_dpH = dv * log(10) * frac * (1 - frac)
    
    # propogate uncertainty
    var = u0^2 + (frac * du)^2 + (dpmv_dpH * σ_pH)^2
    return e0 + de, pmv, var
end

"""
N-way average of a wildcard's component residues/bases: mean pmv and
electron count, variance = sum of variances / N² (generalizes protein's
inline 2-way wildcard averaging, which is just this formula's N=2 case).

# Arguments
- `bases`: the residue/base codes to average over (e.g. ["A", "G"] for R).
- `lookup`: base::AbstractString -> (`electron_count`, pmv, variance).
"""
function _wildcard_var(bases::Vector{String}, lookup::Function)::Tuple{Int64,Float64,Float64}
    n = length(bases)
    es, pmvs, vars = 0, 0.0, 0.0
    for b in bases
        e, pmv, var = lookup(b)
        es += e; pmvs += pmv; vars += var
    end
    return round(Int64, es / n), pmvs / n, vars / n^2
end