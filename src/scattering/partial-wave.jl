# SPDX-License-Identifier: LGPL-3.0-or-later


Base.size(a::SharedAmplitude) = (a.n, length(a.f))
Base.getindex(a::SharedAmplitude, i::Int, q::Int) = a.f[q]
using FastClosures: @closure
using LinearAlgebra: mul!
using ..Runtime: tmapItems, tmapBlocks, withBlasSingle, workerCount

"""
±m symmetry weights: m = 0 -> 1, m > 0 -> 2.

# Arguments
- `lMax::Integer`: maximum spherical harmonic degree. Must be non-negative.

# Returns
    - `Vector{Float64} of length (lMax+1)(lMax+2)/2`, one weight per stored
        (l, m) pair with m = 0, …, l, flattened in the same
        (0,0), (1,0), (1,1), (2,0), (2,1), (2,2), … degree-major order used to
        index `bLm` elsewhere (i.e. k0 = l*(l+1)/2 gives the offset of degree l's block).

# Mathematical derivation

We want:
    
    S(q) = 4π * Σ_l Σ_{m=-l}^{l} |B_lm(q)|²


with

    B_lm(q) = Σ_i f_i(q) * j_l(q r_i) * conj(Y_lm(θ_i, φ_i))

Spherical harmonics satisfy `Y_{l,-m}` = (-1)^m * conj(`Y_lm`). Plugging into `B_{l,-m}`:

    B_{l,-m} = Σ_i f_i * j_l * conj(Y_{l,-m})
         = Σ_i f_i * j_l * conj[(-1)^m * conj(Y_lm)]
         = (-1)^m * Σ_i f_i * j_l * Y_lm


If `f_i` is real, that last sum is just conj(`bLm`), since conjugating a
real-coefficient sum of `Y_lm`'s conjugates flips it back to `Y_lm`:

    B_{l,-m} = (-1)^m * conj(B_lm)   =>   |B_{l,-m}|² = |B_lm|²

Every negative-m term is a free duplicate of its positive-m partner, so:

    Σ_{m=-l}^{l} |B_lm|²    = |B_l0|² + Σ_{m=1}^{l} (|B_lm|² + |B_{l,-m}|²)
                            = 1·|B_l0|² + Σ_{m=1}^{l} 2·|B_lm|²

which is the 1-for-m=0, 2-for-m>0 weighting returned here.
"""
function partialWaveWeights(lMax::Integer)::Vector{Float64}
    lMax < 0 && throw(ArgumentError("partialWaveWeights: lMax must be non-negative"))
    return [2.0 - (m == 0) for deg in 0:lMax for m in 0:deg]
end

"""
Compute `B_lm(q) = Σ_i fAtoms[i](q) * j_l(q*r_i) * conj(Y_lm(θ_i, φ_i))`.

`fAtoms` carries whatever per-atom complex scattering amplitude the
caller wants (element form factors for the vacuum term, dummy-atom
excluded-volume/shell amplitudes for the other terms). The work is done by
[`_computeBLm`](@ref), which this calls with a single amplitude set.

# Arguments
    - `coordsSph::AbstractMatrix{<:Real}, size (3, N)`: per-atom spherical
        coordinates in the column-per-atom layout `MolecularStructure.coordsSpherical`
        returns — row 1 is r, row 2 is θ, row 3 is φ.
    - `qvals::AbstractVector{<:Real}, length Q`: momentum transfer grid, all ≥ 0.
    - `fAtoms::AbstractMatrix{<:Number}, size (N, Q)`: per-atom scattering
        amplitude, already evaluated on qvals. Real or complex.
    - `lMax::Integer`: maximum spherical harmonic degree. Must be non-negative.
    - `_CHUNK::UInt64`: number of atoms to process in one pass (results invariant
        up to rounding).

# Returns
    - `Array{ComplexF64,3}` of size (C, (lMax+1)(lMax+2)÷2, Q). C = 1 when
        `fAtoms` is real, C = 2 when it has a nonzero imaginary part (anomalous
        f''): channel 1 from Re(`fAtoms`), channel 2 from Im(`fAtoms`). The two
        channels add incoherently in the m-summed invariant (see
        [`selfScatter`](@ref)/[`crossScatter`](@ref)) — they must not be
        recombined into one complex `bLm`.

# Exceptions
    - `DomainError`: `_chunk` == 0.
    - `ArgumentError`: lMax < 0, `coordsSph` not (3, N), `fAtoms` not (N, Q), or a
        negative q.
"""
computeBLm(
    coordsSph::AbstractMatrix{<:Real},
    qvals::AbstractVector{<:Real},
    fAtoms::AbstractMatrix{<:Number},
    lMax::Integer,
    _chunk::UInt64,
)::Array{ComplexF64,3} = only(_computeBLm(coordsSph, qvals, (fAtoms,), lMax, _chunk))

