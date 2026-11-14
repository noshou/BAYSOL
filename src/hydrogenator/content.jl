# SPDX-License-Identifier: LGPL-3.0-or-later

# What a structure contains (protein, nucleic acid, both) and the hydrogenation that
# follows from it; and a diagnostic of what pdb2pqr leaves out for modified nucleotides.

"""
The `(chain, number with insertion code)` key of the residue of an ATOM/HETATM `line`,
columns 22 and 23-27, stripped: pdb2pqr and some writers differ in how they align the
number, and a blank chain id is `""`.
"""
_residueKey(line::AbstractString) =
    (String(strip(SubString(line, 22, 22))), String(strip(SubString(line, 23, 27))))

"""
The residues of the ATOM/HETATM records of the .pdb at `path`, by text scan (columns 18-20
name, 22 chain, 23-27 number and insertion code, 13-16 atom name), in order of first
appearance, waters left out. Atom names have the old `*` normalized to `'`.

# Returns
A vector of `(; key, name, atoms)`: `key` is `(chain, number)`, `atoms` the set of names.
"""
function _scanResidues(path::AbstractString)
    order = Tuple{String,String}[]
    res = NamedTuple{(:name, :atoms),Tuple{String,Set{String}}}
    found = Dict{Tuple{String,String},res}()
    for line in eachline(path)
        (startswith(line, "ATOM") || startswith(line, "HETATM")) || continue
        length(line) >= 27 || continue
        name = uppercase(strip(SubString(line, 18, 20)))
        name in WATER_NAMES && continue
        key = _residueKey(line)
        r = get!(found, key) do
            push!(order, key)
            (; name, atoms = Set{String}())
        end
        push!(r.atoms, replace(String(strip(SubString(line, 13, 16))), '*' => '\''))
    end
    return [(; key = k, found[k]...) for k in order]
end

"The number of sugar-phosphate backbone atoms ([`BACKBONE_ATOMS`](@ref)) in `atoms`."
_backboneCount(atoms) = count(in(atoms), BACKBONE_ATOMS)

"""
Residue names the backbone-atom test may reclassify: those the dictionary does not know
(`type` `"unknown"`) and the names of [`NUCLEIC_NAME_CLASH`](@ref).
"""
_backboneCandidate(i) = i.type == "unknown" || i.id in NUCLEIC_NAME_CLASH

"""
Whether a residue is a nucleotide: its component is DNA or RNA, or it is a
[`_backboneCandidate`](@ref) that carries at least [`BACKBONE_MIN`](@ref) backbone atoms.
A name that cannot be looked up (`ComponentError`) is not a nucleotide here.
"""
function _isNucleicResidue(name::AbstractString, atoms)::Bool
    info = try
        component(name)
    catch e
        e isa ComponentError || rethrow()
        return false
    end
    info.class in (:dna, :rna) && return true
    return _backboneCandidate(info) && _backboneCount(atoms) >= BACKBONE_MIN
end

