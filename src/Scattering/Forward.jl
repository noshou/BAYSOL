# SPDX-License-Identifier: LGPL-2.1-or-later

# The forward model, assembled. This is the module-level entry point: given a
# molecule, a q grid, a band limit and the beam energy, build the five species'
# multipoles, reduce them to the species Gram matrix `G(q)`, and contract that
# against a contrast vector to a detector-scale intensity.
#
#     mol ─► (B_vac, B_ex, B_sh_convex, B_sh_concave, B_sh_cavity)   species_multipoles
#         ─► G(q) ∈ ℝ^{5×5×Q}                                        gram_matrix
#         ─► ForwardCache(G, qvals, r_m, form_factor_log)             forward_cache
#         ─► I_calc(q) = scale·(v(q)ᵀ G v(q)) + bkgrnd_corr           forward
#
# `G(q)` depends only on geometry and beam, never on `(scale, bkgrnd_corr, dns, δρ, c_1)`.
# Build the cache once per structure with `forward_cache`; every likelihood
# evaluation is then the O(Q) `forward(cache, scale, bkgrnd_corr, dns, δρ; c_1)`.

using ..MolecularStructure: Molecule, elms, vols

"""
    species_multipoles(mol, qvals, lMax, energy; kwargs...)
        -> NTuple{5, Array{ComplexF64,3}}

The five CRYSOL-3 species' multipoles `B_lm`, in the fixed order

    (vac, ex, sh_convex, sh_concave, sh_cavity)

that [`gram`](@ref) and [`contrast_vector`](@ref) assume. Each is `(C, K, Q)` in
[`compute_B_lm`](@ref)'s packed layout (`C = 2` for `vac` near an absorption
edge, `1` otherwise; `C = 1` for the four dummy species). 
# Arguments
- `mol::Molecule`.
- `qvals::AbstractVector{<:Real}`, length `Q`: momentum transfer in Å⁻¹.
- `lMax::Integer`: spherical-harmonic band limit.
- `energy::Real`: photon energy in eV (for the `vac` anomalous form factors).

# Keywords
    - `ions::Vector{String} = elms(mol)`: ion/element string per atom.
    - `chunk::Unsigned = B_LM_CHUNK`: `compute_B_lm` batch size (results invariant).
    - `form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE`.
    - `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
    `n_target = SHELL_N_TARGET`, `classes = SHELL_CLASSES`: forwarded to
    [`hydration`](@ref). A class not in `classes` comes back an all-zero `B_lm`
    (≡ its `dro_k = 0`), so the return is always a 5-tuple.
    - `form_factor_log::Union{Nothing,Vector{String}} = nothing`: forwarded
    verbatim to [`vacuo`](@ref)'s `log` keyword.
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
)
    _CHUNK = UInt64(chunk)
    b_vac = vacuo(
        mol,
        qvals,
        lMax,
        ions,
        Float64(energy),
        _CHUNK;
        form_factor_source = form_factor_source,
        log = form_factor_log,
    )
    b_ex  = excluded(mol, qvals, lMax, _CHUNK)
    sh    = hydration(mol, qvals, lMax, _CHUNK;
                    thickness = Float64(thickness), probe = Float64(probe),
                    n_target  = n_target, classes = classes)
    return (b_vac, b_ex, sh.convex, sh.concave, sh.cavity)
end

"""
    gram_matrix(mol, qvals, lMax, energy; kwargs...) -> Array{Float64,3}

The five-species Gram matrix `G_ab(q) = S_ab(q)`, shape `(5, 5, Q)`, symmetric
and positive-semidefinite in its species axes. Depends only on geometry and beam.

