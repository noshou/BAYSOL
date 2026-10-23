# SPDX-License-Identifier: LGPL-3.0-or-later

"Fractional uncertainty given to a fixed
polymer grade whose table row states none."
const POLYMER_UNKNOWN_REL_UNC = 0.02

""" lowercase name => (electron count, ϕ°, uncertainty)
of the fixed polymer grades; a grade without a stated
uncertainty gets `POLYMER_UNKNOWN_REL_UNC·ϕ°` """
const _polymers::Dict{String,Tuple{Int64,Float64,Float64}} = Dict(
    k => (
        z,
        v,
        u === nothing ? POLYMER_UNKNOWN_REL_UNC * abs(v) : u,
    ) for (k, (z, v, u)) in
    JSON3.read(
        read(joinpath(@__DIR__, "polymers.json"), String),
        Dict{String,Tuple{Int64,Float64,Union{Float64,Nothing}}},
    )
)

""" alias => target name, the polymer counterpart of `NONBIO_LOOKUP` """
const POLYMER_LOOKUP::Dict{String,String} = JSON3.read(
    read(joinpath(@__DIR__, "polymers_lookup.json"), String),
    Dict{String,String},
)

"""
`(Z, ϕ°, σ)` of a fixed polymer grade (via
`POLYMER_LOOKUP`, case-insensitive), or `nothing`.
"""
function _polymer_table_ϕ°(name::AbstractString)
    s = lowercase(String(name))
    key = lowercase(get(POLYMER_LOOKUP, s, s))
    return get(_polymers, key, nothing)
end

"""
Line `v0 + slope·m` of a homopolymer with `m` repeat units
(real, a mean) and `Z = z_unit·m + 10` electrons (the 10 are
the two end groups, H and OH): `(Z, ϕ°, σ)`, `σ = rel·ϕ°`.

# Exceptions
`ArgumentError` for `m < m_min`: the shortest
oligomers are single solutes of `NonBiological`.
"""
function _chain_ϕ°(what::AbstractString, m::Real, v0, slope, z_unit, rel; m_min = 2)
    m >= m_min || throw(ArgumentError("$what with $m units: too short, see NonBiological"))
    v = v0 + slope * m
    return (round(Int64, z_unit * m + 10), v, rel * v)
end

"PEG, H(OCH₂CH₂)ₘOH; `Z = 24m + 10`. See [`PEG_V0_INTERCEPT`](@ref)."
_peg_ϕ°(m::Real) =
    _chain_ϕ°("PEG", m, PEG_V0_INTERCEPT, PEG_V0_PER_UNIT, 24, PEG_V0_REL_UNC)

"PPG, H(OC₃H₆)ₘOH; `Z = 32m + 10`. See [`PPG_V0_INTERCEPT`](@ref)."
_ppg_ϕ°(m::Real) =
    _chain_ϕ°("PPG", m, PPG_V0_INTERCEPT, PPG_V0_PER_UNIT, 32, PPG_V0_REL_UNC)

"""
Dextran of `m` anhydroglucose units; `Z = 86m + 10`. The measured slope
[`DEXTRAN_V0_PER_UNIT`](@ref) replaces the maltooligosaccharide slope of the α-glucan line.
"""
_dextran_ϕ°(m::Real) = _chain_ϕ°(
    "dextran", m, GLUCAN_V0_INTERCEPT, DEXTRAN_V0_PER_UNIT, 86, DEXTRAN_V0_REL_UNC,
)

"α-glucan of `m` anhydroglucose units; `Z = 86m + 10`. See [`GLUCAN_V0_INTERCEPT`](@ref)."
_glucan_ϕ°(m::Real) =
    _chain_ϕ°("glucan", m, GLUCAN_V0_INTERCEPT, GLUCAN_V0_PER_UNIT, 86, GLUCAN_V0_REL_UNC)

