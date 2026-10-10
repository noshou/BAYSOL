# Scattering

The SAXS/SANS forward model: a molecule and a q grid in, the orientationally-averaged detector intensity `I_calc(q)` out.

## Overview

For a fixed orientation, N point-like scatterers with form factors `f_i(q)` at positions `r_i` give a coherent scattering amplitude

```
A(q) = Σ_i f_i(q) * exp(i q·r_i)
```

Solution-scattering molecules tumble freely, so the measured intensity is the orientational average I(q) = <|A(q)|²>, which is intractable to evaluate directly for a large molecule by averaging over rotations. Like CRYSOL does, we can expand the plane wave via the Rayleigh expansion in spherical harmonics `Y_lm` and spherical Bessel functions `j_l`,

```
exp(i q·r) = 4π Σ_l Σ_m i^l j_l(q r) Y_lm(q̂) conj(Y_lm(r̂))
```

substitute into A(q), and swaps the atom-sum and (l,m)-sum, giving

```
A(q) = 4π Σ_l Σ_m i^l Y_lm(q̂) B_lm(q)
B_lm(q) = Σ_i f_i(q) j_l(q r_i) conj(Y_lm(θ_i, φ_i))
```

`B_lm(q)` is the degree-l, order-m **multipole moment** of the scattering amplitude, truncated at a band limit lMax chosen by the caller. Squaring A(q) and integrating over the orientation of q̂ collapses the double sum via the orthonormality of `Y_lm` on the sphere (the l != l'/m != m' cross terms vanish, and the surviving l = l' phase i^l (-i)^l = 1 cancels), leaving a closed-form orientational average computed once per atom instead of by numerically averaging over rotations:

```
I(q) = 4π Σ_l Σ_{m=-l}^{l} |B_lm(q)|²
```

Because `Y_{l,-m}` = (-1)^m conj(`Y_lm`), a real `f_i(q)` forces `B_{l,-m}` = (-1)^m conj(`B_lm`), so only m = 0..l needs to be stored, with a 1-for-m=0/2-for-m>0 weighting recovering the full -l..l sum (`partial_wave_weights`).

Atomic form factors are complex (f = f0 + f' + i f''); the module splits `f_i` into its real and imaginary parts as two independent "channels" (each individually real, so each satisfies the ±m identity exactly) and adds their |`B_lm`|² incoherently; the cross-channel term is odd in m and cancels once summed over the full range, so this is exact, not an approximation.

### Gram-matrix factorization

A real molecule in solution scatters as several superposed **species**; vac (real atoms in vacuo), ex (one Gaussian excluded-volume dummy per atom, the bulk solvent it displaces), and `sh_convex`/`sh_concave`/`sh_cavity`(hydration-shell dummies on the solvent-accessible surface, split by local geometry into CRYSOL 3's three border-layer populations). Species combine coherently at the amplitude level, `A_total` = `Σ_a` `c_a` `A_a`, so after the applying the orientational average we get:

```
I(q) = Σ_a Σ_b c_a c_b S_ab(q),   S_ab(q) = 4π Σ_lm w_lm Re(B^a_lm(q) conj(B^b_lm(q)))
```

`S_ab` depends only on geometry and beam energy, so it is assembled once into a (5, 5, Q) **Gram matrix** G(q) (symmetric,
positive semidefinite) and reused across every parameter draw: I(q) = vᵀ G(q) v with contrast vector v = [1, -dns, `dro_1`, `dro_2`, `dro_3`]. Classic single-shell CRYSOL is the n = 3 reduction with the three shell classes merged. The module docstring in Scattering.jl derives this in full, including CRYSOL's excluded-volume correction factor `c_1` (an
expansion of every dummy's radius by `r_0`/`r_m`) and the detector-scale model `I_calc(q)` = m·I(q) + c.

ForwardCache.jl's `mean_atomic_radius(mol)` computes `r_m` as CRYSOL itself defines it: the mean of each atom's own excluded-volume-dummy equivalent-sphere radius, `r_m` = N⁻¹ Σᵢ cbrt(3 Vᵢ / 4π), where Vᵢ is MolecularStructure.vols(mol)[i] (the displaced-solvent volume, see MolecularStructure's README) -- **not** the mean van der Waals radius (radii(mol)). vols is computed geometrically: each atom's vdW sphere is clipped by its neighbours' power-diagram planes, so Vᵢ < (4/3)π·rᵢ³ for any atom with overlapping neighbours, and the two radii differ for essentially every atom in a packed structure.

`c_1` is not fitted here: the cache stores `r_m`, and during fitting `Inference.profiled_corrs` profiles `c_1` per likelihood evaluation, from the cached G(q) and `excluded_volume_factor`, within the hard bounds `EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)`, with no prior (see the Inference README).

## Module layout

- **SphFuncs.jl** : `sphHarm!` (`Y_l^m` by the Legendre recurrence, written in place in the real [Re; −Im] layout of the `B_lm` product, with `sphHarmCache`) and Gautschi's continued-fraction method for `j_l`: `sphBessRatios!` (pass 1: ratios `r_l = j_l/j_{l-1}`, start orders and the closed-form anchors `j_0`, `j_1`), `sphBessStep` (one upward step of pass 2), and their `sphBess` buffers.
- **PartialWave.jl** : `compute_B_lm` (the multipole moments themselves: atoms are processed in order of radius so each tile's negligible-Bessel cut is tight, `Y_lm` and the Bessel sweep run only up to a tile's last live degree and over the q columns that need them, and an amplitude shared by all scatterers is a `SharedAmplitude`, e.g. the hydration beads of one class), plus `self_scatter`/`cross_scatter`/`partial_wave_weights` (the reductions to `S_ab(q)`).
- **FormFactor.jl** : X-ray atomic form factors f(q, E) from the bundled `form_factors.sqlite3` (`form_factor_table`, `form_factors`, `compute_form_factors`), consumed by the vacuum amplitude in Scatterers.jl.
- **Scatterers.jl** : one builder per species (vacuum amplitude, excluded-volume dummies, and `hydration`, the last returning one `B_lm` per hydration-shell class), assembled by `species_multipoles`, which computes the vacuum and excluded-volume multipoles in one shared pass.
- **ForwardCache.jl** : `gram` (the `S_ab` matrix G), `excluded_volume_factor` (the `c_1` correction), `mean_atomic_radius`, and the geometry-only `ForwardCache`. `forward_cache` returns a `ForwardCache(G, qvals, r_m, form_factor_log, n_atoms, lMax)`; `n_atoms` and `lMax` feed the report's `=== Run ===` section. Its `shell` keyword takes a precomputed `SASA.sasa` result (`seed_model` computes the accessible surface first, because the diameter of the whole scatterer cloud sets the band limit). Its `stage_log` keyword (a `Timing.StageLog`) times the vacuum, excluded-volume, hydration (SASA + `B_lm`) and Gram + `r_m` stages for the report's `=== Timing ===` section; `BAYSOL.seed_model` passes it automatically. The contraction I(q) = v(q)ᵀ G(q) v(q) lives in `Inference.profiled_corrs`.

## Usage

### Spherical harmonics and Bessel functions (SphFuncs)

```julia
using BAYSOL.Scattering.SphFuncs: sphHarm!, sphHarmCache, sphBess, sphBessRatios!, sphBessStep

# Y_l^m for l = 0..lMax, m = 0..l, by the Legendre recurrence, one column per point, written in place in the real layout
# the B_lm product consumes: for degree l (k0 = l(l+1)÷2) rows 2k0+1..2k0+l+1 hold Re Y_l^m and the next l+1 rows −Im Y_l^m.
# The workspace from sphHarmCache is reusable across calls; θ and φ may be views (e.g. rows of coords_spherical).
A = Matrix{Float64}(undef, (2 + 1) * (2 + 2), 2)
sphHarm!(A, sphHarmCache(2), 2, [0.3, 1.1], [0.2, -1.0])     # (12, 2)

# j_l(q·r) for l = 0..lMax at one radius, every q: pass 1 fills the ratios and the
# anchors j₀ (jm2), j₁ (jm1); pass 2 steps upward, each value already normalized
q, r, lMax = [0.0, 0.1, 0.2], 2.5, 3
b = sphBess(length(q), lMax)
sphBessRatios!(b, r, q, lMax)
j = zeros(lMax + 1, length(q))
j[1, :] .= b.jm2[1:3]; j[2, :] .= b.jm1[1:3]
for l in 2:lMax, k in eachindex(q)
    v = sphBessStep(b.jm1[k], b.jm2[k], l, b.lup[k], b.invx[k], b.R[k, l])
    b.jm2[k], b.jm1[k] = b.jm1[k], v
    j[l + 1, k] = v
end
```

### The geometry-only cache

```julia
using BAYSOL.Scattering: forward_cache
using BAYSOL.MolecularStructure: create

mol   = create("gly", ["n", "c", "c", "o", "o", "h", "h", "h"], coords)
qvals = [0.0, 0.03, 0.07, 0.15, 0.31]
lMax  = 4
energy = 9000.0   # eV

# geometry-only pass: build the (5,5,Q) species Gram matrix G(q) once per structure
cache = forward_cache(mol, qvals, lMax, energy)
cache.G, cache.r_m   # what Inference.profiled_corrs contracts against (v, c_1) per draw
```

### Lower-level primitives

```julia
using BAYSOL.Scattering: compute_B_lm, self_scatter, cross_scatter,
                           partial_wave_weights, gram, species_multipoles, hydration

w    = partial_wave_weights(lMax)                 # 1-for-m=0, 2-for-m>0
B_lm = compute_B_lm(coords_sph, qvals, f_atoms, lMax, UInt64(2048))
S    = self_scatter(B_lm, w)                       # S_aa(q)

Bs = species_multipoles(mol, qvals, lMax, energy)  # (vac, ex, sh_convex, sh_concave, sh_cavity)
G  = gram(collect(Bs), w)                           # (5, 5, Q) Gram matrix
```

`compute_B_lm` works in real arithmetic. Per degree l, `[Re B_l; Im B_l] = [Re Y_l; −Im Y_l] · W_l`, with `W_l[i, q] = f(i, q)·j_l(q·r_i)` for each real amplitude column (Re f, plus Im f when f is anomalous). That is one OpenBLAS product per degree and column, accumulated in place. W is filled directly by the spherical Bessel sweep (`sphBessRatios!`, then `sphBessStep` upward), so no j array is ever stored. It is built for `B_LM_TILE` atoms and a q-tile sized to fit `B_LM_W_BYTES`; all buffers are allocated once per call. Negligible terms are skipped: since |jₗ(x)| ≤ xˡ/(2l+1)!!, jₗ ≤ `BESS_CUT` (1e-9) for x below `x_cut(l)` (`xcut` in `compute_B_lm`) = (`BESS_CUT`·(2l+1)!!)^(1/l), so for each tile (largest radius `r_max`) and degree l the columns q < `x_cut(l)/r_max` are left out of both the W writes and the product. That needs q in ascending order (the full range is used otherwise); each skipped term is below `BESS_CUT`·|f|, changing G by ~1e-12 relative or less. `species_multipoles` computes the vacuum and excluded-volume multipoles in one shared pass (`_compute_B_lm` with both amplitude sets), timed as the single stage `"vacuum + excluded volume (vols + B_lm)"`. With several Julia threads the tiles are dealt round-robin to `B_LM_GROUPS` (24) groups, fixed by the input and never by the thread count; each group sums its tiles in order into an accumulator, the groups run in waves of one per worker with a pool of one accumulator per worker, and the accumulators are added to the result in group order (in parallel by column blocks). The result is therefore bit-identical at any thread count. Each worker owns its work buffers (`A`, `Ft`, `W`, the Bessel and harmonic caches), allocated once per call by the calling thread, and OpenBLAS is limited to one thread inside the groups (`Parallel.with_blas_single`); with one Julia thread, or below `B_LM_PARALLEL_MIN` tiles × q points, the same groups run in order on one thread and OpenBLAS keeps its own threads. `B_LM_ACC_BYTES` caps the number of workers by accumulator memory, never the grouping.

## FormFactor.jl

X-ray atomic scattering factors, f(q, E) = f0(s) + f1(E) + i·f2(E) with s = q/(4π) in Å⁻¹.

The data and interpolation scheme follow the Python package XrayDB, but nothing calls Python at runtime. `form_factors.sqlite3` (tables `waasmaier`, `chantler`, `provenance`) is bundled, and `test/utils/extract_formfactor.tcl` is the offline script (Tcl 9 with the `sqlite3` package, Fedora `sqlite-tcl`) that regenerates it. Consumer: `Scatterers.jl` (`_vacuo_amplitude`), via `form_factor_table`. Each ion that could not be fully resolved is logged (see Tiering below) into `ForwardCache.form_factor_log` and printed in the run report.

Data:

- **waasmaier**: Waasmaier & Kirfel (1995) Gaussian coefficients for the non-resonant term f0. 211 species.
- **chantler**: Chantler FFAST (NIST) anomalous corrections f1/f2, spanning roughly 1.01 eV to 966 keV.


| Citation                                                                                                                                                                      | DOI                         |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| Waasmaier, D. & Kirfel, A. (1995). New analytical scattering-factor functions for free atoms and ions.*Acta Cryst.* A51, 416–431.                                            | 10.1107/S0108767394013292 |
| Chantler, C.T. (1995). Theoretical Form Factor, Attenuation, and Scattering Tabulation for Z = 1–92 from E = 1–10 eV to E = 0.4–1.0 MeV.*J. Phys. Chem. Ref. Data* 24, 71. | —                          |
| Chantler, C.T. (2000). Detailed Tabulation of Atomic Form Factors...*J. Phys. Chem. Ref. Data* 29, 597.                                                                       | —                          |

### Math

#### f0: Waasmaier-Kirfel (non-resonant)

```
f0(s) = c + Σ_{i=1..5} a_i · exp(-b_i·s²),   s = q/(4π)  [Å⁻¹]
```

211 (c, a1..a5, b1..b5) rows, keyed by lowercase ion string ("fe3+", "o2-") or bare element ("fe"). Valid for 0 ≤ s ≤ `WK_S_MAX` = 6.0 Å⁻¹; the fits go non-physical (some ionic c terms are large and negative, e.g.
fe3+'s c = -61.93) if extrapolated past that range, so f0 throws rather than extrapolating (f0("fe3+", `WK_S_MAX` + eps) raises FormFactorError).

At q → 0, f0 recovers the electron count: Z - charge for an ion, Z for a neutral atom (checked in tests to atol = 5e-3, the Cromer-Mann parameterization's own residual at s = 0).

#### f1/f2: Chantler FFAST (anomalous / resonant)

- **f1**: interpolating **cubic spline with not-a-knot end conditions**, fitted to the local **7-point window** around the requested energy  (max(1, j-3):min(n, j+3), where j is the last grid point at or below the query. f1 is stored as
  `f1_FFAST` - Z + `f_rel(3/5·CL)` + `f_NT`
- **f2**: **linear interpolation in log-log space** over the same local window (values below `F2_LOG_FLOOR` = 1e-99 in magnitude are clamped to it before taking the log, since the table can store an exact zero). f2 is used in log-log rather than cubic-spline form because it spans orders of magnitude across an absorption edge, whereas f1 changes sign through one.

### Tiering

Not every ion has both halves of the sum. [`compute_form_factors`](@ref BAYSOL.Scattering.compute_form_factors) classifies each requested species into one of three tiers and logs anything short of a full resolution ([`form_factor_log`](@ref BAYSOL.Scattering.form_factor_log)):

- **DUMMY**: no f0 entry at all for the species or its bare element.
- **F0-ONLY**: has f0 but no Chantler data for its element, or the requested energy falls outside that element's tabulated range (e.g. Pu, or Fe at 1 eV, below the Chantler floor); the row is real-valued (imag(f) == 0).
- **NEUTRAL**: no waasmaier entry for the exact charge state requested (e.g. "fe4+"), so the neutral atom's f0 is substituted.
- Anything not logged is **full**: both f0 and f1/f2 resolved for the requested ion and energy.

Ions are deduplicated on build, preserving first-seen order, so a batch like ["fe3+", "fe3+", "o2-", "fe3+"] produces one fe3+ row in t.tbl, while [`form_factors`](@ref BAYSOL.Scattering.form_factors) still returns one output row per requested (possibly repeated) ion.

### Constants

Defined at module level in `FormFactor.jl` (a file of the `Scattering` module).


`WK_S_MAX = 6.0` (upper bound of the Waasmaier–Kirfel f0 parameterisation's s range), `F2_LOG_FLOOR = 1e-99` (floor applied to Chantler f2 before log-log interpolation)

## Constants

Defined at module level in `Scattering.jl`.


`SHELL_THICKNESS` (3.0 Å, CRYSOL's border-layer default), `B_LM_CHUNK` (`UInt64(2048)`, atoms/dummies per pass in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm)), `B_LM_TILE` (256 atoms per inner tile, the inner dimension of each per-degree BLAS product), `B_LM_W_BYTES` (8 MiB budget for one worker's W buffer, which sets the q-tile length), `B_LM_GROUPS` (24 tile groups, fixed by the input; divides evenly over 1, 2, 3, 4, 6, 8 and 12 workers), `B_LM_ACC_BYTES` (1 GiB for the workers' accumulators together; limits the number of workers only), `B_LM_PARALLEL_MIN` (4096 tiles × q points: below it the groups run on one thread), `B_LM_REDUCE_COLS` (accumulator columns per task in the parallel sum), `EV_EXP_COEFF` ((4π/3)^(2/3)/4π, converting CRYSOL's radius parameterisation of the excluded-volume correction c1 into the volume parameterisation of the dummy amplitudes; also used by c1 profiling), `GAUTSCHI_MARGIN` (`(12, 5.0)`: the continued-fraction start order in [`Scattering.SphFuncs.sphBessRatios!`](@ref BAYSOL.Scattering.SphFuncs.sphBessRatios!) is max(lMax, ⌈x⌉) + 12 + ⌈5·x^(1/3)⌉) and `BESS_CUT` (1e-9: below it jₗ(q·r) is treated as zero in `compute_B_lm`; see the Scattering README)
