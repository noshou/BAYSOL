# SPDX-License-Identifier: LGPL-2.1-or-later
using JSON3

#----------------------------------------------------------
#               Water Bulk Electron Density               
#----------------------------------------------------------

"Memoized water electron bulk density"
const _ρₑ_w_cache = Dict{Int64, Tuple{Float64, Float64}}()

"Molar mass of H₂O, g·mol⁻¹ (IAPWS-95 value)."
const _M_H2O = 18.015268

"Electrons per H₂O molecule (2 from H, 8 from O), in e."
const _Z_H2O = 10

""" 
    ρₑ(t::Real) -> Tuple{Float64, Float64}

Electron density of pure water at temperature `t` (°C) and 1 atm, in e·Å⁻³.

Uses the Kell equation (1975) for mass density, valid 0–150 °C at 1 atm,
returns (ρₑ, uncertainty)
"""
function ρₑ(t::Real)::Tuple{Float64, Float64}
    
    # temperature must be between 0 and 150 
    if (t < 0 || t > 150)
        throw(DomainError(t, "temperature must be between 0°C and 150 °C"))
    end

    # look up in cache if memoized
    key = round(Int64, t * 1000)
    if haskey(_ρₑ_w_cache, key)
        return _ρₑ_w_cache[key]
    else
        # calculate density of water at 1atm using the Kell equation
        ρ = (   999.83952 + 16.945176*t - 7.9870401e-3*t^2
                - 46.170461e-6*t^3 + 105.56302e-9*t^4
                - 280.54253e-12*t^5
            ) / (1 + 16.879850e-3*t)

        # molar mass / density; ρ is kg·m⁻³ and M_H2O is g·mol⁻¹, so v is
        # numerically 1e-3 m³·mol⁻¹ (= 1e27 Å³·mol⁻¹ per unit)
        v = _M_H2O / ρ

        # calculate electron density, e·Å⁻³
        ρₑ_w = (AVOGADRO * _Z_H2O) / (1e27 * v)

        # relative uncertainty = 0.02 / ρ(t)   ≈ 2×10⁻⁵ (≈20 ppm), nearly constant 0-150°C
        # absolute uncertainty on ρₑ_w(t) = ρₑ_w(t) × (0.02 / ρ(t))

        # memoize
        _ρₑ_w_cache[key] = (ρₑ_w, ρₑ_w * 0.02 / ρ) 

        return _ρₑ_w_cache[key]
    end 
end

#----------------------------------------------------------
#               Protein Bulk Electron Density              
#----------------------------------------------------------

"""key => ((pH condition, ionized_key), neutral_key)"""
const _ionization::Dict{String, Tuple{Tuple{Float64, String}, String}} = JSON3.read(
    read(joinpath(@__DIR__, "Proteins", "ionization.json"), String),
    Dict{String, Tuple{Tuple{Float64, String}, String}}
)

""" key => (partial_molar_volume, uncertainty) """
const _proteins::Dict{String, Tuple{Float64, Float64}} = JSON3.read(
    read(joinpath(@__DIR__, "Proteins", "proteins.json"), String),
    Dict{String, Tuple{Float64, Float64}}
)

""" maps ambiguity codes to the two amino acids. Average must be taken. """
const _wildcards = Dict("B" => ("D", "N"), "J" => ("L", "I"), "Z" => ("E", "Q"))

""" handles RNA collisions with DNA amino acids"""
const _RNA_map = Dict("A" => "A_RNA", "C" => "C_RNA", "G" => "G_RNA", "U" => "U_RNA")

"Memoized protein/nucleic-acid partial molar volume, keyed by (sequence, is_RNA)"
const _ρₑ_p_cache = Dict{Tuple{String, Bool}, Tuple{Float64, Float64}}()

