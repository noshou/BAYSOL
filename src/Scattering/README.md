# Scattering

The SAXS/SANS forward model: a molecule and a q grid in, the orientationally-averaged intensity out. Everything that depends only on geometry is computed once into a Gram matrix `G(q)`; every parameter draw afterwards costs O(Q).

## Physics

### Multipole expansion

N point scatterers with form factors `f_i(q)` at `r_i` give the amplitude `A(q) = Σ_i f_i(q) exp(i q·r_i)`. Solute molecules tumble freely, so the measured intensity is the orientational average `⟨|A|²⟩`. Averaging over rotations numerically is intractable; the Rayleigh (plane-wave) expansion

```math
e^{i\mathbf q\cdot\mathbf r} = 4\pi \sum_{l\ge 0}\sum_{m=-l}^{l} i^l\, j_l(qr)\, Y_{lm}(\hat q)\, Y_{lm}^*(\hat r)
```

turns it into a sum over multipole moments. It follows from the Legendre expansion `e^{ixμ} = Σ (2l+1) i^l j_l(x) P_l(μ)` (integrate by parts with Rodrigues' formula and use Poisson's integral for `j_l`) and the addition theorem for `P_l`. Substituting and swapping the sums:

```math
A(\mathbf q)=4\pi\sum_{lm} i^l Y_{lm}(\hat q)\,B_{lm}(q),\qquad
B_{lm}(q)=\sum_i f_i(q)\,j_l(qr_i)\,Y_{lm}^*(\hat r_i)
```

Orthonormality of `Y_lm` on the sphere kills every cross term of `|A|²` (the phases `i^l (−i)^l` cancel on the diagonal), leaving a closed form that costs O(N) per q instead of O(N²):

```math
I(q)=4\pi\sum_{l}\sum_{m=-l}^{l}|B_{lm}(q)|^2
```

