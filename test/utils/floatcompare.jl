# SPDX-License-Identifier: LGPL-2.1-or-later

# Shared float-comparison helper with an explicit, per-call absolute tolerance.

"""
    close_(a, b; atol = DEFAULT_ATOL) -> Bool

Absolute-tolerance float compare. Floating-point tolerances are expressed in
units of `DEFAULT_ATOL` (`k * DEFAULT_ATOL`) so they all scale together; tests
summing many accumulated terms (residue-by-residue partial molar volumes, values
built from several chained physical formulas) pass a larger multiple.
Requires `DEFAULT_ATOL` in scope (testsetup.jl provides it).
"""
close_(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol
