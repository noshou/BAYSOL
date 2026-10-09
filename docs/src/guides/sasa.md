# SASA

Models the molecule's solvent-accessible surface, as input to the CRYSOL-style hydration-shell contrast terms (δρ₁/δρ₂ and the cavity contrast δρ₃, see src/Inference/DeltaRho.jl) used by the forward scattering model.

- **SASA.jl**: `sasa`, the solvent-accessible surface by Shrake–Rupley point sampling, returned as a classified point cloud (convex / concave / cavity) standing in for CRYSOL's three hydration-shell bead populations. `sum(areas)` is the solvent-accessible surface area.

## SASA - solvent-accessible surface

Each atom's *expanded* sphere (radius + probe, probe = solvent probe radius, default 1.4 Å for water) is sampled at `SHELL_SAMPLE` = 256 directions, and a direction is *occluded* if it lands inside any other atom's expanded sphere. Every accepted point stands for 4π(r+probe)²/256 of area, so the cloud's total area is the Shrake–Rupley accessible-area estimate. Sample directions come from the plastic-sequence low-discrepancy set (`PlasticSequence`, see the Utils README) rather than i.i.d. random points or a fixed spherical-cap design, for even coverage at any point count.

### Metrics.jl: the occlusion shortcut and tests

`Metrics.jl` is included into the SASA module (it is not a module of its own: `sasa` is its only consumer). Its tests work over a cloud of expanded spheres (radius + probe) and don't care where a query point came from, so they work unchanged for surface or volume sample points.

- `Coverage`: @enum with values `ALL_EXPOSED`, `ALL_BURIED`, AMBIGUOUS; how much of a sphere its neighbours cover.
- `classify(i, candidates, crds, rads, probe) -> Coverage`: the **exact, sampling-free shortcut** (a wrapper over the internal `_caps!`, which also packs the cutting caps for the sampler). Comparing centre-to-centre distance d against ρᵢ = rᵢ+probe, ρⱼ = rⱼ+probe decides `ALL_BURIED` (one neighbour engulfs the sphere: d + ρᵢ ≤ ρⱼ), or `ALL_EXPOSED` (no neighbour reaches the surface: d ≥ ρᵢ+ρⱼ, or j lies strictly inside i). Everything else, a union-of-caps question, is AMBIGUOUS.
- `blocked(p, candidates, crds, rads, probe, self) -> Bool`: whether point p lies inside any candidate's expanded sphere other than self (self is skipped since p is typically sampled on self's own expanded sphere).
- `blocked(p, d, candidates, crds, rads, probe) -> Bool`: whether the ray from p along unit direction d hits any candidate's expanded sphere.

Who calls what: `_sasa_loop` calls `_caps!` once per atom, *before* testing any direction. `ALL_BURIED` skips the atom; `ALL_EXPOSED` keeps all 256 directions untested; AMBIGUOUS returns the K neighbours whose expanded spheres actually cut a cap from atom i's (the only ones that can occlude a point of its surface). For direction u on atom i's expanded sphere (radius ρ), cap j occludes it iff u·cⱼ ≥ tⱼ, with cⱼ the neighbour's centre relative to atom i and tⱼ = (|cⱼ|² + ρ² − ρⱼ²)/2ρ: one dot product and a compare, the same test as `blocked` rearranged. The directions are tested in two blocks of the prefix-stable plastic sequence, 1:`SASA_N_OCC` (104) then the rest, vectorized over directions one cap at a time, each block stopping as soon as all its directions are occluded. **Witness pass:** if none of the first `SASA_N_OCC` directions is open, the atom can still expose at most about 3/`SASA_N_OCC` of its sphere (rule of three; a relative bound, the same for every atom size), so it contributes no points and the second block is skipped. Every other atom keeps exactly the points the per-point `blocked` test would keep, in the same order.