"""
    hydrogenationChoice(infos, path = nothing) -> NamedTuple

The force field and titration method the residue content of a structure calls for, from the
[`component`](@ref BAYSOL.MolecularStructure.component) records of its residue names
(`MolecularStructure.residueNames`):

| content                       | `content`  | `ff`     | `titration`            |
|:------------------------------|:-----------|:---------|:-----------------------|
| amino acids only, or neither  | `:protein` | `:parse` | [`Propka`](@ref)       |
| DNA/RNA only                  | `:nucleic` | `:amber` | [`NoTitration`](@ref)  |
| both                          | `:mixed`   | `:parse` | [`Propka`](@ref)       |

pdb2pqr's `--pdb-output`, the only output BAYSOL reads, places the same hydrogens under
PARSE and AMBER, so the choice is about robustness, not chemistry: the terminus flags
`--neutraln`/`--neutralc` exist only with PARSE (AMBER exits with an error), which protein
and mixed files need; and PARSE is not one-to-one on chimeras such as 246D, so a nucleic
acid alone gets [`NUCLEIC_FORCE_FIELD`](@ref). PROPKA has no nucleotide model and the
hydrogens of nucleic acids do not depend on pH, so a nucleic acid alone runs no PROPKA. A
residue is an amino acid when the dictionary type names a peptide (`l-peptide linking`,
...) and a nucleotide when its class is `:dna` or `:rna` (this includes the Amber names of
[`AMBER_NUCLEIC_NAMES`](@ref BAYSOL.MolecularStructure.AMBER_NUCLEIC_NAMES), `RG`,
`DA5`, ...).

With `path`, the .pdb the names come from, the legacy ids of the bases ADE GUA CYT URI THY
([`LEGACY_NUCLEOTIDE_NAMES`](@ref BAYSOL.MolecularStructure.LEGACY_NUCLEOTIDE_NAMES))
count as nucleotides for the residues that carry the sugar-phosphate backbone
(`legacyNucleotidesInFile`), and there is a safety net for a nucleic acid under
names nobody knows: if no component is nucleic, the residues whose names are unknown to the
dictionary (and `RU`, which is ruthenium in it) are tested by their atoms, and one with at
least [`BACKBONE_MIN`](@ref) of the sugar-phosphate [`BACKBONE_ATOMS`](@ref) is taken as a
nucleotide; `reason` then names it.

# Returns
`(; content, ff, titration, reason)`: `content` as in the table, `ff` a
[`FORCE_FIELDS`](@ref) entry, `titration` `:propka` or `:none`, and `reason` the empty
string or the safety net's finding.
"""
function hydrogenationChoice(infos, path::Union{Nothing,AbstractString} = nothing)
    isPeptide(i) = occursin("peptide", i.type) && !occursin("peptide-like", i.type)
    protein = any(isPeptide, infos)
    nucleic = any(i -> i.class in (:dna, :rna), infos)
    reason = ""
    # legacy-named nucleotides (ADE GUA CYT URI THY) need their atoms to be told from
    # free-base ligands
    legacy = path === nothing ? nothing : legacyNucleotidesInFile(path)
    if legacy !== nothing && !isempty(legacy)
        nucleic = true
        names = sort!(unique(v.name for v in values(legacy)))
        reason =
            "$(length(legacy)) legacy-named nucleotide residues (" *
            join(names, ", ") * ")"
    end
    if path !== nothing
        nPlain = length(plainLetterDna(path))
        nPlain > 0 && (
            reason *=
                (isempty(reason) ? "" : "; ") *
                "$nPlain plain-letter DNA residues relabelled"
        )
    end
    if !nucleic && path !== nothing
        candidates = Set(i.id for i in infos if _backboneCandidate(i))
        if !isempty(candidates)
            hits = String[]
            for r in _scanResidues(path)
                r.name in candidates && _backboneCount(r.atoms) >= BACKBONE_MIN &&
                    !(r.name in hits) && push!(hits, r.name)
            end
            if !isempty(hits)
                nucleic = true
                reason = "backbone atoms in unknown residue(s) " * join(hits, ", ")
            end
        end
    end
    ff = DEFAULT_FORCE_FIELD
    nucleic || return (; content = :protein, ff, titration = :propka, reason)
    protein ||
        return (; content = :nucleic, ff = NUCLEIC_FORCE_FIELD, titration = :none, reason)
    return (; content = :mixed, ff, titration = :propka, reason)
end

"""
Whether `i`, a [`component`](@ref BAYSOL.MolecularStructure.component) record, is a
**modified** nucleotide: DNA/RNA whose id is neither a wwPDB standard id
([`STANDARD_NUCLEOTIDES`](@ref BAYSOL.MolecularStructure.STANDARD_NUCLEOTIDES)) nor an Amber
name. Whether the dictionary declares a parent for it does not matter.
"""
_isModified(i) =
    i.class in (:dna, :rna) && !(i.id in STANDARD_NUCLEOTIDES) &&
    !haskey(AMBER_NUCLEIC_NAMES, i.id)

"Whether any record of `infos` is a modified nucleotide (see [`_isModified`](@ref))."
hasModifiedNucleotides(infos) = any(_isModified, infos)

"""
Guard run after every pdb2pqr run: every nucleotide residue of the input `inPath` must have
atoms in the output `outPath`. A force field without nucleotide parameters does not fail,
it writes nothing for them (PARSE on DNA: zero atoms), and the structure would lose its
nucleic acid without a word. A text scan of both files; protein-only files pass untouched.

# Exceptions
- `Pdb2pqrError`: a nucleotide residue of the input is absent from the output; the message
    names (some of) them and the force field `ff`.
"""
function _checkNucleotidesKept(
    inPath::AbstractString, outPath::AbstractString, ff::Symbol,
)
    legacy = legacyNucleotidesInFile(inPath)
    ckey(r) = r.key
    lost = [
        r for r in _scanResidues(inPath)
        if _isNucleicResidue(r.name, r.atoms) || haskey(legacy, ckey(r))
    ]
    isempty(lost) && return nothing
    # a blank chain id of the input comes back named by pdb2pqr: match on the number then
    kept = Set(r.key for r in _scanResidues(outPath))
    union!(kept, (("", k[2]) for k in collect(kept)))
    lost = [r for r in lost if !(r.key in kept)]
    isempty(lost) && return nothing
    label(r) = "$(r.name) $(strip(r.key[1]))$(strip(r.key[2]))"
    shown = join(label.(first(lost, 8)), ", ")
    more = length(lost) > 8 ? " and $(length(lost) - 8) more" : ""
    throw(
        Pdb2pqrError(
            "pdb2pqr (--ff $(uppercase(String(ff)))) wrote no atom for $(length(lost)) " *
            "nucleotide residue(s) of \"$inPath\": $shown$more; they would be lost " *
            "from the structure",
        ),
    )
