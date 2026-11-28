# SPDX-License-Identifier: LGPL-3.0-or-later

using StatsBase: autocor

"""
The Wald–Wolfowitz runs-test z-score of a two-valued sequence `x`: with `n₁` true and `n₂`
false values of `n`, the expected number of runs is `μ = 1 + 2 n₁ n₂ / n` with variance
`(μ - 1)(μ - 2)/(n - 1)`, and `z = (runs - μ)/σ`.

# Returns
The z-score (`NaN` when `x` has a single value: `μ = 1` and `σ = 0`).

# Exceptions
None.
"""
function _runsZ(x::AbstractVector{Bool})::Float64
    n = length(x)
    n₁ = count(x)
    μ = 1 + 2 * n₁ * ((n - n₁) / n)
    σ = sqrt((μ - 1) * (μ - 2) / (n - 1))
    runs = 1 + count(k -> x[k] != x[k+1], 1:(n-1))
    return (runs - μ) / σ
end

"""
Whether normalized residuals `r = (I - model)/σ`
are white, as the likelihood assumes.

# Returns
A named tuple:
- `lag1`: the lag-1 autocorrelation `Σ rᵢrᵢ₊₁ / Σ rᵢ²`; ≈ 0 ± 1/√n for white residuals.
- `runsZ`: Wald–Wolfowitz runs-test z-score of the residual signs; ≈ N(0,1) for white
    residuals, strongly negative     when residuals come in long same-sign runs
    (`NaN` if all residuals have one sign).
"""
function residualStructure(r::AbstractVector{<:Real})
    length(r) ≥ 3 || throw(ArgumentError("residualStructure: need at least 3 residuals"))
    lag1 = all(iszero, r) ? 0.0 : autocor(r, [1]; demean = false)[1] # Σ rᵢrᵢ₊₁ / Σ rᵢ²
    return (; lag1, runsZ = _runsZ(r .> 0)) # runs of the residual signs
end
