# SPDX-License-Identifier: LGPL-2.1-or-later

#--------------------------------------------------------------
# Spherical Bessel functions (Gautschi continued fraction)
#--------------------------------------------------------------

"""
Start order of the continued-fraction sweep in
[`Scattering.SphFuncs.sphBessRatios!`](@ref BAYSOL.Scattering.SphFuncs.sphBessRatios!):
N = max(lMax, ⌈x⌉) + GAUTSCHI_MARGIN[1] + ⌈GAUTSCHI_MARGIN[2]·x^(1/3)⌉. Deep enough
that every ratio is converged to the Float64 rounding floor (the floor is reached at
(12, 5) against a 512-bit reference; (16, 6) leaves a safety step).
"""
const GAUTSCHI_MARGIN = (16, 6.0)
