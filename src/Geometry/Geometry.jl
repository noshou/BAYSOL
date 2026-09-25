# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Geometric primitives: low-discrepancy point sequences (PlasticSequence) 
and the pairwise-sphere shortcuts/tests built on them (Metrics).
"""
module Geometry

include("PlasticSequence.jl")
include("Metrics.jl")

using .PlasticSequence: PlasticSequence
using .Metrics:         Metrics

"Volume of a sphere of radius rad."
sphere_volume(rad::Float64)::Float64 = (4.0 / 3.0) * π * rad^3

export sphere_volume

end # module
