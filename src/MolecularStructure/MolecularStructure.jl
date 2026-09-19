# SPDX-License-Identifier: LGPL-3.0-or-later

module MolecularStructure

include("Mols.jl")
include("ProteinResidues.jl")

export  Molecule, MoleculeError, create, coords_cartesian, coords_spherical,
        to_spherical, radii, vols, r_max, elms, name, n_atoms, Residues

end # module
