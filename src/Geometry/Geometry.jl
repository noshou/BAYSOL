# SPDX-License-Identifier: LGPL-2.1-or-later

"""
The point sets everything samples with ([`plastic_points`](@ref)), the
per-atom excluded (displaced-solvent) volume ([`excluded_volume`](@ref)) and
the solvent-accessible surface ([`sasa`](@ref)), which returns the accessible
surface as a point cloud classified into CRYSOL 3's convex / concave / cavity
border-layer populations (`sum(areas)` is the solvent-accessible area).

The algorithms take a [`SphereCloud`](@ref), which supplies centres, radii and a
neighbour tree; a [`Molecule`](@ref BAYSOL.MolecularStructure.Molecule) is one.
"""
module Geometry

using ..Runtime: tmap_blocks
using NearestNeighbors: inrange, inrange!, KDTree
using LinearAlgebra: dot
using StaticArrays: SVector

"""
What [`sasa`](@ref) needs of a structure: a subtype implements
[`coords_cartesian`](@ref), [`radii`](@ref), [`r_max`](@ref) and
[`neighbour_tree`](@ref). [`Molecule`](@ref BAYSOL.MolecularStructure.Molecule) does.
"""
abstract type SphereCloud end

"(3, n) cartesian centres of a [`SphereCloud`](@ref)."
function coords_cartesian end

"Per-sphere radii (length n) of a [`SphereCloud`](@ref)."
function radii end

"Largest radius of a [`SphereCloud`](@ref)."
function r_max end

"A `KDTree` over the centres of a [`SphereCloud`](@ref)."
function neighbour_tree end

# --- constants and types the included files use (before the includes) ---

"2-D plastic ratio, the real root of x³ = x + 1"
const PLASTIC_RATIO_2 = 1.324717957244746

"Square of 2-D plastic ratio"
const PLASTIC_RATIO_2_SQR = 1.754877666246693

"3-D plastic ratio, the real root of x⁴ = x + 1"
const PLASTIC_RATIO_3 = 1.2207440846057596

"Square of 3-D plastic ratio"
const PLASTIC_RATIO_3_SQR = 1.490216120099954

"Cube of 3-D plastic ratio"
const PLASTIC_RATIO_3_CUBE = 1.819172513396165

"A point in the plane, (x, y)."
const Vec2 = NTuple{2,Float64}

"A unit vector on the sphere, (x, y, z)."
const Vec3 = NTuple{3,Float64}

"""
    Coverage

How much of a sphere its neighbours cover.
- `ALL_EXPOSED`:    no neighbour reaches the sphere, so the exposed fraction is
                    exactly 1 and the area/volume is exactly the full sphere's.
- `ALL_BURIED`:     a single neighbour swallows the whole sphere, so the exposed
                    fraction is exactly 0.
- `AMBIGUOUS`:      neighbours cut caps but no single one settles it; only point
                    sampling can estimate the fraction.
"""
@enum Coverage ALL_EXPOSED ALL_BURIED AMBIGUOUS

include("PlasticSequence.jl")

# --- tunable constants ---


"""
Default number of points to generate to sample excluded volume.
10.1016/j.bpj.2023.10.034 uses a 16³ voxel grid for each atom;
a sphere occupies π/6 of the cube. This works out to roughly
(π/6 * 16³) ≈ 2145 points being occupied.
"""
const N_VOL_SHELL::Int64 = 2145

"""
Atoms per task in the threaded loops over atoms ([`excluded_volume`](@ref), [`sasa`](@ref)).
Each atom's result is independent, so the blocks can run in any order and on any number of
threads with identical output; the size only trades task overhead against load balance.
"""
const ATOM_BLOCK::Int = 64

"""
Smallest number of atoms (or hydration beads) for which the loops over atoms are
spread over the Julia threads: below it they run in a plain loop, because the
tasks then cost more than they save (a 2,592-atom fit was 1.3× slower threaded).
The decision depends on the input only, and the results do not depend on it.
"""
const ATOM_PARALLEL_MIN::Int = 4096

"""
Beads per task in the threaded classification loop of
[`sasa`](@ref BAYSOL.Geometry.sasa); the result does not depend on it.
"""
const CLASS_BLOCK = 256

"Solvent probe radius in Å (water), forwarded to [`sasa`](@ref BAYSOL.Geometry.sasa)."
const PROBE_RADIUS = 1.4

"""
Default shell-dummy budget (hydration's `n_target`). nothing lets
[`sasa`](@ref BAYSOL.Geometry.sasa) size the cloud from the accessible area
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
Range (Å) over which [`_bead_class`](@ref BAYSOL.Geometry._bead_class)
casts escape rays. A void whose wall is further than this in every
direction is bulk solvent, not a cavity.
"""
const BEAD_RAY_RANGE = 12.0

"""
Directions sampled by [`_bead_class`](@ref BAYSOL.Geometry._bead_class);
about half fall in the outward hemisphere and are used.
"""
const BEAD_RAY_DIRS = 64

"""
Escaping fraction at or above which a bead is CONVEX; below it
(but nonzero) CONCAVE (see [`BeadClass`](@ref BAYSOL.Geometry.BeadClass)).
"""
const BEAD_CONVEX_ESCAPE = 0.5

"""
Witness-pass prefix of the [`SHELL_SAMPLE`](@ref) directions in
[`sasa`](@ref BAYSOL.Geometry.sasa): an atom none of whose first `SASA_N_OCC`
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

# --- constants whose initializers call `plastic_points`
# (PlasticSequence.jl), so they come after it ---

"""
Points to map onto the volume of a sphere.
"""
const _pts::Vector{Vec3} = plastic_points(N_VOL_SHELL, Val(3), Val(:volume))

"""
The same points as three coordinate vectors, so
the per-plane test below vectorizes over points.
"""
const _ux::Vector{Float64} = [u[1] for u in _pts]
const _uy::Vector{Float64} = [u[2] for u in _pts]
const _uz::Vector{Float64} = [u[3] for u in _pts]

include("ExcludedVolumes.jl")
include("SasaMetrics.jl")
include("SASA.jl")

end # module Geometry
