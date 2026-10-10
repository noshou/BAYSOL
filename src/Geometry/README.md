# Geometry

Geometry of clouds of spheres, in one module (`BAYSOL.Geometry`): the low-discrepancy point sets that everything below samples with, the per-atom excluded (displaced-solvent) volume, and the solvent-accessible surface that models the hydration shell (the CRYSOL-style contrast terms δρ₁/δρ₂ and the cavity contrast δρ₃, see `src/Inference/DeltaRho.jl`). It depends only on `Runtime` (threading helpers); `MolecularStructure` builds on it (`Molecule <: SphereCloud`) and `Scattering` consumes it.

| File | Provides |
|---|---|
| `Geometry.jl` | the module: [`SphereCloud`](@ref BAYSOL.Geometry.SphereCloud) and its interface, and every tunable constant (below) |
| `PlasticSequence.jl` | `plastic_points`, `Vec2`, `Vec3`: even point sets on the plane, the sphere surface and the ball |
| `ExcludedVolumes.jl` | `excluded_volume`, `sphere_volume`: the per-atom displaced-solvent volume |
| `SasaMetrics.jl` | the exact occlusion tests (`_caps!`, `blocked`) |
| `SASA.jl` | `sasa`, `BeadClass` (`CONVEX`, `CONCAVE`, `CAVITY`): the classified accessible-surface point cloud |

## SphereCloud

`sasa` works on any subtype of `SphereCloud` that implements `coords_cartesian` ((3, n) centres), `radii`, `r_max` and `neighbour_tree` (a `KDTree` over the centres). The generic functions are owned by `Geometry`; `MolecularStructure.Molecule` extends them, so `sasa(mol)` works on a molecule and `MolecularStructure` re-exports the accessors.

## Plastic sequence (`PlasticSequence.jl`)

Even point sets drawn from the plastic (`R_d`) family of additive low-discrepancy sequences (Roberts, M. (2018). The Unreasonable Effectiveness of Quasirandom Sequences.). Consumers: [`sasa`](@ref BAYSOL.Geometry.sasa) (surface sampling directions) and `excluded_volume` (`plastic_points(N_VOL_SHELL, Val(3), Val(:volume))`).

