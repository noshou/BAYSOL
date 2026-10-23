# SPDX-License-Identifier: LGPL-3.0-or-later

# Modified nucleotides through their base: pdb2pqr only knows the standard residues, so a
# modified one (PSU, 5MC, 2MG, ...) is relabelled to the standard residue of its base for
# the run and given its own name back afterwards.

"""
The name of the standard residue pdb2pqr hydrogenates a modified nucleotide of class
`class` (`:dna` or `:rna`) and natural base `base` (`"A" "C" "G" "U" "T"`) as, or `nothing`.

RNA is `A C G U`, DNA `DA DC DG DT`. The two awkward cases were measured with pdb2pqr
(PARSE): an RNA component whose base is `T` (ribothymidine) is `U`, because RNA has no T
residue and the 5-methyl is only an extra heavy atom (kept, its hydrogens not placed, like
any hydrogen that exists only in a modification); a DNA component whose base is `U` is
`DT`, because pdb2pqr accepts the name `DU` but places no hydrogen on it (1BNA with its
thymines renamed: 0 of 48), while as `DT` the ring hydrogens are placed (the 5-position
hydrogen, which a methyl-less residue has, is the one it cannot place).
"""
function _standard_name(class::Symbol, base::AbstractString)::Union{Nothing,String}
    if class === :rna
        b = base == "T" ? "U" : base
        return b in ("A", "C", "G", "U") ? b : nothing
    elseif class === :dna
        base == "U" && return "DT"
        return base in ("A", "C", "G", "T") ? "D" * base : nothing
    end
    return nothing
end

"""
The residues of the .pdb at `path` that are DNA written with RNA letters: a residue named
`A`, `C`, `G` or `U` (RNA in the dictionary) that has no `O2'` (or `O2*`) atom, and every
residue named `T` (there is no RNA T). pdb2pqr takes the plain letters as RNA and would
add an `O2'` oxygen to each (and place no hydrogen on a `T`).

The decision is per residue, on the atoms of that residue alone: a chain that mixes both
(a DNA residue in an RNA, as in 246D) is relabelled residue by residue, which is right for a
true chimera; the price is that an RNA residue whose `O2'` is missing from the model is
taken for DNA (its chain-mates keep their RNA names). `A C G` become `DA DC DG`, and
`U` and `T` become `DT` (a uracil without `O2'` is the DNA-class U of [`_standard_name`]).

# Returns
`Dict` residue key `(chain, number)` (columns 22 and 23-27, stripped) `=> standard DNA
name`.
"""
function plain_letter_dna(path::AbstractString)
    dna = Dict("A" => "DA", "C" => "DC", "G" => "DG", "U" => "DT", "T" => "DT")
    out = Dict{Tuple{String,String},String}()
    for r in _scan_residues(path)
        haskey(dna, r.name) || continue
        (r.name == "T" || !("O2'" in r.atoms)) && (out[r.key] = dna[r.name])
    end
    return out
end

"The original atom-name field (columns 13-16) and element (77-78) of an aliased atom."
const AliasBack = @NamedTuple{field::String, element::String}

"""
Atoms of a modified amino acid that the parent has under another name: `(parent, atom)
=> name run as`. `MSE` (parent `MET`) has `SE` where `MET` has `SD`, and `SEC` (parent
`CYS`) `SE` for `SG`; pdb2pqr drops an atom it does not know and builds the missing one at
its own, different position (2.4 A from the selenium on SASDH39), so the atom is run as the
parent's and gets its name and element back afterwards.
"""
const AMINO_ATOM_ALIASES = Dict(("MET", "SE") => "SD", ("CYS", "SE") => "SG")

"""
Whether `i`, a [`component`](@ref BAYSOL.MolecularStructure.component) record, is a
**modified amino acid**: a peptide-linking or peptide-terminus component
([`is_amino_acid`](@ref BAYSOL.MolecularStructure.is_amino_acid)) that is neither one
of the twenty standard names
([`STANDARD_AMINO_ACIDS`](@ref BAYSOL.MolecularStructure.STANDARD_AMINO_ACIDS)) nor `UNK`.
"""
_is_modified_amino(i) =
    _is_amino_type(i.type) && !(i.id in STANDARD_AMINO_ACIDS) && i.id != "UNK"

