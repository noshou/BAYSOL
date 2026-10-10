# SPDX-License-Identifier: LGPL-2.1-or-later

module MolecularStructure

using  SQLite: SQLite
using  DBInterface: DBInterface
using  FastClosures: @closure
using  ..PhysicalConstants: PM_PER_ANGSTROM
using  ..Cache: Lazy, force

"""
Default number of points to generate to sample excluded volume.
10.1016/j.bpj.2023.10.034 uses a 16³ voxel grid for each atom;
a sphere occupies π/6 of the cube. This works out to roughly
(π/6 * 16³) ≈ 2145 points being occupied.
"""
const N_VOL_SHELL::Int64 = 2145

"""
Atoms per task in the threaded loops over atoms ([`excluded_volume`](@ref BAYSOL.MolecularStructure.excluded_volume)).
Each atom's result is independent, so the blocks can run in any order and on any number of threads with
identical output; the size only trades task overhead against load balance.
"""
const ATOM_BLOCK::Int = 64

"""
Smallest number of atoms (or hydration beads) for which the loops over atoms are spread over the Julia threads:
below it they run in a plain loop, because the tasks then cost more than they save (a 2,592-atom fit was 1.3×
slower threaded). The decision depends on the input only, and the results do not depend on it.
"""
const ATOM_PARALLEL_MIN::Int = 4096

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