"""
    _ionized_pmv(res::AbstractString, pH::Real) -> (pmv, variance)

Resolves the pH-dependent partial molar volume of an ionizable residue via
the sigmoidal titration formula (README: `V(pH) = V0 ∓ dV/(1+10^(±(pKa-pH)))`).
Returns *variance*, not standard deviation — callers accumulate variance and
take a single `sqrt` at the end, so taking `sqrt` here just to have callers
square it right back would waste a sqrt/square round-trip.
"""
function _ionized_pmv(res::AbstractString, pH::Real)::Tuple{Float64, Float64}
    (pKa, ionized_key), neutral_key = _ionization[res]
    v0, u0 = _proteins[neutral_key]
    dv, du = _proteins[ionized_key]
    acidic = endswith(ionized_key, "acidic")
    frac = acidic ? 1 / (1 + 10.0^(pKa - pH)) : 1 / (1 + 10.0^(pH - pKa))
    pmv = acidic ? v0 - dv * frac : v0 + dv * frac
    var = u0^2 + (frac * du)^2
    return pmv, var
end

"""
    _residue_var(res::AbstractString, pH::Real) -> (pmv, variance)

Normalizes any residue lookup (ionizable or not) to (pmv, variance), so every
call site in `ρₑ` accumulates variance uniformly regardless of which path
produced it — avoids squaring an already-variance value from `_ionized_pmv`.
"""
function _residue_var(res::AbstractString, pH::Real)::Tuple{Float64, Float64}
    if haskey(_ionization, res)
        return _ionized_pmv(res, pH)
    else
        pmv, u = _proteins[res]
        return pmv, u^2
    end
end

""" 
    ρₑ(pH::Real, seq::AbstractString; RNA::Bool=false) -> Tuple{Float64, Float64}  
takes a sequence of one-letter codes at a pH and returns the estimated partial molar 
volume with its uncertainty (ρₑ, uncertainty). Set RNA to true if the sequence is an 
RNA chain, else keep it as default. The result is cached off of sequence (preserves 
RNA/DNA distinction depending on the bool), and agnostic to pH. 
"""
function ρₑ(pH::Real, seq::AbstractString; RNA::Bool=false)::Tuple{Float64, Float64}
    
    # don't need all of these, but best to fail early and loudly
    if (isempty(seq))
        throw(DomainError(seq, "Sequence is empty!"))
    end

    # cache key: (sequence, is_RNA) so DNA/RNA sequences never collide
    key = (String(seq), RNA)

    if haskey(_ρₑ_p_cache, key)
        return _ρₑ_p_cache[key]
    else 

        # initialize accumulators
        sqr_unc = 0.0
        ρₑ = 0.0

        for aa in string.(collect(seq))
            
            # placeholds, skip
            if (aa == "*" || (RNA && aa == "N") || aa == "X")
                continue

            # RNA case
            elseif (RNA && haskey(_RNA_map, aa))
                res = _RNA_map[aa]
                pmv, var = _residue_var(res, pH)
                ρₑ += pmv
                sqr_unc += var

            # need to be averaged between two residues
            elseif (haskey(_wildcards, aa))

                res1, res2 = _wildcards[aa]
                res1_pmv, res1_var = _residue_var(res1, pH)
                res2_pmv, res2_var = _residue_var(res2, pH)

                # final uncertainty is the variance of the two
                sqr_unc += (res1_var + res2_var) / 4
                ρₑ += (res1_pmv + res2_pmv) / 2


            # ionizable residue, need to get correct key
            elseif (haskey(_ionization, aa))
                pmv, var = _ionized_pmv(aa, pH)
                ρₑ += pmv
                sqr_unc += var

            # regular DNA amino acid
            elseif (haskey(_proteins, aa))
                pmv, u = _proteins[aa]
                ρₑ += pmv
                sqr_unc += u^2
            
            # unknown/illegal char
            else
                throw(DomainError(aa, "unknown amino acid residue"))
            end
        end 

        # cache and return result
        _ρₑ_p_cache[key] = (ρₑ, sqrt(sqr_unc))
        return _ρₑ_p_cache[key]
        
    end 
end