"""
The heavy atoms of the twenty standard amino acids by their PDB names (`OXT` left out), the
atoms a modified amino acid must have to be run as its parent: pdb2pqr invents the heavy
atoms a residue lacks (homoserine `HSE` run as `SER` would get an `OG` of its own), so a
residue that does not have all of its parent's atoms is not run as it.
"""
const STANDARD_AMINO_ATOMS = Dict(
    "ALA" => ("N", "CA", "C", "O", "CB"),
    "ARG" => ("N", "CA", "C", "O", "CB", "CG", "CD", "NE", "CZ", "NH1", "NH2"),
    "ASN" => ("N", "CA", "C", "O", "CB", "CG", "OD1", "ND2"),
    "ASP" => ("N", "CA", "C", "O", "CB", "CG", "OD1", "OD2"),
    "CYS" => ("N", "CA", "C", "O", "CB", "SG"),
    "GLN" => ("N", "CA", "C", "O", "CB", "CG", "CD", "OE1", "NE2"),
    "GLU" => ("N", "CA", "C", "O", "CB", "CG", "CD", "OE1", "OE2"),
    "GLY" => ("N", "CA", "C", "O"),
    "HIS" => ("N", "CA", "C", "O", "CB", "CG", "ND1", "CD2", "CE1", "NE2"),
    "ILE" => ("N", "CA", "C", "O", "CB", "CG1", "CG2", "CD1"),
    "LEU" => ("N", "CA", "C", "O", "CB", "CG", "CD1", "CD2"),
    "LYS" => ("N", "CA", "C", "O", "CB", "CG", "CD", "CE", "NZ"),
    "MET" => ("N", "CA", "C", "O", "CB", "CG", "SD", "CE"),
    "PHE" => ("N", "CA", "C", "O", "CB", "CG", "CD1", "CD2", "CE1", "CE2", "CZ"),
    "PRO" => ("N", "CA", "C", "O", "CB", "CG", "CD"),
    "SER" => ("N", "CA", "C", "O", "CB", "OG"),
    "THR" => ("N", "CA", "C", "O", "CB", "OG1", "CG2"),
    "TRP" => (
        "N", "CA", "C", "O", "CB", "CG", "CD1", "CD2", "NE1", "CE2", "CE3", "CZ2",
        "CZ3",
        "CH2",
    ),
    "TYR" => ("N", "CA", "C", "O", "CB", "CG", "CD1", "CD2", "CE1", "CE2", "CZ", "OH"),
    "VAL" => ("N", "CA", "C", "O", "CB", "CG1", "CG2"),
)

"""
The standard amino acid a modified amino acid `i` is run as in pdb2pqr, or `nothing`: its
parent ([`amino_parent`](@ref BAYSOL.MolecularStructure.amino_parent)), unless it is a **D**
amino acid (the dictionary type starts with `d-`). pdb2pqr places the hydrogens from
internal coordinates of the L form: run as its L parent, a mirrored alanine got its `HA`
0.58 A from its `CB` (2.05 A in the L residue), so a D residue keeps its heavy atoms and
gets no hydrogens, and counts as without a parent.
"""
_amino_run_as(i) = startswith(i.type, "d-") ? nothing : amino_parent(i.id)

"""
The standard amino acid a residue of component `i` with the heavy atom names `atoms` is run
as ([`_amino_run_as`](@ref)), or `nothing` if it lacks one of that parent's heavy atoms
([`STANDARD_AMINO_ATOMS`](@ref); the atoms of [`AMINO_ATOM_ALIASES`](@ref) count under the
parent's name).
"""
function _runs_as_parent(i, atoms)
    parent = _amino_run_as(i)
    parent === nothing && return nothing
    have = Set(get(AMINO_ATOM_ALIASES, (parent, a), a) for a in atoms)
    return all(in(have), STANDARD_AMINO_ATOMS[parent]) ? parent : nothing
end