"""
[`computeBLm`](@ref) for several amplitude sets on the same points (e.g. the
vacuum form factors and the excluded-volume dummies of one molecule), sharing one
spherical-harmonic evaluation and one spherical Bessel sweep per atom.

Real arithmetic throughout. Write `Ȳ_lm` = Re `Y_lm` − i·Im `Y_lm` (the conjugate). Every
amplitude column c (one per set and channel: Re f, and Im f when f is anomalous)
is real, so per degree l

    [Re B_l; Im B_l] (2(l+1) × Q) = [Re Y_l; −Im Y_l] (2(l+1) × atoms) · W_l (atoms × Q),
    W_l[i, q] = fC(i, q)·j_l(q·r_i),

one real matrix product per degree and column, done by OpenBLAS (`mul!`, 5-arg,
accumulating in place).

W is never stored as a full j array. For each atom the Gautschi sweep runs over a
q-tile: [`sphBessRatios!`](@ref) (pass 1), then upward with
[`sphBessStep`](@ref) (pass 2); each jₗ comes out normalized and is
multiplied straight into `W_l` for every column. W covers one tile of atoms
([`B_LM_TILE`](@ref)) and one q-tile, sized so that every degree fits in
[`B_LM_W_BYTES`](@ref); all buffers are allocated once per call.

# Arguments
    - `coordsSph`, `qvals`, `lMax`, `_chunk`: as [`computeBLm`](@ref).
    - `fSets`: tuple of amplitude matrices, each (N, Q), real or complex.

# Returns
    - `Tuple` of `Array{ComplexF64,3}`, one per set, each as [`computeBLm`](@ref)'s.
"""
function _computeBLm(
    coordsSph::AbstractMatrix{<:Real},
    qvals::AbstractVector{<:Real},
    fSets::Tuple{Vararg{AbstractMatrix{<:Number}}},
    lMax::Integer,
    _chunk::UInt64,
)
    # _CHUNK == 0 would make the 1:_CHUNK:N range below step by zero,
    # looping forever instead of raising.
    _chunk == 0 && throw(DomainError(_chunk, "_CHUNK must be > 0"))
    lMax < 0 && throw(ArgumentError("computeBLm: lMax must be non-negative"))

    # coordsSph is the column-per-atom spherical form straight from
    # MolecularStructure.coordsSpherical: 3 rows, (r, θ, φ) in that order.
    size(coordsSph, 1) == 3 || throw(
        ArgumentError(
            "computeBLm: coordsSph must be a (3, N) matrix with rows (r, θ, φ), " *
            "as returned by MolecularStructure.coordsSpherical; " *
            "got $(size(coordsSph, 1)) rows",
        ),
    )
    N = size(coordsSph, 2)
    Q = length(qvals)

    # validated once here: the per-radius Bessel sweep below does not re-check q
    any(<(0), qvals) && throw(ArgumentError("computeBLm: qvals must all be ≥ 0"))
    for f in fSets
        size(f, 1) == N ||
            throw(
                ArgumentError(
                    "computeBLm: fAtoms must have N rows matching coordsSph's columns",
                ),
            )
        size(f, 2) == Q ||
            throw(ArgumentError(
                "computeBLm: fAtoms must have Q columns matching qvals",
            )
            )
    end

    L = Int(lMax)
    # Packed (l,m) row count for m = 0..l only; see partialWaveWeights for
    # why the m < 0 half never needs to be stored.
    K = (L + 1) * (L + 2) ÷ 2

    # A purely real set needs only the Re(f) channel; an imaginary part
    # (anomalous f'') needs a second channel for the ±m symmetry.
    hasImag(f::AbstractMatrix)  = !(eltype(f)<:Real) && any(@closure(x -> imag(x) != 0), f)
    hasImag(f::SharedAmplitude) =
    !(eltype(f)<:Real) && any(@closure(x -> imag(x) != 0), f.f)
    nchan                       = map(f -> hasImag(f) ? 2 : 1, fSets)
    # Internal amplitude columns of the accumulator: a shared
    # amplitude is one column with unit amplitude (scaled by
    # f(q) when unpacking); any other set has one column per
    # channel. `fidx[c]` is the column's slot in `Ft` (0 for
    # a shared one, which has no per-atom amplitude to copy).
    ncols = map(f -> f isa SharedAmplitude ? 1 : (hasImag(f) ? 2 : 1), fSets)
    ncol = sum(ncols)
    colstart = cumsum((0, Base.front(ncols)...))
    fidx = zeros(Int, ncol)
    ncolF = 0
    for (s, f) in enumerate(fSets)
        f isa SharedAmplitude && continue
        for ch in 1:ncols[s]
            ncolF += 1
            fidx[colstart[s]+ch] = ncolF
        end
    end

    # accum[2k0 + 1 : 2k0 + l + 1, (c-1)Q + q] = Re B_lm, the next l + 1 rows Im B_lm,
    # for degree l (k0 = l(l+1)/2) and amplitude column c
    accum = zeros(Float64, 2K, ncol * Q)

    if N > 0
        nchunk = min(Int(_chunk), N)
        T = min(B_LM_TILE, nchunk)

        # q-tile length so that W (every column, every degree, T atoms) fits
        # the budget of one worker, B_LM_W_BYTES. A constant, not a function
        # of the thread count or the group count, so the tile shapes (and
        # with them the rounding) are the same at any number of threads.
        qTile = clamp(B_LM_W_BYTES ÷ (sizeof(Float64) * ncol * T * (L + 1)), 1, Q)
        qv = Vector{Float64}(qvals)
        qtiles = [qv[q0:min(q0+qTile-1, Q)] for q0 in 1:qTile:Q]

        # Negligible-Bessel cut: |jₗ(x)| ≤ xˡ/(2l+1)!! for all x ≥ 0
        # (from |J_ν(x)| ≤ (x/2)^ν/Γ(ν+1), ν ≥ −1/2), so jₗ(x) ≤ BESS_CUT
        # whenever x < x_cut(l) = (BESS_CUT·(2l+1)!!)^(1/l). For a tile
        # with largest radius rMax, degree l contributes nothing at
        # q < x_cut(l)/rMax; with q ascending those columns are a prefix,
        # skipped in the W writes and the product.

        # Unsorted q: no cut.
        qsorted = issorted(qv)
        xcut = zeros(L + 1)
        lndf = 0.0 # ln((2l+1)!!)
        for l in 1:L
            lndf += log(2l + 1.0)
            xcut[l+1] = exp((log(BESS_CUT) + lndf) / l)
        end

        # Atoms in order of increasing radius: the sum over atoms
        # does not care, and each tile then holds atoms of similar
        # radius, so its negligible-Bessel cut (set by the tile's
        # largest radius) is tight: far fewer degrees and q columns
        # survive in the inner tiles.
        order = sortperm(@view coordsSph[1, :])

        # The tiles (positions in `order`), within chunks of `_chunk` atoms,
        # dealt round-robin to at most B_LM_GROUPS groups (so every group gets
        # tiles of all radii). Each group sums its tiles, in order, into its own
        # accumulator; the accumulators are then added in group order. Fixed by
        # the constants and the input, never by the thread count, so the groups
        # can run on any number of threads, or serially, and give identical bits.
        tiles = Tuple{Int,Int}[]
        for start in 1:Int(_chunk):N
            stop = min(start + Int(_chunk) - 1, N)
            for t0 in start:T:stop
                push!(tiles, (t0, min(t0 + T - 1, stop)))
            end
        end
        nF = ncolF   # immutable copy: the group closures below run on other threads
        # B_LM_GROUPS groups (fewer only when there are fewer
        # tiles): fixed by the input, whatever the thread count
        ng = max(1, min(B_LM_GROUPS, length(tiles)))
        groups = [tiles[g:ng:end] for g in 1:ng]
        runGroup!(accG, tl, buf) = _bLmTiles!(
            accG, tl, buf, order, coordsSph, qv, qtiles, qTile, qsorted, xcut,
            fSets, ncols, fidx, ncol, T, L, Q,
        )
        # The groups run in waves of one group per worker, each into a reused scratch
        # accumulator, and every finished accumulator is added to accum in group order.
        # The additions are accum + g₁ + g₂ + … in that order whatever the wave size,
        # so the bits do not depend on the thread count, and the memory is one
        # accumulator per worker (not one per group). Small inputs stay on one thread
        # (and on OpenBLAS's own threads): with few tiles there is too little to
        # spread, and one BLAS thread per group would lose more than the groups gain.
        # The test is on the input only, and the groups are the same either way, so
        # the result is too. The workers hold one accumulator each, so their number
        # is also capped by B_LM_ACC_BYTES (the grouping, and with it the result, is
        # not: the wave size does not change the order of the additions).
        nw =
            (workerCount() > 1 && length(tiles) * Q ≥ B_LM_PARALLEL_MIN) ?
            max(1, min(workerCount(), ng, B_LM_ACC_BYTES ÷ max(sizeof(accum), 1))) : 1
        pool = [zeros(Float64, size(accum)) for _ in 1:nw]
        # the work buffers, one set per worker, allocated here once (not inside the tasks)
        bufs = [_bLmBuffers(T, L, K, Q, ncol, nF, qTile) for _ in 1:nw]
        if nw == 1
            for g in 1:ng
                fill!(pool[1], 0.0)
                runGroup!(pool[1], groups[g], bufs[1])
                accum .+= pool[1]
            end
        else
            withBlasSingle() do
                for g0 in 1:nw:ng
                    wave = g0:min(g0+nw-1, ng)
                    tmapItems(1:length(wave)) do j
                        fill!(pool[j], 0.0)
                        runGroup!(pool[j], groups[wave[j]], bufs[j])
                    end
                    # accum += the wave's accumulators, in group order
                    # for every element, column blocks in parallel
                    tmapBlocks(size(accum, 2), B_LM_REDUCE_COLS) do cols
                        @inbounds for j in 1:length(wave), c in cols
                            @simd for r in axes(accum, 1)
                                accum[r, c] += pool[j][r, c]
                            end
                        end
                    end
                end
            end
        end
    end

    # unpack into the public (C, K, Q) complex layout, one array per set;
    # set s owns amplitude columns c0[s] + 1 .. c0[s] + nchan[s]
    return map(Tuple(1:length(fSets))) do s
        B = Array{ComplexF64,3}(undef, nchan[s], K, Q)
        f = fSets[s]
        for ch in 1:nchan[s]
            # a shared set has one accumulator column holding the
            # unit-amplitude multipoles, scaled here by f(q)
            c = f isa SharedAmplitude ? colstart[s] + 1 : colstart[s] + ch
            scale(q) = f isa SharedAmplitude ? (
                ch == 1 ? real(f.f[q]) : imag(f.f[q])
            ) : 1.0
            @inbounds for q in 1:Q, l in 0:L
                k0 = l * (l + 1) ÷ 2
                col = (c - 1) * Q + q
                sc = scale(q)
                @fastmath @simd for m in 0:l
                    B[ch, k0+m+1, q] =
                        sc * complex(
                            accum[2k0+m+1, col],
                            accum[2k0+l+1+m+1, col],
                        )
                end
            end
        end
        B
    end
