# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Solvent-accessible surface area machinery. Currently just `PlasticMap` (even,
incrementally-extensible unit-sphere point sets); the Shrake–Rupley occlusion
pass will land here on top of it.
"""
module SASA

include("PlasticMap.jl")

using .PlasticMap: PlasticMap

end # module
