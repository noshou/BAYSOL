# SPDX-License-Identifier: LGPL-2.1-or-later

#----------------
# SASA Constants 
#----------------

"""
Å² of accessible surface each shell point stands for; sets the cloud's spacing
at ≈ √SHELL_AREA_PER_POINT ≈ 2 Å.

Calibrated against CRYSOL: its default --fb 17 puts F(17) = 1597 points on a
typical globular protein (~6500 Å²), i.e. ~4 Å² each. Budgeting by area rather
than by a fixed count keeps that spacing at every size, and since surface area
grows as N^(2/3), the point count is sub-linear in atom count rather than flat.
CRYSOL instead caps --fb at F(18) = 2584 for any structure, which
under-resolves large complexes; pass n_target explicitly to reproduce that.
"""
const SHELL_AREA_PER_POINT = 4.0

"Floor on the derived point budget: F(10), the smallest Fibonacci grid CRYSOL's --fb accepts."
const SHELL_MIN_POINTS = 55

"Sample directions per atom, before occlusion and before thinning. 
Internal: only fine enough to resolve one atom's patch."
const _SHELL_SAMPLE = 256

"Range (Å) over which [`_bead_class`](@ref BAYSOL.SASA._bead_class) casts escape rays. A void whose 
wall is further than this in every direction is bulk solvent, not a cavity."
const _BEAD_RAY_RANGE = 12.0

"Directions sampled by [`_bead_class`](@ref BAYSOL.SASA._bead_class); about half fall in the 
outward hemisphere and are used."
const _BEAD_RAY_DIRS = 64

"Escaping fraction at or above which a bead is CONVEX; below it (but nonzero) 
CONCAVE (see [`BeadClass`](@ref BAYSOL.SASA.BeadClass))."
const _BEAD_CONVEX_ESCAPE = 0.5
"""
Default witness-pass point count per atom in [`SASA.sasa`](@ref BAYSOL.SASA.sasa):
the smallest round count measured to lose no area on a dense lattice. Catches any
atom exposed by more than ~1/512 of its sphere (about 0.2 Å²).
"""
const SASA_N_OCC = 512

"""
Default exposed-fraction point count per atom in [`SASA.sasa`](@ref BAYSOL.SASA.sasa).
Measured relative error against the analytic two-sphere cap: 1.3 % at 64 points,
0.36 % at 1024, 0.065 % at 4096, 0.02 % at 16384; costs ~0.09 ms/atom.
"""
const SASA_N_EXP = 4096

"""
Default area tolerance (Å²) in [`SASA.sasa`](@ref BAYSOL.SASA.sasa): an atom with no
witness in the [`SASA_N_OCC`](@ref) pass may still expose up to 3/n_occ of its
sphere (rule of three); if that worst-case area is below this, the full
[`SASA_N_EXP`](@ref) pass is skipped and the atom is treated as buried.
"""
const SASA_AREA_TOL = 2.0
