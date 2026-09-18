# SPDX-License-Identifier: LGPL-2.1-or-later

# The forward model, assembled. This is the module-level entry point: given a
# molecule, a q grid, a band limit and the beam energy, build the five species'
# multipoles, reduce them to the species Gram matrix `G(q)`, and contract that
# against a contrast vector to a detector-scale intensity.
#
#     mol ─► (B_vac, B_ex, B_sh_convex, B_sh_concave, B_sh_cavity)   species_multipoles
#         ─► G(q) ∈ ℝ^{5×5×Q}                                        gram_matrix
#         ─► ForwardCache(G, qvals, r_m)                             forward_cache
#         ─► I_calc(q) = m·(v(q)ᵀ G v(q)) + c                        forward
#
# `G(q)` depends only on geometry and beam, never on `(m, c, dns, δρ, c1)`. Build the
# cache once per structure with `forward_cache`; every likelihood evaluation is then
# the O(Q) `forward(cache, m, c, dns, δρ; c1)`.

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
"""
function species_multipoles(
    mol::Molecule, qvals::AbstractVector{<:Real}, lMax::Integer, energy::Real;
    ions::Vector{String}                 = Molecules.elms(mol),
    chunk::Unsigned                      = B_LM_CHUNK,
    form_factor_source::FormFactorSource = FORM_FACTOR_SOURCE,
    thickness::Real                      = SHELL_THICKNESS,
    probe::Real                          = PROBE_RADIUS,
    n_target::Union{Nothing,Integer}     = SHELL_N_TARGET,
    classes                              = SHELL_CLASSES,
)
    _CHUNK = UInt64(chunk)
    b_vac = vacuo(
        mol, 
        qvals, 
        lMax, 
        ions, 
        Float64(energy), 
        _CHUNK;
        form_factor_source = form_factor_source
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

`kwargs` are those of [`species_multipoles`](@ref).
"""
gram_matrix(mol::Molecule, qvals::AbstractVector{<:Real}, lMax::Integer, energy::Real;
            kwargs...)::Array{Float64,3} =
    gram(collect(species_multipoles(mol, qvals, lMax, energy; kwargs...)),
        partial_wave_weights(lMax))

"""
    mean_atomic_radius(mol) -> Float64

The structure's mean atomic radius `r_m` in Å, which is the reference scale CRYSOL's
excluded-volume correction factor `c₁` is measured against, and the point at which
[`excluded_volume_factor`](@ref)'s single-envelope approximation is exact.
Geometry only, so it caches alongside `G`.
"""
function mean_atomic_radius(mol::Molecule)::Float64
    r = Molecules.radii(mol)
    isempty(r) && throw(ArgumentError("mean_atomic_radius: molecule has no atoms"))
    return sum(r) / length(r)
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
"""
struct ForwardCache
    G::Array{Float64,3}
    qvals::Vector{Float64}
    r_m::Float64
end

"""
    forward_cache(mol, qvals, lMax, energy; kwargs...) -> ForwardCache

The geometry-only pass: [`gram_matrix`](@ref) plus the `q` grid and
[`mean_atomic_radius`](@ref) that fitting `c₁` needs. **Cache once per
structure**; `kwargs` are those of [`species_multipoles`](@ref).
"""
forward_cache(
    mol::Molecule, 
    qvals::AbstractVector{<:Real}, 
    lMax::Integer,
    energy::Real; 
    kwargs...
)::ForwardCache =
    ForwardCache(
        gram_matrix(mol, qvals, lMax, energy; kwargs...),
        collect(Float64, qvals), 
        mean_atomic_radius(mol)
    )

"""
    forward(G, m, c, dns, δρ) -> Vector

The detector-scale model intensity `I_calc(q) = m · (vᵀ G(q) v) + c`, with the
contrast vector `v = contrast_vector(dns, δρ)`.

# Arguments
-   `G::AbstractArray{<:Real,3}`, `(n, n, Q)`: the species Gram matrix, from
    [`gram_matrix`](@ref) (or [`gram`](@ref)).
