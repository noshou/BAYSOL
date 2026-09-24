# SPDX-License-Identifier: LGPL-2.1-or-later

# CRYSOL-style per-atom "displaced solvent volume" (Å³), for the
# excluded-volume dummy species, **not** a physical atomic size. Bonded
# atoms overlap heavily, so an isolated van der Waals sphere
# (`AtomicRadii`/`sphere_volume`) overcounts the volume a bonded atom
# actually displaces from the bulk solvent by roughly 50%. Fraser, MacRae &
# Suzuki (1978) fit a small per-element-type volume instead, calibrated
# against observed partial molar volumes rather than isolated-atom geometry;
# CRYSOL (Svergun, Barberato & Koch, 1995) adopted the same values (its
# Table 1) for its own dummy-atom excluded-volume term.
#
#
# ---- Sources ---------------------------------------------------------------
#
# - Fraser, R.D.B.; MacRae, T.P.; Suzuki, E. (1978). "An improved method for
#   calculating the contribution of solvent to the X-ray diffraction pattern
#   of biological molecules." J. Appl. Cryst. 11, 693-694.
#   DOI 10.1107/S0021889878014296. Original source of the H/C/N/O displaced
#   volumes.
# - Svergun, D.; Barberato, C.; Koch, M.H.J. (1995). "CRYSOL -- a Program to
#   Evaluate X-ray Solution Scattering of Biological Macromolecules from
#   Atomic Coordinates." J. Appl. Cryst. 28, 768-773.
#   DOI 10.1107/S0021889895007047. Table 1 is the table transcribed below
#   (`nm³` converted to `Å³`, `1 nm³ = 1000 Å³`); its own footnotes are the
#   "Verified vs. approximated" split above.
# - International Tables for X-ray Crystallography (1968), Vol. III,
#   Birmingham: Kynoch Press. Source of the S/P/metal radii CRYSOL's Table 1
#   uses (see above); not independently consulted here, only as CRYSOL cites
#   it.
# - Chatzimagas, L.; Hub, J.S. (2022). "Predicting solution scattering
#   patterns with explicit-solvent molecular simulations." arXiv:2204.04961.
#   Its Table 1 independently reproduces the same Fraser et al. (1978) H/C/N/O
#   values used here (5.15/16.44/2.49/9.13 Å³) alongside the Pontius et al.
#   (1996) Voronoi-tessellation alternative.

using ..AtomicRadii: tryparse_ion
# using NearestNeighbors: inrange   # only used by the commented-out _excluded_vol below

"""
Bare-atom/bare-element CRYSOL (1995) Table 1 displaced solvent volume, Å³,
keyed by lowercase element symbol.
"""
const EXCLUDED_VOLUME_TABLE = Dict{String,Float64}(
    "h"  => 5.15,   # Fraser, MacRae & Suzuki (1978), via CRYSOL (1995) Table 1, row `H*`
    "c"  => 16.44,  # Fraser, MacRae & Suzuki (1978), via CRYSOL (1995) Table 1, row `C*`
    "n"  => 2.49,   # Fraser, MacRae & Suzuki (1978), via CRYSOL (1995) Table 1, row `N*`
    "o"  => 9.13,   # Fraser, MacRae & Suzuki (1978), via CRYSOL (1995) Table 1, row `O*`
    "s"  => 19.86,  # CRYSOL (1995) Table 1, row `S`; sphere volume of the Int'l Tables (1968)
                    # covalent-ish radius (0.168 nm), not an independent Fraser-style measurement
    "p"  => 5.73,   # CRYSOL (1995) Table 1, row `P`; radius 0.111 nm; same caveat as `s`
    "mg" => 17.16,  # CRYSOL (1995) Table 1, row `Mg`; radius 0.160 nm; same caveat as `s`
    "ca" => 31.89,  # CRYSOL (1995) Table 1, row `Ca`; radius 0.197 nm; same caveat as `s`
    "mn" => 9.20,   # CRYSOL (1995) Table 1, row `Mn`; radius 0.130 nm; same caveat as `s`
    "fe" => 7.99,   # CRYSOL (1995) Table 1, row `Fe`; radius 0.124 nm; same caveat as `s`
    "cu" => 8.78,   # CRYSOL (1995) Table 1, row `Cu`; radius 0.128 nm; same caveat as `s`
    "zn" => 9.85,   # CRYSOL (1995) Table 1, row `Zn`; radius 0.133 nm; same caveat as `s`
)

"""
Elements for which a charge-suffixed ion string (e.g. `"fe3+"`) still resolves
through [`EXCLUDED_VOLUME_TABLE`](@ref) by its bare element, in
[`excluded_volume`](@ref).
"""
const _ION_FALLTHROUGH_ELEMENTS = Set(("mg", "ca", "mn", "fe", "cu", "zn"))

