# SPDX-License-Identifier: LGPL-2.1-or-later

# The forward model, assembled. This is the module-level entry point: given a
# molecule, a q grid, a band limit and the beam energy, build the five species'
# multipoles, reduce them to the species Gram matrix G(q), and contract that
# against a contrast vector to a detector-scale intensity.
#
#     mol ─► (B_vac, B_ex, B_sh_convex, B_sh_concave, B_sh_cavity)   species_multipoles
#         ─► G(q) ∈ ℝ^{5×5×Q}                                        gram_matrix
#         ─► ForwardCache(G, qvals, r_m, form_factor_log, n_atoms, lMax)   forward_cache
#         ─► I_calc(q) = scale·(v(q)ᵀ G v(q)) + bkgrnd_corr           forward
#
# G(q) depends only on geometry and beam, never on (scale, bkgrnd_corr, dns, δρ, c_1).
# Build the cache once per structure with forward_cache; every likelihood
# evaluation is then the O(Q) forward(cache, scale, bkgrnd_corr, dns, δρ; c_1).

using ..MolecularStructure: Molecule, elms, vols, coords_spherical
using ..BAYSOL_Utils.Timing: StageLog, timed!

"""
$(TYPEDSIGNATURES)

The five CRYSOL-3 species' multipoles B_lm, in the fixed order

    (vac, ex, sh_convex, sh_concave, sh_cavity)

that [`gram`](@ref) and [`contrast_vector`](@ref) assume. Each is (C, K, Q) in
[`compute_B_lm`](@ref)'s packed layout (C = 2 for vac near an absorption
edge, 1 otherwise; C = 1 for the four dummy species). 
# Arguments
- mol::Molecule.
- `qvals::AbstractVector{<:Real}, length Q`: momentum transfer in Å⁻¹.
- `lMax::Integer`: spherical-harmonic band limit.
- `energy::Real`: photon energy in eV (for the vac anomalous form factors).

# Keywords
    - `ions::Vector{String} = elms(mol)`: ion/element string per atom.
    - `chunk::Unsigned = B_LM_CHUNK`: compute_B_lm batch size (results invariant).
    - form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE.
    - thickness::Real = SHELL_THICKNESS, probe::Real = PROBE_RADIUS,
    n_target = SHELL_N_TARGET, classes = SHELL_CLASSES: forwarded to
    [`hydration`](@ref). A class not in classes comes back an all-zero B_lm
    (== its dro_k = 0), so the return is always a 5-tuple.
    - `form_factor_log::Union{Nothing,Vector{String}} = nothing`: when not nothing,
    the form-factor table's construction diagnostics are appended to it (as
    [`vacuo`](@ref)'s log keyword).
    - `stage_log::Union{Nothing,StageLog} = nothing`: if given, records the
    "vacuum + excluded volume (vols + B_lm)" and "hydration (SASA + B_lm)" stages.

The vacuum and excluded-volume multipoles are computed together by
[`_compute_B_lm`](@ref) (one shared pass over the atoms); the result equals
[`vacuo`](@ref) and [`excluded`](@ref) called separately, up to rounding.

# Returns
- `NTuple{5,Array{ComplexF64,3}}`: (vac, ex, sh_convex, sh_concave, sh_cavity).
"""
function species_multipoles(
    mol::Molecule, qvals::AbstractVector{<:Real}, lMax::Integer, energy::Real;
    ions::Vector{String}                 = elms(mol),
    chunk::Unsigned                      = B_LM_CHUNK,
    form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE,
    thickness::Real                      = SHELL_THICKNESS,
    probe::Real                          = PROBE_RADIUS,
    n_target::Union{Nothing,Integer}     = SHELL_N_TARGET,
    classes                              = SHELL_CLASSES,
    form_factor_log::Union{Nothing,Vector{String}} = nothing,
    stage_log::Union{Nothing,StageLog} = nothing,
)
    _CHUNK = UInt64(chunk)
    # vacuum and excluded volume sit on the same atoms, so one pass computes both:
    # one spherical-harmonic evaluation and one Bessel sweep per atom, shared by the
    # form-factor and dummy amplitudes (same result as vacuo / excluded separately)
    b_vac, b_ex = timed!(stage_log, :static, 2, "vacuum + excluded volume (vols + B_lm)") do
        amp_vac = _vacuo_amplitude(qvals, ions, Float64(energy);
                                   form_factor_source = form_factor_source, log = form_factor_log)
        amp_ex  = _gaussian_dummy(vols(mol), qvals)
        _compute_B_lm(coords_spherical(mol), qvals, (amp_vac, amp_ex), lMax, _CHUNK)
    end
    sh = timed!(stage_log, :static, 2, "hydration (SASA + B_lm)") do
        hydration(mol, qvals, lMax, _CHUNK;
                  thickness = Float64(thickness), probe = Float64(probe),
                  n_target  = n_target, classes = classes)
    end
    return (b_vac, b_ex, sh.convex, sh.concave, sh.cavity)