-   `m::Real`: overall scale between the absolute model intensity (units of
    electrons²) and the detector's arbitrary-unit reading. A nuisance
    parameter with no physical prior of its own — see
    [`Fitting.wls_fit`](@ref)/[`Fitting.wls_marg_ll`](@ref) to fit it (jointly
    with `c`) by weighted least squares and profile or marginalise it out of
    the likelihood, rather than giving it a prior and sampling it directly.
-   `c::Real`: flat background left by imperfect buffer subtraction, same
    arbitrary units as the detector reading.
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
    G::AbstractArray{<:Real,3}, m::Real, c::Real, dns::Real, δρ::Union{Real,NTuple{3,<:Real}}
) = intensity_calc(intensity(G, contrast_vector(dns, δρ)), m, c)

"""
    forward(cache, m, c, dns, δρ; c1 = nothing) -> Vector

    I_calc(q) = m · (v(q)ᵀ G(q) v(q)) + c
    v(q)      = [1, -dns · G_ex(q; c₁), dro₁, dro₂, dro₃]

Same model as the `forward(G, m, c, dns, δρ)` method above (see its
`# Arguments` for what `m`, `c`, `dns`, `δρ` are and where their values come
from), plus the optional excluded-volume correction `c1`. O(Q) in the fit
parameters, same cost as the 5-argument method when `c1` is left at its
default.

# Arguments
- `cache::ForwardCache`: from [`forward_cache`](@ref). Bundles `G` with the
    `q` grid and `r_m` that evaluating `c1` needs
- `m`, `c`, `dns`, `δρ`: as in the `forward(G, m, c, dns, δρ)` method above.

# Keywords
-   `c1::Union{Nothing,Real} = nothing`: CRYSOL's excluded-volume correction
    factor, dimensionless (`r₀/r_m` in CRYSOL's own radius parameterisation;
    see [`excluded_volume_factor`](@ref)). CRYSOL's own fitting range is
    `c1 ∈ [0.96, 1.04]`. Has a prior, [`Fitting.c1_prior`](@ref)`(n)` (`n` =
    the percentage of prior mass required within that range). `c1 = nothing`
    (the default) or `c1 == 1` skips the correction entirely and reduces
    exactly to the 5-argument [`forward`](@ref) above.

# Returns
- `Vector` of length `Q`: `I_calc(q)`.
"""
function forward(
    cache::ForwardCache,
    m::Real,
    c::Real,
    dns::Real,
    δρ::Union{Real,NTuple{3,<:Real}};
    c1::Union{Nothing,Real} = nothing
)
    (c1 === nothing || c1 == 1) &&
        return forward(cache.G, m, c, dns, δρ)
    g_ex = excluded_volume_factor(cache.qvals, cache.r_m, c1)
    return intensity_calc(intensity(cache.G, contrast_matrix(dns, δρ, g_ex)), m, c)
end

"""
    forward(mol, qvals, lMax, energy; m, c, dns, δρ, c1, kwargs...) -> Vector

The whole forward model from a molecule in one call: build the cache, then
evaluate. A convenience for one-offs; for repeated evaluation at fixed geometry
call [`forward_cache`](@ref) once and the [`ForwardCache`](@ref) method of
[`forward`](@ref) per parameter set — this method rebuilds `G` from scratch
(the expensive part) on every call, so avoid it in a sampler's inner loop.

# Arguments
- `mol::Molecule`, `qvals`, `lMax`, `energy`: as in [`forward_cache`](@ref)/
  [`species_multipoles`](@ref) — the geometry/beam setup, not fit parameters.

# Keywords
- `m`, `c`, `dns`, `δρ`, `c1`: the fit parameters, exactly as documented on the
  `forward(cache, m, c, dns, δρ; c1)` method above (required except `c1`, which
  defaults to `nothing`).

`kwargs` beyond `m, c, dns, δρ, c1` are those of [`species_multipoles`](@ref).
"""
function forward(
    mol::Molecule,
    qvals::AbstractVector{<:Real},
    lMax::Integer,
    energy::Real;
    m::Real,
    c::Real,
    dns::Real,
    δρ::Union{Real,NTuple{3,<:Real}},
    c1::Union{Nothing,Real} = nothing,
    kwargs...
)
    return forward(forward_cache(mol, qvals, lMax, energy; kwargs...), m, c, dns, δρ; c1 = c1)
end
