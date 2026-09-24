# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Geometric primitives: low-discrepancy point sequences (`PlasticSequence`) 
and the pairwise-sphere shortcuts/tests built on them (`Metrics`).
"""
module Geometry

include("PlasticSequence.jl")
include("Metrics.jl")

using .PlasticSequence: PlasticSequence
using .Metrics:         Metrics

end # module
