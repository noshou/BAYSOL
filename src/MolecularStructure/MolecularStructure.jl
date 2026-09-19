# SPDX-License-Identifier: LGPL-2.1-or-later

module MolecularStructure

include("Mols.jl")
include("ProteinResidues.jl")

export  Molecule, MoleculeError, create, coords_cartesian, coords_spherical,
        to_spherical, radii, vols, r_max, elms, name, n_atoms, Residues

end # module
