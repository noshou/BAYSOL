# SPDX-License-Identifier: LGPL-3.0-or-later

# The heavy atoms of a structure before and after pdb2pqr: the ones it drops are put back
# (verbatim coordinates), the ones it adds are counted and warned about.

"The index in `new` of the atom nearest to `a` within 3 A, `nothing` if none."
function argminOrNothing(new, a)
    best = nothing
    bestd = 3.0
    for (j, o) in enumerate(new)
        d = sqrt(sum((o.xyz[k] - a.xyz[k])^2 for k in 1:3))
        d < bestd && (best = j; bestd = d)
    end
    return best
end

"The coordinates (columns 31-54) of an atom record; `NaN`s when they are not numbers."
function _xyz(line::AbstractString)::NTuple{3,Float64}
    f(a, b) = something(tryparse(Float64, strip(SubString(line, a, b))), NaN)
    return (f(31, 38), f(39, 46), f(47, 54))
end

"Whether two atoms are the same atom: coordinates within 0.01 Å (pdb2pqr may rename atoms)."
_sameSpot(a, b) = all(abs(a[k] - b[k]) < 0.01 for k in 1:3)

"""
The heavy atoms (element not H or D) of the ATOM/HETATM records of the .pdb at `path`, by
text scan, grouped by residue.

# Returns
`Dict` residue key `(chain, number)` ([`_residueKey`](@ref)) `=> Vector` of `(; name, line,
element)` in file order, `name` the stripped atom name (one entry per name: alternate
locations are one atom), `line` the record, `element` the stripped element column.
"""
function _heavyAtomsByResidue(path::AbstractString)
    out = Dict{
        Tuple{String,String},
        Vector{
            NamedTuple{(:name, :line, :element, :xyz),
                Tuple{String,String,String,NTuple{3,Float64}}},
        },
    }()
    for line in eachline(path)
        startswith(line, "ENDMDL") && break
        (startswith(line, "ATOM") || startswith(line, "HETATM")) || continue
        length(line) >= 54 || continue
        name = String(strip(SubString(line, 13, 16)))
        element = length(line) >= 78 ? String(strip(SubString(line, 77, 78))) : ""
        isH =
            element in ("H", "D") ||
            (isempty(element) && !isempty(name) && first(lstrip(isdigit, name)) in "HD")
        isH && continue
        atoms = get!(out, _residueKey(line)) do
            valtype(out)()
        end
        any(a -> a.name == name, atoms) ||
            push!(atoms, (; name, line = String(line), element, xyz = _xyz(line)))
    end
    return out
end

"Whether the radius table knows the element (column, else the atom name) of atom `a`."
function _knownElementOf(a)::Bool
    el = isempty(a.element) ? _inferElement(a.name, true) : a.element
    return !isempty(el) && elementRadius(lowercase(el)) !== nothing
end

"""
Put the input residues `gone` (keys of `before`, [`_heavyAtomsByResidue`](@ref)) that are
ligands the model keeps (every non-water, non-polymer residue; atoms of an unknown
element stay out) back into the file `outPath`, as the input's own records, after its
last atom record.

# Returns
The number of atoms put back (0 leaves the file untouched).

# Exceptions
- `SystemError`: `outPath` cannot be read or written.
- `ComponentError`: a residue name that could not be looked up (offline).
"""
function _restoreLigandResidues!(outPath::AbstractString, before, gone)::Int
    lines = String[]
    nRes = 0
    for k in gone
        atoms = before[k]
        name = uppercase(strip(SubString(first(atoms).line, 18, 20)))
        name in WATER_NAMES && continue
        # a polymer residue is not a ligand; an unknown name (offline) is one
        poly = try
            isNucleotide(name) || isAminoAcid(name)
        catch e
            e isa ComponentError || rethrow()
            false
        end
        poly && continue
        keep = [a.line for a in atoms if _knownElementOf(a)]
        isempty(keep) && continue
        append!(lines, keep)
        nRes += 1
    end
    isempty(lines) && return 0
    out = readlines(outPath)
    lastAtom = findlast(l -> startswith(l, "ATOM") || startswith(l, "HETATM"), out)
    lastAtom === nothing && (lastAtom = length(out))
    open(outPath, "w") do io
        for (i, l) in enumerate(out)
            println(io, l)
            i == lastAtom && foreach(x -> println(io, x), lines)
        end
    end
    @info "pdb2pqr dropped $nRes ligand residue(s) of \"$(basename(outPath))\" " *
          "($(length(lines)) heavy atom(s) put back from the input)"
    return length(lines)
end

