# SPDX-License-Identifier: LGPL-2.1-or-later

#-------------------------
# Constants for BAYSOL.jl 
#-------------------------

"""
"lo-hi" empirical quantile range (integer percentages, 0 ≤ lo < hi ≤ 100) 
used to build "quantiles"/"bounds" entries. The default "16-84" is a ±1σ-equivalent interval for a Normal. The special
case "0-0" means *no* filtering.
"""
const DEFAULT_QUANTILES = "16-84"

"""
Default NUTS target acceptance rate, as a percentage in (0, 100), for
[`run_model`](@ref BAYSOL.run_model) / [`Fitting.run_fitting`](@ref BAYSOL.Fitting.run_fitting):
Stan's usual default of 80 %.
"""
const DEFAULT_TARGET_ACCEPT = 80