"""
UCON 50-HB copolymer (random EO/PO, equal masses of
the two, butanol-started) of mean molar mass `Mn` g/mol, C₄H₉(OR)ₙOH:
`(Z, ϕ°, σ)`, `ϕ° = UCON_STARTER_V0 + PLURONIC_EO_V0·nEO + PLURONIC_PO_V0·nPO`
with `nEO` and `nPO` from [`UCON_EO_MASS_FRACTION`](@ref), `Z = 42 + 24 nEO +
32 nPO`; `σ` adds `UCON_STARTER_UNC` and `PLURONIC_REL_UNC·ϕ°` in quadrature. Only the
Pluronic increments are measured; a random sequence is assumed to add like blocks.

# Exceptions
`ArgumentError` unless the chain holds at least one EO and one PO unit.
"""
function _ucon_ϕ°(Mn::Real)::Tuple{Int64,Float64,Float64}
    m_ox = Mn - UCON_STARTER_MOLAR_MASS
    n_EO = UCON_EO_MASS_FRACTION * m_ox / EO_MOLAR_MASS
    n_PO = (1 - UCON_EO_MASS_FRACTION) * m_ox / PO_MOLAR_MASS
    (n_EO >= 1 && n_PO >= 1) ||
        throw(
            ArgumentError(
                "UCON with Mn = $Mn g/mol holds fewer than one EO and one PO unit",
            ),
        )
    v = UCON_STARTER_V0 + PLURONIC_EO_V0 * n_EO + PLURONIC_PO_V0 * n_PO
    σ = hypot(PLURONIC_REL_UNC * v, UCON_STARTER_UNC)
    return (round(Int64, UCON_STARTER_Z + 24n_EO + 32n_PO), v, σ)
end

"""
Cyclodextrin of `n` anhydroglucose units (6, 7, 8 for α, β, γ), no end groups: `ϕ° =
CYCLODEXTRIN_V0_PER_UNIT·n`, `Z = 86n`.

# Exceptions
`ArgumentError` for `n < 5`.
"""
function _cyclodextrin_ϕ°(n::Real)::Tuple{Int64,Float64,Float64}
    n >= 5 || throw(ArgumentError("cyclodextrin with $n glucose units"))
    v = CYCLODEXTRIN_V0_PER_UNIT * n
    return (round(Int64, 86n), v, CYCLODEXTRIN_V0_REL_UNC * v)
end

"""
Pluronic (poloxamer) with `n_EO` ethylene oxide and `n_PO` propylene oxide units in total
(both PEO blocks together), H(OCH₂CH₂)ₐ(OCH(CH₃)CH₂)_b(OCH₂CH₂)ₐOH: `(Z, ϕ°, σ)` with
`ϕ° = PLURONIC_EO_V0·n_EO + PLURONIC_PO_V0·n_PO + PLURONIC_END_V0` and
`Z = 24 n_EO + 32 n_PO + 10`. `σ` adds `PLURONIC_END_UNC` and `PLURONIC_REL_UNC·ϕ°` in
quadrature.

# Exceptions
`ArgumentError` unless `n_EO ≥ 0` and `n_PO ≥ 1`.
"""
function _pluronic_ϕ°(n_EO::Real, n_PO::Real)::Tuple{Int64,Float64,Float64}
    (n_EO >= 0 && n_PO >= 1) ||
        throw(ArgumentError("Pluronic needs n_EO ≥ 0 and n_PO ≥ 1, got $n_EO, $n_PO"))
    v = PLURONIC_EO_V0 * n_EO + PLURONIC_PO_V0 * n_PO + PLURONIC_END_V0
    σ = hypot(PLURONIC_REL_UNC * v, PLURONIC_END_UNC)
    return (round(Int64, 24n_EO + 32n_PO + 10), v, σ)
end

"""
Octylphenol ethoxylate (Triton X series), C₈H₁₇C₆H₄O(CH₂CH₂O)ₙH
with `n` ethylene oxide units (9.5 for X-100, 7.5 for X-114),
micellar state: `(Z, ϕ°, σ)`, `ϕ° = TRITON_V0_BASE + PLURONIC_EO_V0·n`,
`Z = 114 + 24n`.

# Exceptions
`ArgumentError` for `n < 1`.
"""
function _triton_ϕ°(n::Real)::Tuple{Int64,Float64,Float64}
    n >= 1 || throw(ArgumentError("Triton with $n ethylene oxide units"))
    v = TRITON_V0_BASE + PLURONIC_EO_V0 * n
    return (round(Int64, 114 + 24n), v, TRITON_V0_REL_UNC * v)
