# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Small scientific helpers the rest of the package builds on: physical constants, low-discrepancy point
sets and Shannon binning. Each is re-bound at the package root (`BAYSOL.PhysicalConstants`, …). The process
machinery (caching, timing, GC pausing) is in [`Runtime`](@ref BAYSOL.Runtime).
"""
module Utils

include("PhysicalConstants.jl")
include("PlasticSequence.jl")
include("Shannon.jl")

end # module
