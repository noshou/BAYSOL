# SPDX-License-Identifier: LGPL-2.1-or-later

# Folds the per-species multipoles B_lm (from species_multipoles) into the
# species Gram matrix G(q), and bundles G with what the fit needs to evaluate
# the excluded-volume correction c₁ (ForwardCache). The orientationally-averaged
# intensity itself, I(q) = v(q)ᵀ G(q) v(q), is contracted downstream in
# BAYSOL.Fitting.ProfiledCorrs.
#
# SPECIES ORDERING:
#
#     1  vac         real atoms in vacuo
#     2  ex          excluded-volume dummies      (enters A_total with -dns)
#     3  sh_convex   hydration shell, convex beads   (enters with +dro_1)
#     4  sh_concave  hydration shell, concave beads  (enters with +dro_2)
#     5  sh_cavity   hydration shell, cavity beads   (enters with +dro_3)

using ..MolecularStructure: Molecule, elms, vols
using ..Timing: StageLog, timed!

"""
Species Gram matrix G of shape (n, n, Q) for the n multipole arrays in
Bs (each (C, K, Q) as returned by [`compute_B_lm`](@ref); channel counts
C may differ between species).

G[a, b, :] is the paired partial-wave sum

    S_ab(q) = 4π Σ_c Σ_lm w_lm Re(B_a[c,lm](q) * conj(B_b[c,lm](q)))

i.e. [`cross_scatter`](@ref) off the diagonal and [`self_scatter`](@ref) on it
(`S_aa` = `S_ab`|_{b=a} identically, since |z|² = Re(z * conj z)). Every
G[:, :, k] is real, symmetric and positive semidefinite.

# Arguments
    - `Bs`: an AbstractVector of n ≥ 1 arrays
    <:AbstractArray{<:Complex,3}, each (C, K, Q) sharing a common K and Q.
    Order is (vac, ex, shells…); see the file header.
    - `weights::AbstractVector{<:Real}`, length K:
    [`partial_wave_weights`](@ref)(lMax).

# Returns
- `Array{Float64,3} of size (n, n, Q)`, symmetric in its first two axes.
"""
function gram(
    Bs::AbstractVector{<:AbstractArray{<:Complex,3}}, weights::AbstractVector{<:Real}
)::Array{Float64,3}
    n = length(Bs)
    n ≥ 1 || throw(ArgumentError("gram: need at least one species"))
    K = length(weights)
    Q = size(Bs[1], 3)
    for a in 1:n
        size(Bs[a], 2) == K || throw(ArgumentError(
            "gram: Bs[$a] has $(size(Bs[a], 2)) (l,m) rows but weights has length $K"))
        size(Bs[a], 3) == Q || throw(ArgumentError(
            "gram: Bs[$a] has Q=$(size(Bs[a], 3)) but Bs[1] has Q=$Q"))
    end

    G = Array{Float64,3}(undef, n, n, Q)
    @inbounds for a in 1:n
        G[a, a, :] .= self_scatter(Bs[a], weights)
        for b in (a + 1):n
            s = cross_scatter(Bs[a], Bs[b], weights)
            G[a, b, :] .= s
            G[b, a, :] .= s
        end
    end
    return G
end

# ---------------------------------------------------------------------------
# CRYSOL's c₁: the excluded-volume correction factor
# ---------------------------------------------------------------------------

"""
CRYSOL's excluded-volume envelope G(q): the factor multiplying the ex
species when every dummy atom's radius is expanded from the structure's mean
`r_m` by the correction factor c₁.

    G(q) = c₁³ · exp(−q² (c₁² − 1) (4π/3)^(2/3) r_m² / 4π)

The approximation is exact for an atom of radius `r_m` and degrades with the
spread of radii about it. Absorbs systemic biases introduced by atomic radii table.

`c_1` == 1 returns exactly 1.0 at every q, i.e. the uncorrected model.

# Arguments
- `qvals::AbstractVector{<:Real}, length Q`: momentum transfer in Å⁻¹.
- `r_m::Real`: the structure's mean atomic radius in Å; > 0.
- `c_1::Real`: the excluded-volume correction factor (CRYSOL's `r₀/r_m`), dimensionless; > 0.

# Returns
- `Vector of length Q`, eltype promoted from the arguments.
"""
function excluded_volume_factor(qvals::AbstractVector{<:Real}, r_m::Real, c_1::Real)
    r_m > 0 || throw(DomainError(r_m, "excluded_volume_factor: r_m must be > 0"))
    c_1 > 0 || throw(DomainError(c_1, "excluded_volume_factor: c_1 must be > 0"))
    k = (c_1^2 - 1) * EV_EXP_COEFF * r_m^2
    return @. c_1^3 * exp(-(qvals^2) * k)
end

