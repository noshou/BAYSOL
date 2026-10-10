# SPDX-License-Identifier: LGPL-2.1-or-later

"""
The SAXS/SANS forward model: a molecule and a q grid in, the orientationally
averaged detector intensity `I_calc(q)` out. 
# Module layout

Five files `include`d into the one module `Scattering`:

- `SphFuncs`    -   `Y_lm`, `j_l`, normalised Legendre.
- `FormFactor`  -   X-ray atomic form factors from the bundled `form_factors.sqlite3`.
- `PartialWave` -   `compute_B_lm` (the multipole moments), plus
                    `self_scatter` / `cross_scatter` / `partial_wave_weights`
                    (the reductions to `S_ab(q)`).
- `Scatterers`  -   one builder per species (vacuum, excluded volume, and
                    hydration, the last returning one `B_lm` per shell class),
                    assembled by `species_multipoles`.
- `ForwardCache` -  gram (the `S_ab` matrix G), `excluded_volume_factor`
                    (excluded-volume correction factor c₁), the geometry-only
                    ForwardCache built once per structure by `forward_cache`, and
                    the contraction I(q) = v(q)ᵀ G(q) v(q) at fit parameters
                    (`intensity_terms`, `model_intensity`). Profiling c₁ against
                    data is BAYSOL.Inference's job.

# Background

1.  For a fixed orientation, the coherent scattering amplitude of
    N point-like scatterers with form factors `f_i(q)` at positions `r_i`
    is a Fourier sum:

        A(q) = `Σ_i` `f_i(q)` * exp(i q·`r_i`)

    where q is the momentum-transfer vector. In solution scattering
    (SAXS/SANS), molecules tumble freely, so the measured intensity
    is the square of this amplitude averaged over every possible orientation:

        I(q) = ⟨|A(q)|²⟩_orientations

    which is computationally intractible to calculate exactly for large molecules.
\\
2.  We can instead expand the plane wave in spherical harmonics, since
    exp(i q·r) has an exact expansion (the Rayleigh expansion) in terms
    of spherical Bessel functions `j_l` and spherical harmonics `Y_lm`:

        exp(i q·r) = 4π * `Σ_l` `Σ_m` i^l * `j_l`(q r) * `Y_lm(q_hat)` * conj(`Y_lm(r_hat)`)

    where `q_hat`, `r_hat` are unit vectors and r = |r|.

    Substitute this into A(q) and swap the order of the atom-sum and the (l,m)-sum:

        A(q) = 4π * `Σ_l` `Σ_m` i^l * `Y_lm(q_hat)` * `B_lm(q)`

    where:

        `B_lm(q)` = `Σ_i` `f_i(q)` * `j_l`(q `r_i`) * conj(`Y_lm`(`θ_i`, `φ_i`))

    `B_lm(q)` is therefore the multipole moment of degree (l,m) of the
    scattering amplitude A(q). Squaring A(q) gives:

        |A(q)|² =  (4π)² * `Σ_{l,m}` `Σ_{l',m'}` i^l*(-i)^l'
                    * `Y_lm(q_hat)` * conj(`Y_l'm'(q_hat)`)
                    * `B_lm(q)` * conj(`B_l'm'(q)`)

    Averaging over orientation means averaging over the direction `q_hat`.
    `Y_lm` is orthonormal on the sphere, so ∫`dΩ_q_hat` `Y_lm(q_hat)`*conj(`Y_l'm'(q_hat)`)
    is 1 when (l,m)=(l',m') and 0 otherwise, collapsing the double sum to a single sum.
    The surviving l=l' diagonal's  phase factor becomes i^l*(-i)^l = (i*(-i))^l = 1^l = 1,
    cancelling. What survives both is:

        I(q) = 4π * `Σ_l` `Σ_{m=-l}`^{l} |`B_lm(q)`|²

    an orientational average computed once per atom, in closed form,
    instead of by averaging over rotations.
\\
3.  `B_lm` only needs to be stored for m = 0, ..., l, not the full
    -l, ..., l range, since spherical harmonics satisfy
    `Y_{l,-m}` = (-1)^m * conj(`Y_lm`), so for a real `f_i(q)` the same
    identity forces `B_{l,-m}` = (-1)^m * conj(`B_lm`), hence |`B_{l,-m}`|² = |`B_lm`|²:

        `Σ_{m=-l}`^{l} |`B_lm`|² = 1·|`B_l0`|² + `Σ_{m=1}`^{l} 2·|`B_lm`|²

    a weighting given 1-for-m=0 and 2-for-m>0 over the half that computed.

    The derivation needs `f_i(q)` real. Near an absorption edge, atomic
    form factors are complex (f = f0 + f' + i*f'', the anomalous term),
    and the identity in (3) breaks exactly where it needed conj(`f_i`) = `f_i`.
    The fix: split `f_i` = Re(`f_i`) + i*Im(`f_i`) and build `B_lm` separately
    for each real-valued piece (two "channels"). Each channel individually
    satisfies (3) exactly, and the cross term between channels is odd in
    m and cancels once summed over the full -l..l range, so summing
    the channels' |`B_lm`|² incoherently reproduces the exact total with
    no approximation.
\\
4.  A real molecule scatters as several **species** superposed at the
    amplitude level (coherently), then squared:

        `A_total(q)` = `Σ_a` `c_a` `A_a(q)`

    so, after the orientational average of (2),

        I(q) = `Σ_a` `Σ_b` `c_a` `c_b` `S_ab(q)`,
        `S_ab(q)` = 4π `Σ_lm` `w_lm` Re(B^`a_lm(q)` conj(B^`b_lm(q)`))

    `S_aa` (a species against itself) is the self term 4π `Σ_lm` `w_lm` |`B_lm`|²;
    `S_ab` with a != b is the cross term. The species:

        - vac         molecule as if no solvent existed.
        - ex          one Gaussian excluded-volume dummy per atom: the bulk
                        solvent each atom displaces (a negative contrast).
        - `sh_convex`  ┐ hydration-shell dummies on the solvent-accessible
        - `sh_concave` ├ surface, split by local geometry into CRYSOL 3's
        - `sh_cavity`  ┘ three border-layer populations

    Classic single-shell CRYSOL is the n = 3 reduction (vac, ex, sh) with
    the three shell classes merged.
\\
5.  The dummy species do not carry the true local electron density

        v = (1, -dns, `dro_1`, `dro_2`, `dro_3`),     `dro_k` = `UNIT_OF_δρ` * `δρ_k`

    - dns rescales `A_ex` to the mean electron density of the displaced
            bulk solvent (≈ 0.334 e·Å⁻³).
    - `δρ_k` dimensionless shell contrast per class (CRYSOL's --dro
            multiple, default (1, 1, 0)); `dro_k` is the class's excess
            electron density over bulk.

    With the geometry-only Gram matrix `G_ab(q)` = `S_ab(q)` the whole
    expansion is the bilinear form

        I(q) = vᵀ G(q) v,     G(q) ⪰ 0

    n(n+1)/2 distinct `S_ab(q)` curves (15 for n = 5, 6 for n = 3).
    G depends only on geometry and beam; v only on the fit parameters, so
    G is built once per structure and reused across every parameter set.
\\
6.  A table of atomic radii gets the *displaced* volume wrong. CRYSOL's fix
    is one global expansion factor `c_1` = `r_0/r_m` over all dummies, `r_0`
    fitted and `r_m` the structure's mean atomic radius. Expanding a dummy's
    radius sends `V_j` -> `c_1`^3 `V_j` in the Gaussian of (4), i.e.

        `f_j(q)` -> `c_1`^3 * `f_j(q)` * exp(-q^2 (`c_1`^2 - 1) `V_j`^(2/3) / 4π)

    CRYSOL's
    standard approximation replaces the per-atom `V_j`^(2/3) by
    the mean-radius value `V_m`^(2/3) = (4π/3)^(2/3) `r_m`^2, making it one scalar
    function of q that leaves the sum entirely:

        `G_ex(q)` = `c_1`^3 exp(-q^2 (`c_1`^2 - 1) (4π/3)^(2/3) `r_m`^2 / 4π)

    So `r_0` reweights the *contrast*, not the geometry: v simply becomes
    q-dependent in its ex entry, and G stays cached.

        v(q) = (1, -dns*`G_ex(q)`, `dro_1`, `dro_2`, `dro_3`),   I(q) = v(q)ᵀ G(q) v(q)

    Exact at q = 0 (total excluded volume scales by `c_1`^3) and for an atom
    of radius `r_m`; it degrades with the spread of radii about `r_m`, which for
    protein heavy atoms is small. `r_0` = `r_m` gives `G_ex` == 1, the uncorrected
    model. Note dns and `r_0` are strongly degenerate and CRYSOL fixes dns at
    0.334 and fits `r_0`.
\\
7.  A real detector reads an arbitrary scale over an imperfect buffer
    subtraction, so the reported intensity is

        `I_calc(q)` = m * I(q) + c

    with m the overall scale (absolute → arbitrary units) and c a flat
    background.
"""
module Scattering

