# SPDX-License-Identifier: LGPL-2.1-or-later

#-------------------------
# Forward model constants
#-------------------------

"""
Hydration-shell thickness in Å: how far the perturbed-density water layer
extends beyond the solvent-accessible surface. 3.0 is CRYSOL's border-layer
default.
"""
const SHELL_THICKNESS = 3.0

"Solvent probe radius in Å (water), forwarded to [`SASA.shell_points`](@ref BAYSOL.SASA.shell_points)."
const PROBE_RADIUS = 1.4

"""
Default shell-dummy budget (hydration's n_target). nothing lets
[`SASA.shell_points`](@ref BAYSOL.SASA.shell_points) size the cloud from the accessible area
(≈ area / SHELL_AREA_PER_POINT, floored at SHELL_MIN_POINTS);
an Int pins it.
"""
const SHELL_N_TARGET::Union{Nothing,Int} = nothing

"""
Default number of points to generate to sample excluded volume.
10.1016/j.bpj.2023.10.034 uses a 16³ voxel grid for each atom;
a sphere occupies π/6 of the cube. This works out to roughly
(π/6 * 16³) ≈ 2145 points being occupied.
"""
const N_VOL_SHELL::Int64 = 2145


"Atoms/dummies per pass in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm)."
const B_LM_CHUNK = UInt64(2048)

"""
Atoms per inner tile of [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm):
the inner dimension of each per-degree BLAS product. Large enough that `dgemm`
runs near peak (measured at 256), small enough to bound the W buffer together
with [`B_LM_W_BYTES`](@ref). Results are tile-invariant up to rounding.
"""
const B_LM_TILE = 256

"""
Memory budget, in bytes, for the per-tile W buffer (all degrees ≤ lMax, every
amplitude column, a q-tile) in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm);
the q-tile length is chosen to fit it.
"""
const B_LM_W_BYTES = 64 * 2^20
