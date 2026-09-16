# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Thin aggregator. `Interfaces` is the swappable-backend facade: it declares the
`RadiiSource`/`FormFactorSource` markers plus their generic functions and
encapsulates the bundled backends as its own submodules.
"""
module ScatterNet

include("Constants.jl")
include("Cache.jl")
include("Interfaces/Interfaces.jl")
include("Molecule/Molecule.jl")
include("Scattering/Scattering.jl")
include("Fitting/Fitting.jl")

using .Constants:   Constants
using .Cache:       Cache
using .Interfaces:  Interfaces
using .Molecule:    Molecule
using .Scattering:  Scattering
using .Fitting:     Fitting

end # module