using SQLite: SQLite
using DBInterface: DBInterface
using FastClosures: @closure
using LinearAlgebra: LinearAlgebra
using ..Geometry: PROBE_RADIUS, SHELL_N_TARGET, ATOM_BLOCK, ATOM_PARALLEL_MIN
using ..PhysicalConstants: UNIT_OF_δρ
using ..Runtime: gc_checkpoint, Lazy, force, tmap_blocks
using LinearAlgebra: mul!

"""
Hydration-shell thickness in Å: how far the perturbed-density water layer
extends beyond the solvent-accessible surface. 3.0 is CRYSOL's border-layer
default.
"""
const SHELL_THICKNESS = 3.0

"""
Atoms/dummies per pass in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm).
"""
const B_LM_CHUNK = UInt64(2048)

"""
Atoms per inner tile of [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm):
the inner dimension of each per-degree BLAS product. Large enough that `dgemm`
runs near peak (measured at 256), small enough to bound the W buffer together
with [`B_LM_W_BYTES`](@ref). Results are tile-invariant up to rounding.
"""
const B_LM_TILE = 256

"""
Memory budget, in bytes, for the W buffer of one worker (all degrees ≤ lMax, every
amplitude column, a q-tile) in
[`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm); the q-tile length is
chosen to fit it. 8 MiB: wider tiles measured no faster, and every worker holds one.
"""
const B_LM_W_BYTES = 8 * 2^20

