# SPDX-License-Identifier: LGPL-3.0-or-later

#-------------------------
# Constants for BAYSOL.jl 
#-------------------------

"""
"lo-hi" empirical quantile range (integer percentages, 0 ≤ lo < hi ≤ 100) 
used to build "quantiles"/"bounds" entries. The default "16-84" is a ±1σ-equivalent interval for a Normal. The special
case "0-0" means *no* filtering.
"""
const DEFAULT_QUANTILES = "16-84"