"""
The structure's mean atomic radius `r_m` in Å, which is the reference scale CRYSOL's
excluded-volume correction factor c₁ is measured against, and the point at which
[`excluded_volume_factor`](@ref)'s single-envelope approximation is exact.
Geometry only, so it caches alongside G.

CRYSOL defines `r_m` as the mean of each dummy atom's *own* equivalent-sphere
radius `r_gj` = cbrt(3 `V_j` / 4π) (Svergun, Barberato & Koch, 1995, text
following their eq. 13: `r_m` = N⁻¹ Σⱼ `r_gj`, `r_gj` read off their Table 1).
"""
function mean_atomic_radius(mol::Molecule)::Float64
    v = vols(mol)
    isempty(v) && throw(ArgumentError("mean_atomic_radius: molecule has no atoms"))
    return sum(cbrt(3.0 * vi / (4.0 * π)) for vi in v) / length(v)
end

"""
Species pairs (a, b), a ≤ b, in [`ForwardCache`](@ref)'s `Gc` column order, species numbered
as in the file header (1 vac, 2 ex, 3-5 shells): the 10 pairs of {1, 3, 4, 5} (the
envelope-free terms, "A"), then the 4 pairs (2, b), b ∈ {1, 3, 4, 5} ("B"), then (2, 2) ("C").
"""
const _GRAM_PAIRS = (
    (1, 1), (1, 3), (1, 4), (1, 5), (3, 3),
    (3, 4), (3, 5), (4, 4), (4, 5), (5, 5),
    (1, 2), (2, 3), (2, 4), (2, 5), (2, 2)
)

"""
Repack the five-species Gram matrix G, (5, 5, Q), into `Gc`, (Q, 15), contiguous in q, with
the columns in `_GRAM_PAIRS` order.

# Exceptions
- `ArgumentError`: G is not five-species.
"""
function _pack_gram(G::Array{Float64,3})::Matrix{Float64}
    (size(G, 1) == 5 && size(G, 2) == 5) ||
        throw(ArgumentError("_pack_gram: needs the five-species Gram matrix; got $(size(G, 1))×$(size(G, 2))"))
    Q = size(G, 3)
    Gc = Matrix{Float64}(undef, Q, length(_GRAM_PAIRS))
    @inbounds for (j, (a, b)) in enumerate(_GRAM_PAIRS)
        @simd for q in 1:Q
            Gc[q, j] = G[a, b, q]
        end
    end
    return Gc
end

"""
    ForwardCache

Static structure calculations, independent of fit parameters. Build one
per structure with [`forward_cache`](@ref); every likelihood evaluation
([`BAYSOL.Fitting.profiled_corrs`](@ref)) then works from G and `r_m` alone.

# Fields
- `G::Array{Float64,3}, (5, 5, Q)`: the species Gram matrix, from [`gram`](@ref).
- `Gc::Matrix{Float64}, (Q, 15)`: `G_ab(q)` for the pairs in `_GRAM_PAIRS`, repacked contiguous
    in q for the contrast contraction ([`intensity_terms`](@ref)).
- `qvals::Vector{Float64}, length Q`: the grid G was built on.
- `r_m::Float64`: mean atomic radius in Å.
- `form_factor_log::Vector{String}`: construction-time diagnostics from [`form_factor_table`](@ref BAYSOL.Scattering.form_factor_table).
- `n_atoms::Int`: number of atoms in the structure mol was built from
    (length(elms(mol))), e.g. for reporting alongside the fit.
- `lMax::Int`: the spherical-harmonic band limit G was built with.
"""
struct ForwardCache
    G::Array{Float64,3}
    Gc::Matrix{Float64}
    qvals::Vector{Float64}
    r_m::Float64
    form_factor_log::Vector{String}
    n_atoms::Int
    lMax::Int
end

"""
Static geometry-only and fit independent calculations: the five species'
multipoles ([`species_multipoles`](@ref)), reduced to the Gram matrix G(q), plus
`r_m`.

# Arguments
- `mol::Molecule`.
- `qvals::AbstractVector{<:Real}, length Q`: momentum transfer in Å⁻¹.
- `lMax::Integer`: spherical-harmonic band limit.
- `energy::Real`: photon energy in eV (for the vac anomalous form factors).

# Keywords
-   `chunk::Unsigned = B_LM_CHUNK`: `compute_B_lm` batch size (results invariant).
-   `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
    `n_target = SHELL_N_TARGET`: hydration-shell geometry, forwarded to hydration.
-   `shell::Union{Nothing,Tuple} = nothing`: a precomputed `SASA.sasa` result, see [`hydration`](@ref).
-   `stage_log::Union{Nothing,StageLog} = nothing`: if given, the vacuum,
    excluded-volume, hydration and Gram + `r_m` stages are recorded in it
    (depth 2, group `:static`).

The vacuum term's `form_factor_table` build diagnostics are always collected.
"""
forward_cache(
    mol::Molecule,
    qvals::AbstractVector{<:Real},
    lMax::Integer,
    energy::Real;
    chunk::Unsigned                      = B_LM_CHUNK,
    thickness::Real                      = SHELL_THICKNESS,
    probe::Real                          = PROBE_RADIUS,
    n_target::Union{Nothing,Integer}     = SHELL_N_TARGET,
    shell::Union{Nothing,Tuple}          = nothing,
    stage_log::Union{Nothing,StageLog}   = nothing,
)::ForwardCache = begin
    form_factor_log = String[]
    mp = species_multipoles(
        mol, qvals, lMax, energy;
        chunk = chunk,
        thickness = thickness, probe = probe, n_target = n_target, shell = shell,
        form_factor_log = form_factor_log, stage_log = stage_log,
    )
    G, r_m = timed!(stage_log, :static, 2, "Gram + r_m") do
        gram(collect(mp), partial_wave_weights(lMax)), mean_atomic_radius(mol)
    end
    ForwardCache(G, _pack_gram(G), collect(Float64, qvals), r_m, form_factor_log, length(elms(mol)), lMax)