"""
    restoreDroppedAtoms!(inPath, outPath) -> NamedTuple

Compare the heavy atoms of the pdb2pqr input `inPath` with its output `outPath`,
residue by residue (matched on chain, number and insertion code; a blank input chain id
matches the one output residue with that number, or none if there are several). A
heavy atom of the input that the output lacks (no output atom of the residue with
its name or within 0.01 A of it, and no new output atom within 3 A to pair it with:
pdb2pqr renames some atoms (`OC1` and `OC2` become `O` and `OXT`) and its flips move
others, which are not losses) is re-attached to its residue in the output, with the
input's coordinates, occupancy, B-factor and element and the residue's own name,
chain and number (the case: pdb2pqr's `5TERM` patch deletes `P`, `OP1` and `OP2` of a
chain's first nucleotide). When the `P` of a residue is restored,
the `H5T` pdb2pqr put on its `O5'` is removed, since the oxygen is bonded to the
phosphorus again.
Heavy atoms the output has and the input does not (pdb2pqr adds some, `OXT` for instance)
are not touched, only counted and warned about. A residue the output lacks altogether is
left alone when it is a water or a polymer residue, and otherwise put back, verbatim, with
its atoms of a known element: it is a ligand the model keeps (pdb2pqr may drop a group it
has no definition for and keeps heme without hydrogens). It carries no hydrogens.

The file `outPath` is rewritten when something is restored.

# Returns
`(; restored, added, h5tDropped, ligands)`: the counts, `ligands` the atoms of the
ligand residues put back.

# Exceptions
- `SystemError`: a path cannot be read or written.
"""
function restoreDroppedAtoms!(inPath::AbstractString, outPath::AbstractString)
    before = _heavyAtomsByResidue(inPath)
    after = _heavyAtomsByResidue(outPath)
    # output residues by number alone, for the blank chain ids pdb2pqr names itself
    byNumber = Dict{String,Vector{Tuple{String,String}}}()
    for k in keys(after)
        push!(get!(byNumber, k[2], Tuple{String,String}[]), k)
    end
    added = 0
    todo = Dict{Tuple{String,String},Vector{String}}()   # output residue key => lines
    restored = 0
    gone = Tuple{String,String}[]   # input residues with no counterpart in the output
    for (k, atoms) in before
        okey = k
        if !haskey(after, okey)
            cands = k[1] == "" ? get(byNumber, k[2], Tuple{String,String}[]) : []
            isempty(cands) && push!(gone, k)
            length(cands) == 1 || continue
            okey = only(cands)
        end
        outAtoms = after[okey]
        # atoms with neither a namesake nor a neighbour on the other side
        lost = [
            a for a in atoms
            if !any(o -> o.name == a.name || _sameSpot(o.xyz, a.xyz), outAtoms)
        ]
        new = [
            o for o in outAtoms
            if !any(a -> a.name == o.name || _sameSpot(a.xyz, o.xyz), atoms)
        ]
        # a lost atom and a new one close by are one atom renamed and moved (the carboxylate
        # `OC1`/`OC2` become `O`/`OXT`): pair them off, the rest is lost or added
        for a in lost
            j = argminOrNothing(new, a)
            if j !== nothing
                deleteat!(new, j)
            else
                push!(get!(todo, okey, String[]), a.line)
                restored += 1
            end
        end
        added += length(new)
    end
    h5t = 0
    if restored > 0
        lines = readlines(outPath)
        lastOf = Dict{Tuple{String,String},Int}()
        sibling = Dict{Tuple{String,String},String}()
        for (i, l) in enumerate(lines)
            (startswith(l, "ATOM") || startswith(l, "HETATM")) && length(l) >= 27 ||
                continue
            k = _residueKey(l)
            lastOf[k] = i
            get!(sibling, k, l)
        end
        drop = Set{Int}()
        insertAfter = Dict{Int,Vector{String}}()
        for (okey, new) in todo
            sib = sibling[okey]
            restoresP = false
            for src in new
                nm = String(strip(SubString(src, 13, 16)))
                nm == "P" && (restoresP = true)
                padded = length(nm) < 4 ? " " * rpad(nm, 3) : nm
                push!(
                    get!(insertAfter, lastOf[okey], String[]),
                    String(SubString(sib, 1, 12)) * padded *
                    String(SubString(sib, 17, 27)) *
                    String(SubString(src, 28)),
                )
            end
            if restoresP
                for (i, l) in enumerate(lines)
                    (startswith(l, "ATOM") || startswith(l, "HETATM")) && length(l) >= 27 ||
                        continue
                    _residueKey(l) == okey && strip(SubString(l, 13, 16)) == "H5T" &&
                        (push!(drop, i); h5t += 1)
                end
            end
        end
        open(outPath, "w") do io
            for (i, l) in enumerate(lines)
                i in drop || println(io, l)
                for extra in get(insertAfter, i, String[])
                    println(io, extra)
                end
            end
        end
        @info "pdb2pqr dropped $restored heavy atom(s) of \"$(basename(inPath))\"; " *
              "restored from the input" *
              (h5t > 0 ? " ($h5t H5T removed with the restored phosphorus)" : "")
    end
    ligands = _restoreLigandResidues!(outPath, before, gone)
    added > 0 && @warn "pdb2pqr added $added heavy atom(s) to \"$(basename(inPath))\" " *
          "(kept as pdb2pqr wrote them)"
    return (; restored, added, h5tDropped = h5t, ligands)
end

"""
The number of heavy atoms of the .pdb at `path` ([`_heavyAtomsByResidue`](@ref)), counted
after [`sanitizedCopy`](@ref) with `waters = true` (so two chains that reuse an id count
twice, and waters, which the hydrogenation step removes, not at all).
"""
function heavyAtomCount(path::AbstractString)
    tmp = mktempdir()
    try
        copy = joinpath(tmp, "copy.pdb")
        p = sanitizedCopy(path, copy; waters = true) === nothing ? path : copy
        return sum(length, values(_heavyAtomsByResidue(p)); init = 0)
    finally
        rm(tmp; recursive = true, force = true)
    end
end
