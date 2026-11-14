# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Point sets ([`plasticPoints`](@ref)), per-atom excluded (displaced-solvent) volume 
([`excludedVolume`](@ref)) and the solvent-accessible surface ([`sasa`](@ref)).
"""
module Geometry

using ..Runtime: tmapBlocks
using NearestNeighbors: inrange, inrange!, KDTree
using LinearAlgebra: dot
using StaticArrays: SVector

"""
What [`sasa`](@ref) needs of a structure: a subtype implements
[`coordsCartesian`](@ref), [`radii`](@ref), [`rMax`](@ref) and
[`neighbourTree`](@ref). [`Molecule`](@ref BAYSOL.MolecularStructure.Molecule) does.
"""
abstract type SphereCloud end

"(3, n) cartesian centres of a [`SphereCloud`](@ref)."
function coordsCartesian end

"Per-sphere radii (length n) of a [`SphereCloud`](@ref)."
function radii end

"Largest radius of a [`SphereCloud`](@ref)."
function rMax end

"A `KDTree` over the centres of a [`SphereCloud`](@ref)."
function neighbourTree end

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

include("plastic-sequence.jl")

include("params.jl")

# Fixed internals: not settings (changing them could break a run), so they are not in
# params.jl.

"""
Escaping fraction at or above which a bead is CONVEX; below it
(but nonzero) CONCAVE (see [`BeadClass`](@ref BAYSOL.Geometry.BeadClass)).
"""
const BEAD_CONVEX_ESCAPE = 0.5

"""
Default number of points to generate to sample excluded volume.
10.1016/j.bpj.2023.10.034 uses a 16³ voxel grid for each atom;
a sphere occupies π/6 of the cube. This works out to roughly
(π/6 * 16³) ≈ 2145 points being occupied.
"""
const N_VOL_SHELL::Int64 = 2145

"""
Atoms per task in the threaded loops over atoms ([`excludedVolume`](@ref), [`sasa`](@ref)).
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

# --- constants whose initializers call `plasticPoints`
# (plastic-sequence.jl), so they come after it ---

"""
Points to map onto the volume of a sphere.
"""
const _PTS::Vector{Vec3} = plasticPoints(N_VOL_SHELL, Val(3), Val(:volume))

"""
The same points as three coordinate vectors, so
the per-plane test below vectorizes over points.
"""
const _UX::Vector{Float64} = [u[1] for u in _PTS]
const _UY::Vector{Float64} = [u[2] for u in _PTS]
const _UZ::Vector{Float64} = [u[3] for u in _PTS]

include("excluded-volumes.jl")
include("sasa-metrics.jl")
include("sasa.jl")

end # module Geometry