end


"""
The work buffers of one worker of [`_computeBLm`](@ref) (see [`_bLmTiles!`](@ref)):
allocated by the caller, once per worker, so the tasks that use them allocate nothing large.

# Returns
- `NamedTuple` `(A, Ft, W, sb, Scache, ltopbuf, ks)`.

# Exceptions
- `OutOfMemoryError` if the buffers do not fit.
"""
function _bLmBuffers(T::Int, L::Int, K::Int, Q::Int, ncol::Int, ncolF::Int, qTile::Int)
    return (;
        # [Re Y_l; −Im Y_l] stacked per degree, of the atoms of one tile
        A = Matrix{Float64}(undef, 2K, T),
        # Ft[q, c, tt]: amplitude column c of the tile's atom tt (per-atom sets only)
        ft = Array{Float64,3}(undef, Q, ncolF, T),
        # W[(c-1)qTile + k, t, l+1]
        W = Array{Float64,3}(undef, ncol * qTile, T, L + 1),
        sb = sphBess(qTile, L),
        scache = sphHarmCache(L),
        # per q: the highest degree kept there (see below)
        ltopbuf = Vector{Int}(undef, qTile),
        # first q column (within the q-tile) kept for degree l
        ks = ones(Int, L + 1),
    )
end

"""
The tiles `tl` of [`_computeBLm`](@ref) (pairs of positions in `order`, ascending),
summed into `accG` (`2K × ncol·Q`): for each tile the amplitude columns, the
spherical harmonics of its atoms, and for each q-tile the Bessel sweep, W and the
per-degree products, using the work buffers `buf` ([`_bLmBuffers`](@ref)); groups
that run concurrently need different `buf` and `accG`. `accG` must be zero on entry.

# Returns
- `nothing`; `accG` is updated in place.

# Exceptions
- `BoundsError` if the buffers or tiles do not match the inputs' sizes (a caller error).
"""
function _bLmTiles!(
    accG::Matrix{Float64},
    tl::Vector{Tuple{Int,Int}},
    buf,
    order::Vector{Int},
    coordsSph::AbstractMatrix{<:Real},
    qv::Vector{Float64},
    qtiles::Vector{Vector{Float64}},
    qTile::Int,
    qsorted::Bool,
    xcut::Vector{Float64},
    fSets::Tuple{Vararg{AbstractMatrix{<:Number}}},
    ncols::Tuple{Vararg{Int}},
    fidx::Vector{Int},
    ncol::Int,
    T::Int,
    L::Int,
    Q::Int,
)::Nothing
    A, ft, W, sb, scache, ltopbuf, ks =
        buf.A, buf.ft, buf.W, buf.sb, buf.scache, buf.ltopbuf, buf.ks

    for (a, b) in tl
        tile = view(order, a:b)
        nt = length(tile)
        gcCheckpoint()

        # amplitudes, q-contiguous per atom and column
        # (shared sets have none: unit amplitude)
        c = 0
        for (s, f) in enumerate(fSets)
            f isa SharedAmplitude && continue
            for ch in 1:ncols[s]
                c += 1
                # real part for channel 1, imaginary for
                # channel 2 (branch outside the copy)
                if ch == 1
                    @inbounds for i in 1:nt
                        @fastmath @simd for q in 1:Q
                            ft[q, c, i] = real(f[tile[i], q])
                        end
                    end
                else
                    @inbounds for i in 1:nt
                        @fastmath @simd for q in 1:Q
                            ft[q, c, i] = imag(f[tile[i], q])
                        end
                    end
                end
            end
        end

        # Highest degree with any kept q column in this
        # tile (its largest radius, the largest q): Y_lm is
        # needed only up to it, and the inner tiles of the
        # radius-sorted atoms stop far below lMax.
        rmax = qsorted ? maximum(i -> Float64(coordsSph[1, i]), tile) : 0.0
        ltile = L
        if qsorted
            ltile = 0
            for l in 1:L
                xcut[l+1] ≤ qv[end] * rmax && (ltile = l)
            end
        end
        # [Re Y; −Im Y] of the tile's atoms, straight
        # into the product operand A (degrees 0..Ltile)
        sphHarm!(
            view(A, :, 1:nt),
            scache,
            ltile,
            view(coordsSph, 2, tile),
            view(coordsSph, 3, tile),
        )

        for (ti, qt) in enumerate(qtiles)
            q0 = (ti - 1) * qTile + 1
            nq = length(qt)
            lt = L # last degree with a kept q column in this tile
            if qsorted
                lt = 0
                for l in 1:L
                    ks[l+1] = searchsortedfirst(qt, xcut[l+1] / rmax)
                    ks[l+1] ≤ nq && (lt = l) # xcut grows w/ l; kept degrees are 0..Lt
                end
            end
            # ltop[k]: the highest degree kept at q column k
            # (ks is nondecreasing in l, so the kept degrees at k
            # are 0..ltop[k]): the Bessel ratios are needed only up to it
            if qsorted
                for l in 0:lt
                    lo = ks[l+1]
                    hi = l < lt ? ks[l+2] - 1 : nq
                    @inbounds @simd for k in lo:hi
                        ltopbuf[k] = l
                    end
                end
            else
                fill!(view(ltopbuf, 1:nq), L)
            end

            # W for every atom of the tile, every degree, every column
            for tt in 1:nt
                sphBessRatios!(
                    sb,
                    Float64(coordsSph[1, tile[tt]]),
                    qt,
                    lt;
                    ltop = view(ltopbuf, 1:nq),
                )
                jm1, jm2 = sb.jm1, sb.jm2      # j₁, j₀ after pass 1
                _writeW!(W, ft, jm2, fidx, q0, ks[1], nq, qTile, tt, tt, 0)
                lt ≥ 1 && _writeW!(W, ft, jm1, fidx, q0, ks[2], nq, qTile, tt, tt, 1)
                for l in 2:lt
                    lup, invx, R = sb.lup, sb.invx, sb.R
                    # q columns below ks[l+1] are under the cut at
                    # this degree and every higher one: not advanced
                    @inbounds @fastmath @simd for k in ks[l+1]:nq
                        v = sphBessStep(jm1[k], jm2[k], l, lup[k], invx[k], R[k, l])
                        jm2[k] = jm1[k]
                        jm1[k] = v
                    end
                    _writeW!(W, ft, jm1, fidx, q0, ks[l+1], nq, qTile, tt, tt, l)
                end
            end

            # one real product per degree and column, accumulated in place (BLAS)
            for l in 0:L
                kk = ks[l+1]
                kk > nq && continue # the whole q-tile is below the cut
                k0 = l * (l + 1) ÷ 2
                rows = (2k0+1):(2k0+2(l+1))
                al = view(A, rows, 1:nt)
                for c in 1:ncol
                    mul!(
                        view(
                            accG,
                            rows,
                            (c - 1) * Q .+ ((q0+kk-1):(q0+nq-1)),
                        ),
                        al,
                        transpose(
                            view(
                                W,
                                (c - 1) * qTile .+ (kk:nq),
                                1:nt,
                                l + 1,
                            ),
                        ),
                        1.0, 1.0,
                    )
                end
            end
        end
    end
    return nothing
