# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Resolve a protein structure from any of three input shapes (a local file, a
bare RCSB PDB ID, or an arbitrary URL) into one canonical .pdb file stored
in [`_store_dir`](@ref). Callers who need the parsed Molecule
pass the resulting path to [`load_molecule`](@ref) themselves.
"""

using BioStructures: BioStructures, MMCIFFormat, PDBFormat, writepdb,
    hydrogenselector, retrievepdb, collectmodels
using Downloads: Downloads
using SHA: SHA

"""
Raised for any failure resolving/converting a structure source:
a bad or nonexistent local path, an unrecognized extension, a failed fetch/download,
or a BioStructures write failure.
"""
struct StructureSourceError <: Exception
    msg::String
end
Base.showerror(io::IO, e::StructureSourceError) = print(io, "StructureSourceError: ", e.msg)

"""
Where to obtain a protein structure from. One concrete subtype per input
shape; [`reslove_struct`](@ref) dispatches on it to produce a canonical,
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
The selector of the canonical .pdb for `model`: [`_model_selector`](@ref) without hydrogens.
Which atoms the canonical .pdb keeps: heavy atoms of standard residues and of nucleotides,
including modified ones that are HETATM records (BioStructures' `heavyatomselector` would
drop those), and the ligands of a known composition ([`KEEP_LIGANDS`](@ref)); waters,
placeholders and hydrogens are dropped.
"""
function _canonical_selector(model)
    keep = _model_selector(model)
    return at -> keep(at) && !hydrogenselector(at)
end

"""
The suffix a stored file's name takes for the model `k`: none for the first (so a default
run keeps the names, and the caches, it always had), `_model<k>` for a later one.
"""
_model_suffix(k::Integer) = k == 1 ? "" : "_model$k"

"""
The `k`-th model of the BioStructures structure `struc` (counted from 1), named `key` in the
error.

# Exceptions
- [`StructureSourceError`](@ref): `k` is below 1 or above the number of models.
"""
function _nth_model(struc, k::Integer, key::AbstractString)
    models = collectmodels(struc)
    1 <= k <= length(models) || throw(
        StructureSourceError(
            "model $k was asked for but \"$key\" has $(length(models)) model(s)"),
    )
    return models[k]
end

"""
Shared "produce candidate .pdb, then compare-or-write-or-throw" step used by
[`LocalPathSource`](@ref) and [`URLSource`](@ref) (not [`PDBIDSource`](@ref),
which has its own simpler fetch-if-missing path). Takes model 1 of the
already-parsed BioStructures structure struc, writes it (filtered through
`_canonical_selector`: standard and nucleotide heavy atoms and ligands of a known
composition, no waters or hydrogens) to a temp file, then:

- if nothing is stored under key yet, moves the temp file into place;
- if something is and it's byte-identical, discards the temp file and
    returns the existing path unchanged;
- if something is and it differs, discards the temp file and throws
    [`StructureSourceError`](@ref).

`model` picks the model: the `model`-th that BioStructures lists (1, the default, is the
first whatever its number); one beyond the last is a [`StructureSourceError`](@ref) that
says how many there are.

Wraps any BioStructures.writepdb failure (most notably: a multi-character
chain ID, which legacy .pdb cannot represent) in a [`StructureSourceError`](@ref).

# Arguments
- `struc`: a parsed BioStructures structure (from read or retrievepdb).
- `key`: stored filename stem, e.g. a local file's basename stem or a
    URLSource's id (with the model suffix of [`_model_suffix`](@ref) for a later model).
- `model`: which model to write, counted from 1.
"""
function _resolve_canonical_pdb(struc, key::AbstractString; model::Integer = 1)::String
    final_path = joinpath(_store_dir(), key * ".pdb")
    model = _nth_model(struc, model, key)   # the first one is first whatever its number
    tmpdir = mktempdir()
    tmp_path = joinpath(tmpdir, key * ".pdb")
    try
        writepdb(tmp_path, model, _canonical_selector(model))
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(
            StructureSourceError(
                "failed writing canonical .pdb for \"$key\": $(sprint(showerror, e))"),
        )
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
    throw(
        StructureSourceError(
            "name \"$key\" already refers to different stored content at " *
            "\"$final_path\"; remove the stale file or use a different name/id"),
    )
end

"""
    reslove_struct(source::StructureSource; model = 1) -> String

