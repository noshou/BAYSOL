# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Everything [`shannonData`](@ref) decided about a measured curve,
kept in the `Inference.Seed` so the report and the fitting
scripts can reach both the data the fit used and the raw data.

# Fields
-   `D::Float64`: diameter of the scatterer cloud (atoms and hydration-shell beads), Å.
-   `lMax::Int`: spherical-harmonic band limit the forward model was built with.
-   `rebin::Int`: bins per Shannon channel; `0` when the data was not binned.
-   `nChannels::Float64`: Shannon channels the fitted q range holds, `(qMax - qMin)·D/π`.
-   `qRaw, I_raw, σ_raw`: the measured curve as given.
-   `q, I, σ`: the curve the fit sees (binned, then non-positive bins dropped).
-   `bin::Vector{Int}`: for each raw point, the index into `q` of its bin;
    `0` if that bin was dropped.
-   `nNonpositive::Int`: bins dropped for `I ≤ 0`.
"""
struct ShannonInfo
    D::Float64
    lMax::Int
    rebin::Int
    nChannels::Float64
    qRaw::Vector{Float64}
    iRaw::Vector{Float64}
    σ_raw::Vector{Float64}
    q::Vector{Float64}
    I::Vector{Float64}
    σ::Vector{Float64}
    bin::Vector{Int}
    nNonpositive::Int
end

# The curve binned to `k` bins per channel (as measured when
# `k === nothing`), the non-positive bins dropped when asked: (q, I, σ, per
# raw point the index of its bin (0 if dropped), the number of bins dropped).
function _binAndKeep(qr, ir, σr, D, k, dropNonpositive)
    if k === nothing
        qb, ib, σb, bin = copy(qr), copy(ir), copy(σr), collect(1:length(qr))
    else
        qb, ib, σb, bin = _rebin(qr, ir, σr, π / (k * D))
    end
    keep = dropNonpositive ? findall(>(0), ib) : collect(eachindex(ib))
    isempty(keep) && throw(ArgumentError("no point has a positive intensity after binning"))
    nNonpositive = length(ib) - length(keep)
    if nNonpositive > 0
        remap = zeros(Int, length(ib))
        remap[keep] .= 1:length(keep)
        bin = [b == 0 ? 0 : remap[b] for b in bin]
        qb, ib, σb = qb[keep], ib[keep], σb[keep]
    end
    return qb, ib, σb, bin, nNonpositive
end

# Inverse-variance bins of width Δ from min(q): per
# raw point the bin it falls in, and per bin the
# weighted-mean q and I and σ = 1/√Σw
# (independent-errors assumption). Empty bins vanish;
# the output is in increasing q.
function _rebin(
    q::Vector{Float64},
    I::Vector{Float64},
    σ::Vector{Float64},
    Δ::Float64,
)
    q0 = minimum(q)
    b = [floor(Int, (x - q0) / Δ) + 1 for x in q]
    nb = maximum(b)
    sw = zeros(nb)
    swI = zeros(nb)
    swq = zeros(nb)
    @inbounds for i in eachindex(q)
        w = 1 / σ[i]^2
        sw[b[i]] += w
        swI[b[i]] += w * I[i]
        swq[b[i]] += w * q[i]
    end
    used = findall(>(0), sw)
    remap = zeros(Int, nb)
    remap[used] .= 1:length(used)
    return swq[used] ./ sw[used], swI[used] ./ sw[used], 1 ./ sqrt.(sw[used]), remap[b]
end

"""
Bins a measured curve by Shannon channel, drops the bins with non-positive
intensity, and picks the band limit.

The curve is cut into bins of width π/(rebin·D) in q, and each bin is
replaced by the inverse-variance weighted mean of its points
(position and intensity), with the standard error 1/√Σ(1/σᵢ²). Bins
narrower than the data's own spacing change nothing. Bins whose mean
intensity is not positive (noise at high q) are then dropped, unless
`dropNonpositive = false`. With `rebin = nothing` the curve is not binned,
only filtered. Dropping is not neutral: it removes the negative half of
the noise at high q, so the surviving points are biased upwards.

# Arguments
- `q, I, σ`: the measured curve, equal lengths, `σ > 0`, finite.

# Keywords
-   `D::Real`: diameter of the scatterer cloud in Å (see [`cloudDiameter`](@ref)).
-   `rebin::Union{Nothing,Integer} = SHANNON_REBIN`: bins per Shannon channel,
    at least this many (see `maxBinBias`), or `nothing` for no binning.
