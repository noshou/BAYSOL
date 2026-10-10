# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Solvent-accessible surface: [`sasa`](@ref) samples every atom's probe-expanded sphere and
returns the accessible surface as a point cloud, classified into CRYSOL 3's convex /
concave / cavity border-layer populations. `sum(areas)` is the solvent-accessible area.
"""
module SASA

using ..PlasticSequence: Vec3, plastic_points
using NearestNeighbors: inrange, inrange!
using ..MolecularStructure: Molecule, radii, r_max, coords_cartesian, neighbour_tree, ATOM_BLOCK, ATOM_PARALLEL_MIN
using ..Parallel: tmap_blocks

"Beads per task in the threaded classification loop of [`SASA.sasa`](@ref BAYSOL.SASA.sasa); the result does not depend on it."
const CLASS_BLOCK = 256

"Solvent probe radius in Å (water), forwarded to [`SASA.sasa`](@ref BAYSOL.SASA.sasa)."
const PROBE_RADIUS = 1.4

"""
Default shell-dummy budget (hydration's `n_target`). nothing lets
[`SASA.sasa`](@ref BAYSOL.SASA.sasa) size the cloud from the accessible area
(≈ area / `SHELL_AREA_PER_POINT`, floored at `SHELL_MIN_POINTS`);
an Int pins it.
"""
const SHELL_N_TARGET::Union{Nothing,Int} = nothing

"""
Å² of accessible surface each shell point stands for; sets the cloud's spacing
at ≈ √`SHELL_AREA_PER_POINT` ≈ 2 Å.

Calibrated against CRYSOL: its default --fb 17 puts F(17) = 1597 points on a
typical globular protein (~6500 Å²), i.e. ~4 Å² each. Budgeting by area rather
than by a fixed count keeps that spacing at every size, and since surface area
grows as N^(2/3), the point count is sub-linear in atom count rather than flat.
CRYSOL instead caps --fb at F(18) = 2584 for any structure, which
under-resolves large complexes; pass `n_target` explicitly to reproduce that.
"""
const SHELL_AREA_PER_POINT = 4.0

"Floor on the derived point budget: F(10), the
smallest Fibonacci grid CRYSOL's --fb accepts."
const SHELL_MIN_POINTS = 55

"""
Sample directions per atom, before occlusion and before thinning. 
Internal: only fine enough to resolve one atom's patch.
"""
const SHELL_SAMPLE = 256

"""
Range (Å) over which [`_bead_class`](@ref BAYSOL.SASA._bead_class)
casts escape rays. A void whose wall is further than this in every
direction is bulk solvent, not a cavity.
"""
const BEAD_RAY_RANGE = 12.0

"""
Directions sampled by [`_bead_class`](@ref BAYSOL.SASA._bead_class);
about half fall in the outward hemisphere and are used.
"""
const BEAD_RAY_DIRS = 64

"""
Escaping fraction at or above which a bead is CONVEX; below it
(but nonzero) CONCAVE (see [`BeadClass`](@ref BAYSOL.SASA.BeadClass)).
"""
const BEAD_CONVEX_ESCAPE = 0.5

"""
Witness-pass prefix of the [`SHELL_SAMPLE`](@ref) directions in
[`SASA.sasa`](@ref BAYSOL.SASA.sasa): an atom none of whose first `SASA_N_OCC`
plastic-sequence points is exposed may still expose up to ~3/`SASA_N_OCC` of its
sphere (rule of three; a relative bound, the same for every atom size). Such an atom
skips the remaining directions and contributes no points.

**Accepted error.** The pass may cost at most the shell's own sampling error: the
256-direction sampling is off by up to 0.92 % on the analytic two-sphere cap
(`test_sasa.jl`, `SASA_CAP_RTOL`). 80 is the shortest prefix within that on the fixtures,
but with almost no margin and only ~5 ms saved per fit over 128, so 104 is used: about
half of 80's loss, a comfortable margin, and nearly all of the speed.
Measured loss of total accessible area against sampling every direction, on the protein
fixtures (crambin, BPTI, RNase A, hemoglobin, IgG):


| `SASA_N_OCC` | 48 | 56 | 64 | 80 | 96 | **104** | 128 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **worst loss** | 2.02 % | 1.83 % | 1.40 % | 0.90 % | 0.66 % | **0.57 %** | 0.40 % |

At 104 the loss is 0.31–0.57 % (always a loss, never a gain: dropped atoms have a real but
small exposed patch); 40–58 % of atoms bail, and with the packed cap test the sampling
loop runs 1.9–2.4× faster than the previous per-point test (1.15–1.20× of that is the pass).
"""
const SASA_N_OCC = 104

@assert(0 < SASA_N_OCC ≤ SHELL_SAMPLE, "SASA_N_OCC must be in (0, SHELL_SAMPLE]")

include("Metrics.jl")
include("SasaCalc.jl")

end # module SASA