# Keywords
Forwarded verbatim to [`species_multipoles`](@ref); none of these are fit
parameters, so you generally don't need to pass them:
- `ions::Vector{String} = elms(mol)`: ion/element string per atom.
- `chunk::Unsigned = B_LM_CHUNK`: `compute_B_lm` batch size (results invariant).
- `form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE`.
- `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
`n_target = SHELL_N_TARGET`, `classes = SHELL_CLASSES`: hydration-shell
geometry, forwarded to `hydration`.
- `form_factor_log::Union{Nothing,Vector{String}} = nothing`: forwarded
verbatim to [`species_multipoles`](@ref).
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
    mean_atomic_radius(mol) -> Float64

The structure's mean atomic radius `r_m` in Å, which is the reference scale CRYSOL's
excluded-volume correction factor `c₁` is measured against, and the point at which
[`excluded_volume_factor`](@ref)'s single-envelope approximation is exact.
Geometry only, so it caches alongside `G`.

CRYSOL defines `r_m` as the mean of each dummy atom's *own* equivalent-sphere
radius `r_gj = cbrt(3 V_j / 4π)` (Svergun, Barberato & Koch, 1995, text
following their eq. 13: `r_m = N⁻¹ Σⱼ r_gj`, `r_gj` read off their Table 1),
i.e. the radius implied by the CRYSOL-style excluded volume `V_j` each atom
actually gets in [`excluded`](@ref) (`MolecularStructure.vols`).
"""
function mean_atomic_radius(mol::Molecule)::Float64
    v = vols(mol)
    isempty(v) && throw(ArgumentError("mean_atomic_radius: molecule has no atoms"))
    return sum(cbrt(3.0 * vi / (4.0 * π)) for vi in v) / length(v)
end

"""
    ForwardCache

Everything about a structure the forward model needs that does **not** depend on
the fit parameters: the species Gram matrix `G`, the `q` grid it was built on,
and the mean atomic radius `r_m` that [`excluded_volume_factor`](@ref) measures
`c₁` against. Build one per structure with [`forward_cache`](@ref); every
likelihood evaluation is then the O(Q) [`forward`](@ref)`(cache, …)`.

# Fields
- `G::Array{Float64,3}`, `(n, n, Q)`: from [`gram_matrix`](@ref).
- `qvals::Vector{Float64}`, length `Q`: the grid `G` was built on.
- `r_m::Float64`: mean atomic radius in Å.
- `form_factor_log::Vector{String}`: construction-time diagnostics from the
    vacuum term's [`FormFactor.form_factor_table`](@ref) build.
"""
struct ForwardCache
    G::Array{Float64,3}
    qvals::Vector{Float64}
    r_m::Float64
    form_factor_log::Vector{String}
end

"""
    forward_cache(mol, qvals, lMax, energy; kwargs...) -> ForwardCache

The geometry-only pass: [`gram_matrix`](@ref) plus the `q` grid and
[`mean_atomic_radius`](@ref) that fitting `c₁` needs. **Cache once per
structure.**

# Keywords
Forwarded verbatim to [`species_multipoles`](@ref) (same as [`gram_matrix`](@ref)'s);
none of these are fit parameters, so leaving them all at their defaults is the
common case:
- `ions::Vector{String} = elms(mol)`: ion/element string per atom.
- `chunk::Unsigned = B_LM_CHUNK`: `compute_B_lm` batch size (results invariant).
- `form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE`.
- `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
`n_target = SHELL_N_TARGET`, `classes = SHELL_CLASSES`: hydration-shell
geometry, forwarded to `hydration`.

The vacuum term's `form_factor_table` build diagnostics are always collected.
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
)::ForwardCache = begin
    form_factor_log = String[]
    ForwardCache(
        gram_matrix(
            mol, qvals, lMax, energy;
            ions = ions, chunk = chunk, form_factor_source = form_factor_source,
            thickness = thickness, probe = probe, n_target = n_target, classes = classes,
            form_factor_log = form_factor_log,
        ),
        collect(Float64, qvals),
        mean_atomic_radius(mol),
        form_factor_log,
    )
end