end

"""
Alkyl ethoxylate (Brij, C₁₂E₈ ...) with `n` carbons in the alkyl
chain and `m` ethylene oxide units, H(CH₂)ₙ(OCH₂CH₂)ₘOH: `(Z, ϕ°, σ)`,
`Z = 8n + 24m + 10`. See [`ALKYL_ETHOXYLATE_V0_BASE`](@ref).

# Exceptions
`ArgumentError` unless `n ≥ 1` and `m ≥ 1`.
"""
function _alkyl_ethoxylate_ϕ°(n::Real, m::Real)::Tuple{Int64,Float64,Float64}
    (n >= 1 && m >= 1) ||
        throw(ArgumentError("alkyl ethoxylate needs nC ≥ 1, nEO ≥ 1, got $n, $m"))
    v = ALKYL_ETHOXYLATE_V0_BASE + ALKYL_ETHOXYLATE_V0_PER_CH2 * n + PLURONIC_EO_V0 * m
    return (round(Int64, 8n + 24m + 10), v, ALKYL_ETHOXYLATE_V0_REL_UNC * v)
end

"""
n-Alkyl β-D-maltoside (decyl, dodecyl ... maltoside)
with an `n`-carbon chain, monomer (infinite dilution,
not micellar): `(Z, ϕ°, σ)`, `ϕ° = MALTOSIDE_V0_BASE +
ALKYL_ETHOXYLATE_V0_PER_CH2·n`, `Z = 8n + 182` (C₂₂H₄₂O₁₁ for n = 10),
`σ` the decyl estimate [`MALTOSIDE_V0_UNC`](@ref) and
[`MALTOSIDE_V0_PER_CH2_UNC`](@ref) per CH₂ away from it, in quadrature.

# Exceptions
`ArgumentError` for `n < 1`.
"""
function _maltoside_ϕ°(n::Real)::Tuple{Int64,Float64,Float64}
    n >= 1 || throw(ArgumentError("alkyl maltoside with $n carbons"))
    v = MALTOSIDE_V0_BASE + ALKYL_ETHOXYLATE_V0_PER_CH2 * n
    σ = hypot(
        MALTOSIDE_V0_UNC,
        MALTOSIDE_V0_PER_CH2_UNC * (n - MALTOSIDE_REFERENCE_CARBONS),
    )
    return (round(Int64, 8n + 182), v, σ)
end

"""
LMNG-type detergent (two maltosides on a neopentyl glycol core,
`n` carbons in each of the two chains as drawn: 10 for LMNG,
C₄₇H₈₈O₂₂), monomer: `(Z, ϕ°, σ)`, `ϕ° = LMNG_V0_BASE +
2·ALKYL_ETHOXYLATE_V0_PER_CH2·n`, `Z = 16n + 386`.

# Exceptions
`ArgumentError` for `n < 1`.
"""
function _lmng_ϕ°(n::Real)::Tuple{Int64,Float64,Float64}
    n >= 1 || throw(ArgumentError("LMNG-type detergent with $n carbons per chain"))
    v = LMNG_V0_BASE + 2ALKYL_ETHOXYLATE_V0_PER_CH2 * n
    σ = hypot(
        LMNG_V0_UNC,
        2MALTOSIDE_V0_PER_CH2_UNC * (n - MALTOSIDE_REFERENCE_CARBONS),
    )
    return (round(Int64, 16n + 386), v, σ)
end

# ---------------------------------------------------------------------------
#   Peptides
# ---------------------------------------------------------------------------

