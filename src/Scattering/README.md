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

`c_1` is not fitted here: the cache stores `r_m`, and during fitting `Fitting.profiled_corrs` profiles `c_1` per likelihood evaluation, from the cached G(q) and `excluded_volume_factor`, within the hard bounds `EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)`, with no prior (see the Fitting README).

## Module layout

- **SphFuncs.jl** : sphHarm (complex `Y_l^m`) and Gautschi's continued-fraction method for `j_l`: `sphBessRatios!` (pass 1: ratios `r_l = j_l/j_{l-1}`, start orders and the closed-form anchors `j_0`, `j_1`), `sphBessStep` (one upward step of pass 2), and their `sphBess` buffers.
- **PartialWave.jl** : `compute_B_lm` (the multipole moments themselves), plus `self_scatter`/`cross_scatter`/`partial_wave_weights` (the reductions to `S_ab(q)`).
- **Scatterers.jl** : one builder per species (vacuum amplitude, excluded-volume dummies, and `hydration`, the last returning one `B_lm` per hydration-shell class), assembled by `species_multipoles`, which computes the vacuum and excluded-volume multipoles in one shared pass.
- **ForwardCache.jl** : `gram` (the `S_ab` matrix G), `excluded_volume_factor` (the `c_1` correction), `mean_atomic_radius`, and the geometry-only `ForwardCache`. `forward_cache` returns a `ForwardCache(G, qvals, r_m, form_factor_log, n_atoms, lMax)`; `n_atoms` and `lMax` feed the report's `=== Run ===` section. Its `stage_log` keyword (a `Timing.StageLog`) times the vacuum, excluded-volume, hydration (SASA + `B_lm`) and Gram + `r_m` stages for the report's `=== Timing ===` section; `BAYSOL.seed_model` passes it automatically. The contraction I(q) = v(q)ᵀ G(q) v(q) lives in `Fitting.profiled_corrs`.

## Usage

### Spherical harmonics and Bessel functions (SphFuncs)

```julia
using BAYSOL.Scattering.SphFuncs: sphHarm, sphBess, sphBessRatios!, sphBessStep

# Y_l^m for l = 0..lMax, m = 0..l, packed row = l*(l+1)÷2 + m + 1, one column per point
y = sphHarm(2, [0.3, 1.1], [0.2, -1.0])          # (6, 2) ComplexF64

# same, reading θ/φ straight off MolecularStructure.coords_spherical's layout
y = sphHarm(2, angles)                            # angles :: (2, N), row 1 = θ, row 2 = φ

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
cache.G, cache.r_m   # what Fitting.profiled_corrs contracts against (v, c_1) per draw
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

`compute_B_lm` works in real arithmetic. Per degree l, `[Re B_l; Im B_l] = [Re Y_l; −Im Y_l] · W_l`, with `W_l[i, q] = f(i, q)·j_l(q·r_i)` for each real amplitude column (Re f, plus Im f when f is anomalous). That is one OpenBLAS product per degree and column, accumulated in place. W is filled directly by the spherical Bessel sweep (`sphBessRatios!`, then `sphBessStep` upward), so no j array is ever stored. It is built for `B_LM_TILE` atoms and a q-tile sized to fit `B_LM_W_BYTES`; all buffers are allocated once per call. Negligible terms are skipped: since |jₗ(x)| ≤ xˡ/(2l+1)!!, jₗ ≤ `BESSEL_CUTOFF` (1e-9) for x below `x_cut(l)` (`xcut` in `compute_B_lm`) = (`BESSEL_CUTOFF`·(2l+1)!!)^(1/l), so for each tile (largest radius `r_max`) and degree l the columns q < `x_cut(l)/r_max` are left out of both the W writes and the product. That needs q in ascending order (the full range is used otherwise); each skipped term is below `BESSEL_CUTOFF`·|f|, changing G by ~1e-12 relative or less. `species_multipoles` computes the vacuum and excluded-volume multipoles in one shared pass (`_compute_B_lm` with both amplitude sets), timed as the single stage `"vacuum + excluded volume (vols + B_lm)"`. OpenBLAS's own thread count applies to the products (default 4); set `LinearAlgebra.BLAS.set_num_threads(1)` if Julia-level threads are added later.

## Constants

Defined at module level in `Scattering.jl`.


`SHELL_THICKNESS` (3.0 Å, CRYSOL's border-layer default), `B_LM_CHUNK` (`UInt64(2048)`, atoms/dummies per pass in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm)), `B_LM_TILE` (256 atoms per inner tile, the inner dimension of each per-degree BLAS product), `B_LM_W_BYTES` (64 MiB budget for the per-tile W buffer, which sets the q-tile length), `EV_EXP_COEFF` ((4π/3)^(2/3)/4π, converting CRYSOL's radius parameterisation of the excluded-volume correction c1 into the volume parameterisation of the dummy amplitudes; also used by c1 profiling), `GAUTSCHI_MARGIN` (`(16, 6.0)`: the continued-fraction start order in [`Scattering.SphFuncs.sphBessRatios!`](@ref BAYSOL.Scattering.SphFuncs.sphBessRatios!) is max(lMax, ⌈x⌉) + 16 + ⌈6·x^(1/3)⌉) and `BESSEL_CUTOFF` (1e-9: below it jₗ(q·r) is treated as zero in `compute_B_lm`; see the Scattering README)