end

"""
    modifiedHydrogenDeficit(path, infos) -> NamedTuple

What the hydrogenation did for the **modified** nucleotides of the hydrogenated .pdb at
`path`: a diagnostic for the timing log, the structure is not changed.

The modified nucleotides (`PSU`, `5MC`, `2MG`, ..., HETATM records) are hydrogenated
through their base ([`relabelModified`](@ref)): pdb2pqr places the hydrogens of the
standard residue the base stands for, so the hydrogens that exist only in the modification
(a methyl's) are not placed, and a modified residue with no known base gets none. This
counts, over the residues of `path` whose name is a modified nucleotide of `infos` (the
[`component`](@ref BAYSOL.MolecularStructure.component) records of the structure's residue
names, see [`_isModified`](@ref)), the hydrogens in the file and, to compare, the
hydrogens of the component formulas (`n_hydrogens` of the free monomer: an approximation,
an upper bound, since a residue in a chain has lost the hydrogens of its links).

# Returns
`(; residues, withBase, noBase, expected, placed)`: the modified residues, how many of
them have a known `base` (and were hydrogenated through it), how many have none, the
hydrogens their formulas carry and the hydrogens the file has on them.

# Exceptions
- `SystemError`: `path` cannot be read.
"""
function modifiedHydrogenDeficit(path::AbstractString, infos)
    modified = Dict(i.id => i for i in infos if _isModified(i))
    residues = Dict{Tuple{String,String,String},Int}()   # (name, chain, number) => H
    for line in eachline(path)
        (startswith(line, "ATOM") || startswith(line, "HETATM")) || continue
        length(line) >= 54 || continue
        name = uppercase(strip(SubString(line, 18, 20)))
        haskey(modified, name) || continue
        key = (name, _residueKey(line)...)
        element = length(line) >= 78 ? strip(SubString(line, 77, 78)) : ""
        atomname = strip(SubString(line, 13, 16))
        isH = element in ("H", "D") || (isempty(element) && startswith(atomname, r"[HD]"))
        residues[key] = get(residues, key, 0) + isH
    end
    expected = sum((modified[k[1]].n_hydrogens for k in keys(residues)); init = 0)
    withBase = count(k -> modified[k[1]].base !== nothing, keys(residues))
    return (;
        residues = length(residues), withBase, noBase = length(residues) - withBase,
        expected, placed = sum(values(residues); init = 0),
    )
end

"Whether any record of `infos` is a modified amino acid (see [`_isModifiedAmino`](@ref))."
hasModifiedAmino(infos) = any(_isModifiedAmino, infos)

"""
    modedAaHyd(path, infos) -> NamedTuple

What the hydrogenation did for the **modified amino acids** (`MSE`, `SEP`, ..., HETATM or
ATOM records) of the hydrogenated .pdb at `path`, a diagnostic for the timing log. They are
hydrogenated through their standard parent ([`relabelModified`](@ref)): pdb2pqr places the
hydrogens of the parent (`MET` for `MSE`), when the residue has every heavy atom of it
([`STANDARD_AMINO_ATOMS`](@ref)), so the hydrogens that exist only in the
modification (a phosphate's, a methyl's) are not placed, and a residue with no known parent,
or a D amino acid ([`_aminoRunAs`](@ref)), gets none.

# Returns
`(; residues, withParent, noParent, placed)`: the modified amino acid residues of the file
(names in `infos`), how many have a standard parent, how many have none, and the hydrogens
the file has on them.

# Exceptions
- `SystemError`: `path` cannot be read.
"""
function modedAaHyd(path::AbstractString, infos)
    modified = Set(i.id for i in infos if _isModifiedAmino(i))
    residues = Dict{Tuple{String,String,String},Int}()
    for line in eachline(path)
        (startswith(line, "ATOM") || startswith(line, "HETATM")) || continue
        length(line) >= 54 || continue
        name = uppercase(strip(SubString(line, 18, 20)))
        name in modified || continue
        key = (name, _residueKey(line)...)
        element = length(line) >= 78 ? strip(SubString(line, 77, 78)) : ""
        atomname = strip(SubString(line, 13, 16))
        isH = element in ("H", "D") || (isempty(element) && startswith(atomname, r"[HD]"))
        residues[key] = get(residues, key, 0) + isH
    end
    comp = Dict(i.id => i for i in infos if _isModifiedAmino(i))
    atomsOf = Dict(r.key => r.atoms for r in _scanResidues(path))
    withParent = count(keys(residues)) do k
        _runsAsParent(comp[k[1]], get(atomsOf, (k[2], k[3]), Set{String}())) !== nothing
    end
    return (;
        residues = length(residues), withParent,
        noParent = length(residues) - withParent,
        placed = sum(values(residues); init = 0),
    )
end