end

"""
$(TYPEDSIGNATURES)

The five-species Gram matrix G_ab(q) = S_ab(q), shape (5, 5, Q), symmetric
and positive-semidefinite in its species axes. Depends only on geometry and beam.

# Keywords
Forwarded verbatim to [`species_multipoles`](@ref); none of these are fit
parameters, so you generally don't need to pass them:
- `ions::Vector{String} = elms(mol)`: ion/element string per atom.
- `chunk::Unsigned = B_LM_CHUNK`: compute_B_lm batch size (results invariant).
- `form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE`
- `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
`n_target = SHELL_N_TARGET`, `classes = SHELL_CLASSES`: hydration-shell geometry.
- `form_factor_log::Union{Nothing,Vector{String}} = nothing`: forwarded to [`species_multipoles`](@ref).
"""
gram_matrix(
    mol::Molecule, qvals::AbstractVector{<:Real}, lMax::Integer, energy::Real;
    ions::Vector{String}                 = elms(mol),
    chunk::Unsigned                      = B_LM_CHUNK,
    form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE,
    thickness::Real                      = SHELL_THICKNESS,
    probe::Real                          = PROBE_RADIUS,
    n_target::Union{Nothing,Integer}     = SHELL_N_TARGET,
    classes                              = SHELL_CLASSES,
    form_factor_log::Union{Nothing,Vector{String}} = nothing,
)::Array{Float64,3} =
    gram(collect(species_multipoles(
            mol, qvals, lMax, energy;
            ions = ions, chunk = chunk, form_factor_source = form_factor_source,
            thickness = thickness, probe = probe, n_target = n_target, classes = classes,
            form_factor_log = form_factor_log,
        )),
        partial_wave_weights(lMax))

"""
$(TYPEDSIGNATURES)

The structure's mean atomic radius r_m in Å, which is the reference scale CRYSOL's
excluded-volume correction factor c₁ is measured against, and the point at which
[`excluded_volume_factor`](@ref)'s single-envelope approximation is exact.
Geometry only, so it caches alongside G.

CRYSOL defines r_m as the mean of each dummy atom's *own* equivalent-sphere
radius r_gj = cbrt(3 V_j / 4π) (Svergun, Barberato & Koch, 1995, text
following their eq. 13: r_m = N⁻¹ Σⱼ r_gj, r_gj read off their Table 1).
"""
function mean_atomic_radius(mol::Molecule)::Float64
    v = vols(mol)
    isempty(v) && throw(ArgumentError("mean_atomic_radius: molecule has no atoms"))
    return sum(cbrt(3.0 * vi / (4.0 * π)) for vi in v) / length(v)
end

"""
    ForwardCache

Static structure calculations, independent of fit parameters. Build one 
per structure with [`forward_cache`](@ref); every likelihood evaluation 
is then the O(Q) [`forward`](@ref)(cache, …).

# Fields
- `G::Array{Float64,3}, (n, n, Q)`: from [`gram_matrix`](@ref).
- `qvals::Vector{Float64}, length Q`: the grid G was built on.
- `r_m::Float64`: mean atomic radius in Å.
- `form_factor_log::Vector{String}`: construction-time diagnostics from [`FormFactor.form_factor_table`](@ref).
- `n_atoms::Int`: number of atoms in the structure mol was built from
    (length(elms(mol))), e.g. for reporting alongside the fit.
- `lMax::Int`: the spherical-harmonic band limit G was built with.
"""
struct ForwardCache
    G::Array{Float64,3}
    qvals::Vector{Float64}
    r_m::Float64
    form_factor_log::Vector{String}
    n_atoms::Int
    lMax::Int