Resolve source to an absolute path to a canonical .pdb file in
[`_store_dir`](@ref) (one model only, the first unless `model` says another; modified
nucleotides kept, ligands of a known composition kept ([`KEEP_LIGANDS`](@ref)); no waters
or hydrogens). See [`StructureSource`](@ref) and
its subtypes for per-variant behaviour.

`model` is which model of a multi-model structure (an NMR ensemble) to resolve,
counted from 1 (the `model`-th in the file for a .pdb, the `model`-th that
BioStructures lists for an mmCIF; 1 is the first whatever its number). A later
model of a .pdb file is written to a file of its own in the store,
`<stem>_model<k>_<hash>.pdb`, with the lines of that model only; of an mmCIF or
a download to `<id>_model<k>.pdb`. The first model is resolved as it always was.

# Returns
- The path of the .pdb.

# Exceptions
- [`StructureSourceError`](@ref): a missing file, an unrecognised extension, a failed fetch
    or write, or a `model` that is below 1 or above the number of models.
"""
function reslove_struct end

function reslove_struct(source::LocalPathSource; model::Integer = 1)::String
    path = source.path
    isfile(path) || throw(StructureSourceError("no such file: $path"))
    model >= 1 || throw(StructureSourceError("model must be at least 1, got $model"))
    ext = lowercase(splitext(path)[2])
    if ext == ".pdb"
        model == 1 && return abspath(path)
        return _pdb_model(abspath(path), model)
    elseif ext == ".cif" || ext == ".mmcif"
        key = splitext(basename(path))[1] * _model_suffix(model)

        local struc
        try
            struc = BioStructures.read(path, MMCIFFormat)
        catch e
            throw(
                StructureSourceError(
                    "failed parsing mmCIF \"$path\": $(sprint(showerror, e))",
                ),
            )
        end
        return _resolve_canonical_pdb(struc, key; model)
    else
        throw(
            StructureSourceError(
                "unrecognized structure file extension \"$ext\" for \"$path\"; " *
                "expected .pdb, .cif, or .mmcif",
            ),
        )
    end
end

function reslove_struct(source::PDBIDSource; model::Integer = 1)::String
    id = uppercase(source.id)
    model >= 1 || throw(StructureSourceError("model must be at least 1, got $model"))
    existing = joinpath(_store_dir(), id * _model_suffix(model) * ".pdb")
    isfile(existing) && return existing   # presence trusted outright, no re-fetch

    tmpdir = mktempdir()
    local struc
    try
        struc = retrievepdb(id; dir = tmpdir, format = MMCIFFormat)
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(
            StructureSourceError("failed fetching PDB ID \"$id\": $(sprint(showerror, e))"),
        )
    end
    local chosen
    try
        chosen = _nth_model(struc, model, id)   # the first one is first whatever its number
    catch e
        rm(tmpdir; recursive = true, force = true)
        rethrow()
    end
    try
        writepdb(existing, chosen, _canonical_selector(chosen))
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(
            StructureSourceError(
                "failed writing canonical .pdb for \"$id\": $(sprint(showerror, e))"),
        )
    end
    rm(tmpdir; recursive = true, force = true)
    return existing
end

"""
Heuristic mmCIF/legacy-PDB sniff on downloaded content, per PDBTools.jl's 
documented approach: the literal `loop_` keyword appears in mmCIF but not 
legacy PDB. Not a guarantee; an unusual server response could defeat it.
"""
function _sniff_format(path::AbstractString)
    for line in eachline(path)
        occursin("loop_", line) && return MMCIFFormat
    end
    return PDBFormat
end

function reslove_struct(source::URLSource; model::Integer = 1)::String
    url = source.url
    model >= 1 || throw(StructureSourceError("model must be at least 1, got $model"))
    key = source.id * _model_suffix(model)

    tmpdir = mktempdir()
    local struc
    try
        raw = joinpath(tmpdir, "download")
        Downloads.download(url, raw)
        fmt = _sniff_format(raw)
        struc = BioStructures.read(raw, fmt)
    catch e
        rm(tmpdir; recursive = true, force = true)
        throw(
            StructureSourceError(
                "failed fetching/parsing URL \"$url\": $(sprint(showerror, e))",
            ),
        )
    end
    path = _resolve_canonical_pdb(struc, key; model)
    rm(tmpdir; recursive = true, force = true)
    return path
end

"""
    _pdb_model(path, k) -> String

