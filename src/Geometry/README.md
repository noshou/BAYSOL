# Geometry

Geometry of clouds of spheres, in one module (`BAYSOL.Geometry`): the low-discrepancy point sets everything samples with, the per-atom excluded (displaced-solvent) volume, and the solvent-accessible surface that carries the hydration shell (the contrasts δρ₁, δρ₂, δρ₃ of `Inference`). It depends only on `Runtime`; `MolecularStructure` builds on it (`Molecule <: SphereCloud`) and `Scattering` consumes it.


| File                 | Provides                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| `Geometry.jl`        | the module: [`SphereCloud`](@ref BAYSOL.Geometry.SphereCloud) and every tunable constant (below) |
| `PlasticSequence.jl` | `plastic_points`, `Vec2`, `Vec3`: even point sets on the plane, the sphere surface and the ball  |
| `ExcludedVolumes.jl` | `excluded_volume`, `sphere_volume`: the per-atom displaced-solvent volume                        |
| `SasaMetrics.jl`     | the exact occlusion tests (`_caps!`, `blocked`)                                                  |
| `SASA.jl`            | `sasa`, `BeadClass` (`CONVEX`, `CONCAVE`, `CAVITY`): the classified accessible-surface cloud     |

## SphereCloud

`sasa` and `excluded_volume` work on any subtype of `SphereCloud` implementing `coords_cartesian` ((3, n) centres), `radii`, `r_max` and `neighbour_tree` (a `KDTree` of the centres). `MolecularStructure.Molecule` extends these generics, so `sasa(mol)` works and `MolecularStructure` re-exports the accessors.

**Neighbour search.** Two spheres of radii `a, b` overlap iff the centre distance `d < a + b`. For atom `i` with `ρ_i = r_i + probe` (surface) or `r_i` (volume), every neighbour has `r_j ≤ r_max`, so a k-d tree range query of radius `ρ_i + r_max + probe` (`r_i + r_max` for volumes) returns a superset of the atoms that can matter. In a protein (~0.1 atom/Å³) that is ~100 candidates whatever the size of the molecule, so the neighbour work is linear in the number of atoms, not quadratic.

## Plastic sequence

Random points estimate the covered fraction of a sphere with error `√(p(1−p)/n)` (3 % at `p = ½`, `n = 256`). The plastic sequences `R_d` (Roberts 2018) have discrepancy `O((log n)^d/n)`: with `ϱ_d` the root of `x^{d+1} = x + 1` (`PLASTIC_RATIO_2 ≈ 1.324718`, `PLASTIC_RATIO_3 ≈ 1.220744`, hard-coded, so no root finder at load time), term `i` is `x_i = ({i/ϱ₂}, {i/ϱ₂²})`, computed by division so the fractional part stays accurate until `i` nears 10¹⁵. On polar caps the worst error of 256 points is 0.7 % (random: 5.5 %); on arbitrary caps 2.6 % against 4.8 %. The sets are deterministic and **prefix-stable** (`plastic_points(k, …) == plastic_points(n, …)[1:k]`), which the witness pass below uses, and good for any `n`.

