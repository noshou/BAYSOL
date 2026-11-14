# SPDX-License-Identifier: LGPL-3.0-or-later

# Folds the per-species multipoles B_lm (from speciesMultipoles) into the
# species Gram matrix G(q), and bundles G with what the fit needs to evaluate
# the excluded-volume correction c₁ (ForwardCache). The orientationally-averaged
# intensity itself, I(q) = v(q)ᵀ G(q) v(q), is contracted downstream in
# BAYSOL.Inference.ProfiledCorrs.
#
# SPECIES ORDERING:
#
#     1  vac         real atoms in vacuo
#     2  ex          excluded-volume dummies      (enters A_total with -dns)
#     3  sh_convex   hydration shell, convex beads   (enters with +dro_1)
#     4  sh_concave  hydration shell, concave beads  (enters with +dro_2)
#     5  sh_cavity   hydration shell, cavity beads   (enters with +dro_3)

using ..MolecularStructure: Molecule, elms, vols
using ..Runtime: StageLog, timed!

"""
Species Gram matrix G of shape (n, n, Q) for the n multipole arrays in
Bs (each (C, K, Q) as returned by [`computeBLm`](@ref); channel counts
C may differ between species).

G[a, b, :] is the paired partial-wave sum

    S_ab(q) = 4π Σ_c Σ_lm w_lm Re(B_a[c,lm](q) * conj(B_b[c,lm](q)))

i.e. [`crossScatter`](@ref) off the diagonal and [`selfScatter`](@ref) on it
(`S_aa` = `S_ab`|_{b=a} identically, since |z|² = Re(z * conj z)). Every
G[:, :, k] is real, symmetric and positive semidefinite.

# Arguments
    - `Bs`: an AbstractVector of n ≥ 1 arrays
    <:AbstractArray{<:Complex,3}, each (C, K, Q) sharing a common K and Q.
    Order is (vac, ex, shells…); see the file header.
    - `weights::AbstractVector{<:Real}`, length K:
    [`partialWaveWeights`](@ref)(lMax).

# Returns
- `Array{Float64,3} of size (n, n, Q)`, symmetric in its first two axes.
"""
function gram(
    bs::AbstractVector{<:AbstractArray{<:Complex,3}}, weights::AbstractVector{<:Real},
)::Array{Float64,3}
    n = length(bs)
    n ≥ 1 || throw(ArgumentError("gram: need at least one species"))
    K = length(weights)
    Q = size(bs[1], 3)
    for a in 1:n
        size(bs[a], 2) == K || throw(
            ArgumentError(
                "gram: Bs[$a] has $(size(bs[a], 2)) (l,m) rows but weights has length $K",
            ),
        )
        size(bs[a], 3) == Q || throw(ArgumentError(
            "gram: Bs[$a] has Q=$(size(bs[a], 3)) but Bs[1] has Q=$Q"))
    end

    G = Array{Float64,3}(undef, n, n, Q)
    @inbounds for a in 1:n
        G[a, a, :] .= selfScatter(bs[a], weights)
        for b in (a+1):n
            s = crossScatter(bs[a], bs[b], weights)
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
`rM` by the correction factor c₁.

    G(q) = c₁³ · exp(−q² (c₁² − 1) (4π/3)^(2/3) r_m² / 4π)

The approximation is exact for an atom of radius `rM` and degrades with the
spread of radii about it. Absorbs systemic biases introduced by atomic radii table.

`c1Factor` == 1 returns exactly 1.0 at every q, i.e. the uncorrected model.

