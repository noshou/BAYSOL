# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Leaf module of constant primitives.
"""
module Constants

export DEFAULT_ATOL, SHELL_THICKNESS, PROBE_RADIUS, SHELL_N_TARGET,
DRO_UNIT, B_LM_CHUNK, AVOGADRO, DEFAULT_TEMPERATURE_C,
PMV_REFERENCE_TEMPERATURE_C, PMV_FRACTIONAL_EXPANSIBILITY,
EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS, φ_max, DRO_BOUNDS, 
DRO12_CONCENTRATION, DRO3_CONCENTRATION, SHELL_AREA_PER_POINT, 
SHELL_MIN_POINTS, _SHELL_SAMPLE, _BEAD_RAY_RANGE, _BEAD_RAY_DIRS, 
_BEAD_CONVEX_ESCAPE, DEFAULT_QUANTILES, PLASTIC_RATIO_2, _PLASTIC_RATIO_SQR,
PLASTIC_RATIO_3, _PLASTIC_RATIO_3_SQR, _PLASTIC_RATIO_3_CUBE

include("Constants/absolute_tol.jl")
include("Constants/baysol_main.jl")
include("Constants/plastic.jl")
include("Constants/forward.jl")
include("Constants/physical.jl")
include("Constants/sasa.jl")
include("Constants/delta_rho.jl")

end # module