Summed over all `l` this equals the Debye formula `Σ_ij f_i f_j sin(q r_ij)/(q r_ij)` (Gegenbauer's addition theorem), so the only error is the truncation at the band limit `lMax` chosen by the caller (`Utils.Shannon.auto_lmax`, `⌈q_max·D⌉`). For real `f_i`, `Y_{l,−m} = (−1)^m Y_lm^*` gives `|B_{l,−m}| = |B_lm|`, so only `m = 0..l` is stored, weighted 1 for `m = 0` and 2 otherwise (`partial_wave_weights`). Complex form factors `f = f0 + f' + i f''` are split into a real and an imaginary channel whose `|B|²` add incoherently; this is exact. At q → 0 only `l = 0` survives and `I(0) = (Σ f_i(0))²`.

### Species and the Gram matrix

The scatterers fall into five **species** that add coherently at the amplitude level: `vac` (the atoms in vacuo), `ex` (one Gaussian excluded-volume dummy per atom, the solvent it displaces) and `sh_convex`, `sh_concave`, `sh_cavity` (hydration-shell dummies on the accessible surface, CRYSOL 3's three border-layer populations). With contrast vector `v = (1, −ρₑ·g(q;c1), s₁, s₂, s₃)`, `sᵢ = δρᵢ·UNIT_OF_δρ`,

```math
I(q)=\mathbf v^\top G(q)\,\mathbf v,\qquad
G_{ab}(q)=4\pi\sum_{lm}w_{lm}\,\mathrm{Re}\!\big(B^a_{lm}\overline{B^b_{lm}}\big)
```

`G` is a Gram matrix of vectors (`√(4π w) B^a`), hence symmetric positive semidefinite at every q, so `I ≥ 0` for any parameters and `|G_ab| ≤ √(G_aa G_bb)`. It depends only on geometry and beam energy, is built once as a `(5, 5, Q)` array and repacked by `_pack_gram` into 15 distinct columns, `Q × 15`, contiguous in q (the ten envelope-free pairs among the four contrast-carrying species, the four excluded-volume cross terms, then the excluded-volume self term).

### Excluded-volume envelope

Each displaced-solvent dummy of volume `V_j` is a Gaussian whose Fourier transform is `V_j exp(−q² V_j^{2/3}/4π)` (width tied to volume, `a_j = π/V_j^{2/3}`). CRYSOL's expansion factor `c1 = r₀/r_m` scales every dummy radius, so `V_j → c1³ V_j`:

```math
F_j(q;c_1)=V_j e^{-q^2V_j^{2/3}/4\pi}\cdot c_1^3\exp\!\Big(-q^2\frac{(c_1^2-1)V_j^{2/3}}{4\pi}\Big)
```

CRYSOL replaces `V_j^{2/3}` in the second factor by one common value `(4π/3)^{2/3} r_m²`, which moves it out of the atom sum and gives the envelope `excluded_volume_factor`:

```math
g(q;c_1)=c_1^3\exp\!\big(-q^2 (c_1^2-1)\,\kappa_{EV}\, r_m^2\big),\qquad
\kappa_{EV}=\frac{(4\pi/3)^{2/3}}{4\pi}\ (\texttt{EV\_EXP\_COEFF})
```

`g(q;1) = 1`, `g(0;c1) = c1³`, and `∂ln g/∂c1 = 3/c1 − 2 c1 q² κ_EV r_m²`, so `g` increases in `c1` over the admissible window `[0.8, 1.3]` for every `q ≤ 0.5 Å⁻¹`. `r_m` is CRYSOL's own definition, `mean_atomic_radius`: the mean of the per-atom equivalent-sphere radii `cbrt(3Vᵢ/4π)` of the excluded-volume dummies, **not** the mean van der Waals radius, because each atom's sphere is clipped by its neighbours' power-diagram planes. `c1` is not fitted here: the cache stores `r_m`, and `Inference.profiled_corrs` profiles `c1` per likelihood evaluation within `EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)` (see the Inference README).

### A, B, C

Partition `v = (a, −ρₑ g)` with `a = (1, s₁, s₂, s₃)` and `G` into the contrast block `G_aa`, the cross block `G_ae` and the self term `G_ee`. The expansion is an exact algebraic identity:

```math
\hat I = A + g\,B + g^2 C,\qquad
A=\mathbf a^\top G_{aa}\mathbf a,\quad B=-2\rho_e\,\mathbf a^\top G_{ae},\quad C=\rho_e^2\,G_{ee}
```

`A`, `B`, `C` are built once per `(ρₑ, δρ)` from the packed columns (off-diagonal pairs of `A` counted twice) and reused across the whole `c1` search, which is evaluated in Horner form `A + g(B + gC)`. Only truncation at `lMax`, the atom/bead discretisation and CRYSOL's common-volume envelope are approximations.

## Numerics

**Spherical Bessel functions.** The upward recurrence `j_l = (2l−1)/x · j_{l−1} − j_{l−2}` is stable only for `l ≤ x`: for `l > x`, `j_l` is the minimal solution and rounding errors grow like `|y_l/j_l| ≈ ((2l+1)!!)²/x^{2l+1}` (useless at `l = 10`, `x = 1`). Gautschi's method computes the ratios `r_l = j_l/j_{l−1}` downward from a start order `N`, where the error is damped,

```math
r_l=\cfrac{x}{(2l+1)-x\,r_{l+1}},\qquad N=\max(l_{top},\lceil x\rceil)+12+\lceil 5x^{1/3}\rceil
```

(`GAUTSCHI_MARGIN = (12, 5.0)`; each extra order gains a factor of 20–50, 12 reach the double-precision floor), then `j_l = j_{l−1} r_l` upward from the exact anchors `j₀ = sin x/x`, `j₁ = sin x/x² − cos x/x` (for `x < 1`, where `j₁` cancels catastrophically, `j₁ = j₀ r₁`). `sphBessRatios!` is pass 1 (ratios, stored `q`-contiguous, only for the `(q, l)` pairs that need them), `sphBessStep` pass 2 (one branch-free `ifelse` step). No `j_l` array is ever stored.

**Negligible-Bessel cut.** `|j_l(x)| ≤ x^l/(2l+1)!!` (Poisson's integral), so `j_l ≤ BESS_CUT = 1e-9` for `x < x_cut(l) = (BESS_CUT·(2l+1)!!)^{1/l}`. Atoms are sorted by radius and cut into tiles of `B_LM_TILE = 256`; for a tile of largest radius `r_max` the columns `q < x_cut(l)/r_max` are skipped at degree `l`, which needs `q` ascending. Each skipped term is below `BESS_CUT·|f|`, changing `G` by ~1e-12 relative or less. `Y_lm` is built per tile only up to the tile's last live degree, by a direct stable Legendre recurrence (`sphHarm!`) written straight into the product layout.

**One real product per degree.** Per degree `l`, `[Re B_l; Im B_l] = [Re Y_l; −Im Y_l] · W_l` with `W_l[i,q] = f(i,q)·j_l(q r_i)`: one OpenBLAS `dgemm` per degree and amplitude column, accumulated in place (flops ≈ `2(L+1)(L+2)·N·Q`, against `N²Q/2` pair terms for Debye: the multipole route wins when `(L+1)(L+2) ≲ N/4`). The tiles are dealt round-robin to `B_LM_GROUPS = 24` groups fixed by the input and summed in group order, so `G` is bit-identical at any thread count.

## Module layout

- **SphFuncs.jl**: `sphHarm!`, `sphHarmCache`, and the Gautschi routines `sphBessRatios!`, `sphBessStep`, `sphBess`.
- **PartialWave.jl**: `compute_B_lm` (atoms in order of radius; an amplitude shared by all scatterers is a `SharedAmplitude`, e.g. the beads of one class) and `self_scatter`/`cross_scatter`/`partial_wave_weights`, the reductions to `G_ab`.
- **FormFactor.jl**: X-ray form factors `f(q, E)` from the bundled `form_factors.sqlite3` (below).
- **Scatterers.jl**: one builder per species and `species_multipoles`, which computes the vacuum and excluded-volume multipoles in one shared pass. The hydration beads of area `a = A/B` stand for the shell slab of volume `a·SHELL_THICKNESS` and scatter as Gaussian dummies of that volume; all beads of a class share one amplitude vector.
- **ForwardCache.jl**: `gram`, `excluded_volume_factor`, `mean_atomic_radius` and the geometry-only `ForwardCache(G, qvals, r_m, form_factor_log, n_atoms, lMax)`. Its `shell` keyword takes a precomputed `SASA.sasa` result (`seed_model` computes the surface first, because the cloud diameter sets `lMax`); `stage_log` times the stages for the report. The contraction `v(q)ᵀ G(q) v(q)` lives in `Inference.profiled_corrs`.

## Usage

```julia
using BAYSOL.Scattering: forward_cache
using BAYSOL.MolecularStructure: create

