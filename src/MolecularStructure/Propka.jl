# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Per-residue-instance pKa prediction via the external 
propka3 CLI. PROPKA is invoked as a plain subprocess 
in an isolated CondaPkg-managed Python environment.
"""

using  CondaPkg: CondaPkg
using  FastClosures: @closure
using  ..Cache: KeyedCache

"""
The CondaPkg environment's variables and the paths of the two tools run from it, captured once.
`CondaPkg.withenv` edits the process-wide `ENV` for the duration of its block, which is not safe
beside other tasks; the subprocesses are given this environment explicitly instead (`setenv`).
"""
struct _CondaTools
    env      :: Dict{String,String}
    propka3  :: Union{Nothing,String}
    pdb2pqr  :: Union{Nothing,String}
end

function _read_conda_tools()::_CondaTools
    CondaPkg.withenv() do
        _CondaTools(Dict{String,String}(ENV), CondaPkg.which("propka3"), CondaPkg.which("pdb2pqr"))
    end
end

"The CondaPkg tools, resolved on first use (thread safe, once per process; reset in `__init__`)."
const _CONDA = Ref(Lazy{_CondaTools}(_read_conda_tools))
__init__() = (_CONDA[] = Lazy{_CondaTools}(_read_conda_tools))

"One lock per output path, so concurrent callers for the same structure run the external tool once."
const _PATH_LOCKS = KeyedCache{String,ReentrantLock}()
_path_lock(path::AbstractString) = get!(ReentrantLock, _PATH_LOCKS, String(path))

"""
Raised when propka3 cannot be run or its output cannot be parsed
(bad input path, non-zero exit, malformed .pka file).
"""
struct PropkaError <: Exception; msg::String end
Base.showerror(io::IO, e::PropkaError) = print(io, "PropkaError: ", e.msg)

"Standard titratable protein groups for PROPKA."
const _STANDARD_GROUPS = Set(["ASP", "GLU", "CYS", "TYR", "HIS", "LYS", "ARG", "N+", "C-"])

"""
Parse a propka3 .pka output file into one record per standard titratable
group. Non-standard rows (ligand groups, carrying a trailing ligand
atom-type column) are skipped.

# Arguments
- `path`: path to a .pka file produced by propka3.
"""
function _parse_pka(path::AbstractString)
    lines = readlines(path)
    i = findfirst(@closure(l -> occursin("SUMMARY OF THIS PREDICTION", l)), lines)
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

"Where [`propka_pKas`](@ref) caches the .pka for `pdb_path` (present ⟺ a cache hit)."
_pka_path(pdb_path::AbstractString) =
    joinpath(_store_dir(), splitext(basename(abspath(pdb_path)))[1] * ".pka")

"""
Run propka3 on `abspdb` in a private temporary directory inside `storedir` (no change of the process's
working directory) and move its `.pka` to `pka_path`. The move is a rename within one directory, so a
reader sees the whole file or none.

# Exceptions
- `PropkaError`: propka3 is missing, fails, or writes no `.pka`.
"""
function _run_propka3(abspdb::String, storedir::String, pka_path::String)::Nothing
    tools = force(_CONDA[])
    tools.propka3 === nothing && throw(PropkaError("propka3 not found in CondaPkg environment"))
    tmp = mktempdir(storedir)
    try
        try
            cmd = setenv(`$(tools.propka3) $abspdb`, tools.env; dir = tmp)
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
        catch e
            throw(PropkaError("propka3 failed on $abspdb: $(sprint(showerror, e))"))
        end
        made = joinpath(tmp, basename(pka_path))
        isfile(made) || throw(PropkaError("propka3 did not produce expected output $pka_path"))
        mv(made, pka_path; force = true)
    finally
        rm(tmp; recursive = true, force = true)
    end
    return nothing
end

"""
Run propka3 on a PDB structure and return one record per standard
titratable group: (resname::String, resnum::Int, chain::String, pKa::Float64).

# Arguments
- `pdb_path`: path to a PDB file.

# Returns
Records for ASP, GLU, CYS, TYR, HIS, LYS, ARG, N+, C-
groups only; ligand/hetero rows are skipped.
"""
function propka_pKas(pdb_path::AbstractString)
    isfile(pdb_path) || throw(PropkaError("no such file: $pdb_path"))

    abspdb = abspath(pdb_path)
    storedir = _store_dir()
    pka_path = _pka_path(abspdb)

    if !isfile(pka_path)
        # one propka3 run per structure; others wait, then find the cached file
        @lock _path_lock(pka_path) begin
            isfile(pka_path) || _run_propka3(abspdb, storedir, pka_path)
        end
    end

    return _parse_pka(pka_path)
end
