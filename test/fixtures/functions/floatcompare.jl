# SPDX-License-Identifier: LGPL-2.1-or-later

# Shared float-comparison helper for tests that need an explicit, looser
# absolute tolerance than runtests.jl's own `check_float`.

"""
    close_(a, b; atol = 1.0e-9) -> Bool

Absolute-tolerance float compare with an explicit `atol`. `check_float` from
`runtests.jl` pins a fixed `DEFAULT_ATOL` that is too tight for tests summing
across many accumulated terms (e.g. residue-by-residue partial molar volumes,
or values built from several chained physical formulas), so those files use
this looser, locally-tunable comparison instead.
"""
close_(a, b; atol = 1.0e-9) = abs(a - b) < atol