- `plastic_points(n, Val(2))`: the first `n` raw `R₂` terms, uniform on `[0,1)²`.
- `plastic_points(n, Val(3))` (= `Val(:surface)`): those terms read as (azimuth, height) and lifted to the unit sphere, `φ = 2πu`, `z = 2v − 1`, `p = (√(1−z²)cos φ, √(1−z²) sin φ, z)` (Archimedes' hat-box theorem: uniform in *area*, `|p| = 1`).
- `plastic_points(n, Val(3), Val(:volume))`: the `R₃` terms filling the ball, the third coordinate giving the radius `r = w^{1/3}` (inverse CDF of `P(R ≤ r) = r³`; `r = w` would over-populate the centre).
- `plastic_points(n; dim = 3, shape = :surface)`: keyword front end.

```julia
using BAYSOL.Geometry: plastic_points
surf = plastic_points(256)                         # sphere surface
ball = plastic_points(256, Val(3), Val(:volume))   # fills the ball
```

## Excluded volumes

`vols(mol)` (MolecularStructure, memoised) is the per-atom volume of the excluded-volume dummy species: the solvent the atom displaces. An isolated atom displaces `4π r³/3`, but atoms overlap, and counting each sphere whole counts the overlaps several times. `excluded_volume(cart, rads, tree, rmax)` adapts Chamberlain, Moore & Grant (2023), 10.1016/j.bpj.2023.10.034: space is partitioned by the **radical planes**. The power of a point `x` w.r.t. sphere `i` is `π_i(x) = |x − c_i|² − r_i²`; `π_i = π_j` is the plane perpendicular to `c_j − c_i` at signed distance

```math
h_{ij}=\frac{d^2+r_i^2-r_j^2}{2d}\qquad(d=|c_j-c_i|)
```

from `c_i` (through the circle of intersection for intersecting spheres). Each atom keeps the part of its own ball in its own power cell `C_i = {x : π_i ≤ π_j ∀j}`, and the pieces `B_i ∩ C_i` **partition** the union of the balls (a point of the union lies in the cell of the sphere minimising `π`, and then `π_i ≤ π_j ≤ 0`), so `Σ V_i = vol(∪ B_j)` exactly, up to sampling error. Each ball is sampled with `N_VOL_SHELL = 2145` plastic volume points `x_p = c_i + r_i u_p`; a point beyond some neighbour's plane (one dot product, `x·n > thresh`, vectorised over points) is a victim, and `V_i = (4π/3) r_i³ (N − #victims)/N` (standard error ≤ 1.1 % of `V_i`, smaller for quasi-random points, and averaging over 10³–10⁴ atoms). An atom without overlapping neighbours keeps its whole sphere.

The sum is the volume of the van der Waals union and omits the packing voids no solvent can reach (with hydrogens ≈ 0.73 of the sequence partial molar volume, ≈ 0.66 of CRYSOL's fitted `Vol` on SASDA52). Chamberlain et al. correct this with per-atom-type factors; BAYSOL leaves it to the profiled `c1`: across the fitting tests `c1 ≈ 1.15–1.22`, `c1³ ≈ 1.5–1.8` (consistent with `1/0.73` and `1/0.66`). A solvent-excluded-surface partition that includes the voids was tried and reverted: every dataset's best fit then needed a negative convex-shell contrast, which the priors exclude, and SASDA52 degraded from `χ²_red ≈ 6` to ≈ 19. `radii` stays the isolated van der Waals radius throughout; `vols` is **not** `(4/3)π·radii³`.

## Solvent-accessible surface

The accessible surface is the boundary of the union of the *expanded* spheres `(c_i, ρ_i)`, `ρ_i = r_i + probe` (`PROBE_RADIUS` = 1.4 Å, water), exposed to the outside. Shrake–Rupley: each expanded sphere is sampled at `SHELL_SAMPLE = 256` plastic surface directions `u_j`; the point `p = c_i + ρ_i u_j` is accepted if it lies inside no other expanded sphere, and stands for the area `4πρ_i²/256`, so `Â = Σ_i (4πρ_i²/256)·#accepted_i`.

**Occlusion is one dot product.** With `d = c_j − c_i`, the point lies inside sphere `j` iff

```math
\mathbf u\cdot\mathbf d\ \ge\ t_j=\frac{|d|^2+\rho_i^2-\rho_j^2}{2\rho_i},
```

a spherical cap of angular radius `arccos(t_j/|d|)` around `d/|d|`. With `(d, t_j)` stored once per neighbour, a direction costs three multiplications, two additions and a compare, vectorised over directions. `_caps!` first classifies the atom from the sphere geometry alone (`Coverage`): `ALL_BURIED` (a neighbour engulfs it, `d + ρ_i ≤ ρ_j`: skipped), `ALL_EXPOSED` (no neighbour reaches it, `d ≥ ρ_i + ρ_j`, or `j` lies strictly inside `i`: all 256 directions kept untested) or `AMBIGUOUS`, and packs only the `K` neighbours that cut a cap (`|ρ_i − ρ_j| < d < ρ_i + ρ_j`). In a bonded protein the first two cases almost never occur; the saving is from ~100 candidates to a few tens of caps.

**Witness pass.** The directions are tested in two blocks of the prefix-stable sequence, `1:SASA_N_OCC` (104) then the rest, one cap at a time, each block stopping as soon as all its directions are occluded. If none of the first 104 is open, an atom exposes at most ≈ `3/104` of its sphere (rule of three), so it contributes no points and the second block is skipped; every other atom keeps exactly the points the per-point `blocked` test would keep, in the same order. The cost is a systematic underestimate of the accessible area on the protein fixtures (crambin, BPTI, RNase A, hemoglobin, IgG; worst fixture): 2.02 % at a 48-direction prefix, 1.40 % at 64, 0.90 % at 80, 0.66 % at 96, **0.57 % at 104**, 0.40 % at 128; 80 is the shortest within budget but with no margin, and 0.31–0.57 % is within the 0.92 % error of the 256-direction sampling itself (40–58 % of atoms leave after the first block).

**Thinning.** The ~10⁴–10⁵ accepted points are thinned to a budget `B = max(SHELL_MIN_POINTS, round(Â/SHELL_AREA_PER_POINT))` (4 Å² per point, calibrated against CRYSOL's default Fibonacci grid) by a Bresenham allocation: with `c_i` accepted points, `C_i = Σ_{l≤i} c_l` and `m = C_n`, atom `i` keeps `b_i = ⌊C_i B/m⌋ − ⌊C_{i−1} B/m⌋` of them (a prefix). Then `Σ b_i = B` exactly, `0 ≤ b_i ≤ c_i` and `|b_i − c_i B/m| < 1`; all points carry the same area `Â/B`, so the total is conserved.

**Classification** (`_bead_class`). From each bead with outward normal `n̂` rays are cast against the expanded spheres within `BEAD_RAY_RANGE` = 12 Å (a ray `p + su` hits sphere `j` iff `Δ = b² − (|w|² − ρ_j²) ≥ 0` and `−b + √Δ > 0`, `w = p − c_j`, `b = w·u`). If the ray along `n̂` escapes the bead is at least convex; otherwise `BEAD_RAY_DIRS` = 64 plastic directions are tried, those with `u·n̂ > 0` (about half) are kept, and with `f_esc` the escaping fraction

```math
\text{class}=\begin{cases}\text{CAVITY}& f_{esc}=0\\ \text{CONCAVE}&0<f_{esc}<\tfrac12\\ \text{CONVEX}& f_{esc}\ge\tfrac12\end{cases}\qquad(\texttt{BEAD\_CONVEX\_ESCAPE}=0.5)
```

A geometric proxy for exposure: convex points of a globular surface see almost the whole outward hemisphere, clefts see little, enclosed water none. Cavity detection is exact for voids up to `BEAD_RAY_RANGE` across; a larger void degrades to open surface. Each bead then scatters as a Gaussian dummy of volume `(Â/B)·SHELL_THICKNESS` (Scattering).

```julia
using BAYSOL.Geometry: sasa, CONVEX, CONCAVE, CAVITY, PROBE_RADIUS

pts, areas, class = sasa(mol; probe = PROBE_RADIUS, n_target = nothing)
# pts: (3, M) accessible points in mol's centred frame; areas: (M,) Å², equal; class: (M,) BeadClass
```

`probe ≥ 0`; `n_target` (> 0 if given) overrides the budget derived from the accessible area.

## Parallelism

The loops over atoms (excluded volumes, SASA) and beads (classification) are cut into blocks of `ATOM_BLOCK = 64` / `CLASS_BLOCK = 256`, run on the Julia threads from `ATOM_PARALLEL_MIN = 4096` items, and the block outputs are concatenated in block order, so the cloud is the serial one bit for bit at any thread count. Each block owns its scratch arrays; the tree-typed arguments pass through a function barrier (`_sasa_loop`) so the range query is not dispatched dynamically per atom. All of it is linear in the number of atoms and a one-time cost per structure.

## Constants

Module level in `Geometry.jl`: `N_VOL_SHELL` (2145), `ATOM_BLOCK`, `ATOM_PARALLEL_MIN`, `CLASS_BLOCK` (neither affects the result), `PROBE_RADIUS` (1.4 Å), `SHELL_N_TARGET` (`nothing`: size the shell from the area), `SHELL_AREA_PER_POINT` (4.0), `SHELL_MIN_POINTS` (55), `SHELL_SAMPLE` (256), `BEAD_RAY_RANGE`, `BEAD_RAY_DIRS`, `BEAD_CONVEX_ESCAPE`, `SASA_N_OCC` (104). `PROBE_RADIUS` and `SHELL_N_TARGET` are also the hydration-shell defaults that Scattering and `seed_model` forward.
