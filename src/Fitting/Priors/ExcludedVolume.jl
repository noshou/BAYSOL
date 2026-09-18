# SPDX-License-Identifier: LGPL-2.1-or-later

using Distributions
using SpecialFunctions

"""
    prior(n::Real) -> LogNormal

Log normal distribution over excluded volume correction factor c1. 

`c1 = r0/rm`, where CRYSOL puts the following bounds: `0.96 • r_m <= r_0 <= 1.04 • rm`.
In other words: 

    r0 ∈ [0.96rm, 1.04rm] 
    c1 ∈ [0.96, 1.04] 
    r0 = c1 • r_m

Assuming a normal distribution, if `n%` of samples fall within z standard deviations 
of CRYSOL's default, we have: 

    μ±z•σ = [0.96, 1.04] 

where `μ = 1`. The value of z (ie: the `z-score`) is: 
    
    √2•erf⁻¹(n/100) 
    
Given a constant `C = (1.04 − 0.96)/2` = 0.04: 

    σ = C / z 

Which when transformed into LogNormal space gives: 

    σ_ln = √(ln(1+σ²/μ²))
    μ_ln = ln(μ) − σ_ln²/2

Substituting `μ=1`:

    σ_ln = √(ln(1+σ²))
    μ_ln = -σ_ln²/2

# Keywords
    -n: percentage ((0, 100]) of the prior mass required to fall within
        CRYSOL's bound `[0.96, 1.04]` around its default `c1 = 1`. Higher `n` 
        concentrates more mass near the default; lower `n` allows more spread.
        Defaulted to `n = 95`; only change if more spread is needed.
"""
function c1_prior(n::Real=95)::LogNormal{Float64}
    
    if n <= 0 || n > 100 
        throw(DomainError(n, "n ∈(0, 100]"))
    end

    # calculate z score, σ
    z = sqrt(2) * erfinv(n/100)
    σ = 0.04 / z

    # calculate log transformations
    σ_ln = sqrt(log(1+σ^2))
    μ_ln = -σ_ln^2/2

    # return distribution
    return LogNormal(μ_ln, σ_ln)

end