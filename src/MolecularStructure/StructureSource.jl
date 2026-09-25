# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Resolve a protein structure from any of three input shapes (a local file, a
bare RCSB PDB ID, or an arbitrary URL) into one canonical .pdb file stored
in [`_store_dir`](@ref). Callers who need the parsed Molecule/Residues
pair pass the resulting path to [`load_molecule`](@ref) themselves.
"""

using BioStructures: BioStructures, MMCIFFormat, PDBFormat, writepdb,
                    standardselector, heavyatomselector, retrievepdb
using Downloads: Downloads

"Raised for any failure resolving/converting a structure source:
a bad or nonexistent local path, an unrecognized extension, a failed fetch/download,
or a BioStructures write failure."
struct StructureSourceError <: Exception; msg::String end
Base.showerror(io::IO, e::StructureSourceError) = print(io, "StructureSourceError: ", e.msg)

"""
Where to obtain a protein structure from. One concrete subtype per input
shape; [`resolve_structure`](@ref) dispatches on it to produce a canonical,
cached local .pdb path.
"""
abstract type StructureSource end

"""
A structure already on local disk, at path. A .pdb path is used
in place (no storage, no copy — it's already local); a .cif/.mmcif path
is converted to a canonical .pdb stored in [`_store_dir`](@ref), named
after the file's own basename stem (e.g. fixture.cif → "fixture").
Conversion always re-runs (it's cheap and local — there's no "skip the work"
benefit to be had here, only deduplication of the resulting file); if a file
already exists under that name, the freshly-converted result is byte
-compared against it: identical content reuses the existing file, but
different content under the same name is a collision and raises
[`StructureSourceError`](@ref) rather than silently overwriting or renaming
around it — remove the stale file or use a different filename.
"""
struct LocalPathSource <: StructureSource
    path::String
end

"""
A structure identified by its 4-character RCSB PDB ID, e.g. "1CRN". Fetched
via BioStructures.retrievepdb and stored in [`_store_dir`](@ref) under the
uppercased ID. A repeat request for the same ID trusts an existing file's
presence outright and skips fetching — no re-verification, safe only because
a real RCSB ID always refers to the same content.
"""
struct PDBIDSource <: StructureSource
    id::String
end

"""
A structure available at an arbitrary url, in either legacy .pdb or
mmCIF format (sniffed from the downloaded content, not the URL), stored in
[`_store_dir`](@ref) under the caller-supplied id (never derived from the
URL — there's no safe, unique way to do that automatically, so it's the
caller's responsibility). Every call re-downloads and re-converts then
byte-compared against any existing file under id: identical content reuses
it, but different content under the same id is a collision and raises
[`StructureSourceError`](@ref).
"""
struct URLSource <: StructureSource
    url::String
    id::String

    function URLSource(url::AbstractString, id::AbstractString)
        isempty(id) && throw(StructureSourceError("URLSource id must not be empty"))
        return new(url, id)
    end
end

"""
    _resolve_canonical_pdb(struc, key::AbstractString) -> String

Shared "produce candidate .pdb, then compare-or-write-or-throw" step used by
[`LocalPathSource`](@ref) and [`URLSource`](@ref) (not [`PDBIDSource`](@ref),
which has its own simpler fetch-if-missing path). Takes model 1 of the
already-parsed BioStructures structure struc, writes it (filtered through
standardselector and heavyatomselector, dropping HETATM/waters and
hydrogens) to a temp file, then:

- if nothing is stored under key yet, moves the temp file into place;
- if something is and it's byte-identical, discards the temp file and
    returns the existing path unchanged;
- if something is and it differs, discards the temp file and throws
    [`StructureSourceError`](@ref).

Wraps any BioStructures.writepdb failure (most notably: a multi-character
chain ID, which legacy .pdb cannot represent) in a [`StructureSourceError`](@ref).

# Arguments
- `struc`: a parsed BioStructures structure (from read or retrievepdb).
- `key`: stored filename stem, e.g. a local file's basename stem or a
    URLSource's id.
"""
function _resolve_canonical_pdb(struc, key::AbstractString)::String
    final_path = joinpath(_store_dir(), key * ".pdb")
    tmpdir = mktempdir()
    tmp_path = joinpath(tmpdir, key * ".pdb")
    model = struc[1]
    try
        writepdb(tmp_path, model, standardselector, heavyatomselector)
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(StructureSourceError(
            "failed writing canonical .pdb for \"$key\": $(sprint(showerror, e))"))
    end

    if !isfile(final_path)
        mv(tmp_path, final_path)
        rm(tmpdir; recursive = true, force = true)
        return final_path
    end

    if read(tmp_path) == read(final_path)
        rm(tmpdir; recursive = true, force = true)
        return final_path
    end

    rm(tmpdir; recursive = true, force = true)
    throw(StructureSourceError(
        "name \"$key\" already refers to different stored content at " *
        "\"$final_path\"; remove the stale file or use a different name/id"))
end

"""
    resolve_structure(source::StructureSource) -> String

Resolve source to an absolute path to a canonical .pdb file in
[`_store_dir`](@ref) (model 1 only, no HETATM/waters, no hydrogens). See
[`StructureSource`](@ref) and its subtypes for per-variant behaviour.
"""
function resolve_structure end

function resolve_structure(source::LocalPathSource)::String
    path = source.path
    isfile(path) || throw(StructureSourceError("no such file: $path"))
    ext = lowercase(splitext(path)[2])
    if ext == ".pdb"
        return abspath(path)
    elseif ext == ".cif" || ext == ".mmcif"
        key = splitext(basename(path))[1]

        local struc
        try
            struc = BioStructures.read(path, MMCIFFormat)
        catch e
            throw(StructureSourceError("failed parsing mmCIF \"$path\": $(sprint(showerror, e))"))
        end
        return _resolve_canonical_pdb(struc, key)
    else
        throw(StructureSourceError(
            "unrecognized structure file extension \"$ext\" for \"$path\"; expected .pdb, .cif, or .mmcif"))
    end
end

function resolve_structure(source::PDBIDSource)::String
    id = uppercase(source.id)
    existing = joinpath(_store_dir(), id * ".pdb")
    isfile(existing) && return existing   # presence trusted outright, no re-fetch

    tmpdir = mktempdir()
    local struc
    try
        struc = retrievepdb(id; dir = tmpdir, format = MMCIFFormat)
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(StructureSourceError("failed fetching PDB ID \"$id\": $(sprint(showerror, e))"))
    end
    model = struc[1]
    try
        writepdb(existing, model, standardselector, heavyatomselector)
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(StructureSourceError(
            "failed writing canonical .pdb for \"$id\": $(sprint(showerror, e))"))
    end
    rm(tmpdir; recursive = true, force = true)
    return existing
end

"Heuristic mmCIF/legacy-PDB sniff on downloaded content, per PDBTools.jl's 
documented approach: the literal loop_ keyword appears in mmCIF but not 
legacy PDB. Not a guarantee; an unusual server response could defeat it."
function _sniff_format(path::AbstractString)
    for line in eachline(path)
        occursin("loop_", line) && return MMCIFFormat
    end
    return PDBFormat
end

function resolve_structure(source::URLSource)::String
    url = source.url
    key = source.id

    tmpdir = mktempdir()
    local struc
    try
        raw = joinpath(tmpdir, "download")
        Downloads.download(url, raw)
        fmt = _sniff_format(raw)
        struc = BioStructures.read(raw, fmt)
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(StructureSourceError("failed fetching/parsing URL \"$url\": $(sprint(showerror, e))"))
    end
    path = _resolve_canonical_pdb(struc, key)
    rm(tmpdir; recursive = true, force = true)
    return path
end
