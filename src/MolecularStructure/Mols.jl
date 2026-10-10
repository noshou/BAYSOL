# SPDX-License-Identifier: LGPL-2.1-or-later

"""
A molecule.
"""

using ..Runtime: Lazy, force
using BioStructures: BioStructures, PDBFormat, standardselector,
    collectatoms, collectmodels, atomname, element, coords, ishetero
using NearestNeighbors: KDTree
using FastClosures: @closure

"Raised for malformed molecule input (empty or mismatched coords, missing radii)."
struct MoleculeError <: Exception
    msg::String
end
Base.showerror(io::IO, e::MoleculeError) = print(io, "MoleculeError: ", e.msg)


"""
Fallback element guess from an atom name, for legacy-format PDB files whose
element column (columns 77-78) is blank -- some pre-remediation-era files
predate that column. Digits/whitespace are stripped first (e.g. "1HB2" ->
"HB"). For an ATOM record (standard protein/nucleic-acid naming), only the
first letter is trusted: "CA" is always the alpha carbon (Carbon), never
calcium, under that naming convention. For a HETATM record, a name that
spells out a full two-letter element symbol (e.g. an ion literally named
"FE"/"ZN"/"NA") is trusted in full; anything else falls back to one letter.
"""
function _infer_element(name::AbstractString, is_hetatm::Bool)::String
    stripped = filter(isletter, name)
    isempty(stripped) && return ""
    if is_hetatm && length(stripped) ≥ 2
        two = uppercase(stripped[1:2])
        two in _TWO_LETTER_ELEMENTS && return two
    end
    return string(stripped[1])
end


"""
Stack coordinates into a (3, n) matrix translated to the centroid.

# Arguments
- `cs`: per-atom (x, y, z) tuples; must be non-empty.
"""
function _center(cs::Vector{NTuple{3,Float64}})::Matrix{Float64}
    n = length(cs)
    n == 0 && throw(MoleculeError("Empty coordinates"))
    sx = 0.0
    sy = 0.0
    sz = 0.0
    @inbounds @simd for c in cs
        sx += c[1]
        sy += c[2]
        sz += c[3]
    end
    nf = Float64(n)
    mx = sx / nf
    my = sy / nf
    mz = sz / nf
    out = Matrix{Float64}(undef, 3, n)
    @inbounds @simd for j in 1:n
        c = cs[j]
        out[1, j] = c[1] - mx
        out[2, j] = c[2] - my
        out[3, j] = c[3] - mz
    end
    return out
end

"""
Spherical (r, theta, phi) per column of the (3, n) cartesian matrix c,
returned as a (3, n) matrix sharing c's column index (the atom/point).
theta = acos(z/r) lies in [0, π] and phi = atan(y, x) in (-π, π].

r = 0 would make theta a 0/0; it is handled without one. The angle is arbitrary there
and unobservable downstream, since `j_l(0)` = 0 for every l > 0.

# Arguments
- `c`: (3, n) cartesian coordinates; rows are x, y, z.
"""
function to_spherical(c::AbstractMatrix{<:Real})::Matrix{Float64}
    size(c, 1) == 3 || throw(
        MoleculeError(
            "to_spherical: expected a (3, n) matrix with rows (x, y, z); " *
            "got $(size(c, 1)) rows",
        ),
    )
    n = size(c, 2)
    out = Matrix{Float64}(undef, 3, n)
    @inbounds for j in 1:n
        x = Float64(c[1, j])
        y = Float64(c[2, j])
        z = Float64(c[3, j])
        rj = sqrt(x * x + y * y + z * z)
        rsafe = rj > 0.0 ? rj : 1.0   # see the r = 0 note above
        out[1, j] = rj
        out[2, j] = acos(clamp(z / rsafe, -1.0, 1.0))
        out[3, j] = atan(y, x)
    end
    return out
end

"""
Resolve per-element radii through
[`lookup_radii`](@ref BAYSOL.MolecularStructure.lookup_radii); throws
MoleculeError on an empty list or any element with no radius data.

A negative radius is clamped to 0.0. Shannon's tables carry a handful of
these (h1+, c4+, n5+) as extrapolation artifacts of fitting to
coordination-number trends, not as physical sizes.

# Arguments
- `es`: element/ion strings, one per atom.
"""
function _compute_radii(es::Vector{String})::Vector{Float64}
    isempty(es) && throw(MoleculeError("Empty elements"))
    pairs = lookup_radii(es)
    out = Vector{Float64}(undef, length(pairs))
    @inbounds for i in eachindex(pairs)
        el, rad = pairs[i]
        rad === nothing && throw(MoleculeError("no radius data for element \"$el\""))
        out[i] = max(0.0, rad)   # negative table entries are artifacts; see above
    end
    return out
end

"""
    _to_tuples(cs) -> Vector{NTuple{3,Float64}}

Normalize any iterable of 3-component coordinates to Float64 tuples (identity
when already Vector{NTuple{3,Float64}}). Throws MoleculeError if an entry
lacks 3 components.

# Arguments
- `cs`: iterable of per-atom coordinates.
"""
_to_tuples(cs::Vector{NTuple{3,Float64}}) = cs
function _to_tuples(cs)
    out = Vector{NTuple{3,Float64}}(undef, length(cs))
    @inbounds for (i, c) in enumerate(cs)
        length(c) == 3 || throw(MoleculeError("each coordinate needs 3 components"))
        out[i] = (Float64(c[1]), Float64(c[2]), Float64(c[3]))
    end
    return out