end

"""
W[(c−1)qTile + k, tt, l+1] = Ft[q0+k−1, fidx[c], i]·j[k] (just j[k]
for a shared column, `fidx[c] == 0`) for every amplitude column c and
k = kstart..nq: degree l's slice of W for one atom, from its normalized
jₗ over the q-tile (columns below kstart are under the negligible-Bessel
cut and not used).

# Returns
- `nothing`.
"""
@inline function _writeW!(
    W::Array{Float64,3},
    ft::Array{Float64,3},
    j::Vector{Float64},
    fidx::Vector{Int},
    q0::Int,
    kstart::Int,
    nq::Int,
    qTile::Int,
    tt::Int,
    i::Int,
    l::Int,
)::Nothing
    @inbounds for c in eachindex(fidx)
        off = (c - 1) * qTile
        fc = fidx[c]
        if fc == 0 # shared amplitude: unit, scaled when unpacking
            @fastmath @simd for k in kstart:nq
                W[off+k, tt, l+1] = j[k]
            end
        else
            @fastmath @simd for k in kstart:nq
                W[off+k, tt, l+1] = ft[q0+k-1, fc, i] * j[k]
            end
        end
    end
    return nothing
end

"""
S(q) = 4π * `Σ_c` `Σ_lm` `w_lm` * |`B_lm(q)`|².

Channels (real/imaginary amplitude) add incoherently: the cross terms
between them cancel identically once summed over the full -l..l range ofm.

# Arguments
- `B_lm::AbstractArray{<:Complex,3}, size (C, K, Q)`: as returned by [`computeBLm`](@ref).
- `weights::AbstractVector{<:Real}, length K`:
    as returned by [`partialWaveWeights`](@ref).

# Returns
- `AbstractVector{<:Real} of length Q`."""
function selfScatter(
    bLm::AbstractArray{<:Complex,3}, weights::AbstractVector{<:Real},
)::AbstractVector{<:Real}

    C, K, Q = size(bLm)
    length(weights) == K || throw(
        DimensionMismatch(
            "selfScatter: weights has length $(length(weights)), B_lm has K = $K",
        ),
    )
    T = promote_type(real(eltype(bLm)), eltype(weights))
    # Σ_c Σ_lm w_lm·|B_lm|² per q. Each q's (C, K) block is one contiguous run, so it
    # is summed as a single vector with the weights repeated per channel.
    bq = reshape(bLm, C * K, Q)
    wc = repeat(weights, inner = C)
    S = Vector{T}(undef, Q)
    @inbounds for q in 1:Q
        acc = zero(T)
        @fastmath @simd for j in 1:(C*K)
            acc += wc[j] * abs2(bq[j, q])
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
- `weights::AbstractVector{<:Real}, length K`: as returned by
    [`partialWaveWeights`](@ref).