The `k`-th model (counted from 1, in file order) of the .pdb at `path`, as a .pdb of its own
in [`_store_dir`](@ref): the lines before the first `MODEL` record, the lines of that model
without its `MODEL`/`ENDMDL` records, and `END`. The name is `<stem>_model<k>_<hash>.pdb`,
the hash that of the content (8 hexadecimal digits of SHA-256), so a file of the same name
in another folder, or an edited file, never reuses another's copy and the caches of the
hydrogens (keyed by this path) stay right. An existing copy is reused.

# Exceptions
- [`StructureSourceError`](@ref): the file has no `MODEL` records or fewer than `k` models.
"""
function _pdb_model(path::AbstractString, k::Integer)::String
    lines = readlines(path)
    starts = findall(l -> startswith(l, "MODEL"), lines)
    k <= length(starts) || throw(
        StructureSourceError(
            "model $k was asked for but \"$path\" has $(max(1, length(starts))) model(s)",
        ),
    )
    stop = k < length(starts) ? starts[k+1] - 1 : length(lines)
    body = [
        l for l in @view(lines[(starts[k]+1):stop])
        if !startswith(l, "ENDMDL") && !startswith(l, "END")
    ]
    text = join(vcat(lines[1:(starts[1]-1)], body, "END"), "\n") * "\n"
    stem = splitext(basename(path))[1]
    out = joinpath(
        _store_dir(), "$(stem)_model$(k)_$(first(bytes2hex(SHA.sha256(text)), 8)).pdb")
    if !isfile(out)
        tmp = out * ".tmp." * string(getpid())
        write(tmp, text)
        mv(tmp, out; force = true)
    end
    return out
end

"""
    keep_chains(path, chains) -> String

The structure at the .pdb `path` reduced to the chains `chains` (a collection of
one-character ids, case counts), for [`seed_model`](@ref BAYSOL.Pipeline.seed_model)'s
`chains`. With no chains (the default) it returns `path` itself, with nothing written,
so a run without the option is the run it always was. Otherwise the `ATOM`, `HETATM`,
`ANISOU` and `TER` records of those chains (every `TER` block that carries one of the
ids) are written, with `END`, to `<stem>_chains<ids>_<hash>.pdb` in [`_store_dir`](@ref)
(the hash is that of the content, so the copy follows the file and the hydrogen caches
keyed by the path stay right), and the path of that copy is returned. The filter reads
the text, as [`sanitized_copy`](@ref) does, so it works on a file BioStructures would
refuse. It acts on the ids as they are written, before any relabelling of reused ids.

# Returns
- `path` for no chains, else the path of the reduced copy.

# Exceptions
- [`StructureSourceError`](@ref): a chain that has no atom record in the file (the message
    lists the chains the file has).
"""
function keep_chains(path::AbstractString, chains)::String
    ids = String[String(c) for c in chains]
    isempty(ids) && return String(path)
    keep = Set(only(c) for c in ids)
    lines = readlines(path)
    present = Set{Char}()
    out = String[]
    for l in lines
        (
            startswith(l, "ATOM") || startswith(l, "HETATM") || startswith(l, "ANISOU") ||
            startswith(l, "TER")
        ) || continue
        c = length(l) >= 22 ? l[22] : ' '
        startswith(l, "TER") || push!(present, c)
        c in keep && push!(out, l)
    end
    missing_ids = sort!([c for c in ids if only(c) ∉ present])
    isempty(missing_ids) || throw(
        StructureSourceError(
            "chain(s) $(join(missing_ids, ", ")) not found in \"$(basename(path))\", " *
            "which has $(join(sort!(collect(present)), ", "))"),
    )
    text = join(vcat(out, "END"), "\n") * "\n"
    stem = splitext(basename(path))[1]
    name = "$(stem)_chains$(join(sort(ids)))_$(first(bytes2hex(SHA.sha256(text)), 8)).pdb"
    dest = joinpath(_store_dir(), name)
    if !isfile(dest)
        tmp = dest * ".tmp." * string(getpid())
        write(tmp, text)
        mv(tmp, dest; force = true)
    end
    return dest
end
