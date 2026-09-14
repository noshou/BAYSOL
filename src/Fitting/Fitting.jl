# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Statistics layer on top of the `Scattering` forward model: given a measured
curve, recover the parameters that produced it and their uncertainty.

# Module layout

- `WLS` — weighted least squares for the instrumental scale/background pair
  `(m, c)` in `I_calc(q) = m·I(q) + c`: [`wls_fit`](@ref), the [`WLSFit`](@ref)
  result, [`predict`](@ref), and [`profiled_nll`](@ref) / [`marginal_nll`](@ref)
  for using the fit as a (plugged-in or marginalised) Gaussian likelihood term.
"""
module Fitting

# `WLS.jl` is a plain include (no submodule); its names land directly here.
include("WLS.jl")

export WLSError, WLSFit, wls_fit, predict, profiled_nll, marginal_nll

end # module
