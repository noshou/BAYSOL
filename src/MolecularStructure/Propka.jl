# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Per-residue-instance pKa prediction via the external 
`propka3` CLI. PROPKA is invoked as a plain subprocess 
in an isolated `CondaPkg`-managed Python environment.
"""

using  CondaPkg: CondaPkg

"Raised when `propka3` cannot be run or its output cannot be parsed 
(bad input path, non-zero exit, malformed `.pka` file)."
struct PropkaError <: Exception; msg::String end
Base.showerror(io::IO, e::PropkaError) = print(io, "PropkaError: ", e.msg)

"Standard titratable protein groups for PROPKA."
const _STANDARD_GROUPS = Set(["ASP", "GLU", "CYS", "TYR", "HIS", "LYS", "ARG", "N+", "C-"])

"""
    _parse_pka(path::AbstractString) -> 
        Vector{NamedTuple{(:resname,:resnum,:chain,:pKa), Tuple{String,Int,String,Float64}}}

Parse a `propka3` `.pka` output file into one record per standard titratable
group. Non-standard rows (ligand groups, carrying a trailing ligand
atom-type column) are skipped.

# Arguments
- `path`: path to a `.pka` file produced by `propka3`.
"""
function _parse_pka(path::AbstractString)
    lines = readlines(path)
    i = findfirst(l -> occursin("SUMMARY OF THIS PREDICTION", l), lines)
    i === nothing && throw(PropkaError("no 'SUMMARY OF THIS PREDICTION' section in $path"))
    # line i+1 is the column header ("Group  pKa  model-pKa  ligand atom-type");
    # rows follow until a blank line or EOF.
    out = NamedTuple{(:resname, :resnum, :chain, :pKa), Tuple{String, Int, String, Float64}}[]
    for line in @view lines[(i + 2):end]
        stripped = strip(line)
        isempty(stripped) && break
        toks = split(stripped)
        length(toks) < 4 && continue
        resname = String(toks[1])
        resname in _STANDARD_GROUPS || continue
        resnum = tryparse(Int, toks[2])
        pka = tryparse(Float64, rstrip(toks[4], '*'))  # trailing '*' flags a coupled residue
        (resnum === nothing || pka === nothing) && continue
        chain = String(toks[3])
        push!(out, (resname = resname, resnum = resnum, chain = chain, pKa = pka))
    end
    return out
end

"""
    propka_pKas(pdb_path::AbstractString) -> Vector{<:NamedTuple}

Run `propka3` on a PDB structure and return one record per standard
titratable group: `(resname::String, resnum::Int, chain::String, pKa::Float64)`.

# Arguments
- `pdb_path`: path to a PDB file.

# Returns
Records for `ASP`, `GLU`, `CYS`, `TYR`, `HIS`, `LYS`, `ARG`, `N+`, `C-`
groups only; ligand/hetero rows are skipped.
"""
function propka_pKas(pdb_path::AbstractString)
    isfile(pdb_path) || throw(PropkaError("no such file: $pdb_path"))

    abspdb = abspath(pdb_path)
    base = splitext(basename(abspdb))[1]
    storedir = _store_dir()
    pka_path = joinpath(storedir, base * ".pka")

    if !isfile(pka_path)
        try
            CondaPkg.withenv() do
                propka3 = CondaPkg.which("propka3")
                propka3 === nothing && throw(PropkaError("propka3 not found in CondaPkg environment"))
                cd(storedir) do
                    run(pipeline(`$propka3 $abspdb`; stdout = devnull, stderr = devnull))
                end
            end
        catch e
            e isa PropkaError && rethrow()
            throw(PropkaError("propka3 failed on $pdb_path: $(sprint(showerror, e))"))
        end
        isfile(pka_path) || throw(PropkaError("propka3 did not produce expected output $pka_path"))
    end

    return _parse_pka(pka_path)
end
