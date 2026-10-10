# SPDX-License-Identifier: LGPL-2.1-or-later

"""
The process machinery the rest of the package runs on: thread-safe memoization, per-stage timing,
garbage-collector pausing and the threading helpers (random streams per work item, ordered task map,
BLAS scope). Each is re-bound at the package root (`BAYSOL.Cache`, …). Loaded after
[`Utils`](@ref BAYSOL.Utils): `Timing` imports `NS_PER_S` from `PhysicalConstants`.
"""
module Runtime

include("Cache.jl")
include("Timing.jl")
include("GCPause.jl")
include("Parallel.jl")

end # module