"Acyl (N-side) and free (C-terminal) residue names of
the 20 amino acids -> one-letter code."
const _PEPTIDE_ACYL = Dict(
    "GLYCYL"       => 'G',
    "ALANYL"       => 'A',
    "VALYL"        => 'V',
    "LEUCYL"       => 'L',
    "ISOLEUCYL"    => 'I',
    "SERYL"        => 'S',
    "THREONYL"     => 'T',
    "CYSTEINYL"    => 'C',
    "METHIONYL"    => 'M',
    "PROLYL"       => 'P',
    "PHENYLALANYL" => 'F',
    "TYROSYL"      => 'Y',
    "TRYPTOPHYL"   => 'W',
    "ASPARTYL"     => 'D',
    "GLUTAMYL"     => 'E',
    "ASPARAGINYL"  => 'N',
    "GLUTAMINYL"   => 'Q',
    "LYSYL"        => 'K',
    "ARGINYL"      => 'R',
    "HISTIDYL"     => 'H',
)
const _PEPTIDE_FREE = Dict(
    "GLYCINE"       => 'G',
    "ALANINE"       => 'A',
    "VALINE"        => 'V',
    "LEUCINE"       => 'L',
    "ISOLEUCINE"    => 'I',
    "SERINE"        => 'S',
    "THREONINE"     => 'T',
    "CYSTEINE"      => 'C',
    "METHIONINE"    => 'M',
    "PROLINE"       => 'P',
    "PHENYLALANINE" => 'F',
    "TYROSINE"      => 'Y',
    "TRYPTOPHAN"    => 'W',
    "ASPARTICACID"  => 'D',
    "GLUTAMICACID"  => 'E',
    "ASPARAGINE"    => 'N',
    "GLUTAMINE"     => 'Q',
    "LYSINE"        => 'K',
    "ARGININE"      => 'R',
    "HISTIDINE"     => 'H',
)
const _PEPTIDE_COUNT = Dict(
    "DI"    => 2,
    "TRI"   => 3,
    "TETRA" => 4,
    "PENTA" => 5,
    "HEXA"  => 6,
    "HEPTA" => 7,
    "OCTA"  => 8,
    "NONA"  => 9,
    "DECA"  => 10,
)

"""
One-letter sequence (at least two residues) named by `s`: `PEPTIDE<SEQ>`
(`peptide GAG`), a counted residue (`tetraalanine`) or an acyl chain
(`glycylleucylglycine`, `glycyl-α-aspartylglycine`), or `nothing`.
Names with a charge marker or a γ/ε-linkage are not recognised, they
stay fixed grades.
"""
function _peptide_sequence(s::AbstractString)::Union{Nothing,String}
    m = match(r"^PEPTIDE([ACDEFGHIKLMNPQRSTVWY]{2,})$", s)
    m === nothing || return String(m[1])
    m = match(r"^(DI|TRI|TETRA|PENTA|HEXA|HEPTA|OCTA|NONA|DECA)([A-Z]+)$", s)
    if m !== nothing && haskey(_PEPTIDE_FREE, m[2])
        return repeat(string(_PEPTIDE_FREE[m[2]]), _PEPTIDE_COUNT[m[1]])
    end
    acyl = join(sort(collect(keys(_PEPTIDE_ACYL)); by = length, rev = true), "|")
    free = join(sort(collect(keys(_PEPTIDE_FREE)); by = length, rev = true), "|")
    m = match(Regex("^((?:$acyl)+)($free)\$"), s)
    m === nothing && return nothing
    seq = [_PEPTIDE_ACYL[t.match] for t in eachmatch(Regex(acyl), m[1])]
    push!(seq, _PEPTIDE_FREE[m[2]])
    return String(seq)
end

