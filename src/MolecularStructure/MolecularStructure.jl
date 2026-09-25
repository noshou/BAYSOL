# SPDX-License-Identifier: LGPL-2.1-or-later

module MolecularStructure

"""
    _store_dir() -> String

Package-root-relative  local store (_cache/). Created on first use.
"""
function _store_dir()::String
    dir = joinpath(pkgdir(@__MODULE__), "_cache")
    mkpath(dir)
    return dir
end

include("Mols.jl")
include("ExcludedVolumes.jl")
include("Ionization.jl")
include("Propka.jl")
include("StructureSource.jl")
include("PDB2PQR.jl")

export  Molecule, MoleculeError, create, coords_cartesian, coords_spherical,
        to_spherical, radii, vols, r_max, neighbour_tree, elms, name, n_atoms, Residues,
        Ionization, propka_pKas, PropkaError, StructureSource, LocalPathSource,
        PDBIDSource, URLSource, StructureSourceError, resolve_structure, load_molecule,
        resolve_hydrogens, PDB2PQRError, excluded_volume

end # module
