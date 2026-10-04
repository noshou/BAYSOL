# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Leaf module of constant primitives.
"""
module Constants

export DEFAULT_ATOL, SHELL_THICKNESS, PROBE_RADIUS, SHELL_N_TARGET, N_VOL_SHELL,
WATER_MOLAR_MASS, WATER_ELECTRONS, ANGSTROM3_PER_LITER, CM3_PER_LITER,
DRO_UNIT, B_LM_CHUNK, AVOGADRO, DEFAULT_TEMPERATURE_C,
PMV_REFERENCE_TEMPERATURE_C, PMV_FRACTIONAL_EXPANSIBILITY,
EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS, φ_max, DRO_BOUNDS, 
DRO12_MODE, DRO12_CONCENTRATION, DRO3_CONCENTRATION, SHELL_AREA_PER_POINT, 
SHELL_MIN_POINTS, _SHELL_SAMPLE, _BEAD_RAY_RANGE, _BEAD_RAY_DIRS, 
_BEAD_CONVEX_ESCAPE, DEFAULT_QUANTILES, PLASTIC_RATIO_2, _PLASTIC_RATIO_SQR,
PLASTIC_RATIO_3, _PLASTIC_RATIO_3_SQR, _PLASTIC_RATIO_3_CUBE, GAUTSCHI_MARGIN, BESSEL_CUTOFF,
DEFAULT_TARGET_ACCEPT, NS_PER_S, SASA_N_OCC, SASA_N_EXP, SASA_AREA_TOL,
WK_S_MAX, F2_LOG_FLOOR, BACKBONE_PMV, BACKBONE_ELECTRONS, B_LM_TILE, B_LM_W_BYTES

include("Constants/absolute_tol.jl")
include("Constants/baysol_main.jl")
include("Constants/plastic.jl")
include("Constants/forward.jl")
include("Constants/physical.jl")
include("Constants/sasa.jl")
include("Constants/delta_rho.jl")
include("Constants/gautschi.jl")
include("Constants/timing.jl")
include("Constants/form_factor.jl")

end # module