"""
    excluded_volume(element::AbstractString, vdw_radius::Real) -> Float64

Per-atom CRYSOL-style excluded (displaced-solvent) volume in Å³: the table
value from [`EXCLUDED_VOLUME_TABLE`](@ref) for a covered element, else the
isolated van der Waals sphere volume of `vdw_radius` (today's pre-fix
behaviour) as a documented fallback for elements with no verified displaced-
volume data (halogens, alkali metals, noble gases, and any other element not
in the table).

A charge-suffixed ion string of one of the six covered metals (e.g.
`"fe3+"`, `"zn2+"`) is parsed via [`AtomicRadii.tryparse_ion`](@ref) and
looked up by its bare element, so every oxidation state of a covered metal is
covered exactly like the neutral atom.

# Arguments
- `element::AbstractString`: lowercase element/ion string, e.g. `"c"`,
    `"fe3+"`.
- `vdw_radius::Real`: this atom's van der Waals radius in Å (`>= 0`), i.e.
    `radii(mol)[i]`, used only as the fallback sphere radius.

# Returns
- `Float64`: excluded volume in Å³, `>= 0`.
"""
function excluded_volume(element::AbstractString, vdw_radius::Real)::Float64
    v = get(EXCLUDED_VOLUME_TABLE, element, nothing)
    if v === nothing
        ion = tryparse_ion(element)
        if ion !== nothing && ion.element in _ION_FALLTHROUGH_ELEMENTS
            v = get(EXCLUDED_VOLUME_TABLE, ion.element, nothing)
        end
    end
    return v === nothing ? sphere_volume(Float64(vdw_radius)) : v
end


# WIP, incomplete (references an undefined `Mol` type and never assembles a
# return value) — commented out so the module loads; see git history for the
# in-progress radical-plane/power-diagram excluded-volume algorithm this was
# building toward (10.1016/j.bpj.2023.10.034).
#
# """
# Algorithm adapted from 10.1016/j.bpj.2023.10.034
# """
# function _excluded_vol(mol::Mol)::Bool
#     xyz_ = coords_cartesian(mol)
#     tree = neighbour_tree(mol)
#     rmax = r_max(mol)
#     rads = radii(mol)
#     elem = elms(mol)
#
#     i = 1
#
#     # returns: [(name, vol)]
#
#     # iterate over columns for each atom coord
#     for (x, y, z) in eachcol(xyz_)
#
#         p_i = [x,y,z]
#
#         # candidate list of all possible overlapping radii.
#         # Radii can overlap when: d_ij < r_i + r_j, and since
#         # r_j <= r_max; d_ij < r_i + r_j <= r_i + r_max
#         candidates = inrange(tree, p_i, rads[i] + rmax)
#
#         # For atoms of unequal radius, a simple midpoint Voronoi boundary
#         # does not correctly partition their shared region. The radical plane
#         # provides the radius-weighted (power-diagram) boundary between atoms
#         # i and j.
#         #
#         # Atom i's contribution is the part of its vdW sphere that lies on
#         # i's side of every relevant radical plane:
#         #
#         #   S_i = {x : |x - p_i| <= r_i
#         #             and power_i(x) <= power_j(x) for every j}
#         #
#         # where:
#         #
#         #   power_k(x) = |x - p_k|² - r_k²
#         #
#         # Rather than evaluating the power functions for every point x, the
#         # equivalent radical-plane test can be evaluated with a dot product.
#         #
#         # For neighbour j:
#         #
#         #   d = |p_j - p_i|
#         #   n = (p_j - p_i) / d
#         #   plane_dist = (d² + r_i² - r_j²) / (2d)
#         #
#         # A point x belongs to atom i's side of the plane when:
#         #
#         #   dot(x - p_i, n) <= plane_dist
#         for c in candidates
#
#             # distance between candidate and target
#             p_j = [xyz_[1][c], xyz_[2][c], xyz_[3][c]]
#             dst = sqrt(sum((p_i .- p_j) .^ 2))
#
#
#             # # discard x if it lies beyond the radical plane
#             # if dot(x .- p_i, n) > plane_dist
#             #     continue
#             # end
#
#             # skip self
#             if dst == 0
#                 continue
#             end
#
#             # only actual overlaps matter
#             if dst >= rads[i] + rads[c]
#                 continue
#             end
#
#             # calculate distance to radical plane
#             plane_dist = (dst^2 + rads[i]^2 - rads[c]^2) / (2 * dst)
#
#             # unit vector from i to j
#             n = (p_j .- p_i) ./ dst
#
#         end
#
#         i+=1
#
#     end
# end
