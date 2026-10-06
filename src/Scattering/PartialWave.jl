# SPDX-License-Identifier: LGPL-2.1-or-later

using .SphFuncs: sphHarm, sphBess, sphBessRatios!, sphBessStep
using FastClosures: @closure
using LinearAlgebra: mul!

"""
±m symmetry weights: m = 0 -> 1, m > 0 -> 2.

# Arguments
- `lMax::Integer`: maximum spherical harmonic degree. Must be non-negative.

# Returns
    - `Vector{Float64} of length (lMax+1)(lMax+2)/2`, one weight per stored
        (l, m) pair with m = 0, …, l, flattened in the same
        (0,0), (1,0), (1,1), (2,0), (2,1), (2,2), … degree-major order used to
        index `B_lm` elsewhere (i.e. k0 = l*(l+1)/2 gives the offset of degree l's block).

# Mathematical derivation

We want:
    
    S(q) = 4π * Σ_l Σ_{m=-l}^{l} |B_lm(q)|²


with

    B_lm(q) = Σ_i f_i(q) * j_l(q r_i) * conj(Y_lm(θ_i, φ_i))

Spherical harmonics satisfy `Y_{l,-m}` = (-1)^m * conj(`Y_lm`). Plugging into `B_{l,-m}`:

    B_{l,-m} = Σ_i f_i * j_l * conj(Y_{l,-m})
         = Σ_i f_i * j_l * conj[(-1)^m * conj(Y_lm)]
         = (-1)^m * Σ_i f_i * j_l * Y_lm


If `f_i` is real, that last sum is just conj(`B_lm`), since conjugating a
real-coefficient sum of `Y_lm`'s conjugates flips it back to `Y_lm`:

    B_{l,-m} = (-1)^m * conj(B_lm)   =>   |B_{l,-m}|² = |B_lm|²

Every negative-m term is a free duplicate of its positive-m partner, so:

    Σ_{m=-l}^{l} |B_lm|²    = |B_l0|² + Σ_{m=1}^{l} (|B_lm|² + |B_{l,-m}|²)
                            = 1·|B_l0|² + Σ_{m=1}^{l} 2·|B_lm|²

which is the 1-for-m=0, 2-for-m>0 weighting returned here.
"""
function partial_wave_weights(lMax::Integer)::Vector{Float64}
    lMax < 0 && throw(ArgumentError("partial_wave_weights: lMax must be non-negative"))
    return [2.0 - (m == 0) for deg in 0:lMax for m in 0:deg]
end

"""
Compute `B_lm(q) = Σ_i f_atoms[i](q) * j_l(q*r_i) * conj(Y_lm(θ_i, φ_i))`.

`f_atoms` carries whatever per-atom complex scattering amplitude the
caller wants (element form factors for the vacuum term, dummy-atom
excluded-volume/shell amplitudes for the other terms). The work is done by
[`_compute_B_lm`](@ref), which this calls with a single amplitude set.

# Arguments
    - `coords_sph::AbstractMatrix{<:Real}, size (3, N)`: per-atom spherical
        coordinates in the column-per-atom layout `MolecularStructure.coords_spherical`
        returns — row 1 is r, row 2 is θ, row 3 is φ.
    - `qvals::AbstractVector{<:Real}, length Q`: momentum transfer grid, all ≥ 0.
    - `f_atoms::AbstractMatrix{<:Number}, size (N, Q)`: per-atom scattering
        amplitude, already evaluated on qvals. Real or complex.
    - `lMax::Integer`: maximum spherical harmonic degree. Must be non-negative.
    - `_CHUNK::UInt64`: number of atoms to process in one pass (results invariant
        up to rounding).

# Returns
    - `Array{ComplexF64,3}` of size (C, (lMax+1)(lMax+2)÷2, Q). C = 1 when
        `f_atoms` is real, C = 2 when it has a nonzero imaginary part (anomalous
        f''): channel 1 from Re(`f_atoms`), channel 2 from Im(`f_atoms`). The two
        channels add incoherently in the m-summed invariant (see
        [`self_scatter`](@ref)/[`cross_scatter`](@ref)) — they must not be
        recombined into one complex `B_lm`.

# Exceptions
    - `DomainError`: `_CHUNK` == 0.
    - `ArgumentError`: lMax < 0, `coords_sph` not (3, N), `f_atoms` not (N, Q), or a
        negative q.
"""
compute_B_lm(
    coords_sph::AbstractMatrix{<:Real},
    qvals::AbstractVector{<:Real},
    f_atoms::AbstractMatrix{<:Number},
    lMax::Integer,
    _CHUNK::UInt64,
)::Array{ComplexF64,3} = only(_compute_B_lm(coords_sph, qvals, (f_atoms,), lMax, _CHUNK))

