# SPDX-License-Identifier: LGPL-2.1-or-later


Base.size(a::SharedAmplitude) = (a.n, length(a.f))
Base.getindex(a::SharedAmplitude, i::Int, q::Int) = a.f[q]
using FastClosures: @closure
using LinearAlgebra: mul!
using ..Runtime: tmap_items, tmap_blocks, with_blas_single, worker_count

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
q-tile: [`sphBessRatios!`](@ref) (pass 1), then upward with
[`sphBessStep`](@ref) (pass 2); each jₗ comes out normalized and is
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
    size(coords_sph, 1) == 3 || throw(
        ArgumentError(
            "compute_B_lm: coords_sph must be a (3, N) matrix with rows (r, θ, φ), " *
            "as returned by MolecularStructure.coords_spherical; " *
            "got $(size(coords_sph, 1)) rows",
        ),
    )
    N = size(coords_sph, 2)
    Q = length(qvals)

    # validated once here: the per-radius Bessel sweep below does not re-check q
    any(<(0), qvals) && throw(ArgumentError("compute_B_lm: qvals must all be ≥ 0"))
    for f in f_sets
        size(f, 1) == N ||
            throw(
                ArgumentError(
                    "compute_B_lm: f_atoms must have N rows matching coords_sph's columns",
                ),
            )
        size(f, 2) == Q ||
            throw(ArgumentError(
                "compute_B_lm: f_atoms must have Q columns matching qvals",
            )
            )
    end

    L = Int(lMax)
    # Packed (l,m) row count for m = 0..l only; see partial_wave_weights for
    # why the m < 0 half never needs to be stored.
    K = (L + 1) * (L + 2) ÷ 2

    # A purely real set needs only the Re(f) channel; an imaginary part
    # (anomalous f'') needs a second channel for the ±m symmetry.
    has_imag(f::AbstractMatrix)  = !(eltype(f)<:Real) && any(@closure(x -> imag(x) != 0), f)
    has_imag(f::SharedAmplitude) =
    !(eltype(f)<:Real) && any(@closure(x -> imag(x) != 0), f.f)
    nchan                        = map(f -> has_imag(f) ? 2 : 1, f_sets)
    # Internal amplitude columns of the accumulator: a shared
    # amplitude is one column with unit amplitude (scaled by
    # f(q) when unpacking); any other set has one column per
    # channel. `fidx[c]` is the column's slot in `Ft` (0 for
    # a shared one, which has no per-atom amplitude to copy).
    ncols = map(f -> f isa SharedAmplitude ? 1 : (has_imag(f) ? 2 : 1), f_sets)
    ncol = sum(ncols)
    colstart = cumsum((0, Base.front(ncols)...))
    fidx = zeros(Int, ncol)
    ncolF = 0
    for (s, f) in enumerate(f_sets)
        f isa SharedAmplitude && continue
        for ch in 1:ncols[s]
            ncolF += 1
            fidx[colstart[s]+ch] = ncolF
        end
    end

    # Acc[2k0 + 1 : 2k0 + l + 1, (c-1)Q + q] = Re B_lm, the next l + 1 rows Im B_lm,
    # for degree l (k0 = l(l+1)/2) and amplitude column c
    Acc = zeros(Float64, 2K, ncol * Q)

    if N > 0
        nchunk = min(Int(_CHUNK), N)
        T = min(B_LM_TILE, nchunk)

        # q-tile length so that W (every column, every degree, T atoms) fits
        # the budget of one worker, B_LM_W_BYTES. A constant, not a function
        # of the thread count or the group count, so the tile shapes (and
        # with them the rounding) are the same at any number of threads.
        Qt = clamp(B_LM_W_BYTES ÷ (sizeof(Float64) * ncol * T * (L + 1)), 1, Q)
        qv = Vector{Float64}(qvals)
        qtiles = [qv[q0:min(q0+Qt-1, Q)] for q0 in 1:Qt:Q]

        # Negligible-Bessel cut: |jₗ(x)| ≤ xˡ/(2l+1)!! for all x ≥ 0
        # (from |J_ν(x)| ≤ (x/2)^ν/Γ(ν+1), ν ≥ −1/2), so jₗ(x) ≤ BESS_CUT
        # whenever x < x_cut(l) = (BESS_CUT·(2l+1)!!)^(1/l). For a tile
        # with largest radius r_max, degree l contributes nothing at
        # q < x_cut(l)/r_max; with q ascending those columns are a prefix,
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
        order = sortperm(@view coords_sph[1, :])

        # The tiles (positions in `order`), within chunks of `_CHUNK` atoms,
        # dealt round-robin to at most B_LM_GROUPS groups (so every group gets
        # tiles of all radii). Each group sums its tiles, in order, into its own
        # accumulator; the accumulators are then added in group order. Fixed by
        # the constants and the input, never by the thread count, so the groups
        # can run on any number of threads, or serially, and give identical bits.
        tiles = Tuple{Int,Int}[]
        for start in 1:Int(_CHUNK):N
            stop = min(start + Int(_CHUNK) - 1, N)
            for t0 in start:T:stop
                push!(tiles, (t0, min(t0 + T - 1, stop)))
            end
        end
        nF = ncolF   # immutable copy: the group closures below run on other threads
        # B_LM_GROUPS groups (fewer only when there are fewer
        # tiles): fixed by the input, whatever the thread count
        ng = max(1, min(B_LM_GROUPS, length(tiles)))
        groups = [tiles[g:ng:end] for g in 1:ng]
        run_group!(Acc_g, tl, buf) = _b_lm_tiles!(
            Acc_g, tl, buf, order, coords_sph, qv, qtiles, Qt, qsorted, xcut,
            f_sets, ncols, fidx, ncol, T, L, Q,
        )
        # The groups run in waves of one group per worker, each into a reused scratch
        # accumulator, and every finished accumulator is added to Acc in group order.
        # The additions are Acc + g₁ + g₂ + … in that order whatever the wave size,
        # so the bits do not depend on the thread count, and the memory is one
        # accumulator per worker (not one per group). Small inputs stay on one thread
        # (and on OpenBLAS's own threads): with few tiles there is too little to
        # spread, and one BLAS thread per group would lose more than the groups gain.
        # The test is on the input only, and the groups are the same either way, so
        # the result is too. The workers hold one accumulator each, so their number
        # is also capped by B_LM_ACC_BYTES (the grouping, and with it the result, is
        # not: the wave size does not change the order of the additions).
        nw =
            (worker_count() > 1 && length(tiles) * Q ≥ B_LM_PARALLEL_MIN) ?
            max(1, min(worker_count(), ng, B_LM_ACC_BYTES ÷ max(sizeof(Acc), 1))) : 1
        pool = [zeros(Float64, size(Acc)) for _ in 1:nw]
        # the work buffers, one set per worker, allocated here once (not inside the tasks)
        bufs = [_b_lm_buffers(T, L, K, Q, ncol, nF, Qt) for _ in 1:nw]
        if nw == 1
            for g in 1:ng
                fill!(pool[1], 0.0)
                run_group!(pool[1], groups[g], bufs[1])
                Acc .+= pool[1]
            end
        else
            with_blas_single() do
                for g0 in 1:nw:ng
                    wave = g0:min(g0+nw-1, ng)
                    tmap_items(1:length(wave)) do j
                        fill!(pool[j], 0.0)
                        run_group!(pool[j], groups[wave[j]], bufs[j])
                    end
                    # Acc += the wave's accumulators, in group order
                    # for every element, column blocks in parallel
                    tmap_blocks(size(Acc, 2), B_LM_REDUCE_COLS) do cols
                        @inbounds for j in 1:length(wave), c in cols
                            @simd for r in axes(Acc, 1)
                                Acc[r, c] += pool[j][r, c]
                            end
                        end
                    end
                end
            end
        end
    end

    # unpack into the public (C, K, Q) complex layout, one array per set;
    # set s owns amplitude columns c0[s] + 1 .. c0[s] + nchan[s]
    return map(Tuple(1:length(f_sets))) do s
        B = Array{ComplexF64,3}(undef, nchan[s], K, Q)
        f = f_sets[s]
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
                            Acc[2k0+m+1, col],
                            Acc[2k0+l+1+m+1, col],
                        )
                end
            end
        end
        B
    end
