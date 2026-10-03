# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Default absolute tolerance for floating-point equality checks
(abs(a - b) < DEFAULT_ATOL, or isapprox(a, b; atol = DEFAULT_ATOL)):
a few orders of magnitude above Float64 roundoff.
"""
const DEFAULT_ATOL = 1.0e-9