# Arguments
-   `qvals::AbstractVector{<:Real}, length Q`: momentum transfer in Å⁻¹.
-   `rM::Real`: the structure's mean atomic radius in Å; > 0.
-   `c1Factor::Real`: the excluded-volume correction factor (CRYSOL's `r₀/rM`),
    dimensionless; > 0.

# Returns
- `Vector of length Q`, eltype promoted from the arguments.
"""
function excludedVolumeFactor(qvals::AbstractVector{<:Real}, rM::Real, c1Factor::Real)
    rM > 0 || throw(DomainError(rM, "excludedVolumeFactor: rM must be > 0"))
    c1Factor > 0 ||
        throw(DomainError(c1Factor, "excludedVolumeFactor: c1Factor must be > 0"))
    k = (c1Factor^2 - 1) * EV_EXP_COEFF * rM^2
    return @. c1Factor^3 * exp(-(qvals^2) * k)
end

"""
The structure's mean atomic radius `rM` in Å, which is the reference scale CRYSOL's
excluded-volume correction factor c₁ is measured against, and the point at which
[`excludedVolumeFactor`](@ref)'s single-envelope approximation is exact.
Geometry only, so it caches alongside G.

CRYSOL defines `rM` as the mean of each dummy atom's *own* equivalent-sphere
radius `r_gj` = cbrt(3 `V_j` / 4π) (Svergun, Barberato & Koch, 1995, text
following their eq. 13: `rM` = N⁻¹ Σⱼ `r_gj`, `r_gj` read off their Table 1).
"""
function meanAtomicRadius(mol::Molecule)::Float64
    v = vols(mol)
    isempty(v) && throw(ArgumentError("meanAtomicRadius: molecule has no atoms"))
    return sum(cbrt(3.0 * vi / (4.0 * π)) for vi in v) / length(v)
end


"""
Repack the five-species Gram matrix G, (5, 5, Q),
into `Gc`, (Q, 15), contiguous in q, with the
columns in `_GRAM_PAIRS` order.

# Exceptions
- `ArgumentError`: G is not five-species.
"""
function _packGram(G::Array{Float64,3})::Matrix{Float64}
    (size(G, 1) == 5 && size(G, 2) == 5) || throw(
        ArgumentError(
            "_packGram: needs the five-species Gram matrix; " *
            "got $(size(G, 1))×$(size(G, 2))",
        ),
    )
    Q = size(G, 3)
    gc = Matrix{Float64}(undef, Q, length(_GRAM_PAIRS))
    @inbounds for (j, (a, b)) in enumerate(_GRAM_PAIRS)
        @fastmath @simd for q in 1:Q
            gc[q, j] = G[a, b, q]
        end
    end
    return gc
end

"""
    ForwardCache

Static structure calculations, independent of fit parameters. Build one
per structure with [`forwardCache`](@ref); every likelihood evaluation
([`BAYSOL.Inference.profiledCorrs`](@ref)) then works from G and `rM` alone.

# Fields
-   `G::Array{Float64,3}, (5, 5, Q)`: the species Gram matrix, from [`gram`](@ref).
-   `Gc::Matrix{Float64}, (Q, 15)`: `G_ab(q)` for the pairs in `_GRAM_PAIRS`,
    repacked contiguous in q for the contrast contraction ([`intensityTerms`](@ref)).
-   `qvals::Vector{Float64}, length Q`: the grid G was built on.
-   `rM::Float64`: mean atomic radius in Å.
-   `formFactorLog::Vector{String}`: construction-time diagnostics from
    [`formFactorTable`](@ref BAYSOL.Scattering.formFactorTable).
-   `nAtoms::Int`: number of atoms in the structure mol was built from
    (length(elms(mol))), e.g. for reporting alongside the fit.
-   `lMax::Int`: the spherical-harmonic band limit G was built with.
"""
struct ForwardCache
    G::Array{Float64,3}
    gc::Matrix{Float64}
    qvals::Vector{Float64}
    rM::Float64
    formFactorLog::Vector{String}
    nAtoms::Int
    lMax::Int
end

"""
Static geometry-only and fit independent calculations: the five species'
multipoles ([`speciesMultipoles`](@ref)), reduced to the Gram matrix G(q), plus
`rM`.

# Arguments
- `mol::Molecule`.
- `qvals::AbstractVector{<:Real}, length Q`: momentum transfer in Å⁻¹.
- `lMax::Integer`: spherical-harmonic band limit.
- `energy::Real`: photon energy in eV (for the vac anomalous form factors).

# Keywords
-   `chunk::Unsigned = B_LM_CHUNK`: `computeBLm` batch size (results invariant).
-   `thickness::Real = SHELL_THICKNESS`, `probe::Real = PROBE_RADIUS`,
    `nTarget = nothing`: hydration-shell geometry, forwarded to hydration.
-   `shell::Union{Nothing,Tuple} = nothing`: a precomputed `sasa`
    result, see [`hydration`](@ref).
-   `stageLog::Union{Nothing,StageLog} = nothing`: if given, the vacuum,
    excluded-volume, hydration and Gram + `rM` stages are recorded in it
    (depth 2, group `:static`).

The vacuum term's `formFactorTable` build diagnostics are always collected.
"""
forwardCache(
    mol::Molecule,
    qvals::AbstractVector{<:Real},
    lMax::Integer,
    energy::Real;
    chunk::Unsigned                   = B_LM_CHUNK,
    thickness::Real                   = SHELL_THICKNESS,
    probe::Real                       = PROBE_RADIUS,
    nTarget::Union{Nothing,Integer}   = nothing,
    shell::Union{Nothing,Tuple}       = nothing,
    stageLog::Union{Nothing,StageLog} = nothing,
)::ForwardCache = begin
    formFactorLog = String[]
    mp = speciesMultipoles(
        mol, qvals, lMax, energy;
        chunk = chunk,
        thickness = thickness, probe = probe, nTarget = nTarget, shell = shell,
        formFactorLog = formFactorLog, stageLog = stageLog,
    )
    G, rM = timed!(stageLog, :static, 2, "Gram + rM") do
        gram(collect(mp), partialWaveWeights(lMax)), meanAtomicRadius(mol)
    end
    ForwardCache(
        G,
        _packGram(G),
        collect(Float64, qvals),
        rM,
        formFactorLog,
        length(elms(mol)),
        lMax,
    )
end

"""
A, B, C of the model intensity at fit parameters (ρₑ, δρ), as a function of the
excluded-volume envelope g(q; c₁) ([`excludedVolumeFactor`](@ref)) on species 2:

    I(q; c₁) = v(q)ᵀ G(q) v(q) = A(q) + g·B(q) + g²·C(q)

with contrast vector

    v = (1, −ρₑ·g, dro₁, dro₂, dro₃)
    `dro_k` = `UNIT_OF_δρ`·`δρ_k`

and

    A = Σ_{a,b ∈ S} v_a v_b G_ab
    B = −2ρₑ Σ_{b ∈ S} v_b G_2b
    C = ρₑ² G_22,   S = {1, 3, 4, 5}.

c₁ enters only through g, so A, B, C depend on (ρₑ, δρ) and the
structure alone: build them once per parameter point, then evaluate
any c₁ cheaply ([`modelIntensity`](@ref)). Two products against the
repacked `fw.gc` (BLAS for Float64; Julia's generic product when ρₑ/δρ
carry ForwardDiff dual numbers).

# Arguments
- `fw::ForwardCache`: the structure's geometry-only cache.
- `ρ::Real`: the buffer's bulk electron density ρₑ, e·Å⁻³.
- `δρ::NTuple{S,<:Real}`: dimensionless shell contrasts, (convex, concave,
    cavity) for the five-species model (`S = 3`); the packed Gram matrix
    must have the `(S+1)(S+2)/2 + S + 2` columns of that many species.

# Returns
- `(A, B, C)`, three length-Q vectors with the eltype of ρₑ/δρ.
"""
function intensityTerms(fw::ForwardCache, ρ::Real, δρ::NTuple{S,<:Real}) where {S}
    T  = promote_type(typeof(ρ), eltype(δρ), Float64)
    M  = S + 1              # species that carry a contrast: vac (weight 1) and the S shells
    nA = M * (M + 1) ÷ 2    # envelope-free pairs, row-major upper triangle
    gc = fw.gc
    size(gc, 2) == nA + M + 1 || throw(
        ArgumentError(
            "intensityTerms: $S contrasts need $(nA + M + 1) Gram columns, " *
            "got $(size(gc, 2))",
        ),
    )
    v  = (one(T), ntuple(k -> T(UNIT_OF_δρ * δρ[k]), Val(S))...)
    kA = T[(i == j ? v[i] * v[j] : 2v[i] * v[j]) for i in 1:M for j in i:M]
    kB = T[-2ρ * v[i] for i in 1:M]
    Q  = size(gc, 1)
    A  = Vector{T}(undef, Q)
    B  = Vector{T}(undef, Q)
    mul!(A, view(gc, :, 1:nA), kA)
    mul!(B, view(gc, :, (nA+1):(nA+M)), kB)
    ρ2 = T(ρ)^2
    C = Vector{T}(undef, Q)
    @inbounds @fastmath @simd for q in 1:Q
        C[q] = ρ2 * gc[q, nA+M+1]
    end
    return A, B, C
end

"""
The model intensity A + g·(B + g·C) at the envelope `g`
(from [`excludedVolumeFactor`](@ref)), for A, B, C from
[`intensityTerms`](@ref); scale 1, no background.

# Returns
- `Vector of length Q`, eltype promoted from the arguments.
"""
function modelIntensity(
    A::AbstractVector,
    B::AbstractVector,
    C::AbstractVector,
    g::AbstractVector,
)
    ŷ = similar(A, promote_type(eltype(A), eltype(B), eltype(C), eltype(g)))
    @inbounds @fastmath @simd for i in eachindex(ŷ)
        ŷ[i] = A[i] + g[i] * (B[i] + g[i] * C[i])
    end
    return ŷ
end

"""
Fraction of the hydration-shell volume carried by cavity beads,
read off the Gram matrix at the lowest q (where `S_kk` →
(Σ bead volumes)², so √`S_kk` is the species' total volume).
0 when the structure has no cavity beads.
"""
function cavityShellFraction(fw::ForwardCache)::Float64
    v = [sqrt(max(fw.G[k, k, 1], 0.0)) for k in 3:5]
    tot = sum(v)
    return tot > 0 ? v[3] / tot : 0.0
end