end


"""
The work buffers of one worker of [`_compute_B_lm`](@ref) (see [`_b_lm_tiles!`](@ref)):
allocated by the caller, once per worker, so the tasks that use them allocate nothing large.

# Returns
- `NamedTuple` `(A, Ft, W, sb, Scache, ltopbuf, ks)`.

# Exceptions
- `OutOfMemoryError` if the buffers do not fit.
"""
function _b_lm_buffers(T::Int, L::Int, K::Int, Q::Int, ncol::Int, ncolF::Int, Qt::Int)
    return (;
        # [Re Y_l; −Im Y_l] stacked per degree, of the atoms of one tile
        A = Matrix{Float64}(undef, 2K, T),
        # Ft[q, c, tt]: amplitude column c of the tile's atom tt (per-atom sets only)
        Ft = Array{Float64,3}(undef, Q, ncolF, T),
        # W[(c-1)Qt + k, t, l+1]
        W = Array{Float64,3}(undef, ncol * Qt, T, L + 1),
        sb = sphBess(Qt, L),
        Scache = sphHarmCache(L),
        # per q: the highest degree kept there (see below)
        ltopbuf = Vector{Int}(undef, Qt),
        # first q column (within the q-tile) kept for degree l
        ks = ones(Int, L + 1),
    )
