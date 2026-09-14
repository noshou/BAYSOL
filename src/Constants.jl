# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Leaf module of constant primitives.
"""
module Constants

export  DEFAULT_ATOL, SHELL_THICKNESS, PROBE_RADIUS, 
SHELL_N_TARGET, DRO_UNIT, B_LM_CHUNK

#-------------------------
# Floating-point accuracy 
#-------------------------

"""
Default absolute tolerance for floating-point equality checks (`abs(a - b) < DEFAULT_ATOL`,
or `isapprox(a, b; atol = DEFAULT_ATOL)`): a few orders of magnitude above `Float64` roundoff.
"""
const DEFAULT_ATOL = 1.0e-9

#-------------------------
# Forward model constants
#-------------------------

"""
Hydration-shell thickness in Å: how far the perturbed-density water layer
extends beyond the solvent-accessible surface. `3.0` is CRYSOL's border-layer
default.
"""
const SHELL_THICKNESS = 3.0

"Solvent probe radius in Å (water), forwarded to `SASA.shell_points`."
const PROBE_RADIUS = 1.4

"""
Default shell-dummy budget (`hydration`'s `n_target`). `nothing` lets
`SASA.shell_points` size the cloud from the accessible area
(`≈ area / SASA.SHELL_AREA_PER_POINT`, floored at `SASA.SHELL_MIN_POINTS`);
an `Int` pins it.
"""
const SHELL_N_TARGET::Union{Nothing,Int} = nothing

"Shell-contrast unit in e·Å⁻³ (CRYSOL's `--dro`); `dro_k = DRO_UNIT * ρ_k`."
const DRO_UNIT = 0.03

"Atoms/dummies per pass in `compute_B_lm`."
const B_LM_CHUNK = UInt64(2048)

#--------------------
# Physical Constants 
#--------------------

"Avogadro constant, mol⁻¹ (CODATA, exact since the 2019 SI redefinition)."
const AVOGADRO = 6.02214076e23

end # module
