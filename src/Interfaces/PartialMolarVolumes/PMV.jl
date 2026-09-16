# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Partial molar volumes (V0, cm³/mol) and water bulk electron density.
"""
module PartialMolarVolumes

import ..Interfaces
using  ..Interfaces: PartialMolarVolumeSource
using  ...Constants: AVOGADRO
using  ...Cache: KeyedCache
using  JSON3: JSON3

export PMVSrcTables, COMMON_TO_IUPAC

"Marker for the bundled-table backend."
struct PMVSrcTables <: PartialMolarVolumeSource end

"""
    _titrated(
        res::AbstractString,
        _ionization::Dict{String, Tuple{Tuple{Float64, String}, String}},
        _dict::Dict{String, Tuple{Int64, Float64, Float64}},
        pH::Real;
        σ_pH::Real = 0.0
    ) -> Tuple{Int64, Float64, Float64}

Resolves the pH-dependent partial molar volume of an ionizable residue via
the sigmoidal titration formula `V(pH) = V0 ∓ dV/(1+10^(±(pKa-pH)))`.

Generic over which value table is titrated: `_ionization` and `_dict` are
passed in rather than closed over, so the same function serves Protein's
`_ionization`/`_Protein` pair and any nucleotide ionization/residue-table
pair with the same shapes, without duplicating the titration math per
molecule kind.

`σ_pH`, the standard uncertainty on the measured `pH`, is propagated into
`variance` by the delta method: on either branch `∂pmv/∂pH = ∓dV·ln(10)·frac·(1-frac)`,
which has the same magnitude both ways, so its contribution is
`(dV·ln(10)·frac·(1-frac)·σ_pH)²`, added in quadrature to the existing
parameter-uncertainty term. This is a local linear approximation: it
degrades away from the steepest part of the sigmoid only in the sense of
the higher-order terms it drops, but blows up fastest right at
`pH == pKa`, where the sigmoid is steepest and `σ_pH` is least negligible
relative to the curvature.

# Arguments
- `res`: residue code to look up in `_ionization` (e.g. a protein one-letter
    code, or a nucleotide letter/`-nucleoside` key); must be a key of `_ionization`.
- `_ionization`: `res -> ((pKa, ionized_key), neutral_key)` table, e.g.
    `Protein`'s own ionization table or a nucleotide's.