mol    = create("gly", ["n", "c", "c", "o", "o", "h", "h", "h"], coords)
qvals  = [0.0, 0.03, 0.07, 0.15, 0.31]          # Å⁻¹, ascending
cache  = forward_cache(mol, qvals, 4, 9000.0)   # lMax = 4, energy in eV
cache.G, cache.r_m                              # what Inference.profiled_corrs contracts
```

Lower-level primitives (`compute_B_lm`, `self_scatter`, `species_multipoles`, `gram`, `sphHarm!`, `sphBess*`) are exported from `BAYSOL.Scattering` with docstrings; `Bs = species_multipoles(mol, qvals, lMax, energy)` returns `(vac, ex, sh_convex, sh_concave, sh_cavity)` and `gram(collect(Bs), partial_wave_weights(lMax))` the `(5, 5, Q)` matrix.

## FormFactor.jl

```math
f(q,E)=f_0(s)+f'(E)+i\,f''(E),\qquad f_0(s)=c+\sum_{i=1}^{5}a_i e^{-b_i s^2},\quad s=\frac{q}{4\pi}
```

`f0` is the Waasmaier–Kirfel five-Gaussian fit (212 species; `d` is a copy of `h`, since X-ray scattering depends on the electron cloud only), valid for `0 ≤ s ≤ WK_S_MAX = 6.0 Å⁻¹` and raising `FormFactorError` beyond it (ionic `c` terms are non-physical past that range, e.g. Fe³⁺ `c = −61.93`). At `q → 0` it recovers the electron count `Z − charge`. `f'`, `f''` are Chantler FFAST corrections (≈1 eV–966 keV): `f1` by a not-a-knot cubic spline over the 7 grid points around the energy, `f2` by linear interpolation in log–log (it spans orders of magnitude across an edge; values below `F2_LOG_FLOOR = 1e-99` are clamped). No Python at run time: `dev/extract_formfactor.clj` (Babashka with the `org.babashka/go-sqlite3` pod) regenerates `form_factors.sqlite3`. Consumer: `Scatterers._vacuo_amplitude` via `form_factor_table`.

Each requested ion is resolved into one of four tiers and anything short of **full** is logged in `ForwardCache.form_factor_log` and written to the workbook's `form_factor_log` sheet: **DUMMY** (no `f0` for the ion or its element), **F0-ONLY** (no Chantler data for the element or the energy is outside its range; real-valued row), **NEUTRAL** (no entry for the requested charge state, the neutral atom's `f0` is used), **full**. Ions are deduplicated on build, first-seen order preserved, while `form_factors` still returns one row per request.

Waasmaier & Kirfel (1995), *Acta Cryst.* A51, 416–431, [10.1107/S0108767394013292](https://doi.org/10.1107/S0108767394013292). Chantler (1995), *J. Phys. Chem. Ref. Data* 24, 71; Chantler (2000), *J. Phys. Chem. Ref. Data* 29, 597.

## Constants

Module level in `Scattering.jl`: `SHELL_THICKNESS` (3.0 Å, CRYSOL's border layer), `EV_EXP_COEFF` (`κ_EV` above, also used by the `c1` profiling), `GAUTSCHI_MARGIN`, `BESS_CUT`, `B_LM_CHUNK` (atoms per pass), `B_LM_TILE` (256), `B_LM_W_BYTES` (budget of one worker's `W` buffer, which sets the q-tile length), `B_LM_GROUPS` (24; divides evenly over 1, 2, 3, 4, 6, 8, 12 workers), `B_LM_ACC_BYTES` (1 GiB for the workers' accumulators; limits the number of workers, never the grouping), `B_LM_PARALLEL_MIN` (4096 tiles × q points; below it the groups run in order on one thread), `B_LM_REDUCE_COLS`. In `FormFactor.jl`: `WK_S_MAX`, `F2_LOG_FLOOR`.
