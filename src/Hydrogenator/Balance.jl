# SPDX-License-Identifier: LGPL-3.0-or-later

# The heavy atoms of a structure before and after pdb2pqr: the ones it drops are put back
# (verbatim coordinates), the ones it adds are counted and warned about.

"The index in `new` of the atom nearest to `a` within 3 A, `nothing` if none."
function argmin_or_nothing(new, a)
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
_same_spot(a, b) = all(abs(a[k] - b[k]) < 0.01 for k in 1:3)

"""
The heavy atoms (element not H or D) of the ATOM/HETATM records of the .pdb at `path`, by
text scan, grouped by residue.

# Returns
`Dict` residue key `(chain, number)` ([`_residue_key`](@ref)) `=> Vector` of `(; name, line,
element)` in file order, `name` the stripped atom name (one entry per name: alternate
locations are one atom), `line` the record, `element` the stripped element column.
"""
function _heavy_atoms_by_residue(path::AbstractString)
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
        is_h =
            element in ("H", "D") ||
            (isempty(element) && !isempty(name) && first(lstrip(isdigit, name)) in "HD")
        is_h && continue
        atoms = get!(out, _residue_key(line)) do
            valtype(out)()
        end
        any(a -> a.name == name, atoms) ||
            push!(atoms, (; name, line = String(line), element, xyz = _xyz(line)))
    end
    return out
end

"""
    restore_dropped_atoms!(in_path, out_path) -> NamedTuple

Compare the heavy atoms of the pdb2pqr input `in_path` with its output `out_path`,
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
Heavy atoms the output has and
the input does not (pdb2pqr adds some, `OXT` for instance) are not touched, only counted and
warned about. Residues the output lacks altogether (waters, ligands) are left alone.

The file `out_path` is rewritten when something is restored.

# Returns
`(; restored, added, h5t_dropped)`: the counts.

# Exceptions
- `SystemError`: a path cannot be read or written.
"""
function restore_dropped_atoms!(in_path::AbstractString, out_path::AbstractString)
    before = _heavy_atoms_by_residue(in_path)
    after = _heavy_atoms_by_residue(out_path)
    # output residues by number alone, for the blank chain ids pdb2pqr names itself
    by_number = Dict{String,Vector{Tuple{String,String}}}()
    for k in keys(after)
        push!(get!(by_number, k[2], Tuple{String,String}[]), k)
    end
    added = 0
    todo = Dict{Tuple{String,String},Vector{String}}()   # output residue key => lines
    restored = 0
    for (k, atoms) in before
        okey = k
        if !haskey(after, okey)
            k[1] == "" || continue
            cands = get(by_number, k[2], Tuple{String,String}[])
            length(cands) == 1 || continue
            okey = only(cands)
        end
        out_atoms = after[okey]
        # atoms with neither a namesake nor a neighbour on the other side
        lost = [
            a for a in atoms
            if !any(o -> o.name == a.name || _same_spot(o.xyz, a.xyz), out_atoms)
        ]
        new = [
            o for o in out_atoms
            if !any(a -> a.name == o.name || _same_spot(a.xyz, o.xyz), atoms)
        ]
        # a lost atom and a new one close by are one atom renamed and moved (the carboxylate
        # `OC1`/`OC2` become `O`/`OXT`): pair them off, the rest is lost or added
        for a in lost
            j = argmin_or_nothing(new, a)
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
        lines = readlines(out_path)
        last_of = Dict{Tuple{String,String},Int}()
        sibling = Dict{Tuple{String,String},String}()
        for (i, l) in enumerate(lines)
            (startswith(l, "ATOM") || startswith(l, "HETATM")) && length(l) >= 27 ||
                continue
            k = _residue_key(l)
            last_of[k] = i
            get!(sibling, k, l)
        end
        drop = Set{Int}()
        insert_after = Dict{Int,Vector{String}}()
        for (okey, new) in todo
            sib = sibling[okey]
            restores_p = false
            for src in new
                nm = String(strip(SubString(src, 13, 16)))
                nm == "P" && (restores_p = true)
                padded = length(nm) < 4 ? " " * rpad(nm, 3) : nm
                push!(
                    get!(insert_after, last_of[okey], String[]),
                    String(SubString(sib, 1, 12)) * padded *
                    String(SubString(sib, 17, 27)) *
                    String(SubString(src, 28)),
                )
            end
            if restores_p
                for (i, l) in enumerate(lines)
                    (startswith(l, "ATOM") || startswith(l, "HETATM")) && length(l) >= 27 ||
                        continue
                    _residue_key(l) == okey && strip(SubString(l, 13, 16)) == "H5T" &&
                        (push!(drop, i); h5t += 1)
                end
            end
        end
        open(out_path, "w") do io
            for (i, l) in enumerate(lines)
                i in drop || println(io, l)
                for extra in get(insert_after, i, String[])
                    println(io, extra)
                end
            end
        end
        @info "pdb2pqr dropped $restored heavy atom(s) of \"$(basename(in_path))\"; " *
              "restored from the input" *
              (h5t > 0 ? " ($h5t H5T removed with the restored phosphorus)" : "")
    end
    added > 0 && @warn "pdb2pqr added $added heavy atom(s) to \"$(basename(in_path))\" " *
          "(kept as pdb2pqr wrote them)"
    return (; restored, added, h5t_dropped = h5t)
end

"""
The number of heavy atoms of the .pdb at `path` ([`_heavy_atoms_by_residue`](@ref)), counted
after [`sanitized_copy`](@ref) (so two chains that reuse an id count twice).
"""
function heavy_atom_count(path::AbstractString)
    tmp = mktempdir()
    try
        copy = joinpath(tmp, "copy.pdb")
        p = sanitized_copy(path, copy) === nothing ? path : copy
        return sum(length, values(_heavy_atoms_by_residue(p)); init = 0)
    finally
        rm(tmp; recursive = true, force = true)
    end
end
