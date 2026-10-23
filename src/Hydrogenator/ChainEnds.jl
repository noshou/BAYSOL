# SPDX-License-Identifier: LGPL-3.0-or-later

# Chain ends that are not nucleotides: pdb2pqr patches the first residue of a chain with a
# 5' patch only if it is nucleic and the last with a 3' patch only if it is nucleic. A
# nucleic chain that starts with a ligand (a 5' GTP) or ends with a non-nucleotide (the
# aminoacyl residue of a tRNA) gets one patch, whose fractional charge is not cancelled, and
# pdb2pqr aborts on its total-charge check. The non-nucleotide ends are therefore run under
# chain ids of their own, and get their own back afterwards.

"The chain ids [`isolate_chain_ends`](@ref) hands out to the runs it separates, in order."
const FRESH_CHAIN_IDS = vcat('A':'Z', 'a':'z', '0':'9')

"""
Whether a residue named `name` (as run, after [`relabel_modified`](@ref)) is nucleic to
pdb2pqr: a standard nucleotide id or an Amber nucleic name.
"""
_nucleic_as_run(name::AbstractString) =
    name in STANDARD_NUCLEOTIDES || haskey(AMBER_NUCLEIC_NAMES, name)

"""
    isolate_chain_ends(in_path, out_path) -> NamedTuple

Write to `out_path` a copy of the .pdb at `in_path` in which the leading and the trailing
run of non-nucleic residues of every chain that has nucleotides get a chain id of their own
(an id the file does not use, [`FRESH_CHAIN_IDS`](@ref)). The runs are taken twice, over
the residues of a chain id as a whole and over each TER-delimited segment of it that has
nucleotides, since which of the two pdb2pqr patches by is not documented; a residue is
moved if either says so. Nucleotides are told by their name as run
([`_nucleic_as_run`](@ref)), so `in_path` is the copy after [`relabel_modified`](@ref).
Nothing is written if no chain has such an end.

# Returns
`(; changed, back, trailing_amino)`: whether `out_path` was written; `back` maps each fresh
chain id to the id it replaces, for [`restore_chain_ends!`](@ref); `trailing_amino` is the
set of residue keys `(chain, number)` (original chain ids) of the isolated trailing
residues that are standard amino acids.

# Exceptions
- `SystemError`: a path cannot be read or written.
"""
function isolate_chain_ends(in_path::AbstractString, out_path::AbstractString)
    # residues in order of first appearance, with the TER segment each belongs to
    res = NamedTuple{(:key, :name, :segment),Tuple{Tuple{String,String},String,Int}}[]
    seen = Set{Tuple{String,String}}()
    used = Set{Char}()
    segment = 0
    for line in eachline(in_path)
        if startswith(line, "TER")
            segment += 1
        elseif (startswith(line, "ATOM") || startswith(line, "HETATM")) &&
               length(line) >= 27
            push!(used, line[22])
            key = _residue_key(line)
            key in seen && continue
            push!(seen, key)
            name = uppercase(strip(SubString(line, 18, 20)))
            name in WATER_NAMES || push!(res, (; key, name, segment))
        end
    end
    # residue key => (run id, :lead or :trail)
    moved = Dict{Tuple{String,String},Tuple{String,Symbol}}()
    runs = Tuple{String,Symbol,Int}[]   # (chain, end, first index) of each run, in order
    function mark!(idx)
        nuc = [_nucleic_as_run(res[i].name) for i in idx]
        any(nuc) || return nothing
        first_nuc = findfirst(nuc)
        last_nuc = findlast(nuc)
        for (range, side) in ((1:(first_nuc-1), :lead), ((last_nuc+1):length(idx), :trail))
            isempty(range) && continue
            id = string(res[idx[first(range)]].key[1], '/', side, '/', idx[first(range)])
            for j in range
                haskey(moved, res[idx[j]].key) || (moved[res[idx[j]].key] = (id, side))
            end
        end
    end
    by_chain = Dict{String,Vector{Int}}()
    by_segment = Dict{Tuple{String,Int},Vector{Int}}()
    for (i, r) in enumerate(res)
        push!(get!(by_chain, r.key[1], Int[]), i)
        push!(get!(by_segment, (r.key[1], r.segment), Int[]), i)
    end
    for idx in values(by_chain)
        mark!(idx)
    end
    for idx in values(by_segment)
        mark!(idx)
    end
    back = Dict{Char,Char}()
    trailing_amino = Set{Tuple{String,String}}()
    isempty(moved) && return (; changed = false, back, trailing_amino)
    # one fresh id per run (runs are identified by the id string made above)
    free = [c for c in FRESH_CHAIN_IDS if !(c in used)]
    fresh = Dict{String,Char}()
    for (key, (run, side)) in sort!(collect(moved); by = p -> p.second[1])
        if !haskey(fresh, run)
            isempty(free) && continue   # out of ids: that run is left where it is
            fresh[run] = popfirst!(free)
            c = key[1]
            back[fresh[run]] = isempty(c) ? ' ' : first(c)
        end
    end
    new_id = Dict(k => fresh[run] for (k, (run, _)) in moved if haskey(fresh, run))
    for (k, (_, side)) in moved
        haskey(new_id, k) || continue
        name = only(r.name for r in res if r.key == k)
        side === :trail && name in STANDARD_AMINO_ACIDS && push!(trailing_amino, k)
    end
    isempty(new_id) && return (; changed = false, back, trailing_amino)
    open(out_path, "w") do io
        for line in eachline(in_path)
            if (startswith(line, "ATOM") || startswith(line, "HETATM")) &&
               length(line) >= 27
                c = get(new_id, _residue_key(line), nothing)
                c === nothing ||
                    (
                        line =
                            String(SubString(line, 1, 21)) * c *
                            String(SubString(line, 23))
                    )
            end
            println(io, line)
        end
    end
    return (; changed = true, back, trailing_amino)
end

"""
    restore_chain_ends!(path, iso, in_path)

Give the residues of the pdb2pqr output at `path` the chain ids [`isolate_chain_ends`](@ref)
replaced (`iso.back`, its result). An isolated trailing amino acid is a residue pdb2pqr took
for the end of a protein chain: the `OXT` and `HXT` it added are removed again (its carboxyl
is esterified to the nucleotide before it), unless the input `in_path` has them. Run before
[`restore_modified!`](@ref) and [`restore_dropped_atoms!`](@ref), which match residues on
the original chain ids.

# Exceptions
- `SystemError`: a path cannot be read or written.
"""
function restore_chain_ends!(path::AbstractString, iso, in_path::AbstractString)::Nothing
    iso.changed || return nothing
    had = Dict(r.key => r.atoms for r in _scan_residues(in_path))
    # the isolated residues by their fresh id: only those carry a trailing amino acid
    lines = String[]
    for line in eachline(path)
        if (startswith(line, "ATOM") || startswith(line, "HETATM")) && length(line) >= 27
            c = line[22]
            if haskey(iso.back, c)
                line =
                    String(SubString(line, 1, 21)) * iso.back[c] *
                    String(SubString(line, 23))
                key = _residue_key(line)
                atom = String(strip(SubString(line, 13, 16)))
                if key in iso.trailing_amino && atom in ("OXT", "HXT") &&
                   !(atom in get(had, key, Set{String}()))
                    continue
                end
            end
        end
        push!(lines, line)
    end
    write(path, join(lines, "\n") * "\n")
    return nothing
end
