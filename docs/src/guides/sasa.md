# SASA

Models the molecule's solvent-accessible surface, as input to the CRYSOL-style hydration-shell contrast terms (δρ₁/δρ₂ and the cavity contrast δρ₃, see src/Fitting/DeltaRho.jl) used by the forward scattering model.

- **SASA.jl**: solvent-accessible surface area, both as per-atom areas (Shrake–Rupley point sampling) and as a classified point cloud (convex / concave / cavity) standing in for CRYSOL's three hydration-shell bead populations.

SASA is a top-level module (`BAYSOL.SASA`). It used to live under the removed `Solvation` module, together with the Debye-Hückel cavity electrostatics. Its consumer is `Scattering.hydration`, which turns `shell_points` into the three hydration-shell species.

## SASA - solvent-accessible surface area

### Per-atom area: sasa

Implements Shrake–Rupley: each atom's *expanded* sphere (radius + probe, probe = solvent probe radius, default 1.4 Å for water) is sampled at a set of directions, and a direction is *occluded* if it lands inside any other atom's expanded sphere. The exposed fraction times the sphere's full area 4π(r+probe)² is that atom's accessible area.

Sample points come from the plastic-sequence low-discrepancy set (Geometry.PlasticSequence, see src/Geometry/README.md) rather than i.i.d. random points or a fixed spherical-cap design, for even coverage at any point count.

1. **Exact, no sampling** (Geometry.Metrics.classify, see src/Geometry/README.md): comparing centre-to-centre distance d against ρᵢ = rᵢ+probe, ρⱼ = rⱼ+probe alone decides
   `ALL_EXPOSED` (no neighbour reaches the surface → area is exactly 4π(r+probe)²) or `ALL_BURIED` (one neighbour engulfs the atom whole → area is exactly 0.0). This shortcut, along with the point/ray occlusion tests (Metrics.blocked), is a general sphere-geometry primitive independent of SASA — not specific to surface-area sampling.
2. **Witness pass** (AMBIGUOUS case, `n_occ` points): if any of the first `n_occ` sampled directions is unoccluded, sampling continues to the full `n_exp` pass. If none is, the worst-case remaining exposed fraction is bounded by the rule of three (3/`n_occ`); if the worst-case area that  could still be hiding is under `area_tol`, the atom is treated as buried without paying for the full pass.
3. **Full pass** (`n_exp` points): exposed fraction = (unoccluded points) / `n_exp`, giving area = 4π(r+probe)² · (count/`n_exp`).

Non-existence of a witness in the coarse pass is *not* proof of burial, since a finite sample can prove exposure but never burial. This is why step 2 uses a worst-case bound (`area_tol`) rather than concluding an atom is burried.

```julia
using BAYSOL.MolecularStructure: create
using BAYSOL.SASA: sasa

mol = create("my-mol", elements, coords_cartesian)
area, exposed = sasa(mol; probe = 1.4, n_occ = 512, n_exp = 4096, area_tol = 2.0)
# area:    (n,) Å² per atom, indexed like coords_cartesian(mol)'s columns
# exposed: (n,) Bool, true where the atom has ≥ 1 accessible sample point
```

Keywords:

- probe::Float64 = 1.4: solvent probe radius, Å; must be ≥ 0.
- `n_occ`::Int = 512: points for the witness pass; must be > 0 and ≤ `n_exp`.
- `n_exp`::Int = 4096: points for the full exposed-fraction pass; measured relative error against the analytic two-sphere-cap solution is ~0.065% at 4096 points.
- `area_tol`::Float64 = 2.0: Å² worst-case-exposed-area threshold below which an unwitnessed atom is called buried without the full pass.

### Point cloud: `shell_points`

The accessible surface as a (3, M) point cloud plus per-point area and a BeadClass (CONVEX / CONCAVE / CAVITY), matching CRYSOL 3's three hydration border-layer populations (each with its own fitted contrast).

Every atom is sampled at `_SHELL_SAMPLE` = 256 directions, occlusion-filtered the same way sasa does it, then thinned to a target point budget proportional to each atom's accepted-point share (`_prefix_thin`, cumulative-floor/Bresenham allocation). Points thinned this way all carry an equal share of the total area, so sum(areas) still matches sum(sasa(mol)[1]).

Classification (constants below live in `BAYSOL_Utils.Constants`) (`_bead_class`) casts rays from each surviving bead: if the outward normal escapes the molecule within `_BEAD_RAY_RANGE` = 12.0 Å the bead is at least CONVEX; otherwise rays (`_BEAD_RAY_DIRS` = 64 sampled directions, about half in the outward hemisphere) are cast over the bead's outward hemisphere and classified by escaping fraction against `_BEAD_CONVEX_ESCAPE` = 0.5: ≥ 0.5 escaping is CONVEX, > 0 but < 0.5 is CONCAVE, and 0 (every ray blocked) is CAVITY. Cavity detection is exact for voids up to `_BEAD_RAY_RANGE` across; a larger void degrades to open surface.

```julia
using BAYSOL.SASA: shell_points, CONVEX, CONCAVE, CAVITY

pts, areas, class = shell_points(mol; probe = 1.4, n_target = nothing)
# pts:   (3, M) accessible points, mol's centred cartesian frame
# areas: (M,) Å² per point, equal across all M
# class: (M,) BeadClass per point
```

Keywords:

- probe::Float64 = 1.4: solvent probe radius, Å; must be ≥ 0.
- `n_target`::Union{Nothing,Int} = nothing: total points to keep, > 0 if given. nothing derives the budget from accessible area via `SHELL_AREA_PER_POINT` = 4.0 Å²/point (calibrated against CRYSOL's default --fb 17 Fibonacci grid, ~4 Å²/point on a typical globular protein), so spacing stays fixed as the molecule grows rather than the point count staying flat. Floored at `SHELL_MIN_POINTS` = 55.