"""
Peptide of one-letter sequence `seq` (two or more residues)
at `pH`: `(Z, ϕ°, σ)`. The protein backbone/side-chain scheme
[`ϕ°(::Real, ::AbstractString)`](@ref) gives the zwitterion with its
side chains titrated; the two termini are titrated on top (carboxyl, pKa 3.3, +10.5 on
protonation; amine, pKa 8.0, +4.8 on deprotonation). Peptides of at most
`PEPTIDE_SHORT_MAX_RESIDUES` residues get `PEPTIDE_SHORT_UNC` added in quadrature.

# Exceptions
`ArgumentError` for fewer than two residues or an unknown residue letter.
"""
function _peptide_ϕ°(
    seq::AbstractString,
    pH::Real,
    σ_pH::Real,
)::Tuple{Int64,Float64,Float64}
    length(seq) >= 2 || throw(ArgumentError("a peptide has at least two residues: $seq"))
    z, v, σ = ϕ°(pH, seq; σ_pH)
    f_c = 1 / (1 + 10.0^(pH - PEPTIDE_COOH_PKA)) # fraction with the carboxyl protonated
    f_n = 1 / (1 + 10.0^(PEPTIDE_NH2_PKA - pH))  # fraction with the amine deprotonated
    v += PEPTIDE_COOH_DV * f_c - PEPTIDE_NH2_DV * f_n
    dv_dpH = (
        log(10)
        * (-PEPTIDE_COOH_DV * f_c * (1 - f_c)
         - PEPTIDE_NH2_DV * f_n * (1 - f_n))
    )
    var = (
        σ^2
        + (PEPTIDE_COOH_DV_UNC * f_c)^2
        + (PEPTIDE_NH2_DV_UNC * f_n)^2
        + (dv_dpH * σ_pH)^2
    )
    length(seq) <= PEPTIDE_SHORT_MAX_RESIDUES && (var += PEPTIDE_SHORT_UNC^2)
    return (z, v, sqrt(var))
end

# ---------------------------------------------------------------------------
#   Entry point
# ---------------------------------------------------------------------------