**Accepted error.** The witness pass trades accessible area for speed, and is allowed up to the shell sampling's error: 256 directions per atom are off by up to 0.92 % on the analytic two-sphere cap. On the protein fixtures (crambin, BPTI, RNase A, hemoglobin, IgG) the loss of total accessible area against sampling every direction is 2.02 % at a 48-direction prefix, 1.40 % at 64, 0.90 % at 80, 0.66 % at 96, 0.57 % at 104 and 0.40 % at 128 (worst fixture each). 80 is the shortest within budget but has almost no margin and saves only ~5 ms per fit over 128, so `SASA_N_OCC = 104`: 0.31–0.57 % lost (a systematic underestimate, from atoms with a real but small exposed patch), 40–58 % of atoms bail. On those fixtures the scalar shortcut itself never fires (bonded atoms always cut caps out of each other), while the packed, vectorized cap test plus the witness pass make the sampling loop 1.9–2.4× faster than the previous per-point test. `_bead_class` uses the ray form of `blocked` to classify each accepted bead; the point form is kept as the general occlusion predicate.

### The accessible surface as a point cloud: `sasa`

`sasa` returns the accessible surface as a (3, M) point cloud plus per-point area and a BeadClass (CONVEX / CONCAVE / CAVITY), matching CRYSOL 3's three hydration border-layer populations (each with its own fitted contrast).

Every atom is sampled at `SHELL_SAMPLE` = 256 directions (atoms dropped by the witness pass contribute none), occlusion-filtered as above, then thinned to a target point budget proportional to each atom's accepted-point share (`_prefix_thin`, cumulative-floor/Bresenham allocation). Points thinned this way all carry an equal share of the total accessible area, so `sum(areas)` is unchanged by thinning.

Classification (`_bead_class`; constants below are module-level in `SASA.jl`) casts rays from each surviving bead: if the outward normal escapes the molecule within `BEAD_RAY_RANGE` = 12.0 Å the bead is at least CONVEX; otherwise rays (`BEAD_RAY_DIRS` = 64 sampled directions, about half in the outward hemisphere) are cast over the bead's outward hemisphere and classified by escaping fraction against `BEAD_CONVEX_ESCAPE` = 0.5: ≥ 0.5 escaping is CONVEX, > 0 but < 0.5 is CONCAVE, and 0 (every ray blocked) is CAVITY. Cavity detection is exact for voids up to `BEAD_RAY_RANGE` across; a larger void degrades to open surface.

```julia
using BAYSOL.SASA: sasa, CONVEX, CONCAVE, CAVITY
using BAYSOL.SASA: PROBE_RADIUS

pts, areas, class = sasa(mol; probe = PROBE_RADIUS, n_target = nothing)
# pts:   (3, M) accessible points, mol's centred cartesian frame
# areas: (M,) Å² per point, equal across all M
# class: (M,) BeadClass per point
```

Keywords:

- `probe`::Float64 = `PROBE_RADIUS` (1.4): solvent probe radius, Å; must be ≥ 0.
- `n_target`::Union{Nothing,Int} = nothing: total points to keep, > 0 if given. nothing derives the budget from accessible area via `SHELL_AREA_PER_POINT` = 4.0 Å²/point (calibrated against CRYSOL's default --fb 17 Fibonacci grid, ~4 Å²/point on a typical globular protein), so spacing stays fixed as the molecule grows rather than the point count staying flat. Floored at `SHELL_MIN_POINTS` = 55.

## Constants

Defined at module level in `SASA.jl`.

`PROBE_RADIUS` (1.4 Å water probe), `SHELL_N_TARGET` (nothing by default: [`SASA.sasa`](@ref BAYSOL.SASA.sasa) sizes the hydration-shell cloud from the accessible area), `SHELL_AREA_PER_POINT`, `SHELL_MIN_POINTS`, `SHELL_SAMPLE`, `BEAD_RAY_RANGE`, `BEAD_RAY_DIRS`, `BEAD_CONVEX_ESCAPE`, `SASA_N_OCC` (104, the witness-pass prefix and its accepted area error; see the SASA README) `PROBE_RADIUS` and `SHELL_N_TARGET` are also the hydration-shell defaults that Scattering and `seed_model` forward.