- The plastic ratios are module-level constants in `PlasticSequence.jl`: `PLASTIC_RATIO_2` ≈ 1.324718 (real root of x³ = x + 1) and `PLASTIC_RATIO_3` ≈ 1.220744 (real root of x⁴ = x + 1), plus the precomputed powers `PLASTIC_RATIO_2_SQR`, `PLASTIC_RATIO_3_SQR` and `PLASTIC_RATIO_3_CUBE`. They are hardcoded rather than solved for at load time, so the package no longer depends on Roots.jl.
- Vec2, Vec3: NTuple{2,Float64}/NTuple{3,Float64} point types.
- `plastic_points`(n::Int, ::Val{2}) -> Vector{Vec2}: the first n raw 2-D R₂ terms (frac(i/ρ), frac(i/ρ²)), uniform on [0, 1)².
- `plastic_points`(n::Int, ::Val{3}) -> Vector{Vec3} (same as Val{3}, Val{:surface}): those same 2-D R₂ terms read as (azimuth, height) and lifted onto the **surface** of the unit sphere via Lambert's cylindrical equal-area projection. Points are uniform in *area*, |p| == 1 .
- `plastic_points`(n::Int, ::Val{3}, ::Val{:volume}) -> Vector{Vec3}: the 3-D R₃ terms lifted to **fill** the unit ball, a 3-D region built from the R₃ generator (the extra coordinate becomes a radius, inverse-CDF-corrected for the sphere's r²dr volume element). Points are uniform in *volume*, 0 ≤ |p| < 1.
- `plastic_points`(n::Int; dim::Int=3, shape::Symbol=:surface): keyword convenience dispatching to the Val methods above; shape is only consulted when dim == 3.

Both 3-D layouts are deterministic and prefix-stable, term i never changes as n grows, so `plastic_points`(k, args...) == `plastic_points`(n, args...)[1:k] for any k ≤ n.

```julia
using BAYSOL.Geometry: plastic_points

pts2d = plastic_points(500, Val(2))                 # Vector{Vec2}, [0,1)^2
surf  = plastic_points(256)                         # Vector{Vec3}, sphere surface (default)
ball  = plastic_points(256, Val(3), Val(:volume))   # Vector{Vec3}, fills the sphere volume
```

## Excluded volumes (`ExcludedVolumes.jl`)

`sphere_volume(r)` (4π/3·r³, defined in ExcludedVolumes.jl) is the volume of an isolated sphere. `vols(mol)` (MolecularStructure, memoized on the molecule) is the per-atom volume of the excluded-volume dummy species (`Scattering._gaussian_dummy`): the solvent volume the atom displaces. `excluded_volume(cart, rads, tree, rmax)` computes it geometrically, adapted from Chamberlain, Moore & Grant (2023), 10.1016/j.bpj.2023.10.034: each atom's van der Waals sphere is clipped by the radical (power-diagram) planes of its overlapping neighbours, and the surviving volume is estimated by quasi-random sampling (`N_VOL_SHELL` = 2145 plastic-sequence points per atom). An atom with no overlapping neighbour keeps its whole sphere.

The per-atom volumes sum to the volume of the vdW union. That leaves out the packing voids between atoms that no solvent can reach (with hydrogens, Σvols ≈ 0.73 of the sequence partial molar volume and ≈ 0.66 of CRYSOL's fitted `Vol` on SASDA52). Chamberlain et al. correct for this with per-atom-type scale factors fitted to lysozyme data; BAYSOL instead leaves it to the profiled excluded-volume correction c1. Across the fitting tests c1 ≈ 1.15–1.22, so c1³ ≈ 1.5–1.8 (see `test/fitting_tests/README.md`).

A solvent-excluded-surface (SES) partition that includes those voids was tried on 2026-09-29 and reverted: with it, every tested dataset's best fit required a negative convex-shell contrast (δρ₁ < 0), which the δρ priors exclude, and under the priors SASDA52's fit degraded from `χ²_red` ≈ 6 to ≈ 19.

radii stays the isolated van der Waals radius throughout ([`sasa`](@ref BAYSOL.Geometry.sasa) and hydration-shell generation need real atomic sizes); vols is **not** (4/3)π·radii³.

## Solvent-accessible surface (`SasaMetrics.jl`, `SASA.jl`)

Each atom's *expanded* sphere (radius + probe, probe = solvent probe radius, default 1.4 Å for water) is sampled at `SHELL_SAMPLE` = 256 directions, and a direction is *occluded* if it lands inside any other atom's expanded sphere. Every accepted point stands for 4π(r+probe)²/256 of area, so the cloud's total area is the Shrake–Rupley accessible-area estimate. Sample directions come from the plastic-sequence low-discrepancy set (see "Plastic sequence" above) rather than i.i.d. random points or a fixed spherical-cap design, for even coverage at any point count.

### SasaMetrics.jl: the occlusion shortcut and tests

`SasaMetrics.jl` is a file of the `Geometry` module (`sasa` is its only consumer). Its tests work over a cloud of expanded spheres (radius + probe) and don't care where a query point came from, so they work unchanged for surface or volume sample points.

- `Coverage`: @enum with values `ALL_EXPOSED`, `ALL_BURIED`, AMBIGUOUS; how much of a sphere its neighbours cover.
- `_caps!(i, candidates, crds, rads, probe, ...) -> Coverage`: the **exact, sampling-free shortcut**, which also packs the cutting caps for the sampler. Comparing centre-to-centre distance d against ρᵢ = rᵢ+probe, ρⱼ = rⱼ+probe decides `ALL_BURIED` (one neighbour engulfs the sphere: d + ρᵢ ≤ ρⱼ), or `ALL_EXPOSED` (no neighbour reaches the surface: d ≥ ρᵢ+ρⱼ, or j lies strictly inside i). Everything else, a union-of-caps question, is AMBIGUOUS.
- `blocked(p, candidates, crds, rads, probe, self) -> Bool`: whether point p lies inside any candidate's expanded sphere other than self (self is skipped since p is typically sampled on self's own expanded sphere).
- `blocked(p, d, candidates, crds, rads, probe) -> Bool`: whether the ray from p along unit direction d hits any candidate's expanded sphere.

Who calls what: `_sasa_loop` calls `_caps!` once per atom, *before* testing any direction. `ALL_BURIED` skips the atom; `ALL_EXPOSED` keeps all 256 directions untested; AMBIGUOUS returns the K neighbours whose expanded spheres actually cut a cap from atom i's (the only ones that can occlude a point of its surface). For direction u on atom i's expanded sphere (radius ρ), cap j occludes it iff u·cⱼ ≥ tⱼ, with cⱼ the neighbour's centre relative to atom i and tⱼ = (|cⱼ|² + ρ² − ρⱼ²)/2ρ: one dot product and a compare, the same test as `blocked` rearranged. The directions are tested in two blocks of the prefix-stable plastic sequence, 1:`SASA_N_OCC` (104) then the rest, vectorized over directions one cap at a time, each block stopping as soon as all its directions are occluded. **Witness pass:** if none of the first `SASA_N_OCC` directions is open, the atom can still expose at most about 3/`SASA_N_OCC` of its sphere (rule of three; a relative bound, the same for every atom size), so it contributes no points and the second block is skipped. Every other atom keeps exactly the points the per-point `blocked` test would keep, in the same order.

**Accepted error.** The witness pass trades accessible area for speed, and is allowed up to the shell sampling's error: 256 directions per atom are off by up to 0.92 % on the analytic two-sphere cap. On the protein fixtures (crambin, BPTI, RNase A, hemoglobin, IgG) the loss of total accessible area against sampling every direction is 2.02 % at a 48-direction prefix, 1.40 % at 64, 0.90 % at 80, 0.66 % at 96, 0.57 % at 104 and 0.40 % at 128 (worst fixture each). 80 is the shortest within budget but has almost no margin and saves only ~5 ms per fit over 128, so `SASA_N_OCC = 104`: 0.31–0.57 % lost (a systematic underestimate, from atoms with a real but small exposed patch), 40–58 % of atoms bail. On those fixtures the scalar shortcut itself never fires (bonded atoms always cut caps out of each other), while the packed, vectorized cap test plus the witness pass make the sampling loop 1.9–2.4× faster than the previous per-point test. `_bead_class` uses the ray form of `blocked` to classify each accepted bead; the point form is kept as the general occlusion predicate.

### The accessible surface as a point cloud: `sasa`

`sasa` returns the accessible surface as a (3, M) point cloud plus per-point area and a BeadClass (CONVEX / CONCAVE / CAVITY), matching CRYSOL 3's three hydration border-layer populations (each with its own fitted contrast).

Every atom is sampled at `SHELL_SAMPLE` = 256 directions (atoms dropped by the witness pass contribute none), occlusion-filtered as above, then thinned to a target point budget proportional to each atom's accepted-point share (`_prefix_thin`, cumulative-floor/Bresenham allocation). Points thinned this way all carry an equal share of the total accessible area, so `sum(areas)` is unchanged by thinning.

Classification (`_bead_class`; constants below are module-level in `Geometry.jl`) casts rays from each surviving bead: if the outward normal escapes the molecule within `BEAD_RAY_RANGE` = 12.0 Å the bead is at least CONVEX; otherwise rays (`BEAD_RAY_DIRS` = 64 sampled directions, about half in the outward hemisphere) are cast over the bead's outward hemisphere and classified by escaping fraction against `BEAD_CONVEX_ESCAPE` = 0.5: ≥ 0.5 escaping is CONVEX, > 0 but < 0.5 is CONCAVE, and 0 (every ray blocked) is CAVITY. Cavity detection is exact for voids up to `BEAD_RAY_RANGE` across; a larger void degrades to open surface.

```julia
using BAYSOL.Geometry: sasa, CONVEX, CONCAVE, CAVITY, PROBE_RADIUS

pts, areas, class = sasa(mol; probe = PROBE_RADIUS, n_target = nothing)
# pts:   (3, M) accessible points, mol's centred cartesian frame
# areas: (M,) Å² per point, equal across all M
# class: (M,) BeadClass per point
```

Keywords:

- `probe`::Float64 = `PROBE_RADIUS` (1.4): solvent probe radius, Å; must be ≥ 0.
- `n_target`::Union{Nothing,Int} = nothing: total points to keep, > 0 if given. nothing derives the budget from accessible area via `SHELL_AREA_PER_POINT` = 4.0 Å²/point (calibrated against CRYSOL's default --fb 17 Fibonacci grid, ~4 Å²/point on a typical globular protein), so spacing stays fixed as the molecule grows rather than the point count staying flat. Floored at `SHELL_MIN_POINTS` = 55.

## Constants

Defined at module level in `Geometry.jl`.

`N_VOL_SHELL` (2145 quasi-random points per atom for the power-diagram excluded-volume estimate), `ATOM_BLOCK` (64 atoms per task in the threaded loops over atoms) and `ATOM_PARALLEL_MIN` (4096: below this many atoms or hydration beads the loops run in a plain loop, because the tasks would cost more than they save; the result does not depend on either), `PROBE_RADIUS` (1.4 Å water probe), `CLASS_BLOCK` (256 beads per task in the threaded bead classification), `SHELL_N_TARGET` (nothing by default: [`sasa`](@ref BAYSOL.Geometry.sasa) sizes the hydration-shell cloud from the accessible area), `SHELL_AREA_PER_POINT`, `SHELL_MIN_POINTS`, `SHELL_SAMPLE`, `BEAD_RAY_RANGE`, `BEAD_RAY_DIRS`, `BEAD_CONVEX_ESCAPE`, `SASA_N_OCC` (104, the witness-pass prefix and its accepted area error; see above). `PROBE_RADIUS` and `SHELL_N_TARGET` are also the hydration-shell defaults that Scattering and `seed_model` forward.