end

"""
Build a Molecule: coords are centred at the centroid, both coordinate
frames computed now, `radii/vols/r_max` on first access.

# Arguments
- `name`: molecule label.
- `elms`: element/ion string per atom, e.g. "c", "Fe", "o2-". Case is
        normalized to lowercase (the radii and form-factor tables are lowercase-keyed),
        so elms(m) returns the lowercased strings.
- `coords`: per-atom (x, y, z) in any frame; length must match elms.
"""
function create(name::AbstractString, elms::AbstractVector{<:AbstractString}, coords)
    es = String[lowercase(e) for e in elms]   # radii/form-factor tables are lowercase-keyed
    return _build(name, es, coords, @closure(() -> _compute_radii(es)))
end

"""
[`create`](@ref)'s body: `es` are the already-lowercased element strings and
`radii` the zero-argument thunk that supplies the per-atom radii on first access.
Unexported; [`create`](@ref) is the only production caller, and the unit tests and
`test/visualize` scripts call it directly to build molecules with hand-picked radii.
"""
function _build(name::AbstractString, es::Vector{String}, coords, radii)
    cs = _to_tuples(coords)
    n  = length(cs)
    n == length(es) || throw(MoleculeError("coords and elms length mismatch"))
    cart = _center(cs)
    sph  = to_spherical(cart)
    rad  = Lazy{Vector{Float64}}(radii)
    rmax = Lazy{Float64}(@closure(() -> maximum(force(rad))))
    tree = Lazy{KDTree}(@closure(() -> KDTree(cart)))

    # Per-atom displaced-solvent volume (see `excluded_volume`,
    # Geometry/ExcludedVolumes.jl). Recomputes the max radius locally instead
    # of force(rmax), so that forcing vols does not also mark r_max as forced.
    vol = Lazy{Vector{Float64}}(
        @closure(() -> begin
            rv = force(rad)
            excluded_volume(cart, rv, force(tree), maximum(rv))
        end)
    )
    return Molecule(String(name), es, n, cart, sph, rad, vol, rmax, tree)
end

"(3, n) centroid-centred cartesian coordinates; rows are x, y, z."
coords_cartesian(m::Molecule)::Matrix{Float64} = m._cart

"(3, n) spherical coordinates about the centroid; rows are r, theta, phi."
coords_spherical(m::Molecule)::Matrix{Float64} = m._sph

"Number of atoms."
n_atoms(m::Molecule)::Int = m._n

"Per-atom radius; resolved and cached on first call."
radii(m::Molecule)::Vector{Float64} = force(m._radii)

"""
Per-atom excluded (displaced-solvent) volume. This is not the isolated van der Waals
volume; use [`BAYSOL.Geometry.sphere_volume`](@ref) on the radii.
"""
vols(m::Molecule)::Vector{Float64} = force(m._vols)

"""
Largest per-atom radius in the molecule; forces (and caches) radii.

[`sasa`](@ref BAYSOL.Geometry.sasa)'s coarse neighbour filter needs this to bound how
far away an atom can still occlude another, before any individual radius is known.
"""
r_max(m::Molecule)::Float64 = force(m._r_max)

"""
A KDTree over `coords_cartesian(m)`.
"""
neighbour_tree(m::Molecule)::KDTree = force(m._tree)

"Element/ion string per atom."
elms(m::Molecule)::Vector{String} = m._elms

"Molecule label."
name(m::Molecule)::String = m._name

"""
Parse whatever .pdb is at `pdb_path` into a Molecule.
Works identically whether `pdb_path` is heavy-atom-only or hydrogenated:
atoms are collected via standardselector alone (no heavyatomselector), so
a heavy-only file naturally yields just its heavy atoms, and a hydrogenated
file keeps its hydrogens too.

# Arguments
- `pdb_path`: path to any parseable .pdb, e.g. from [`resolve_structure`](@ref) or
    [`resolve_hydrogens`](@ref).

# Returns
- `Molecule` built from each atom's element and coordinates.
"""
function load_molecule(pdb_path::AbstractString)::Molecule
    isfile(pdb_path) || throw(MoleculeError("no such file: $pdb_path"))

    key = splitext(basename(pdb_path))[1]
    local struc
    try
        struc = BioStructures.read(pdb_path, PDBFormat)
    catch e
        throw(MoleculeError("failed parsing .pdb \"$pdb_path\": $(sprint(showerror, e))"))
    end
    # first model whatever its number (an ensemble member
    # extracted to its own file keeps e.g. MODEL 63)
    atoms = collectatoms(first(collectmodels(struc)), standardselector)

    n        = length(atoms)
    elms_v   = Vector{String}(undef, n)
    coords_v = Vector{NTuple{3,Float64}}(undef, n)

    @inbounds for (i, at) in enumerate(atoms)
        el          = element(at)
        elms_v[i]   = isempty(el) ? _infer_element(atomname(at), ishetero(at)) : el
        c           = coords(at)
        coords_v[i] = (Float64(c[1]), Float64(c[2]), Float64(c[3]))
    end

    return create(key, elms_v, coords_v)
end
