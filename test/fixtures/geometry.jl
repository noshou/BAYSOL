# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared point-cloud geometry for tests that need a real 3D atom arrangement
# rather than a hand-picked handful of coordinates.

"""
    sph(R, n) -> Vector{NTuple{3,Float64}}

`n` points on a sphere of radius `R`, via the Fibonacci/golden-angle spiral
(near-uniform coverage, no clustering at the poles). Used to build a sealed
shell of atoms around an enclosed void.

# Arguments
- `R`: sphere radius.
- `n`: point count.
"""
sph(R, n) = [(R * sqrt(1 - z^2) * cos(t), R * sqrt(1 - z^2) * sin(t), R * z)
             for (z, t) in ((-1 + 2(k - 0.5) / n, π * (1 + sqrt(5)) * k) for k in 1:n)]
