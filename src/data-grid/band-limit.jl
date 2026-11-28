# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Spherical-harmonic band limit the forward model needs for
a particle of diameter `D` at momentum transfers up to
`qMax`: `ceil(qMax·D)`, the usual `q·D_max` multipole
resolution rule of thumb.

# Returns
- `Int`: the band limit, at least 1.

# Exceptions
- `DomainError`: `D` or `qMax` is not positive and finite.
"""
function autoLmax(D::Real, qMax::Real)::Int
    (isfinite(D) && D > 0) || throw(
        DomainError(
            D,
            "autoLmax: D must be positive and finite",
        ),
    )
    (isfinite(qMax) && qMax > 0) || throw(DomainError(
        qMax, "autoLmax: qMax must be positive and finite")
    )
    return max(1, ceil(Int, qMax * D))
end
