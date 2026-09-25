# SPDX-License-Identifier: LGPL-2.1-or-later

# Weighted least squares for the two instrumental parameters scale,
# bkgrnd_corr in
#
#     I_calc(q) = scale · I(q) + bkgrnd_corr
#
# scale is the overall scale between the absolute model intensity and the
# detector's arbitrary units; bkgrnd_corr is a flat background from
# imperfect buffer subtraction. At a fixed geometry / contrast the model
# curve y_model = I(q; θ) is known and I_calc is linear in (scale,
# bkgrnd_corr), so this is one 2-parameter weighted linear regression of
# I_obs on [y_model, 1] with wᵢ = 1/σᵢ².
#

"Raised by [`wls_fit`](@ref) on invalid input or a degenerate (flat-model) fit."
struct WLSError <: Exception
    msg::String
end
Base.showerror(io::IO, e::WLSError) = print(io, "WLSError: ", e.msg)

"""
    WLSFit{T}

Result of [`wls_fit`](@ref): the fitted I_calc(q) = scale·y_model(q) +
bkgrnd_corr plus everything needed for uncertainty propagation and for
using the fit as a (profiled or marginalised) Gaussian log-likelihood term.

# Fields
    - `scale, bkgrnd_corr`: the WLS point estimate.
    - `var_scale`, `var_bkgrnd_corr`, `cov_scale_bkgrnd_corr`: entries of the
    2×2 conditional covariance (XᵀWX)⁻¹. Multiply by
    [`reduced_chi2`](@ref)(f) for the σ-rescaled ("aposteriori") version.
    var_scale → ∞ is the signal that the scale/bkgrnd_corr fit is
    near-degenerate.
    - `chi2`: weighted residual sum of squares at the optimum, i.e. χ².
    See [`reduced_chi2`](@ref) for the χ²/dof goodness-of-fit diagnostic
    built from this and dof.
    - `dof`: n − 2.
    - `det_XtWX`: det(XᵀWX) = SwII·Sw − SwI², the normalising determinant. Enters
    [`wls_marg_ll`](@ref); depends on the forward-model parameters through
    y_model.
    - `sum_log_var`: Σ log σᵢ², the data-only constant of the Gaussian.
"""
struct WLSFit{T}
    scale::T
    bkgrnd_corr::T
    var_scale::T
    var_bkgrnd_corr::T
    cov_scale_bkgrnd_corr::T
    chi2::T
    dof::Int
    det_XtWX::T
    sum_log_var::T
end