"""
Number of tile groups of [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm):
the tiles are dealt round-robin to this many groups, each summed into its own accumulator
(memory: this many `2K × ncol·Q` matrices), and the groups run on the Julia threads in
waves of one group per worker. A constant, not the thread count, so the result is
bit-identical at any number of threads. 24 divides evenly over 1, 2, 3, 4, 6, 8 and 12
workers (and fills 7 to 86 %), so ordinary core counts all stay busy; the cost is one more
accumulator addition per group.
"""
const B_LM_GROUPS = 24

"""
Memory budget, in bytes, for the accumulators of the workers of
[`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm) (one `2K × ncol·Q` matrix
of doubles each, up to ~125 MB for the largest fitting test): the number of workers is cut
when they would not fit, which keeps the memory of a threaded build modest on an ordinary
laptop. It limits parallelism only, never the grouping or the result. 1 GiB.
"""
const B_LM_ACC_BYTES = 1024 * 2^20

"""
Smallest `tiles × Q` for which
[`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm) spreads its tile groups
over the Julia threads. Below it the work (a few tens of milliseconds) is run on one thread,
with OpenBLAS threaded, which measured faster than the groups on several threads (SASDMJ9:
11 tiles × 121 q = 1331 was 1.3–1.8× slower threaded; SASDJ62: 38 × 411 ≈ 15,600 was 2×
faster). The decision depends on the input only, so the result does not depend on it.
"""
const B_LM_PARALLEL_MIN = 4096

"""
Columns of the accumulator per task when the tile groups' sums are added up in
parallel in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm).
"""
const B_LM_REDUCE_COLS = 16

"""
Coefficients of
[`excluded_volume_factor`](@ref BAYSOL.Scattering.excluded_volume_factor):
(4π/3)^(2/3) / 4π.

Converts CRYSOL's *radius* parameterisation into the *volume* parameterisation
[`_gaussian_dummy`](@ref BAYSOL.Scattering._gaussian_dummy) is written in,
via V = (4π/3) r³ (which is exactly `Geometry.sphere_volume`,
so `r_m` and the dummy volumes stay consistent).
"""
const EV_EXP_COEFF = (4π / 3)^(2 / 3) / (4π)

"""
Start order of the continued-fraction sweep in
[`sphBessRatios!`](@ref BAYSOL.Scattering.sphBessRatios!): N = max(lMax,
⌈x⌉) + `GAUTSCHI_MARGIN[1]` + ⌈`GAUTSCHI_MARGIN[2]`·x^(1/3)⌉. Deep enough
that every ratio is converged to the Float64 rounding floor (the floor is
reached at (12, 5) against a 512-bit reference, which is the margin used;
the earlier (16, 6) left a safety step that only cost sweep time).
"""
const GAUTSCHI_MARGIN = (12, 5.0)

