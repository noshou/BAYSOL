# SPDX-License-Identifier: LGPL-2.1-or-later

"""
The small modules every other module builds on, in dependency order: [`PhysicalConstants`](@ref
BAYSOL.Utils.PhysicalConstants) (every physical constant and unit conversion, defined once), [`Cache`](@ref BAYSOL.Utils.Cache)
(thread-safe memoization), [`Timing`](@ref BAYSOL.Utils.Timing) (per-stage wall/JIT/GC time), [`GCPause`](@ref
BAYSOL.Utils.GCPause) (the garbage collector paused around allocation-heavy stretches, with a byte budget), [`PlasticSequence`](@ref
BAYSOL.Utils.PlasticSequence) (low-discrepancy point sets) and [`Shannon`](@ref BAYSOL.Utils.Shannon) (the Shannon-channel data
reduction). Each is a named submodule, re-bound at the package root (`BAYSOL.Cache`, ...), so imports name the
submodule and not `Utils`.
"""
module Utils

include("PhysicalConstants.jl")
include("Cache.jl")
include("Timing.jl")
include("GCPause.jl")
include("PlasticSequence.jl")
include("Shannon.jl")

end # module
