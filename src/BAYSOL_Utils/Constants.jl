# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Leaf module of constant primitives.
"""
module Constants

export DEFAULT_ATOL, SHELL_THICKNESS, PROBE_RADIUS, SHELL_N_TARGET,
DRO_UNIT, B_LM_CHUNK, AVOGADRO, DEFAULT_TEMPERATURE_C,
PMV_REFERENCE_TEMPERATURE_C, PMV_FRACTIONAL_EXPANSIBILITY,
EXCL_VOL_CORR_BOUNDS, EXCL_VOL_CORR_EPS, φ_max,
DRO_BOUNDS, DRO12_CONCENTRATION, DRO3_CONCENTRATION

#-------------------------
# Floating-point accuracy 
#-------------------------

"""
Default absolute tolerance for floating-point equality checks
(abs(a - b) < DEFAULT_ATOL, or isapprox(a, b; atol = DEFAULT_ATOL)):
a few orders of magnitude above Float64 roundoff.
"""
const DEFAULT_ATOL = 1.0e-9

#-------------------------
# Forward model constants
#-------------------------

"""
Hydration-shell thickness in Å: how far the perturbed-density water layer
extends beyond the solvent-accessible surface. 3.0 is CRYSOL's border-layer
default.
"""
const SHELL_THICKNESS = 3.0

"Solvent probe radius in Å (water), forwarded to [`SASA.shell_points`](@ref BAYSOL.SASA.shell_points)."
const PROBE_RADIUS = 1.4

"""
Default shell-dummy budget (hydration's n_target). nothing lets
[`SASA.shell_points`](@ref BAYSOL.SASA.shell_points) size the cloud from the accessible area
(≈ area / SASA.SHELL_AREA_PER_POINT, floored at SASA.SHELL_MIN_POINTS);
an Int pins it.
"""
const SHELL_N_TARGET::Union{Nothing,Int} = nothing

"""
Default number of points to generate to sample excluded volume.
10.1016/j.bpj.2023.10.034 uses a 16³ voxel grid for each atom;
a sphere occupies π/6 of the cube. This works out to roughly
(π/6 * 16³) ≈ 2145 points being occupied.
"""
const N_VOL_SHELL::Int64 = 2145

"Shell-contrast unit in e·Å⁻³ (CRYSOL's --dro); dro_k = DRO_UNIT * δρ_k."
const DRO_UNIT = 0.03

"Atoms/dummies per pass in [`Scattering.compute_B_lm`](@ref BAYSOL.Scattering.compute_B_lm)."
const B_LM_CHUNK = UInt64(2048)

#--------------------
# Physical Constants 
#--------------------

"Avogadro constant, mol⁻¹ (CODATA, exact since the 2019 SI redefinition)."
const AVOGADRO = 6.02214076e23

#----------------------------
# Sampler defaults
#----------------------------

"""
Default solution temperature, °C, for _ρₑ/[`Fitting.ρₑ_prior`](@ref)'s bulk-electron
-density calculation. Pass the sample's real temperature instead whenever it is
known: water's density is evaluated at it exactly, and the solutes' 25 °C
partial molar volumes get a widened uncertainty (see
[`PMV_FRACTIONAL_EXPANSIBILITY`](@ref)).
"""
const DEFAULT_TEMPERATURE_C = 25.0

"""
Temperature, °C, at which the bundled partial-molar-volume tables are tabulated
(see PartialMolarVolumes/README.md: 298.15 K unless a source says otherwise).
"""
const PMV_REFERENCE_TEMPERATURE_C = 25.0

"""
Fractional partial-molar-volume expansibility, K⁻¹: an upper bound on
(∂ϕ°/∂T)/ϕ° used to widen a solute's 25 °C ϕ° uncertainty when the sample is at
another temperature, σ_T = PMV_FRACTIONAL_EXPANSIBILITY · ϕ° · |t - 25|.

Derived from the multi-temperature series already bundled with the tables
(15-35 °C: sugars, ureas and glycolurils in sources/extracted_pmv_candidates.tsv;
18-40 °C: Chalikian et al. 2001's nucleobases/nucleosides, 10.1016/S0301-4622(01)00200-9,
the `other-T` rows of nonbiological.tsv): across those 42 solutes the fractional
expansibility spans 0.44-2.96 × 10⁻³ K⁻¹ (median 0.82 × 10⁻³), so 3.0 × 10⁻³
covers every one of them. No electrolyte has multi-temperature data in the
tables, so this bound is unverified for salts.
"""
const PMV_FRACTIONAL_EXPANSIBILITY = 3.0e-3

"""
Hard bounds `(cmin, cmax)` on CRYSOL's excluded-volume correction c1
([`Fitting.profiled_corrs`](@ref BAYSOL.Fitting.profiled_corrs)), CRYSOL's
r₀/r_m. c1 is profiled, not sampled, so these bounds -- not a prior -- are
what stops it from absorbing model misspecification that belongs on the
physically meaningful parameters (dns/δρ1-3) instead.
"""
const EXCL_VOL_CORR_BOUNDS = (0.8, 1.3)

"""
Padding/grid-resolution unit for [`Fitting.profiled_corrs`](@ref
BAYSOL.Fitting.profiled_corrs)'s c1 search: the search actually runs on
`(cmin - EXCL_VOL_CORR_EPS, cmax + EXCL_VOL_CORR_EPS)` so that landing
exactly on `cmin`/`cmax` can be distinguished from genuinely wanting to go
further (real "saturation"), and the same value is the coarse pre-scan
grid's step size.
"""
const EXCL_VOL_CORR_EPS = 0.02

"""
Upper bound on the cavity occupancy φ = ρ_cavity/ρ₀. Water in a cavity can
be at most modestly denser than bulk: the densest well-attested hydration
water is Merzel & Smith's first layer at 1.15·ρ₀, so φ_max = 1.25 leaves
margin above it while excluding unphysical over-dense "water" (e.g. the
δρ3 = 4, φ ≈ 1.36, seen when δρ3 was unconstrained).
"""
const φ_max = 1.25

"""
CRYSOL3's fitting limits `(lo, hi)` on the convex/concave shell contrasts
δρ₁, δρ₂, in units of [`DRO_UNIT`](@ref): "The limits during the fitting are
-10 to 2". They are the support of the δρ₁/δρ₂ priors
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)) and of the scaled-logit
maps [`Fitting.Θ`](@ref BAYSOL.Fitting.Θ)/[`Fitting.Ξ`](@ref BAYSOL.Fitting.Ξ)
put on them.
"""
const DRO_BOUNDS = (-10.0, 2.0)

"""
Default concentration κ = α + β − 2 of the δρ₁/δρ₂ Beta priors
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)). κ = 14 gives
Beta(83/6, 13/6) on [`DRO_BOUNDS`](@ref), with its mode at δρ = 1 and
SD(δρ) ≈ 1.00. That is the same spread as the Normal(1, 1) δρ₂ prior it
replaces.
"""
const DRO12_CONCENTRATION = 14.0

"""
Default concentration κ = α + β − 2 of the cavity-contrast (δρ₃) Beta prior
([`Fitting.δρ_prior`](@ref BAYSOL.Fitting.δρ_prior)), stretched onto
[−ρ̄ₑ/`DRO_UNIT`, (`φ_max` − 1)·ρ̄ₑ/`DRO_UNIT`]. κ = 1.25 gives Beta(2, 1.25) on
u = (δρ₃ − X)/W, with its mode at δρ₃ = 0 (bulk-density cavity water).
"""
const DRO3_CONCENTRATION = 1.25

@assert(
    0 < EXCL_VOL_CORR_EPS <= (EXCL_VOL_CORR_BOUNDS[2] - EXCL_VOL_CORR_BOUNDS[1]),
    "EXCL_VOL_CORR_EPS must be in (0, cmax-cmin]"
)

end # module