"""
`(Z, ϕ°, σ)` for a polymer given by a parametric family, or `nothing` if `name` is not one.
Case, spaces, dashes, underscores, commas, parentheses and α are ignored. Recognised:

-   `PEG-400`, `PEG 3350`, `poly(ethylene glycol) 1000`, `PPG 2000`: the
    number is the mean molar mass Mn in g/mol (n = (Mn − 18.015)/44.053
    or /58.079 units); `PEG n=22`, `PPG n=10`: the number of repeat units
    (at least 2: the glycols below that are `NonBiological` solutes);
-   `dextran 40000`, `dextran 40` (below 1000 means kDa), `dextran n=250` (measured
    dextran slope), `pullulan 100000`, `glucan n=250` (maltooligosaccharide slope):
    the mean molar mass or the number of anhydroglucose units;
-   `UCON 3930`, `UCON Mn=3930` (50-HB random EO/PO copolymers):
    the mean molar mass; a grade name such as `UCON 50-HB-5100`
    carries a viscosity, not a molar mass, so it is not recognised;
-   `cyclodextrin n=7`: the number of glucose units;
-   `Pluronic nEO=150 nPO=30` (also `poloxamer`, either order of the two inputs): the total
    numbers of ethylene oxide and propylene oxide units, e.g. 2·75 = 150 and 30 for F68;
-   `Triton nEO=9.5` (octylphenol ethoxylate);
-   `C12E23` or `Brij nC=12 nEO=23` (also `alkyl ethoxylate nC=.. nEO=..`): alkyl chain
    length and ethylene oxide units (Brij 35 = C12E23, Brij 58 = C16E20, C12E8 ...);
-   `maltoside nC=10` (also `alkyl maltoside nC=..`): n-alkyl maltoside
    monomer with `nC` carbons in the chain (decyl 10, dodecyl 12);
    `LMNG nC=10` (also `MNG nC=..`): neopentyl glycol maltoside with `nC`
    carbons in each of its two chains (LMNG 10). Monomer values, not micellar;
-   a peptide: `peptide GAG`, `tetraalanine`,
    `glycylleucylglycine`; its termini follow `pH`.

# Exceptions
`ArgumentError` from the family functions for out-of-range inputs.
"""
function _polymer_family_ϕ°(name::AbstractString, pH::Real = 7.0, σ_pH::Real = 0.0)
    s = uppercase(replace(strip(String(name)), r"[\s_\-(),α]+" => ""))
    num = raw"(\d+(?:\.\d+)?)"
    rx(pre, post = "") = Regex("^(?:$pre)$post$num\$")
    peg = "PEG|POLYETHYLENEGLYCOL|POLYETHYLENEOXIDE|PEO"
    ppg = "PPG|POLYPROPYLENEGLYCOL"
    glu = "PULLULAN|GLUCAN"
    m = match(rx(peg, "N="), s)
    m === nothing || return _peg_ϕ°(parse(Float64, m[1]))
    m = match(rx(peg), s)
    m === nothing ||
        return _peg_ϕ°((parse(Float64, m[1]) - WATER_MOLAR_MASS) / EO_MOLAR_MASS)
    m = match(rx(ppg, "N="), s)
    m === nothing || return _ppg_ϕ°(parse(Float64, m[1]))
    m = match(rx(ppg), s)
    m === nothing ||
        return _ppg_ϕ°((parse(Float64, m[1]) - WATER_MOLAR_MASS) / PO_MOLAR_MASS)
    m = match(rx("DEXTRAN", "N="), s)
    m === nothing || return _dextran_ϕ°(parse(Float64, m[1]))
    m = match(rx("DEXTRAN"), s)
    if m !== nothing
        Mn = parse(Float64, m[1])
        Mn < 1000 && (Mn *= 1000)       # "dextran 40" = 40 kDa
        return _dextran_ϕ°((Mn - WATER_MOLAR_MASS) / GLUCOSE_UNIT_MOLAR_MASS)
    end
    m = match(rx("UCON", "MN="), s)
    m === nothing || return _ucon_ϕ°(parse(Float64, m[1]))
    m = match(rx("UCON"), s)
    m === nothing || return _ucon_ϕ°(parse(Float64, m[1]))
    m = match(rx(glu, "N="), s)
    m === nothing || return _glucan_ϕ°(parse(Float64, m[1]))
    m = match(rx(glu), s)
    if m !== nothing
        Mn = parse(Float64, m[1])
        Mn < 1000 && (Mn *= 1000)       # "dextran 40" = 40 kDa
        return _glucan_ϕ°((Mn - WATER_MOLAR_MASS) / GLUCOSE_UNIT_MOLAR_MASS)
    end
    m = match(rx("CYCLODEXTRIN", "N="), s)
    m === nothing || return _cyclodextrin_ϕ°(parse(Float64, m[1]))
    m = match(rx("TRITON|OCTYLPHENOLETHOXYLATE", "NEO="), s)
    m === nothing || return _triton_ϕ°(parse(Float64, m[1]))
    m = match(r"^C(\d+)E(\d+)$", s)
    m === nothing || return _alkyl_ethoxylate_ϕ°(parse(Int, m[1]), parse(Int, m[2]))
    m = match(Regex("^(?:BRIJ|ALKYLETHOXYLATE|CE)NC=$num" * "NEO=$num\$"), s)
    m === nothing || return _alkyl_ethoxylate_ϕ°(parse(Float64, m[1]), parse(Float64, m[2]))
    m = match(Regex("^(?:ALKYL)?MALTOSIDENC=$num\$"), s)
    m === nothing || return _maltoside_ϕ°(parse(Float64, m[1]))
    m = match(Regex("^(?:LMNG|MNG)NC=$num\$"), s)
    m === nothing || return _lmng_ϕ°(parse(Float64, m[1]))
    pre = "^(?:PLURONIC|POLOXAMER)"
    m = match(Regex(pre * "NEO=$num" * "NPO=$num\$"), s)
    m === nothing || return _pluronic_ϕ°(parse(Float64, m[1]), parse(Float64, m[2]))
    m = match(Regex(pre * "NPO=$num" * "NEO=$num\$"), s)
    m === nothing || return _pluronic_ϕ°(parse(Float64, m[2]), parse(Float64, m[1]))
    seq = _peptide_sequence(s)
    seq === nothing || return _peptide_ϕ°(seq, pH, σ_pH)
    return nothing
end

"""
`(Z, ϕ°, σ)` of a [`Polymer`](@ref) solute named `name` at `pH`: a parametric family first
([`_polymer_family_ϕ°`](@ref)), then the fixed grades of `polymers.json` through
`POLYMER_LOOKUP`.

# Exceptions
`ArgumentError` for an unknown polymer or an out-of-range family input.
"""
function _polymer_ϕ°(name::AbstractString, pH::Real = 7.0, σ_pH::Real = 0.0)
    fam = _polymer_family_ϕ°(name, pH, σ_pH)
    fam === nothing || return fam
    grade = _polymer_table_ϕ°(name)
    grade === nothing && throw(ArgumentError("unknown polymer: $name"))
    return grade
end