# Returns
- `AbstractVector{<:Real} of length Q`
"""
function crossScatter(
    bLmA::AbstractArray{<:Complex,3},
    bLmB::AbstractArray{<:Complex,3},
    weights::AbstractVector{<:Real},
)::AbstractVector{<:Real}

    # Only the channels both operands actually have can be paired up; a real
    # amplitude's missing second channel would otherwise have nothing to mul against.
    nChan = min(size(bLmA, 1), size(bLmB, 1))

    # Re(B_a * conj(B_b)) per (channel, l/m, q) entry, matching selfScatter
    # with |B_lm|^2 (= Re(B_lm * conj(B_lm))) generalised to two operands.
    K, Q = size(bLmA, 2), size(bLmA, 3)
    (size(bLmB, 2) == K && size(bLmB, 3) == Q && length(weights) == K) || throw(
        DimensionMismatch(
            "crossScatter: B_lm_a is (_, $K, $Q), B_lm_b is $(size(bLmB)), " *
            "weights has length $(length(weights))",
        ),
    )
    T = promote_type(real(eltype(bLmA)), real(eltype(bLmB)), eltype(weights))
    S = zeros(T, Q)
    if size(bLmA, 1) == size(bLmB, 1) == nChan
        # same channel count: each q's (C, K) block is one contiguous run in both,
        # summed as a single vector (as selfScatter)
        aq = reshape(bLmA, nChan * K, Q)
        bq = reshape(bLmB, nChan * K, Q)
        wc = repeat(weights, inner = nChan)
        @inbounds for q in 1:Q
            acc = zero(T)
            @fastmath @simd for j in 1:(nChan*K)
                a = aq[j, q]
                b = bq[j, q]
                acc += wc[j] * (real(a) * real(b) + imag(a) * imag(b))
            end
            S[q] = acc
        end
    else
        # mixed channel counts (e.g. the 2-channel vacuum term against a dummy):
        # pair only the shared channels
        @inbounds for q in 1:Q, c in 1:nChan
            acc = zero(T)
            @fastmath @simd for k in 1:K
                a = bLmA[c, k, q]
                b = bLmB[c, k, q]
                acc += weights[k] * (real(a) * real(b) + imag(a) * imag(b))
            end
            S[q] += acc
        end
    end
    return S .* (4π)
end
