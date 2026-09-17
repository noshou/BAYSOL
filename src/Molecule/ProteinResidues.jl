# SPDX-License-Identifier: LGPL-3.0-or-later
module ProteinResidues

export Residues

"""
Per-atom residue/atom-name identity for a protein `Molecule`.
"""
struct Residues
    resname  :: Vector{String}
    atomname :: Vector{String}
end

end