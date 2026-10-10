# SPDX-License-Identifier: LGPL-2.1-or-later

# Partial molar volumes at infinite dilution, ϕ° (cm³·mol⁻¹, with
# uncertainty), of the buffer solutes: one backend per solute class (protein
# sequences, non-biological names, DNA and RNA sequences) and the titration
# helper they share. Internal: only `ρₑ` (CalcDensity.jl) uses them.

""" Returns the partial molar volume at infinite dilution of a solute. """
function ϕ° end

# ---------------------------------------------------------------------------
#   Titration helper shared by the protein and nucleotide backends
# ---------------------------------------------------------------------------

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
    _ionization::Dict{String,Tuple{Tuple{Float64,String},String}},
    _dict::Dict{String,Tuple{Int64,Float64,Float64}},
    pH::Real;
    σ_pH::Real = 0.0,
)::Tuple{Int64,Float64,Float64}

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
function _wildcard_var(
    bases::Vector{String},
    lookup::Function,
)::Tuple{Int64,Float64,Float64}
    n = length(bases)
    es, pmvs, vars = 0, 0.0, 0.0
    for b in bases
        e, pmv, var = lookup(b)
        es += e
        pmvs += pmv
        vars += var
    end
    return round(Int64, es / n), pmvs / n, vars / n^2
end

# ---------------------------------------------------------------------------
#   Proteins
# ---------------------------------------------------------------------------

"""
Normalizes any residue lookup (ionizable or not) to (`electron_count`, pmv, variance),
so every call site in ρₑ accumulates uniformly. Non-ionizable residues have no
pH dependence, so `σ_pH` contributes nothing for them.
"""
function _residue_var(
    res::AbstractString,
    pH::Real;
    σ_pH::Real = 0.0,
)::Tuple{Int64,Float64,Float64}
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
function ϕ°(pH::Real, seq::AbstractString; σ_pH::Real = 0.0)::Tuple{Int64,Float64,Float64}

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

# ---------------------------------------------------------------------------
#   Non-biological solutes
# ---------------------------------------------------------------------------

"""
Look up a non-protein solute's IUPAC name from its common name via
`COMMON_TO_IUPAC` (case-insensitive). Returns (`iupac_name`, true) on a hit,
with `iupac_name` always lowercase regardless of the case `COMMON_TO_IUPAC`
happens to store its values in, or ("", false) if name has no mapping.
Private: the only caller is `_resolve_solute_name` below.
"""
function _common2iupac(name::AbstractString)::Tuple{String,Bool}
    iupac = get(COMMON_TO_IUPAC, lowercase(String(name)), nothing)
    return iupac === nothing ? ("", false) : (lowercase(iupac), true)
end

"""
name (lowercased) itself if it is already an nonbiological.json key,
else its `COMMON_TO_IUPAC` mapping via [`_common2iupac`](@ref) (already
lowercase), else name lowercased, unchanged otherwise (so ϕ° below
still throws its own ArgumentError rather than a KeyError from here).
`_solutes` is lowercase-keyed, so name is lowercased before every lookup
here regardless of the case the caller passed in. Mirrors AtomicRadii's
fallback-chain style.

# Arguments
- `name`: common or IUPAC solute name.
"""
function _resolve_solute_name(name::AbstractString)::String
    s = lowercase(String(name))
    haskey(_solutes, s) && return s
    iupac, ok = _common2iupac(s)
    return ok ? iupac : s
end

"""
Takes the IUPAC name of a solute and returns (electron count, pmv, uncertainty).
Private: name must already be an exact nonbiological.json key (see
[`ϕ°(::AbstractString)`](@ref), the public entry point, which resolves a
common name to its IUPAC form via [`_resolve_solute_name`](@ref) first).
"""
function _ϕ°_by_iupac_name(name::AbstractString)::Tuple{Int64,Float64,Float64}

    key = String(name)

    return @closure get!(_ϕ°_s_cache, key) do
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

"""
Takes the common or IUPAC name of a solute (resolved via
[`_resolve_solute_name`](@ref), which is case-insensitive) and returns
(electron count, pmv, uncertainty).
"""
ϕ°(name::AbstractString)::Tuple{Int64,Float64,Float64} =
    _ϕ°_by_iupac_name(_resolve_solute_name(name))

# ---------------------------------------------------------------------------
#   DNA and RNA
# ---------------------------------------------------------------------------

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
    σ_pH::Real = 0.0,
)::Tuple{Int64,Float64,Float64}

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
    σ_pH::Real = 0.0,
)::Tuple{Int64,Float64,Float64}

    if isempty(seq)
        throw(ArgumentError("Sequence is empty!"))
    end

    cache = isDNA ? _ϕ°_d_cache : _ϕ°_r_cache
    key = (String(seq), Float64(pH), Float64(σ_pH))

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
