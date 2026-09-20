# SPDX-License-Identifier: LGPL-2.1-or-later

module BayeSol

include("Helpers/Helpers.jl")
include("AtomicRadii/AtomicRadii.jl")
include("FormFactor/FormFactor.jl")
include("PartialMolarVolumes/PMV.jl")
include("MolecularStructure/MolecularStructure.jl")
include("Solvation/Solvation.jl")
include("Scattering/Scattering.jl")
include("Fitting/Fitting.jl")

using .Helpers:            Helpers
using .Helpers.Constants:  Constants
using .Helpers.Cache:      Cache
using .AtomicRadii:        AtomicRadii
using .FormFactor:         FormFactor
using .PartialMolarVolumes: PartialMolarVolumes
using .MolecularStructure: MolecularStructure
using .Solvation:          Solvation
using .Scattering:         Scattering
using .Fitting:            Fitting

# eventual orchestration to go from PDB source -> Seed goes here 

end # module