"""
Threshold below which a spherical Bessel value jₗ(q·r) is treated as zero in
[`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm): degree-l columns with
q·`r_max` < `x_cut(l)` (`xcut` in `compute_B_lm`), where xˡ/(2l+1)!! = `BESS_CUT`
(an upper bound on |jₗ|), are skipped. Each skipped term is below `BESS_CUT`·|f|,
far under any tolerance on G.
"""
const BESS_CUT = 1e-9

"""
Upper end of the Waasmaier-Kirfel f0 fit range, s = sin θ/λ in Å⁻¹.
Beyond it the ion fits diverge; see the FormFactor README.
"""
const WK_S_MAX = 6.0

"""
Floor applied to Chantler f2 table values before the log-log interpolation
`f1f2`: f2 is positive and spans decades, and the floor keeps the log finite
where the table stores an exact zero.
"""
const F2_LOG_FLOOR = 1e-99

"""
Species pairs (a, b), a ≤ b, in [`ForwardCache`](@ref)'s `Gc`
column order, species numbered as in the file header
(1 vac, 2 ex, 3-5 shells): the 10 pairs of {1, 3, 4, 5} (the
envelope-free terms, "A"), then the 4 pairs (2, b),
b ∈ {1, 3, 4, 5} ("B"), then (2, 2) ("C").
"""
const _GRAM_PAIRS = (
    (1, 1), (1, 3), (1, 4), (1, 5), (3, 3),
    (3, 4), (3, 5), (4, 4), (4, 5), (5, 5),
    (1, 2), (2, 3), (2, 4), (2, 5), (2, 2),
)

# Types shared by several files of the module, defined before the includes.

"""
An amplitude shared by all `n` scatterers: `f[q]`, the same for every
one (the hydration beads of a class all carry the same area, so the
same Gaussian amplitude). An `(n, length(f))` matrix by interface,
stored as one vector. [`compute_B_lm`](@ref) recognizes it: the amplitude
factors out of the sum over scatterers, so it computes the multipoles with
unit amplitude once and scales them by `f(q)`, which costs no `Ft` fill and
no per-scatterer multiply.
"""
struct SharedAmplitude{T<:Number} <: AbstractMatrix{T}
    f::Vector{T}
    n::Int
end

"""
Reusable workspace for evaluating spherical Bessel functions over a fixed
`q` grid.

The workspace is used by [`sphBessRatios!`](@ref) to perform the first pass of
the spherical-Bessel recurrence. It stores the per-`q` quantities needed by
the subsequent upward sweep, avoiding allocation for each radius.

# Fields
- `x`: `x[k] = q[k] * r` for the current radius.
- `invx`: `1 / x[k]`, with `0.0` substituted when `x[k] == 0`.
- `lup`: `floor(Int, x[k])`, the largest order for which the upward recurrence
    is used.
- `N`: starting order of the downward continued-fraction recurrence. A value
    of `-1` indicates that `floor(x[k]) ≥ lMax` and no ratios are required.
- `rp`: scratch storage for the current continued-fraction ratio during the
    downward sweep.
- `jm1`: current `jₗ₋₁(x[k])` value for the upward sweep. After
    [`sphBessRatios!`](@ref), it contains `j₁(x[k])`.
- `jm2`: current `jₗ₋₂(x[k])` value for the upward sweep. After
    [`sphBessRatios!`](@ref), it contains `j₀(x[k])`.
- `R`: ratio table with `R[k, l] = jₗ(x[k]) / jₗ₋₁(x[k])` for the orders
    required by the sweep. The first dimension is contiguous in `q`.
"""
struct sphBess
    x::Vector{Float64}
    invx::Vector{Float64}
    lup::Vector{Int}
    N::Vector{Int}
    rp::Vector{Float64}
    jm1::Vector{Float64}
    jm2::Vector{Float64}
    R::Matrix{Float64}
end

# The public surface: forward_cache builds the geometry-only ForwardCache.
# Everything the includes below bring in (compute_B_lm, hydration, gram, …)
# is the machinery it composes.
export forward_cache, form_factor_table, form_factors, form_factor_log, FF, FormFactorError

include("SphFuncs.jl")
include("FormFactor.jl")
include("PartialWave.jl")
include("Scatterers.jl")
include("ForwardCache.jl")

# Defined after the includes: its initializer `_read_tables` and the type `_FFTables`
# live in FormFactor.jl, and nothing included uses `_TABLES` outside function bodies.
"The tables, read from the database on first use (thread safe, built once)."
const _TABLES = Lazy{_FFTables}(_read_tables)

end # module
