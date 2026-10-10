# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Small scientific helpers the rest of the package builds on: physical constants and
Shannon binning. Each is re-bound at the package root (`BAYSOL.PhysicalConstants`,
…). `Utils` is the only module with submodules. The process machinery (caching,
timing, GC pausing, threading) is in [`Runtime`](@ref BAYSOL.Runtime), the point
sets and surfaces in [`Geometry`](@ref BAYSOL.Geometry).
"""
module Utils

include("PhysicalConstants.jl")
include("Shannon.jl")

end # module
