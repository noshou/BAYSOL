# SPDX-License-Identifier: LGPL-2.1-or-later

module MolecularStructure

using SQLite: SQLite
using DBInterface: DBInterface
using FastClosures: @closure
using ..PhysicalConstants: PM_PER_ANGSTROM
using ..Runtime: Lazy, force, KeyedCache
using NearestNeighbors: KDTree
# extended for Molecule below
import ..Geometry: coords_cartesian, radii, r_max, neighbour_tree
using ..Geometry: SphereCloud, excluded_volume

"""
Package-root-relative  local store (`_cache`/). Created on first use.
"""
function _store_dir()::String
    dir = joinpath(pkgdir(@__MODULE__), "_cache")
    mkpath(dir)
    return dir
end

# ---------------------------------------------------------------------------
#   Constants and shared types
# ---------------------------------------------------------------------------

# Ion string -> (element, signed charge): element = 1-2 lowercase; magnitude has a non-zero
# leading digit (no charge 0); a bare sign means +/-1.
const _ION_RE =
    r"^\s*([a-z]{1,2})\s*(?:([1-9][0-9]*)\s*([+-])|([+-])\s*([1-9][0-9]*)?)?\s*$"

"""
Two-letter element symbols an atom name can plausibly
spell out in full (HETATM ions/metals only).
"""
const _TWO_LETTER_ELEMENTS = Set([
    "FE", "ZN", "MG", "NA", "CL", "CA", "MN", "NI", "CU", "CO", "CD", "HG",
    "BR", "SE", "AL", "SI", "AS", "LI", "BE", "NE", "AR", "KR", "SR", "MO",
    "AG", "SN", "SB", "TE", "XE", "CS", "BA", "PT", "AU", "PB",
])

"""
One lock per output path, so concurrent callers
for the same structure run the external tool once.
"""
const _PATH_LOCKS = KeyedCache{String,ReentrantLock}()

"Standard titratable protein groups for PROPKA."
const _STANDARD_GROUPS = Set(["ASP", "GLU", "CYS", "TYR", "HIS", "LYS", "ARG", "N+", "C-"])

"""
# Fields
- `_name::String`: structure identifier (e.g. PDB ID or file stem).
- `_elms::Vector{String}`: per-atom element symbol, length n.
- `_n::Int`: atom count; set at construction, never recomputed.
- `_cart::Matrix{Float64}, (3, n)`: centred Cartesian coordinates (x, y, z).
- `_sph::Matrix{Float64}, (3, n)`: spherical coordinates (r, theta, phi),
    sharing `_cart`'s column index.
- `_radii::Lazy{Vector{Float64}}`: per-atom isolated van der Waals radius
    (AtomicRadii), length n.
- `_vols::Lazy{Vector{Float64}}`: per-atom geometrically-computed excluded
    volume from [`excluded_volume`](@ref), length n.
- `_r_max::Lazy{Float64}`: largest per-atom radius in `_radii`.
- `_tree::Lazy{KDTree}`: KDTree over `_cart`, shared across neighbour queries.
"""
struct Molecule <: SphereCloud
    _name  :: String
    _elms  :: Vector{String}
    _n     :: Int                   # atom count; set at construction, never recomputed
    _cart  :: Matrix{Float64}       # (3, n) centred (x, y, z)
    _sph   :: Matrix{Float64}       # (3, n) (r, theta, phi)
    _radii :: Lazy{Vector{Float64}}
    _vols  :: Lazy{Vector{Float64}}
    _r_max :: Lazy{Float64}         # largest per-atom radius
    _tree  :: Lazy{KDTree}          # KDTree over _cart; shared across neighbour queries
end

include("AtomicRadii.jl")
include("Mols.jl")
include("StructureSource.jl")
include("Pdb2pqr.jl")

# Constants whose initializers call code defined in the
# included files (so they come after the includes).

"The tables, read from the database on first use (thread safe, built once)."
const _TABLES = Lazy{_RadiiTables}(_read_tables)

"Sentinel for \"not yet resolved\" in the `resolve_one` batch cache."
const _MISS = _Miss()

"""
The CondaPkg tools, resolved on first use (thread
safe, once per process; reset in `__init__`).
"""
const _CONDA = Ref(Lazy{_CondaTools}(_read_conda_tools))

export lookup_radii, Ion, tryparse_ion, ion_key, ion_radius, element_radius, nearest_ion,
    resolve_one,
    Molecule, MoleculeError, create, coords_cartesian, coords_spherical,
    to_spherical, radii, vols, r_max, neighbour_tree, elms, name, n_atoms,
    propka_pKas, PropkaError, StructureSource, LocalPathSource,
    PDBIDSource, URLSource, StructureSourceError, resolve_structure, load_molecule,
    resolve_hydrogens, Pdb2pqrError, excluded_volume

end # module
