# SPDX-License-Identifier: LGPL-2.1-or-later
module Molecule

include("Molecules.jl")
include("SASA.jl")
include("Hydrophobicity.jl")

using .Molecules: Molecules
using .SASA: SASA
using .Hydrophobicity: Hydrophobicity

end # module
