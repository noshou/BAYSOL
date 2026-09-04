# SPDX-License-Identifier: LGPL-3.0-or-later
"""
Real-space structure: atomic/ionic radii and the `Molecule` geometry built on
them. Depends on the top-level `Interfaces` markers; `Cache` is local here.
"""
module Structure

include("Cache.jl")
include("AtomicRadii.jl")
include("Molecules.jl")

using .Cache: Cache
using .AtomicRadii: AtomicRadii
using .Molecules: Molecules

end # module
