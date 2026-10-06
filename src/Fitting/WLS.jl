# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Weighted least squares for the two instrumental parameters scale,
`bkgrnd_corr` in

    I_calc(q) = scale · I(q) + bkgrnd_corr

The measured data `I_obs` and σ are fixed during inference, so all
data-only weighted sums are precomputed in WLSData. The hot-path
`wls_fit`(`y_model`, data) therefore only needs three weighted reductions:

    SwI  = Σ wᵢ y_modelᵢ
    SwII = Σ wᵢ y_modelᵢ²
    SwIy = Σ wᵢ y_modelᵢ I_obsᵢ

Sw, Swy, Swyy, and Σ log σᵢ² are all data-only.
"""

"Raised by [`wls_fit`](@ref) on invalid input or a degenerate (flat-model) fit."
struct WLSError <: Exception
    msg::String
end

Base.showerror(io::IO, e::WLSError) = print(io, "WLSError: ", e.msg)


"""
Construct the precomputed weighted data used by [`wls_fit`](@ref).

`I_obs` and σ are assumed to remain unchanged for subsequent fits.
"""
function WLSData(
    I_obs::AbstractVector,
    σ::AbstractVector,
)
    n = length(I_obs)

    length(σ) == n || throw(WLSError(
        "I_obs and σ must have equal length; got $n and $(length(σ))"))

    n ≥ 3 || throw(WLSError(
        "need n ≥ 3 points for a 2-parameter fit with a residual; got n = $n"))

    T = promote_type(eltype(I_obs), eltype(σ))

    weights = similar(I_obs, T)

    Sw = zero(T)
    Swy = zero(T)
    Swyy = zero(T)
    sum_log_var = zero(T)

    @inbounds for i in 1:n
        σi = σ[i]
        σi > 0 || throw(WLSError(
            "σ[$i] = $σi is not positive"))

        yi = I_obs[i]
        wi = inv(σi * σi)

        weights[i] = wi

        Sw += wi
        Swy += wi * yi
        Swyy += wi * yi * yi
        sum_log_var += 2 * log(σi)
    end

    return WLSData(
        I_obs,
        weights,
        Sw,
        Swy,
        Swyy,
        sum_log_var,
    )
end


"""
Fit scale and `bkgrnd_corr` in

    I_calc(q) = scale·y_model(q) + bkgrnd_corr

using precomputed [`WLSData`](@ref).

This is the NUTS hot-path implementation. Since the measured data and
uncertainties are already preprocessed, only the three model-dependent
weighted sums are calculated here.
"""
function wls_fit(
    y_model::AbstractVector,
    data::WLSData,
)::WLSFit
    n = length(y_model)
    n == length(data.I_obs) || throw(WLSError(
        "y_model and WLSData must have equal length; got $n and $(length(data.I_obs))"))

    T = promote_type(eltype(y_model), typeof(data.Sw))

    SwI  = zero(T)
    SwII = zero(T)
    SwIy = zero(T)

    I_obs = data.I_obs
    weights = data.weights

    @inbounds @fastmath @simd for i in 1:n
        wi = weights[i]
        xi = y_model[i]
        yi = I_obs[i]

        SwI += wi * xi
        SwII += wi * xi * xi
        SwIy += wi * xi * yi
    end

    return _wls_from_sums(SwI, SwII, SwIy, n, data)
end

"""
The closed-form weighted least-squares fit behind [`wls_fit`](@ref), from the three
model-dependent sums Σwᵢyᵢ, Σwᵢyᵢ², Σwᵢyᵢ·Iᵢ (y = `y_model`, I = `I_obs`) and the
data-only sums in `data`. Shared with the c1 search in [`profiled_corrs`](@ref), which
gets those sums without forming `y_model`.

# Arguments
- `SwI`, `SwII`, `SwIy`: the three model-dependent weighted sums.
- `n::Int`: number of data points.
- `data::WLSData`: the data-only sums.

# Returns
- `WLSFit{T}`, T the promoted type of the sums and the data.

# Exceptions
- `WLSError`: det(XᵀWX) ≤ 0 (the model is flat across the q-window).
"""
function _wls_from_sums(SwI, SwII, SwIy, n::Int, data::WLSData)::WLSFit
    T = promote_type(typeof(SwI), typeof(SwII), typeof(SwIy), typeof(data.Sw))

    Sw = data.Sw
    Swy = data.Swy
    Swyy = data.Swyy

    det_XtWX = SwII * Sw - SwI * SwI

    det_XtWX > 0 || throw(WLSError(
        "det(XᵀWX) ≤ 0: y_model is flat across the q-window, so scale is not determined"))

    scale = (Sw * SwIy - SwI * Swy) / det_XtWX
    bkgrnd_corr = (SwII * Swy - SwI * SwIy) / det_XtWX

    chi2 = max(
        zero(T),
        Swyy - scale * SwIy - bkgrnd_corr * Swy,
    )

    return WLSFit{T}(
        scale,
        bkgrnd_corr,
        chi2,
        n - 2,
        det_XtWX,
        data.sum_log_var,
    )
end


"""
Convenience interface for a one-off weighted least-squares fit.

For repeated fits against the same data, construct `WLSData(I_obs, σ)`
once and use `wls_fit(y_model, data)` instead.
"""
function wls_fit(
    y_model::AbstractVector,
    I_obs::AbstractVector,
    σ::AbstractVector,
)::WLSFit
    return wls_fit(y_model, WLSData(I_obs, σ))
end


"""
The fitted `I_calc` = f.scale .* `y_model` .+ `f.bkgrnd_corr`.
"""
wls_predict(f::WLSFit, y_model::AbstractVector) =
    f.scale .* y_model .+ f.bkgrnd_corr


"""
χ²/dof.
"""
reduced_chi2(f::WLSFit) = f.chi2 / f.dof


"""
Profile log-likelihood with scale and background fitted at their WLS optimum.
"""
wls_prof_ll(f::WLSFit) =
    -(f.chi2 + f.sum_log_var) / 2 -
    (f.dof + 2) * log(2π) / 2


"""
Log marginal-likelihood with scale and background integrated out under
a flat prior.
"""
wls_marg_ll(f::WLSFit) = wls_prof_ll(f) - log(f.det_XtWX) / 2 + log(2π)