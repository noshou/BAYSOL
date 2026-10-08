# SPDX-License-Identifier: LGPL-2.1-or-later

module MolecularStructure

using  SQLite: SQLite
using  DBInterface: DBInterface
using  FastClosures: @closure
using  ..PhysicalConstants: PM_PER_ANGSTROM

"""
Default number of points to generate to sample excluded volume.
10.1016/j.bpj.2023.10.034 uses a 16³ voxel grid for each atom;
a sphere occupies π/6 of the cube. This works out to roughly
(π/6 * 16³) ≈ 2145 points being occupied.
"""
const N_VOL_SHELL::Int64 = 2145

"""
Package-root-relative  local store (`_cache`/). Created on first use.
"""
function _store_dir()::String
    dir = joinpath(pkgdir(@__MODULE__), "_cache")
    mkpath(dir)
    return dir
end

include("AtomicRadii.jl")
include("Mols.jl")
include("ExcludedVolumes.jl")
include("Propka.jl")
include("StructureSource.jl")
include("Pdb2pqr.jl")

export  lookup_radii, Ion, tryparse_ion, ion_key, ion_radius, element_radius, nearest_ion, resolve_one,
        Molecule, MoleculeError, create, coords_cartesian, coords_spherical,
        to_spherical, radii, vols, r_max, neighbour_tree, elms, name, n_atoms,
        propka_pKas, PropkaError, StructureSource, LocalPathSource,
        PDBIDSource, URLSource, StructureSourceError, resolve_structure, load_molecule,
        resolve_hydrogens, Pdb2pqrError, excluded_volume

end # module