end

"""
$(TYPEDSIGNATURES)

Static geometry-only and fit independent calculations.

# Keywords
-   `ions::Vector{String} = elms(mol)`: ion/element string per atom.
-   `chunk::Unsigned = B_LM_CHUNK`: compute_B_lm batch size (results invariant).
-   `form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE`
-   `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
    `n_target = SHELL_N_TARGET`, `classes = SHELL_CLASSES`: hydration-shell
    geometry, forwarded to hydration.
-   `stage_log::Union{Nothing,StageLog} = nothing`: if given, the vacuum,
    excluded-volume, hydration and Gram + r_m stages are recorded in it
    (depth 2, group `:static`).

The vacuum term's form_factor_table build diagnostics are always collected.
"""
forward_cache(
    mol::Molecule,
    qvals::AbstractVector{<:Real},
    lMax::Integer,
    energy::Real;
    ions::Vector{String}                 = elms(mol),
    chunk::Unsigned                      = B_LM_CHUNK,
    form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE,
    thickness::Real                      = SHELL_THICKNESS,
    probe::Real                          = PROBE_RADIUS,
    n_target::Union{Nothing,Integer}     = SHELL_N_TARGET,
    classes                              = SHELL_CLASSES,
    stage_log::Union{Nothing,StageLog}   = nothing,
)::ForwardCache = begin
    form_factor_log = String[]
    mp = species_multipoles(
        mol, qvals, lMax, energy;
        ions = ions, chunk = chunk, form_factor_source = form_factor_source,
        thickness = thickness, probe = probe, n_target = n_target, classes = classes,
        form_factor_log = form_factor_log, stage_log = stage_log,
    )
    G, r_m = timed!(stage_log, :static, 2, "Gram + r_m") do
        gram(collect(mp), partial_wave_weights(lMax)), mean_atomic_radius(mol)
    end
    ForwardCache(G, collect(Float64, qvals), r_m, form_factor_log, length(ions), lMax)
end

"""
$(TYPEDSIGNATURES)

The detector-scale model intensity I_calc(q) = scale · (vᵀ G(q) v) +
bkgrnd_corr, with the contrast vector v = contrast_vector(dns, δρ).

# Arguments
-   `G::AbstractArray{<:Real,3}, (n, n, Q)`: the species Gram matrix, from
    [`gram_matrix`](@ref) (or [`gram`](@ref)).
-   `scale::Real`: overall scale between the absolute model intensity (units
    of electrons²) and the detector's arbitrary-unit reading. A nuisance
    parameter with no physical prior of its own — see
    [`BAYSOL.Fitting.wls_fit`](@ref)/[`BAYSOL.Fitting.wls_marg_ll`](@ref) to
    fit it (jointly with bkgrnd_corr) by weighted least squares and profile
    or marginalise it out of the likelihood, rather than giving it a prior
    and sampling it directly.
-   `bkgrnd_corr::Real`: flat background left by imperfect buffer
    subtraction, same arbitrary units as the detector reading.
-   `dns::Real`: the mean electron density (e·Å⁻³) of the bulk solvent dummy atom displaces..
-   `δρ`: dimensionless change in hydration-shell contrast(s);dro_k = DRO_UNIT · δρ_k. Either
    δρ::NTuple{3,<:Real} = (δρ_convex, δρ_concave, δρ_cavity) or a single δρ::Real 
    for a merged three-species G (vac/ex/sh).

# Returns
- `Vector of length Q`: I_calc(q), eltype promoted from the arguments.
"""
forward(
    G::AbstractArray{<:Real,3}, scale::Real, bkgrnd_corr::Real, dns::Real, δρ::Union{Real,NTuple{3,<:Real}}
) = _fused_intensity_calc(G, contrast_vector(dns, δρ), scale, bkgrnd_corr)