- `_dict`: `key -> (electron_count, V0, uncertainty)` value table that
    `neutral_key`/`ionized_key` are resolved against. The ionized entry's
    `electron_count` is the *delta* relative to the neutral entry — always
    `0`, since deprotonation removes a bare proton, not an electron (see
    `_Protein`'s own docstring) — not an absolute count.
- `pH`: solution pH the titration is evaluated at.

# Keywords
- `σ_pH`: standard uncertainty on `pH`, propagated by the delta method
    above; default `0.0` (no propagation).
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


#----------------------------------------------------------
#               Water Bulk Electron Density
#----------------------------------------------------------

"Memoized water electron bulk density"
const _ρₑ_w_cache = KeyedCache{Int64, Tuple{Float64, Float64}}()

"Molar mass of H₂O, g·mol⁻¹ (IAPWS-95 value)."
const _M_H2O = 18.015268

"Electrons per H₂O molecule (2 from H, 8 from O), in e."
const _Z_H2O = 10

"""
    ρₑ_w(t::Real) -> Tuple{Float64, Float64}

Electron density of pure water at temperature `t` (°C) and 1 atm, in e·Å⁻³.

Uses the Kell equation (1975) for mass density, valid 0–150 °C at 1 atm,
returns (ρₑ, uncertainty)
"""
function ρₑ_w(t::Real)::Tuple{Float64, Float64}

    # temperature must be between 0 and 150
    if (t < 0 || t > 150)
        throw(DomainError(t, "temperature must be between 0°C and 150 °C"))
    end

    # look up in cache if memoized
    key = round(Int64, t * 1000)
    return get!(_ρₑ_w_cache, key) do
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
        (ρₑ_w, ρₑ_w * 0.02 / ρ)
    end
end

#----------------------------------------------------------
#              Protein Partial Molar Volume
#----------------------------------------------------------

"""key => ((pH condition, ionized_key), neutral_key)"""
const _protein_ionization::Dict{String, Tuple{Tuple{Float64, String}, String}} = JSON3.read(
    read(joinpath(@__DIR__, "Protein", "ionization.json"), String),
    Dict{String, Tuple{Tuple{Float64, String}, String}}
)

""" key => (electron_count, partial_molar_volume, uncertainty). electron_count is a
side-chain-only increment relative to glycine (see `_backbone_electrons`), and is
identical between a group's "-neutral" and "-acidic"/"-basic" forms since deprotonation
only removes a bare proton (no electron) — so every ionization delta row's own
electron_count is legitimately 0, not a placeholder. """
const _Protein::Dict{String, Tuple{Int64, Float64, Float64}} = JSON3.read(
    read(joinpath(@__DIR__, "Protein", "protein.json"), String),
    Dict{String, Tuple{Int64, Float64, Float64}}
)

""" maps ambiguity codes to the two amino acids. Average must be taken. """
const _wildcards = Dict("B" => ("D", "N"), "J" => ("L", "I"), "Z" => ("E", "Q"))

"""
Peptide-bond backbone unit (`-CH2CONH-`, "glycyl") volume at 25°C, added once per
residue in `ρₑ`. `Protein.json`'s per-residue entries (`A`, `V`, `L`, ... and `G`'s
zero) are side-chain-only increments relative to glycine (Lee et al. 2008's own
convention), not absolute residue volumes — this shared backbone term is what
they sit on top of. Source: `Protein.tsv` CH2CONH row, `10.1039/9781782627043-00542`.
"""
const _backbone_pmv = (37.4, 0.1)

"""
Peptide backbone unit (`-CH2CONH-`, neutral, C2H3NO) electron count: 2×C(6) + 3×H(1)
+ N(7) + O(8) = 30 e. Added once per residue in `ρₑ`, on the same basis as
`_backbone_pmv` — `Protein.json`'s electron_count field is a side-chain-only
increment relative to glycine, and this is the shared unit it sits on top of.
"""
const _backbone_electrons = 30

"""
Electrons contributed by one water molecule (`_Z_H2O`), added once per `ρₑ` call
(not per residue): joining N free amino acids into a chain releases (N-1) waters,
so the repeated backbone unit above is short exactly one H2O's worth of capping
atoms at the two open chain termini.
"""
const _formation_water_electrons = _Z_H2O

"Memoized protein partial molar volume, keyed by sequence"
const _ϕ°_p_cache = KeyedCache{String, Tuple{Int64, Float64, Float64}}()

"""
    _residue_var(res::AbstractString, pH::Real; σ_pH::Real = 0.0) -> (electron_count, pmv, variance)

Normalizes any residue lookup (ionizable or not) to (electron_count, pmv, variance),
so every call site in `ρₑ` accumulates uniformly. Non-ionizable residues have no
`pH` dependence, so `σ_pH` contributes nothing for them.
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
    ϕ°(pH::Real, seq::AbstractString; σ_pH::Real = 0.0) -> Tuple{Int64, Float64, Float64}
takes a sequence of one-letter amino acid codes at a pH and returns the estimated
partial molar volume at inifinit dilution (total electron count, partial molar volume,
uncertainty). `σ_pH` is the standard uncertainty on `pH`, propagated by the delta
method through each ionizable residue's titration term (see `_titrated`). The
result is cached off of sequence only, so only the first call of `σ_pH` and `pH`
are taken into account.
"""
function ϕ°(pH::Real, seq::AbstractString; σ_pH::Real = 0.0)::Tuple{Int64, Float64, Float64}

    # don't need all of these, but best to fail early and loudly
    if (isempty(seq))
        throw(ArgumentError("Sequence is empty!"))
    end

    key = String(seq)

    return get!(_ϕ°_p_cache, key) do

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
            ϕ° += _backbone_pmv[1]
            sqr_unc += _backbone_pmv[2]^2
            z_i += _backbone_electrons

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
        any_real && (z_i += _formation_water_electrons)

        # cache and return result
        (z_i, ϕ°, sqrt(sqr_unc))

    end
end

#----------------------------------------------------------
#        Non Biological Solute Partial Molar Volume        
#----------------------------------------------------------

"Memoized solute partial molar volume, keyed by iupac name"
const _ϕ°_s_cache = KeyedCache{String, Tuple{Int64, Float64, Float64}}()

""" iupac name => (electron count, pmv, uncertainty) """
const _solutes::Dict{String, Tuple{Int64, Float64, Union{Float64, Nothing}}} =
    JSON3.read(
    read(joinpath(@__DIR__, "NonBiological", "nonbiological.json"), String),
    Dict{String, Tuple{Int64, Float64, Union{Float64, Nothing}}}
)

""" common name => iupac name """
const COMMON_TO_IUPAC::Dict{String, String} = JSON3.read(
    read(joinpath(@__DIR__, "NonBiological", "common_to_iupac.json"), String),
    Dict{String, String}
)

"""
    _common2iupac(name::AbstractString) -> Tuple{String,Bool}

Look up a non-protein solute's IUPAC name from its common name via
`COMMON_TO_IUPAC` (case-insensitive). Returns `(iupac_name, true)` on a hit,
or `("", false)` if `name` has no mapping. Private: the only caller is
`_resolve_solute_name` below, so this has no reason to be part of the
swappable-backend `Interfaces` surface.
"""
function _common2iupac(name::AbstractString)::Tuple{String,Bool}
    iupac = get(COMMON_TO_IUPAC, lowercase(String(name)), nothing)
    return iupac === nothing ? ("", false) : (iupac, true)
end

"""
    _resolve_solute_name(name::AbstractString) -> String

`name` itself if it is already an `nonbiological.json` key, else its
`COMMON_TO_IUPAC` mapping via [`_common2iupac`](@ref), else `name` unchanged
(so `ϕ°` below still throws its own `ArgumentError` rather than a
`KeyError` from here). Mirrors `AtomicRadii`'s fallback-chain style.

# Arguments
- `name`: common or IUPAC solute name.
"""
function _resolve_solute_name(name::AbstractString)::String
    s = String(name)
    haskey(_solutes, s) && return s
    iupac, ok = _common2iupac(s)
    return ok ? iupac : s
end

"""
    ϕ°(name::AbstractString) -> Tuple{Int64, Float64, Float64}

Takes the IUPAC name of a solute and returns (electron count, pmv, uncertainty).
"""
function ϕ°(name::AbstractString)::Tuple{Int64, Float64, Float64}

    key = String(name)

    return get!(_ϕ°_s_cache, key) do
        res = get(_solutes, name, nothing)

        # name is not mapped, throw error
        if res === nothing
            throw(ArgumentError("unknown solute: $name"))
        else
            # if uncertainty is unknown, assign average uncertainty
            if res[3] === nothing
                i = 0
                s = 0.0
                for k in keys(_solutes)
                    u = _solutes[k][3]
                    if u !== nothing
                        i += 1
                        s += u
                    end
                end
                s /= i
                (res[1], res[2], s)

            else
                (res[1], res[2], res[3])
            end
        end
    end
end

#----------------------------------------------------------
#             Nucleotides Partial Molar Volume              
#----------------------------------------------------------

"Memoized DNA partial molar volume, keyed by sequence"
const _ϕ°_d_cache = KeyedCache{String, Tuple{Int64, Float64, Float64}}()

"Memoized RNA partial molar volume, keyed by sequence"
const _ϕ°_r_cache = KeyedCache{String, Tuple{Int64, Float64, Float64}}()

""" key => (electron_count, V0, uncertainty). Strict `Float64` uncertainty
(not `Union{Float64,Nothing}` like `_solutes`, since no `RNA/DNA` entry has
a missing uncertainty) — matches `_Protein`'s type, required by `_titrated`. """
const _DNA::Dict{String, Tuple{Int64, Float64, Float64}} =
    JSON3.read(
    read(joinpath(@__DIR__, "DNA", "dna.json"), String),
    Dict{String, Tuple{Int64, Float64, Float64}}
)

""" key => (electron_count, V0, uncertainty). Strict `Float64` uncertainty
(not `Union{Float64,Nothing}` like `_solutes`, since no `RNA/DNA` entry has
a missing uncertainty) — matches `_Protein`'s type, required by `_titrated`. """
const _RNA::Dict{String, Tuple{Int64, Float64, Float64}} =
    JSON3.read(
    read(joinpath(@__DIR__, "RNA", "rna.json"), String),
    Dict{String, Tuple{Int64, Float64, Float64}}
)

""" key => ((pKa, ionized_key), neutral_key), same shape as `_protein_ionization`. """
const _DNA_ionization::Dict{String, Tuple{Tuple{Float64, String}, String}} = JSON3.read(
    read(joinpath(@__DIR__, "DNA", "ionization.json"), String),
    Dict{String, Tuple{Tuple{Float64, String}, String}}
)

""" key => ((pKa, ionized_key), neutral_key), same shape as `_protein_ionization`. """
const _RNA_ionization::Dict{String, Tuple{Tuple{Float64, String}, String}} = JSON3.read(
    read(joinpath(@__DIR__, "RNA", "ionization.json"), String),
    Dict{String, Tuple{Tuple{Float64, String}, String}}
)

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
    _wildcard_var(bases::Vector{String}, lookup::Function) -> Tuple{Int64, Float64, Float64}

N-way average of a wildcard's component residues/bases: mean `pmv` and
electron count, `variance = sum of variances / N²` (generalizes protein's
inline 2-way wildcard averaging, which is just this formula's `N=2` case).

# Arguments
- `bases`: the residue/base codes to average over (e.g. `["A", "G"]` for `R`).
- `lookup`: `base::AbstractString -> (electron_count, pmv, variance)` resolver
    called once per element of `bases` — the caller's own per-residue
    resolver (e.g. `_nuc_residue_var` itself, for recursive reuse so a
    wildcard's component bases are still checked for ionizability).
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

"""
    _nuc_residue_var(res::AbstractString, isDNA::Bool, pH::Real; σ_pH::Real = 0.0)
        -> Tuple{Int64, Float64, Float64}

Resolves a single nucleotide letter (or IUPAC ambiguity code) to
`(electron_count, pmv, variance)`, normalizing plain/ionizable/wildcard
lookups the same way `_residue_var` does for protein. `isDNA` selects which
value/ionization table pair to resolve against.

# Arguments
- `res`: one-letter nucleotide or ambiguity code (`A/U/G/C` or `A/T/G/C`,
    or any key of `_wildcards_nuc`).
- `isDNA`: `true` to resolve against `_DNA`/`_DNA_ionization`, `false` for
    `_RNA`/`_RNA_ionization`.
- `pH`: solution pH, forwarded to `_titrated` for ionizable residues.

# Keywords
- `σ_pH`: standard uncertainty on `pH`; default `0.0`.

# Throws
- `ArgumentError` if `res` is not a recognized key.
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
        return _wildcard_var(bases, b -> _nuc_residue_var(b, isDNA, pH; σ_pH))
    elseif haskey(ion_dict, res)
        return _titrated(res, ion_dict, value_dict, pH; σ_pH)
    elseif haskey(value_dict, res)
        e, pmv, u = value_dict[res]
        return e, pmv, u^2
    else
        throw(ArgumentError("unknown $(isDNA ? "DNA" : "RNA") residue: $res"))
    end
end

"Bulk water molar volume at 25°C (cm³/mol), same Kell-equation source as `ρₑ_w`."
const _H2O_V0_25C = 18.07

"""
    ϕ°(isDNA::Bool, pH::Real, seq::AbstractString; σ_pH::Real = 0.0)
        -> Tuple{Int64, Float64, Float64}

Partial molar volume at infinite dilution of a DNA/RNA sequence at a given
pH: takes a string of one-letter nucleotide codes (or IUPAC ambiguity
codes) and returns `(total electron count, partial molar volume, uncertainty)`.
# Arguments
- `isDNA`: `true` for a DNA sequence, `false` for RNA.
- `pH`: solution pH the titration is evaluated at.
- `seq`: sequence of one-letter nucleotide/ambiguity codes. `*` is a
    no-op placeholder.

# Keywords
- `σ_pH`: standard uncertainty on `pH`, propagated through each ionizable
    residue's titration term via `_titrated`; default `0.0`.

# Returns
`(electron_count, pmv, uncertainty)`.

# Throws
- `ArgumentError` if `seq` is empty.
- `ArgumentError` (from `_nuc_residue_var`) if `seq` contains a character
    that isn't a valid residue, ambiguity code, or `*` for the selected
    `isDNA` alphabet.
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

    return get!(cache, key) do

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
        z_i -= n_bonds * _Z_H2O
        ϕ_total -= n_bonds * _H2O_V0_25C

        (z_i, ϕ_total, sqrt(sqr_unc))
    end
end

#----------------------------------------------------------
#                  Interfaces generics
#----------------------------------------------------------
# ϕ°/ρₑ_w are the stable API (declared in Interfaces.jl); only the backend
# (`src`, first argument) varies. The `src`-less forms below default it to
# `PMVSrcTables()`, same convention as `form_factor_table`.

"""
    Interfaces.ρₑ_w([src::PMVSrcTables,] t::Real) -> (ρₑ, uncertainty)

Bulk electron density of pure water at `t` (°C), in e·Å⁻³. Thin wrapper over
the local [`ρₑ_w`](@ref).
"""
Interfaces.ρₑ_w(::PMVSrcTables, t::Real)::Tuple{Float64,Float64} = ρₑ_w(t)
Interfaces.ρₑ_w(t::Real)::Tuple{Float64,Float64} = Interfaces.ρₑ_w(PMVSrcTables(), t)

"""
    Interfaces.ϕ°(
        [src::PMVSrcTables,] pH::Real, 
        seq::AbstractString; 
        σ_pH::Real = 0.0
    ) -> (electron_count, v0, uncertainty)
    
    Interfaces.ϕ°([src::PMVSrcTables,] name::AbstractString) 
        -> (electron_count, v0, uncertainty)

Partial molar volume at infinite dilution (`v0` in cm³/mol) for a protein
sequence at a given pH, or a non-protein solute by common or IUPAC name.
`σ_pH` is the standard uncertainty on `pH`, propagated by the delta method
(see the local [`ϕ°`](@ref)). Thin wrappers over the local [`ϕ°`](@ref).
"""
Interfaces.ϕ°(
    ::PMVSrcTables, 
    pH::Real, 
    seq::AbstractString; 
    σ_pH::Real = 0.0
)::Tuple{Int64,Float64,Float64} = ϕ°(pH, seq; σ_pH)
Interfaces.ϕ°(
    pH::Real, 
    seq::AbstractString; 
    σ_pH::Real = 0.0
)::Tuple{Int64,Float64,Float64} = Interfaces.ϕ°(PMVSrcTables(), pH, seq; σ_pH)

Interfaces.ϕ°(::PMVSrcTables, name::AbstractString)::Tuple{Int64,Float64,Float64} = ϕ°(_resolve_solute_name(name))

Interfaces.ϕ°(name::AbstractString)::Tuple{Int64,Float64,Float64} = Interfaces.ϕ°(PMVSrcTables(), name)

"""
    Interfaces.ϕ°(
        [src::PMVSrcTables,] isDNA::Bool,
        pH::Real,
        seq::AbstractString;
        σ_pH::Real = 0.0
    ) -> (electron_count, v0, uncertainty)

Partial molar volume at infinite dilution (`v0` in cm³/mol) for a DNA/RNA
sequence at a given pH. `isDNA` selects the `A/T/G/C` alphabet/backend
table when `true`, `A/U/G/C` when `false`. `σ_pH` is the standard
uncertainty on `pH`, propagated by the delta method (see the local
[`ϕ°`](@ref)). Thin wrappers over the local [`ϕ°`](@ref).
"""
Interfaces.ϕ°(
    ::PMVSrcTables,
    isDNA::Bool,
    pH::Real,
    seq::AbstractString;
    σ_pH::Real = 0.0
)::Tuple{Int64,Float64,Float64} = ϕ°(isDNA, pH, seq; σ_pH)
Interfaces.ϕ°(
    isDNA::Bool,
    pH::Real,
    seq::AbstractString;
    σ_pH::Real = 0.0
)::Tuple{Int64,Float64,Float64} = Interfaces.ϕ°(PMVSrcTables(), isDNA, pH, seq; σ_pH)


end # module PartialMolarVolumes