end

"""
The tiles `tl` of [`_compute_B_lm`](@ref) (pairs of positions in `order`, ascending),
summed into `Acc_g` (`2K × ncol·Q`): for each tile the amplitude columns, the
spherical harmonics of its atoms, and for each q-tile the Bessel sweep, W and the
per-degree products, using the work buffers `buf` ([`_b_lm_buffers`](@ref)); groups
that run concurrently need different `buf` and `Acc_g`. `Acc_g` must be zero on entry.

# Returns
- `nothing`; `Acc_g` is updated in place.

# Exceptions
- `BoundsError` if the buffers or tiles do not match the inputs' sizes (a caller error).
"""
function _b_lm_tiles!(
    Acc_g::Matrix{Float64},
    tl::Vector{Tuple{Int,Int}},
    buf,
    order::Vector{Int},
    coords_sph::AbstractMatrix{<:Real},
    qv::Vector{Float64},
    qtiles::Vector{Vector{Float64}},
    Qt::Int,
    qsorted::Bool,
    xcut::Vector{Float64},
    f_sets::Tuple{Vararg{AbstractMatrix{<:Number}}},
    ncols::Tuple{Vararg{Int}},
    fidx::Vector{Int},
    ncol::Int,
    T::Int,
    L::Int,
    Q::Int,
)::Nothing
    A, Ft, W, sb, Scache, ltopbuf, ks =
        buf.A, buf.Ft, buf.W, buf.sb, buf.Scache, buf.ltopbuf, buf.ks

    for (a, b) in tl
        tile = view(order, a:b)
        nt = length(tile)
        gc_checkpoint()

        # amplitudes, q-contiguous per atom and column
        # (shared sets have none: unit amplitude)
        c = 0
        for (s, f) in enumerate(f_sets)
            f isa SharedAmplitude && continue
            for ch in 1:ncols[s]
                c += 1
                # real part for channel 1, imaginary for
                # channel 2 (branch outside the copy)
                if ch == 1
                    @inbounds for i in 1:nt
                        @fastmath @simd for q in 1:Q
                            Ft[q, c, i] = real(f[tile[i], q])
                        end
                    end
                else
                    @inbounds for i in 1:nt
                        @fastmath @simd for q in 1:Q
                            Ft[q, c, i] = imag(f[tile[i], q])
                        end
                    end
                end
            end
        end

        # Highest degree with any kept q column in this
        # tile (its largest radius, the largest q): Y_lm is
        # needed only up to it, and the inner tiles of the
        # radius-sorted atoms stop far below lMax.
        rmax = qsorted ? maximum(i -> Float64(coords_sph[1, i]), tile) : 0.0
        Ltile = L
        if qsorted
            Ltile = 0
            for l in 1:L
                xcut[l+1] ≤ qv[end] * rmax && (Ltile = l)
            end
        end
        # [Re Y; −Im Y] of the tile's atoms, straight
        # into the product operand A (degrees 0..Ltile)
        sphHarm!(
            view(A, :, 1:nt),
            Scache,
            Ltile,
            view(coords_sph, 2, tile),
            view(coords_sph, 3, tile),
        )

        for (ti, qt) in enumerate(qtiles)
            q0 = (ti - 1) * Qt + 1
            nq = length(qt)
            Lt = L # last degree with a kept q column in this tile
            if qsorted
                Lt = 0
                for l in 1:L
                    ks[l+1] = searchsortedfirst(qt, xcut[l+1] / rmax)
                    ks[l+1] ≤ nq && (Lt = l) # xcut grows w/ l; kept degrees are 0..Lt
                end
            end
            # ltop[k]: the highest degree kept at q column k
            # (ks is nondecreasing in l, so the kept degrees at k
            # are 0..ltop[k]): the Bessel ratios are needed only up to it
            if qsorted
                for l in 0:Lt
                    lo = ks[l+1]
                    hi = l < Lt ? ks[l+2] - 1 : nq
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
                    Float64(coords_sph[1, tile[tt]]),
                    qt,
                    Lt;
                    ltop = view(ltopbuf, 1:nq),
                )
                jm1, jm2 = sb.jm1, sb.jm2      # j₁, j₀ after pass 1
                _write_W!(W, Ft, jm2, fidx, q0, ks[1], nq, Qt, tt, tt, 0)
                Lt ≥ 1 && _write_W!(W, Ft, jm1, fidx, q0, ks[2], nq, Qt, tt, tt, 1)
                for l in 2:Lt
                    lup, invx, R = sb.lup, sb.invx, sb.R
                    # q columns below ks[l+1] are under the cut at
                    # this degree and every higher one: not advanced
                    @inbounds @fastmath @simd for k in ks[l+1]:nq
                        v = sphBessStep(jm1[k], jm2[k], l, lup[k], invx[k], R[k, l])
                        jm2[k] = jm1[k]
                        jm1[k] = v
                    end
                    _write_W!(W, Ft, jm1, fidx, q0, ks[l+1], nq, Qt, tt, tt, l)
                end
            end

            # one real product per degree and column, accumulated in place (BLAS)
            for l in 0:L
                kk = ks[l+1]
                kk > nq && continue # the whole q-tile is below the cut
                k0 = l * (l + 1) ÷ 2
                rows = (2k0+1):(2k0+2(l+1))
                Al = view(A, rows, 1:nt)
                for c in 1:ncol
                    mul!(
                        view(
                            Acc_g,
                            rows,
                            (c - 1) * Q .+ ((q0+kk-1):(q0+nq-1)),
                        ),
                        Al,
                        transpose(
                            view(
                                W,
                                (c - 1) * Qt .+ (kk:nq),
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
W[(c−1)Qt + k, tt, l+1] = Ft[q0+k−1, fidx[c], i]·j[k] (just j[k]
for a shared column, `fidx[c] == 0`) for every amplitude column c and
k = kstart..nq: degree l's slice of W for one atom, from its normalized
jₗ over the q-tile (columns below kstart are under the negligible-Bessel
cut and not used).

# Returns
- `nothing`.
"""
@inline function _write_W!(
    W::Array{Float64,3},
    Ft::Array{Float64,3},
    j::Vector{Float64},
    fidx::Vector{Int},
    q0::Int,
    kstart::Int,
    nq::Int,
    Qt::Int,
    tt::Int,
    i::Int,
    l::Int,
)::Nothing
    @inbounds for c in eachindex(fidx)
        off = (c - 1) * Qt
        fc = fidx[c]
        if fc == 0 # shared amplitude: unit, scaled when unpacking
            @fastmath @simd for k in kstart:nq
                W[off+k, tt, l+1] = j[k]
            end
        else
            @fastmath @simd for k in kstart:nq
                W[off+k, tt, l+1] = Ft[q0+k-1, fc, i] * j[k]
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
- `B_lm::AbstractArray{<:Complex,3}, size (C, K, Q)`: as returned by [`compute_B_lm`](@ref).
- `weights::AbstractVector{<:Real}, length K`:
    as returned by [`partial_wave_weights`](@ref).

# Returns
- `AbstractVector{<:Real} of length Q`."""
function self_scatter(
    B_lm::AbstractArray{<:Complex,3}, weights::AbstractVector{<:Real},
)::AbstractVector{<:Real}

    C, K, Q = size(B_lm)
    length(weights) == K || throw(
        DimensionMismatch(
            "self_scatter: weights has length $(length(weights)), B_lm has K = $K",
        ),
    )
    T = promote_type(real(eltype(B_lm)), eltype(weights))
    # Σ_c Σ_lm w_lm·|B_lm|² per q. Each q's (C, K) block is one contiguous run, so it
    # is summed as a single vector with the weights repeated per channel.
    Bq = reshape(B_lm, C * K, Q)
    wc = repeat(weights, inner = C)
    S = Vector{T}(undef, Q)
    @inbounds for q in 1:Q
        acc = zero(T)
        @fastmath @simd for j in 1:(C*K)
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
- `weights::AbstractVector{<:Real}, length K`: as returned by
    [`partial_wave_weights`](@ref).

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
    (size(B_lm_b, 2) == K && size(B_lm_b, 3) == Q && length(weights) == K) || throw(
        DimensionMismatch(
            "cross_scatter: B_lm_a is (_, $K, $Q), B_lm_b is $(size(B_lm_b)), " *
            "weights has length $(length(weights))",
        ),
    )
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
            @fastmath @simd for j in 1:(n_chan*K)
                a = Aq[j, q]
                b = Bq[j, q]
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
                a = B_lm_a[c, k, q]
                b = B_lm_b[c, k, q]
                acc += weights[k] * (real(a) * real(b) + imag(a) * imag(b))
            end
            S[q] += acc
        end
    end
    return S .* (4π)
end
