# SPDX-License-Identifier: LGPL-3.0-or-later

# Residues pdb2pqr cannot build on: a polymer residue without its backbone (the C-alpha-only
# stretches of a CORAL/EOM-style model, a phosphate split off as a residue) is held out of
# the run and put back afterwards, as deposited and without hydrogens.

"""
    holdBackIncomplete(inPath, outPath) -> NamedTuple

Write to `outPath` a copy of the .pdb at `inPath` without its **backbone-less**
polymer residues, and return their records. pdb2pqr rebuilds a residue's missing
atoms from the three atoms nearest to them and stops on a residue it cannot anchor
(`Too few atoms present to reconstruct or cap residue`). A residue is held back when
it is a standard amino acid lacking one of [`PROTEIN_BACKBONE_ATOMS`](@ref), or a
nucleotide with fewer than [`BACKBONE_MIN`](@ref) of the [`BACKBONE_ATOMS`](@ref)
and none of the [`NUCLEOBASE_ATOMS`](@ref) (the same tests as the fragment check of
[`dummyLikeResidues`](@ref BAYSOL.MolecularStructure.dummyLikeResidues)). They are
written back by [`restoreHeldBack!`](@ref); every other line is copied unchanged.

# Returns
`(; held, lines)`: `held` the number of residues, `lines` their ATOM/HETATM records (and
the `ANISOU` lines after them are dropped with them). `held == 0` writes nothing.

# Exceptions
- `SystemError`: a path cannot be read or written.
"""
function holdBackIncomplete(inPath::AbstractString, outPath::AbstractString)
    heldKeys = Set{Tuple{String,String}}()
    for r in _scanResidues(inPath)
        if r.name in STANDARD_AMINO_ACIDS
            all(in(r.atoms), PROTEIN_BACKBONE_ATOMS) || push!(heldKeys, r.key)
        elseif (r.name in STANDARD_NUCLEOTIDES || _isNucleicResidue(r.name, r.atoms)) &&
               _backboneCount(r.atoms) < BACKBONE_MIN &&
               !any(in(r.atoms), NUCLEOBASE_ATOMS)
            push!(heldKeys, r.key)
        end
    end
    lines = String[]
    isempty(heldKeys) && return (; held = 0, lines)
    keep = String[]
    for line in eachline(inPath)
        atom = startswith(line, "ATOM") || startswith(line, "HETATM")
        if atom && length(line) >= 27 && _residueKey(line) in heldKeys &&
           !(uppercase(strip(SubString(line, 18, 20))) in WATER_NAMES)
            push!(lines, String(line))
        elseif startswith(line, "ANISOU") && length(line) >= 27 &&
               _residueKey(line) in heldKeys
            continue
        else
            push!(keep, String(line))
        end
    end
    write(outPath, join(keep, "\n") * "\n")
    return (; held = length(heldKeys), lines)
end

"""
    restoreHeldBack!(path, held) -> Int

Append the records `held.lines` ([`holdBackIncomplete`](@ref)) to the pdb2pqr output at
`path`, after its last atom record, verbatim (they carry no hydrogens: nothing could place
them). Logged once per call.

# Returns
The number of residues put back.

# Exceptions
- `SystemError`: `path` cannot be read or written.
"""
function restoreHeldBack!(path::AbstractString, held)::Int
    held.held == 0 && return 0
    out = readlines(path)
    lastAtom = findlast(l -> startswith(l, "ATOM") || startswith(l, "HETATM"), out)
    lastAtom === nothing && (lastAtom = length(out))
    open(path, "w") do io
        for (i, l) in enumerate(out)
            println(io, l)
            i == lastAtom && foreach(x -> println(io, x), held.lines)
        end
    end
    @info "$(held.held) backbone-less polymer residue(s) of \"$(basename(path))\" " *
          "($(length(held.lines)) atoms) kept as deposited, without hydrogens"
    return held.held
end