"""
    relabel_modified(in_path, out_path) -> NamedTuple

Write to `out_path` a copy of the .pdb at `in_path` in which every residue whose component
is a modified nucleotide ([`_is_modified`](@ref)) with a known base, a legacy-named
nucleotide (`legacy_nucleotides_in_file`: `ADE`, `GUA`, ...), or a modified amino acid
with a
known standard parent (`amino_parent`: `MSE` is `MET`), is given the name of the
standard residue of that base ([`_standard_name`](@ref)) and the record type `ATOM`, so that
pdb2pqr hydrogenates it. The other lines are copied unchanged.

# Returns
`(; plan, aliases, no_base, no_parent_amino, renumbered)`: `aliases` maps `(residue key,
atom name as run)` to the original atom-name field and element of the atoms run under a
parent's name ([`AMINO_ATOM_ALIASES`](@ref)), for [`restore_modified!`](@ref);
`no_parent_amino` is the number of modified amino acid residues left as they were for
want of a standard parent; `renumbered` says the atom serials were not all
integers (hybrid-36) and the copy numbers its atoms afresh; `plan` maps the residue key
`(chain, number with insertion code)` to
`(; name, record)`, the original residue name and record type columns, for
[`restore_modified!`](@ref); `no_base` is the number of modified residues left as they were
for want of a base.

# Exceptions
- `SystemError`: a path cannot be read or written.
"""
function relabel_modified(in_path::AbstractString, out_path::AbstractString)
    plan = Dict{Tuple{String,String},NamedTuple{(:name, :record),Tuple{String,String}}}()
    skipped = Set{Tuple{String,String}}()
    skipped_amino = Set{Tuple{String,String}}()
    aliases =
        Dict{Tuple{Tuple{String,String},String},AliasBack}()
    legacy = legacy_nucleotides_in_file(in_path)
    plain = plain_letter_dna(in_path)
    # residue name => (kind, standard name it is run as): kind is `:nucleotide` or
    # `:amino` for a modified residue, `:none` otherwise
    seen = Dict{String,Tuple{Symbol,Union{Nothing,String},Any}}()
    atoms_of = Dict(r.key => r.atoms for r in _scan_residues(in_path))
    # hybrid-36 atom serials (`B0205`, from files of more than 99999 atoms) are not read by
    # pdb2pqr, which does not need them: the copy then numbers its atoms afresh
    renumber = any(
        l ->
            (startswith(l, "ATOM") || startswith(l, "HETATM")) && length(l) >= 11 &&
            tryparse(Int, strip(SubString(l, 7, 11))) === nothing,
        eachline(in_path),
    )
    serial = 0
    open(out_path, "w") do io
        for line in eachline(in_path)
            if renumber && (startswith(line, "ANISOU") || startswith(line, "CONECT"))
                continue   # they refer to the serials
            end
            is_atom = startswith(line, "ATOM") || startswith(line, "HETATM")
            if is_atom && length(line) >= 27
                name = uppercase(strip(SubString(line, 18, 20)))
                kind, new, info = get!(seen, name) do
                    info = try
                        component(name)
                    catch e
                        e isa ComponentError || rethrow()
                        nothing
                    end
                    info === nothing && return (:none, nothing, nothing)
                    if _is_modified_amino(info)
                        return (:amino, _amino_run_as(info), info)
                    end
                    _is_modified(info) || return (:none, nothing, nothing)
                    info.base === nothing && return (:nucleotide, nothing, info)
                    (:nucleotide, _standard_name(info.class, info.base), info)
                end
                key = _residue_key(line)
                if kind === :amino && new !== nothing
                    new = _runs_as_parent(info, atoms_of[key])
                end
                lg =
                    isempty(legacy) ? nothing :
                    get(legacy, key, nothing)
                lg === nothing || (new = _standard_name(lg.class, lg.base))
                haskey(plain, key) && (new = plain[key])
                if new !== nothing
                    plan[key] = (; name = String(SubString(line, 18, 20)),
                        record = String(SubString(line, 1, 6)))
                    line =
                        "ATOM  " * SubString(line, 7, 17) * lpad(new, 3) *
                        SubString(line, 21)
                    # an atom the parent has under another name (Se for S) runs as that
                    atom = String(strip(SubString(line, 13, 16)))
                    alias =
                        kind === :amino ? get(AMINO_ATOM_ALIASES, (new, atom), nothing) :
                        nothing
                    if alias !== nothing
                        l = rpad(line, 78)
                        aliases[(key, alias)] = (;
                            field = String(SubString(l, 13, 16)),
                            element = String(SubString(l, 77, 78)),
                        )
                        line =
                            SubString(l, 1, 12) * rpad(" " * alias, 4) *
                            SubString(l, 17, 76) * lpad(first(alias, 1), 2) *
                            SubString(l, 79)
                    end
                elseif kind === :nucleotide
                    push!(skipped, key)
                elseif kind === :amino
                    push!(skipped_amino, key)
                end
            end
            if renumber && is_atom && length(line) >= 11
                serial += 1
                line =
                    SubString(line, 1, 6) * lpad(mod1(serial, 99999), 5) *
                    SubString(line, 12)
            end
            println(io, line)
        end
    end
    return (;
        plan, aliases, no_base = length(skipped), no_parent_amino = length(skipped_amino),
        renumbered = renumber,
    )
end

"""
    restore_modified!(path, plan)

Rewrite the pdb2pqr output at `path` so that each residue of `plan` (from
[`relabel_modified`](@ref)) has its original residue name and record type again, hydrogens
included. Residues are matched on chain, number and insertion code, which pdb2pqr keeps
(a blank chain id of the input excepted: pdb2pqr then names the chain itself, and the
match is on number and insertion code alone).

# Exceptions
- `SystemError`: `path` cannot be read or written.
"""
function restore_modified!(path::AbstractString, plan, aliases = nothing)::Nothing
    isempty(plan) && return nothing
    lines = readlines(path)
    for (i, line) in enumerate(lines)
        (startswith(line, "ATOM") || startswith(line, "HETATM")) || continue
        length(line) >= 27 || continue
        key = _residue_key(line)
        # a blank chain id in the input comes back as the segment id (pdb2pqr assigns one)
        orig = get(plan, key, get(plan, ("", key[2]), nothing))
        orig === nothing && continue
        lines[i] = orig.record * SubString(line, 7, 17) * orig.name * SubString(line, 21)
        # an atom that was run under its parent's name (`SE` as `SD`) gets its own back
        aliases === nothing && continue
        back = get(aliases, (key, String(strip(SubString(line, 13, 16)))), nothing)
        if back !== nothing
            l = rpad(lines[i], 78)
            lines[i] =
                SubString(l, 1, 12) * back.field * SubString(l, 17, 76) * back.element *
                SubString(l, 79)
        end
    end
    write(path, join(lines, "\n") * "\n")
    return nothing
end