end

"""
A, B, C of the model intensity at fit parameters (ρₑ, δρ), as a function of the
excluded-volume envelope g(q; c₁) ([`excluded_volume_factor`](@ref)) on species 2:

    I(q; c₁) = v(q)ᵀ G(q) v(q) = A(q) + g·B(q) + g²·C(q)

with contrast vector v = (1, −ρₑ·g, dro₁, dro₂, dro₃), `dro_k` = `DRO_UNIT`·`δρ_k`, and

    A = Σ_{a,b ∈ S} v_a v_b G_ab,   B = −2ρₑ Σ_{b ∈ S} v_b G_2b,   C = ρₑ² G_22,   S = {1, 3, 4, 5}.

c₁ enters only through g, so A, B, C depend on (ρₑ, δρ) and the structure alone: build them once
per parameter point, then evaluate any c₁ cheaply ([`model_intensity`](@ref)). Two products
against the repacked `fw.Gc` (BLAS for Float64; Julia's generic product when ρₑ/δρ carry
ForwardDiff dual numbers).

# Arguments
- `fw::ForwardCache`: the structure's geometry-only cache.
- `ρ::Real`: the buffer's bulk electron density ρₑ, e·Å⁻³.
- `δρ::NTuple{3,<:Real}`: dimensionless (convex, concave, cavity) shell contrasts.

# Returns
- `(A, B, C)`, three length-Q vectors with the eltype of ρₑ/δρ.
"""
function intensity_terms(fw::ForwardCache, ρ::Real, δρ::NTuple{3,<:Real})
    T  = promote_type(typeof(ρ), eltype(δρ), Float64)
    v1 = one(T)
    v3 = T(DRO_UNIT * δρ[1])
    v4 = T(DRO_UNIT * δρ[2])
    v5 = T(DRO_UNIT * δρ[3])
    kA = T[
            v1^2,
            2v1 * v3,
            2v1 * v4,
            2v1 * v5,
            v3^2,
            2v3 * v4,
            2v3 * v5,
            v4^2,
            2v4 * v5,
            v5^2
        ]
    kB = T[
            -2ρ * v1,
            -2ρ * v3,
            -2ρ * v4,
            -2ρ * v5
        ]
    Gc = fw.Gc
    Q  = size(Gc, 1)
    A = Vector{T}(undef, Q); B = Vector{T}(undef, Q)
    mul!(A, view(Gc, :, 1:10), kA)
    mul!(B, view(Gc, :, 11:14), kB)
    ρ2 = T(ρ)^2
    C = Vector{T}(undef, Q)
    @inbounds @fastmath @simd for q in 1:Q
        C[q] = ρ2 * Gc[q, 15]
    end
    return A, B, C
end

"""
The model intensity A + g·(B + g·C) at the envelope `g` (from [`excluded_volume_factor`](@ref)),
for A, B, C from [`intensity_terms`](@ref); scale 1, no background.

# Returns
- `Vector of length Q`, eltype promoted from the arguments.
"""
function model_intensity(A::AbstractVector, B::AbstractVector, C::AbstractVector, g::AbstractVector)
    ŷ = similar(A, promote_type(eltype(A), eltype(B), eltype(C), eltype(g)))
    @inbounds @fastmath @simd for i in eachindex(ŷ)
        ŷ[i] = A[i] + g[i] * (B[i] + g[i] * C[i])
    end
    return ŷ
end

"""
Fraction of the hydration-shell volume carried by cavity beads, read off the Gram matrix
at the lowest q (where `S_kk` → (Σ bead volumes)², so √`S_kk` is the species' total volume).
0 when the structure has no cavity beads.
"""
function cavity_shell_fraction(fw::ForwardCache)::Float64
    v = [sqrt(max(fw.G[k, k, 1], 0.0)) for k in 3:5]
    tot = sum(v)
    return tot > 0 ? v[3] / tot : 0.0
end