"""
[`compute_B_lm`](@ref) for several amplitude sets on the same points (e.g. the
vacuum form factors and the excluded-volume dummies of one molecule), sharing one
spherical-harmonic evaluation and one spherical Bessel sweep per atom.

Real arithmetic throughout. Write `Ȳ_lm` = Re `Y_lm` − i·Im `Y_lm` (the conjugate). Every
amplitude column c (one per set and channel: Re f, and Im f when f is anomalous)
is real, so per degree l

    [Re B_l; Im B_l] (2(l+1) × Q) = [Re Y_l; −Im Y_l] (2(l+1) × atoms) · W_l (atoms × Q),
    W_l[i, q] = f_c(i, q)·j_l(q·r_i),

one real matrix product per degree and column, done by OpenBLAS (`mul!`, 5-arg,
accumulating in place).

W is never stored as a full j array. For each atom the Gautschi sweep runs over a
q-tile: [`SphFuncs.sphBessRatios!`](@ref) (pass 1), then upward with
[`SphFuncs.sphBessStep`](@ref) (pass 2); each jₗ comes out normalized and is
multiplied straight into `W_l` for every column. W covers one tile of atoms
([`B_LM_TILE`](@ref)) and one q-tile, sized so that every degree fits in
[`B_LM_W_BYTES`](@ref); all buffers are allocated once per call.

# Arguments
    - `coords_sph`, `qvals`, `lMax`, `_CHUNK`: as [`compute_B_lm`](@ref).
    - `f_sets`: tuple of amplitude matrices, each (N, Q), real or complex.

# Returns
    - `Tuple` of `Array{ComplexF64,3}`, one per set, each as [`compute_B_lm`](@ref)'s.
"""
function _compute_B_lm(
    coords_sph::AbstractMatrix{<:Real},
    qvals::AbstractVector{<:Real},
    f_sets::Tuple{Vararg{AbstractMatrix{<:Number}}},
    lMax::Integer,
    _CHUNK::UInt64,
)
    # _CHUNK == 0 would make the 1:_CHUNK:N range below step by zero,
    # looping forever instead of raising.
    _CHUNK == 0 && throw(DomainError(_CHUNK, "_CHUNK must be > 0"))
    lMax < 0 && throw(ArgumentError("compute_B_lm: lMax must be non-negative"))

    # coords_sph is the column-per-atom spherical form straight from
    # MolecularStructure.coords_spherical: 3 rows, (r, θ, φ) in that order.
    size(coords_sph, 1) == 3 || throw(ArgumentError(
        "compute_B_lm: coords_sph must be a (3, N) matrix with rows (r, θ, φ), " *
        "as returned by MolecularStructure.coords_spherical; got $(size(coords_sph, 1)) rows"))
    N = size(coords_sph, 2)
    Q = length(qvals)
    # validated once here: the per-radius Bessel sweep below does not re-check q
    any(<(0), qvals) && throw(ArgumentError("compute_B_lm: qvals must all be ≥ 0"))
    for f in f_sets
        size(f, 1) == N ||
            throw(ArgumentError("compute_B_lm: f_atoms must have N rows matching coords_sph's columns"))
        size(f, 2) == Q ||
            throw(ArgumentError("compute_B_lm: f_atoms must have Q columns matching qvals"))
    end

    L = Int(lMax)
    # Packed (l,m) row count for m = 0..l only; see partial_wave_weights for
    # why the m < 0 half never needs to be stored.
    K = (L + 1) * (L + 2) ÷ 2

    # A purely real set needs only the Re(f) channel; an imaginary part
    # (anomalous f'') needs a second channel for the ±m symmetry.
    nchan = map(f -> (eltype(f) <: Real || !any(@closure(x -> imag(x) != 0), f)) ? 1 : 2, f_sets)
    ncol = sum(nchan)

    # Acc[2k0 + 1 : 2k0 + l + 1, (c-1)Q + q] = Re B_lm, the next l + 1 rows Im B_lm,
    # for degree l (k0 = l(l+1)/2) and amplitude column c
    Acc = zeros(Float64, 2K, ncol * Q)

    if N > 0
        nchunk = min(Int(_CHUNK), N)
        T = min(B_LM_TILE, nchunk)
        # q-tile length so that W (every column, every degree, T atoms) fits the budget
        Qt = clamp(B_LM_W_BYTES ÷ (sizeof(Float64) * ncol * T * (L + 1)), 1, Q)
        qv = Vector{Float64}(qvals)
        qtiles = [qv[q0:min(q0 + Qt - 1, Q)] for q0 in 1:Qt:Q]

        A  = Matrix{Float64}(undef, 2K, nchunk)       # [Re Y_l; −Im Y_l] stacked per degree
        Ft = Array{Float64,3}(undef, Q, ncol, nchunk)  # Ft[q, c, i]: amplitude column c of atom i
        W  = Array{Float64,3}(undef, ncol * Qt, T, L + 1)   # W[(c-1)Qt + k, t, l+1]
        sb = sphBess(Qt, L)

        # Negligible-Bessel cut: |jₗ(x)| ≤ xˡ/(2l+1)!! for all x ≥ 0 (from
        # |J_ν(x)| ≤ (x/2)^ν/Γ(ν+1), ν ≥ −1/2), so jₗ(x) ≤ BESSEL_CUTOFF whenever
        # x < x_cut(l) = (BESSEL_CUTOFF·(2l+1)!!)^(1/l). For a tile with largest radius
        # r_max, degree l contributes nothing at q < x_cut(l)/r_max; with q ascending
        # those columns are a prefix, skipped below in the W writes and the product.
        # Unsorted q: no cut.
        qsorted = issorted(qv)
        xcut = zeros(L + 1)
        lndf = 0.0                      # ln((2l+1)!!)
        for l in 1:L
            lndf += log(2l + 1.0)
            xcut[l + 1] = exp((log(BESSEL_CUTOFF) + lndf) / l)
        end
        ks = ones(Int, L + 1)           # first q column (within the q-tile) kept for degree l

        for start in 1:Int(_CHUNK):N
            # _CHUNK is a UInt64; keep the index Int (a UInt64 range underflows
            # when reindexed by a nested view)
            idx = start:min(start + Int(_CHUNK) - 1, N)
            nc = length(idx)

            # rows 2:3 of coords_sph are (θ, φ): handed to sphHarm as a (2, chunk) block
            Y = sphHarm(L, view(coords_sph, 2:3, idx))   # (K, nc), complex
            @inbounds for i in 1:nc, l in 0:L
                k0 = l * (l + 1) ÷ 2
                @simd for m in 0:l
                    y = Y[k0 + m + 1, i]
                    A[2k0 + m + 1, i] = real(y)
                    A[2k0 + l + 1 + m + 1, i] = -imag(y)
                end
            end

            # amplitudes, q-contiguous per atom and column
            c = 0
            for (s, f) in enumerate(f_sets), ch in 1:nchan[s]
                c += 1
                # real part for channel 1, imaginary for channel 2 (branch outside the copy)
                if ch == 1
                    @inbounds for i in 1:nc
                        @simd for q in 1:Q
                            Ft[q, c, i] = real(f[idx[i], q])
                        end
                    end
                else
                    @inbounds for i in 1:nc
                        @simd for q in 1:Q
                            Ft[q, c, i] = imag(f[idx[i], q])
                        end
                    end
                end
            end

            for t0 in 1:T:nc
                ts = t0:min(t0 + T - 1, nc)
                for (ti, qt) in enumerate(qtiles)
                    q0 = (ti - 1) * Qt + 1
                    nq = length(qt)
                    if qsorted
                        rmax = maximum(i -> Float64(coords_sph[1, idx[i]]), ts)
                        for l in 1:L
                            ks[l + 1] = searchsortedfirst(qt, xcut[l + 1] / rmax)
                        end
                    end

                    # W for every atom of the tile, every degree, every column
                    for (tt, i) in enumerate(ts)
                        sphBessRatios!(sb, Float64(coords_sph[1, idx[i]]), qt, L)
                        jm1, jm2 = sb.jm1, sb.jm2      # j₁, j₀ after pass 1
                        _write_W!(W, Ft, jm2, ncol, q0, ks[1], nq, Qt, tt, i, 0)
                        L ≥ 1 && _write_W!(W, Ft, jm1, ncol, q0, ks[2], nq, Qt, tt, i, 1)
                        for l in 2:L
                            lup, invx, R = sb.lup, sb.invx, sb.R
                            @inbounds @fastmath @simd for k in 1:nq
                                v = sphBessStep(jm1[k], jm2[k], l, lup[k], invx[k], R[k, l])
                                jm2[k] = jm1[k]
                                jm1[k] = v
                            end
                            _write_W!(W, Ft, jm1, ncol, q0, ks[l + 1], nq, Qt, tt, i, l)
                        end
                    end

                    # one real product per degree and column, accumulated in place (BLAS)
                    nt = length(ts)
                    for l in 0:L
                        kk = ks[l + 1]
                        kk > nq && continue     # the whole q-tile is below the cut
                        k0 = l * (l + 1) ÷ 2
                        rows = (2k0 + 1):(2k0 + 2(l + 1))
                        Al = view(A, rows, ts)
                        for c in 1:ncol
                            mul!(view(Acc, rows, (c - 1) * Q .+ ((q0 + kk - 1):(q0 + nq - 1))), Al,
                                 transpose(view(W, (c - 1) * Qt .+ (kk:nq), 1:nt, l + 1)), 1.0, 1.0)
                        end
                    end
                end
            end
        end
    end

    # unpack into the public (C, K, Q) complex layout, one array per set;
    # set s owns amplitude columns c0[s] + 1 .. c0[s] + nchan[s]
    c0 = cumsum((0, Base.front(nchan)...))
    return map(Tuple(1:length(f_sets))) do s
        B = Array{ComplexF64,3}(undef, nchan[s], K, Q)
        for ch in 1:nchan[s]
            c = c0[s] + ch
            @inbounds for q in 1:Q, l in 0:L
                k0 = l * (l + 1) ÷ 2
                col = (c - 1) * Q + q
                @simd for m in 0:l
                    B[ch, k0 + m + 1, q] = complex(Acc[2k0 + m + 1, col], Acc[2k0 + l + 1 + m + 1, col])
                end
            end
        end
        B
    end