"""
$(TYPEDSIGNATURES)

    I_calc(q) = scale · (v(q)ᵀ G(q) v(q)) + bkgrnd_corr
    v(q)      = [1, -dns · G_ex(q; c₁), dro₁, dro₂, dro₃]

# Arguments
- `cache::ForwardCache`: from [`forward_cache`](@ref). Bundles G with the
    q grid and r_m that evaluating c_1 needs
- `scale, bkgrnd_corr, dns, δρ`: as in the forward(G, scale,
    bkgrnd_corr, dns, δρ) method above.
- `c_1::Union{Nothing,Real} = nothing`: CRYSOL's excluded-volume correction
    factor, dimensionless (r₀/r_m in CRYSOL's own radius parameterisation;
    see [`excluded_volume_factor`](@ref)). CRYSOL's own fitting range is
    c_1 ∈ [0.96, 1.04]. c_1 is no longer sampled with a prior; it is
    profiled out per draw by [`BAYSOL.Fitting.profiled_corrs`](@ref) over
    the wider search bounds `cmin=0.8, cmax=1.3`. c_1 = nothing
    (the default) or c_1 == 1 skips the correction entirely and reduces
    exactly to the 5-argument [`forward`](@ref) above.

# Returns
- `Vector of length Q`: I_calc(q).
"""
function forward(
    cache::ForwardCache,
    scale::Real,
    bkgrnd_corr::Real,
    dns::Real,
    δρ::Union{Real,NTuple{3,<:Real}},
    c_1::Union{Nothing,Real} = nothing
)
    (c_1 === nothing || c_1 == 1) &&
        return forward(cache.G, scale, bkgrnd_corr, dns, δρ)
    g_ex = excluded_volume_factor(cache.qvals, cache.r_m, c_1)
    return _fused_intensity_calc(cache.G, contrast_matrix(dns, δρ, g_ex), scale, bkgrnd_corr)
end

"""
$(TYPEDSIGNATURES)

# Arguments
- `mol::Molecule, qvals, lMax, energy`: as in [`forward_cache`](@ref)/
    [`species_multipoles`](@ref) — the geometry/beam setup, not fit parameters.
- `scale, bkgrnd_corr, dns, δρ, c_1`: the fit parameters, positional
    exactly as on the forward(cache, scale, bkgrnd_corr, dns, δρ, c_1)
    method above (required except c_1, which defaults to nothing).

# Keywords
Any keywords are forwarded verbatim to [`species_multipoles`](@ref) (same list
as [`forward_cache`](@ref)'s); these are geometry/beam settings, not fit
parameters, so you generally don't need to pass them:
- `ions::Vector{String} = elms(mol)`
- `chunk::Unsigned = B_LM_CHUNK`
- `form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE`
- `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
    `n_target = SHELL_N_TARGET`, `classes = SHELL_CLASSES`
"""
function forward(
    mol::Molecule,
    qvals::AbstractVector{<:Real},
    lMax::Integer,
    energy::Real,
    scale::Real,
    bkgrnd_corr::Real,
    dns::Real,
    δρ::Union{Real,NTuple{3,<:Real}},
    c_1::Union{Nothing,Real} = nothing;
    ions::Vector{String}                 = elms(mol),
    chunk::Unsigned                      = B_LM_CHUNK,
    form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE,
    thickness::Real                      = SHELL_THICKNESS,
    probe::Real                          = PROBE_RADIUS,
    n_target::Union{Nothing,Integer}     = SHELL_N_TARGET,
    classes                              = SHELL_CLASSES,
)
    cache = forward_cache(
        mol, qvals, lMax, energy;
        ions = ions, chunk = chunk, form_factor_source = form_factor_source,
        thickness = thickness, probe = probe, n_target = n_target, classes = classes,
    )
    return forward(cache, scale, bkgrnd_corr, dns, δρ, c_1)
end