-   `maxBinBias::Real = BIN_BIAS_MAX`: if [`binBiasRatio`](@ref) of
    the binned curve exceeds this, `rebin` is raised until it does not (a
    precise curve needs finer bins), and the curve is fitted as measured
    once the bins are as fine as its points; `Inf` keeps `rebin` as given.
-   `lMax::Union{Nothing,Integer} = nothing`: band limit; `nothing` takes
    [`autoLmax`](@ref)`(D, qMax)` with `qMax` the largest binned q.
-   `dropNonpositive::Bool = true`: drop the bins whose mean intensity is not positive.

# Returns
- [`ShannonInfo`](@ref).

# Exceptions
-   `DomainError`: lengths differ, `q`, `I` or `σ` is not finite,
    `σ ≤ 0`, `rebin < 1`, or `D ≤ 0`.
- ` ArgumentError`: no point has a positive binned intensity.
"""
function shannonData(
    q::AbstractVector{<:Real},
    I::AbstractVector{<:Real},
    σ::AbstractVector{<:Real};
    D::Real,
    rebin::Union{Nothing,Integer} = SHANNON_REBIN,
    lMax::Union{Nothing,Integer} = nothing,
    dropNonpositive::Bool = true,
    maxBinBias::Real = BIN_BIAS_MAX,
)::ShannonInfo
    length(q) == length(I) == length(σ) || throw(
        DomainError(
            (length(q),
                length(I),
                length(σ),
            ),
            "q, I and σ must have the same length",
        ),
    )
    isempty(q) && throw(ArgumentError("q, I and σ cannot be empty"))
    (all(isfinite, q) && all(isfinite, I) && all(isfinite, σ)) || throw(
        DomainError("non-finite", "q, I and σ must be finite"),
    )
    all(>(0), σ) || throw(DomainError(minimum(σ), "σ must be positive"))
    (isfinite(D) && D > 0) || throw(DomainError(D, "D must be positive and finite"))
    rebin === nothing || rebin ≥ 1 ||
        throw(
            DomainError(rebin, "rebin must be at least 1 (or nothing)"),
        )

    qr, ir, σr = Float64.(q), Float64.(I), Float64.(σ)
    k = rebin
    local qb, ib, σb, bin, nNonpositive
    for _ in 1:64
        qb, ib, σb, bin, nNonpositive = _binAndKeep(qr, ir, σr, D, k, dropNonpositive)
        k === nothing && break
        ratio = (π^2 / (96 * k^2)) / minimum(σb ./ ib)
        ratio ≤ maxBinBias && break
        # the bound falls as 1/k² (and faster, since finer bins hold fewer
        # points and so have larger errors): jump to the k that meets it, and
        # fit the curve as measured once the bins are as fine as its points
        k =
            length(qb) ≥ 0.9 * length(qr) ? nothing :
            max(k + 1, ceil(Int, k * sqrt(ratio / maxBinBias)))
    end
    # bins finer than the points, reached only by
    # raising a coarser request: nothing left to average
    if k !== nothing && k != rebin && length(qb) ≥ length(qr)
        qb, ib, σb, bin, nNonpositive =
            _binAndKeep(qr, ir, σr, D, nothing, dropNonpositive)
        k = nothing
    end

    l = lMax === nothing ? autoLmax(D, maximum(qb)) : Int(lMax)
    return ShannonInfo(
        Float64(D),
        l,
        k === nothing ? 0 : Int(k),
        (maximum(qb) - minimum(qb)) * D / π,
        qr,
        ir,
        σr,
        qb,
        ib,
        σb,
        bin,
        nNonpositive,
    )
end

"""
Worst-case bias of the binning against the precision of the binned points,
as a fraction of the smallest binned relative error.

A binned point is the mean of the curve over a bin of width `Δq = π/(rebin·D)`,
not its value at the bin's mean q; the relative difference is about `(Δq²/24)·|I″/I|`.
For a particle of diameter `D`, `I(q)` is the Fourier transform of a function supported
on `[0, D]`, so `|I″/I| ≤ (D/2)²` and the bias is at most `π²/(96·rebin²)` whatever the
size (a typical protein is several times smoother). Dividing by the smallest `σ/I` of
the binned curve says whether the bias can matter; [`shannonData`](@ref) makes the bins
finer until the ratio is at most [`BIN_BIAS_MAX`](@ref).

# Returns
- `Float64`: the ratio; `NaN` when the data was not binned.
"""
function binBiasRatio(info::ShannonInfo)::Float64
    info.rebin == 0 && return NaN
    return (π^2 / (96 * info.rebin^2)) / minimum(info.σ ./ info.I)
end