end


"""
W[(c−1)Qt + k, tt, l+1] = Ft[q0+k−1, c, i]·j[k] for every amplitude column c and
k = kstart..nq: degree l's slice of W for one atom, from its normalized jₗ over the
q-tile (columns below kstart are under the negligible-Bessel cut and not used).

# Returns
- `nothing`.
"""
@inline function _write_W!(
    W::Array{Float64,3}, 
    Ft::Array{Float64,3}, 
    j::Vector{Float64},
    ncol::Int, 
    q0::Int, 
    kstart::Int, 
    nq::Int, 
    Qt::Int, 
    tt::Int, 
    i::Int, 
    l::Int
)::Nothing
    @inbounds for c in 1:ncol
        off = (c - 1) * Qt
        @fastmath @simd for k in kstart:nq
            W[off + k, tt, l + 1] = Ft[q0 + k - 1, c, i] * j[k]
        end
    end
    return nothing
end

"""
S(q) = 4π * `Σ_c` `Σ_lm` `w_lm` * |`B_lm(q)`|².

Channels (real/imaginary amplitude) add incoherently: the cross terms
between them cancel identically once summed over the full -l..l range ofm.

# Arguments
- `B_lm::AbstractArray{<:Complex,3}, size (C, K, Q)`: as returned by [`compute_B_lm`](@ref).
- `weights::AbstractVector{<:Real}, length K`: as returned by [`partial_wave_weights`](@ref).

# Returns
- `AbstractVector{<:Real} of length Q`."""
function self_scatter(
    B_lm::AbstractArray{<:Complex,3}, weights::AbstractVector{<:Real}
)::AbstractVector{<:Real}
    
    C, K, Q = size(B_lm)
    length(weights) == K || throw(DimensionMismatch("self_scatter: weights has length $(length(weights)), B_lm has K = $K"))
    T = promote_type(real(eltype(B_lm)), eltype(weights))
    # Σ_c Σ_lm w_lm·|B_lm|² per q. Each q's (C, K) block is one contiguous run, so it
    # is summed as a single vector with the weights repeated per channel.
    Bq = reshape(B_lm, C * K, Q)
    wc = repeat(weights, inner = C)
    S = Vector{T}(undef, Q)
    @inbounds for q in 1:Q
        acc = zero(T)
        @fastmath @simd for j in 1:(C * K)
            acc += wc[j] * abs2(Bq[j, q])
        end
        S[q] = 4π * acc
    end
    return S
end

"""
S(q) = 4π * `Σ_c` `Σ_lm` `w_lm` * Re(`B_a(q)` * conj(`B_b(q)`)).

# Arguments
- `B_lm_a::AbstractArray{<:Complex,3}, size (C_a, K, Q)`
- `B_lm_b::AbstractArray{<:Complex,3}, size (C_b, K, Q)`
- `weights::AbstractVector{<:Real}, length K`: as returned by [`partial_wave_weights`](@ref).

# Returns
- `AbstractVector{<:Real} of length Q`
"""
function cross_scatter(
    B_lm_a::AbstractArray{<:Complex,3},
    B_lm_b::AbstractArray{<:Complex,3},
    weights::AbstractVector{<:Real},
)::AbstractVector{<:Real}
    
    # Only the channels both operands actually have can be paired up; a real
    # amplitude's missing second channel would otherwise have nothing to mul against.
    n_chan = min(size(B_lm_a, 1), size(B_lm_b, 1))
    
    # Re(B_a * conj(B_b)) per (channel, l/m, q) entry, matching self_scatter
    # with |B_lm|^2 (= Re(B_lm * conj(B_lm))) generalised to two operands.
    K, Q = size(B_lm_a, 2), size(B_lm_a, 3)
    (size(B_lm_b, 2) == K && size(B_lm_b, 3) == Q && length(weights) == K) || throw(DimensionMismatch(
        "cross_scatter: B_lm_a is (_, $K, $Q), B_lm_b is $(size(B_lm_b)), weights has length $(length(weights))"))
    T = promote_type(real(eltype(B_lm_a)), real(eltype(B_lm_b)), eltype(weights))
    S = zeros(T, Q)
    if size(B_lm_a, 1) == size(B_lm_b, 1) == n_chan
        # same channel count: each q's (C, K) block is one contiguous run in both,
        # summed as a single vector (as self_scatter)
        Aq = reshape(B_lm_a, n_chan * K, Q)
        Bq = reshape(B_lm_b, n_chan * K, Q)
        wc = repeat(weights, inner = n_chan)
        @inbounds for q in 1:Q
            acc = zero(T)
            @fastmath @simd for j in 1:(n_chan * K)
                a = Aq[j, q]; b = Bq[j, q]
                acc += wc[j] * (real(a) * real(b) + imag(a) * imag(b))
            end
            S[q] = acc
        end
    else
        # mixed channel counts (e.g. the 2-channel vacuum term against a dummy):
        # pair only the shared channels
        @inbounds for q in 1:Q, c in 1:n_chan
            acc = zero(T)
            @fastmath @simd for k in 1:K
                a = B_lm_a[c, k, q]; b = B_lm_b[c, k, q]
                acc += weights[k] * (real(a) * real(b) + imag(a) * imag(b))
            end
            S[q] += acc
        end
    end
    return S .* (4π)
end