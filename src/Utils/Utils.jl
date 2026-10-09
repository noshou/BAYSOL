# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Small modules the rest of the package builds on: physical constants, caching, timing, GC pausing,
low-discrepancy point sets and Shannon binning. Each is re-bound at the package root (`BAYSOL.Cache`, …).
"""
module Utils

include("PhysicalConstants.jl")
include("Cache.jl")
include("Timing.jl")
include("GCPause.jl")
include("PlasticSequence.jl")
include("Shannon.jl")

end # module