"""
    wls_fit(y_model, I_obs, σ) -> WLSFit

Fit scale, bkgrnd_corr in I_calc(q) = scale·y_model(q) + bkgrnd_corr by
weighted least squares with weights wᵢ = 1/σᵢ²: minimise
Σ wᵢ (I_obs(qᵢ) − scale·y_model(qᵢ) − bkgrnd_corr)².

One O(n) pass builds the six weighted sums:

    [SwII  SwI] [scale      ]   [SwIy]
    [SwI   Sw ] [bkgrnd_corr] = [Swy ]

then gives scale, bkgrnd_corr, the conditional covariance (XᵀWX)⁻¹, and
χ² = Swyy − scale·SwIy − bkgrnd_corr·Swy.

# Arguments
    - `y_model::AbstractVector`: the forward-model curve I(q; θ); may carry
    ForwardDiff.Duals.
    - `I_obs::AbstractVector`: measured intensity, same length.
    - `σ::AbstractVector`: per-point standard errors, same length, all > 0.

n = length(y_model) ≥ 3 (two parameters plus a residual).

# Returns
- [`WLSFit`](@ref), eltype promoted from the three inputs.

# Throws
    - [`WLSError`](@ref) on a length mismatch, n < 3, a non-positive σ, or det(XᵀWX) ≤ 0.
"""
function wls_fit(y_model::AbstractVector, I_obs::AbstractVector, σ::AbstractVector)::WLSFit
    n = length(y_model)
    (length(I_obs) == n && length(σ) == n) || throw(WLSError(
        "y_model, I_obs, σ must have equal length; got $n, $(length(I_obs)), $(length(σ))"))
    n ≥ 3 || throw(WLSError("need n ≥ 3 points for a 2-parameter fit with a residual; got n = $n"))

    T = promote_type(eltype(y_model), eltype(I_obs), eltype(σ))

    Sw   = zero(T) # Σ wᵢ
    SwI  = zero(T) # Σ wᵢ y_modelᵢ
    SwII = zero(T) # Σ wᵢ y_modelᵢ²
    Swy  = zero(T) # Σ wᵢ I_obsᵢ
    SwIy = zero(T) # Σ wᵢ y_modelᵢ I_obsᵢ
    Swyy = zero(T) # Σ wᵢ I_obsᵢ²
    
    sum_log_var = zero(T)
    
    @inbounds for i in 1:n
        σi = σ[i]
        σi > 0 || throw(WLSError("σ[$i] = $σi is not positive"))
        wi = inv(σi * σi)
        xi = y_model[i]
        yi = I_obs[i]
        Sw += wi
        SwI += wi * xi
        SwII += wi * xi * xi
        Swy += wi * yi
        SwIy += wi * xi * yi
        Swyy += wi * yi * yi
        sum_log_var += 2 * log(σi)
    end

    det_XtWX = SwII * Sw - SwI * SwI
    det_XtWX > 0 || throw(WLSError(
        "det(XᵀWX) ≤ 0: y_model is flat across the q-window, so scale is not determined"))

    scale = (Sw * SwIy - SwI * Swy) / det_XtWX
    bkgrnd_corr = (SwII * Swy - SwI * SwIy) / det_XtWX

    # (XᵀWX)⁻¹ = [Sw -SwI; -SwI SwII] / det.
    var_scale = Sw / det_XtWX
    var_bkgrnd_corr = SwII / det_XtWX
    cov_scale_bkgrnd_corr = -SwI / det_XtWX

    # χ² at the optimum: Σ w r² collapses to Swyy − scale·SwIy − bkgrnd_corr·Swy
    # once the above equations hold. Same "difference of large sums" as det;
    # floor the last-ulp dip a near-perfect fit can produce.
    chi2 = max(zero(T), Swyy - scale * SwIy - bkgrnd_corr * Swy)

    return WLSFit{T}(
        scale, 
        bkgrnd_corr, 
        var_scale, 
        var_bkgrnd_corr, 
        cov_scale_bkgrnd_corr, 
        chi2, 
        n - 2, 
        det_XtWX, 
        sum_log_var
    )
end

"""
    predict(f::WLSFit, y_model) -> Vector

The fitted I_calc = f.scale .* y_model .+ f.bkgrnd_corr, on the same curve
or a fresh one.
"""
wls_predict(f::WLSFit, y_model::AbstractVector) = f.scale .* y_model .+ f.bkgrnd_corr

"""
    reduced_chi2(f::WLSFit) -> Real

χ²/dof. A diagnostic, not a likelihood: should land ≈ 1 when both the
per-point σᵢ and the model are right; well above 1 signals an underestimated
σ or a poor model, well below 1 an overestimated σ.
"""
reduced_chi2(f::WLSFit) = f.chi2 / f.dof

"""
    wls_prof_ll(f::WLSFit) -> Real

Log-likelihood of the data with (scale, bkgrnd_corr) fixed at their WLS
optimum (the profile likelihood):

    -½ χ² - ½ Σ log σᵢ² - ½ n log 2π

Use when (scale, bkgrnd_corr) are treated as plugged-in point estimates. Positive
log-likelihood (not negative) so it composes by addition with the
Distributions.logpdf prior terms in the rest of the log-posterior, with no
sign to keep track of at the call site.
"""
wls_prof_ll(f::WLSFit) =
    -(f.chi2 + f.sum_log_var) / 2 - (f.dof + 2) * log(2π) / 2

"""
    wls_marg_ll(f::WLSFit) -> Real

Log marginal-likelihood with (scale, bkgrnd_corr) integrated out under a flat prior:

    wls_prof_ll(f) - ½ log det(XᵀWX) + ½ p log 2π ,   p = 2

Add this to the rest of the stage-1 log-posterior so that scale / background
uncertainty propagates into the posterior on the geometry and contrast
parameters instead of being frozen at a point. Only χ² and log det(XᵀWX)
depend on the forward-model parameters; everything else is a constant the sampler
may drop.
"""
wls_marg_ll(f::WLSFit) =
    wls_prof_ll(f) - log(f.det_XtWX) / 2 + log(2π)