"""
    forward(G, scale, bkgrnd_corr, dns, δρ) -> Vector

The detector-scale model intensity `I_calc(q) = scale · (vᵀ G(q) v) +
bkgrnd_corr`, with the contrast vector `v = contrast_vector(dns, δρ)`.

# Arguments
-   `G::AbstractArray{<:Real,3}`, `(n, n, Q)`: the species Gram matrix, from
    [`gram_matrix`](@ref) (or [`gram`](@ref)).
-   `scale::Real`: overall scale between the absolute model intensity (units
    of electrons²) and the detector's arbitrary-unit reading. A nuisance
    parameter with no physical prior of its own — see
    [`BayeSol.Fitting.wls_fit`](@ref)/[`BayeSol.Fitting.wls_marg_ll`](@ref) to
    fit it (jointly with `bkgrnd_corr`) by weighted least squares and profile
    or marginalise it out of the likelihood, rather than giving it a prior
    and sampling it directly.
-   `bkgrnd_corr::Real`: flat background left by imperfect buffer
    subtraction, same arbitrary units as the detector reading.
-   `dns::Real`: the mean electron density (e·Å⁻³) of the bulk solvent dummy atom displaces..
-   `δρ`: dimensionless hydration-shell contrast(s); the *actual* per-species
    contrast fed into `v` is `dro_k = DRO_UNIT · δρ_k`. Either
    `δρ::NTuple{3,<:Real}` = `(δρ_convex, δρ_concave, δρ_cavity)` for the
    five-species `G` this file builds (`sh_convex`/`sh_concave`/`sh_cavity`,
    see the file-header species ordering in `Intensity.jl`), or a single
    `δρ::Real` for a merged three-species `G` (`vac`/`ex`/`sh`).

# Returns
- `Vector` of length `Q`: `I_calc(q)`, `eltype` promoted from the arguments.
"""
forward(
    G::AbstractArray{<:Real,3}, scale::Real, bkgrnd_corr::Real, dns::Real, δρ::Union{Real,NTuple{3,<:Real}}
) = _fused_intensity_calc(G, contrast_vector(dns, δρ), scale, bkgrnd_corr)

"""
    forward(cache, scale, bkgrnd_corr, dns, δρ, c_1 = nothing) -> Vector

    I_calc(q) = scale · (v(q)ᵀ G(q) v(q)) + bkgrnd_corr
    v(q)      = [1, -dns · G_ex(q; c₁), dro₁, dro₂, dro₃]

Same model as the `forward(G, scale, bkgrnd_corr, dns, δρ)` method above (see
its `# Arguments` for what `scale`, `bkgrnd_corr`, `dns`, `δρ` are and where
their values come from), plus the optional excluded-volume correction `c_1`.
O(Q) in the fit parameters, same cost as the 5-argument method when `c_1` is
left at its default. All five fit-parameter arguments are positional,
matching the `forward(G, scale, bkgrnd_corr, dns, δρ)` method above, so a
`ξ = (dns, δρ1, δρ2, δρ3, c1)` draw can be splatted straight in:
`forward(cache, scale, bkgrnd_corr, ξ[1], (ξ[2], ξ[3], ξ[4]), ξ[5])`.

# Arguments
- `cache::ForwardCache`: from [`forward_cache`](@ref). Bundles `G` with the
    `q` grid and `r_m` that evaluating `c_1` needs
- `scale`, `bkgrnd_corr`, `dns`, `δρ`: as in the `forward(G, scale,
    bkgrnd_corr, dns, δρ)` method above.
- `c_1::Union{Nothing,Real} = nothing`: CRYSOL's excluded-volume correction
    factor, dimensionless (`r₀/r_m` in CRYSOL's own radius parameterisation;
    see [`excluded_volume_factor`](@ref)). CRYSOL's own fitting range is
    `c_1 ∈ [0.96, 1.04]`. Has a prior, [`BayeSol.Fitting.c1_prior`](@ref)`(n)` (`n` =
    the percentage of prior mass required within that range). `c_1 = nothing`
    (the default) or `c_1 == 1` skips the correction entirely and reduces
    exactly to the 5-argument [`forward`](@ref) above.

# Returns
- `Vector` of length `Q`: `I_calc(q)`.
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
    forward(mol, qvals, lMax, energy, scale, bkgrnd_corr, dns, δρ, c_1 = nothing; kwargs...) -> Vector

The whole forward model from a molecule in one call: build the cache, then
evaluate. A convenience for one-offs; for repeated evaluation at fixed geometry
call [`forward_cache`](@ref) once and the [`ForwardCache`](@ref) method of
[`forward`](@ref) per parameter set — this method rebuilds `G` from scratch
(the expensive part) on every call, so avoid it in a sampler's inner loop.

# Arguments
- `mol::Molecule`, `qvals`, `lMax`, `energy`: as in [`forward_cache`](@ref)/
    [`species_multipoles`](@ref) — the geometry/beam setup, not fit parameters.
- `scale`, `bkgrnd_corr`, `dns`, `δρ`, `c_1`: the fit parameters, positional
    exactly as on the `forward(cache, scale, bkgrnd_corr, dns, δρ, c_1)`
    method above (required except `c_1`, which defaults to `nothing`).

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
