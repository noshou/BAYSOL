# SPDX-License-Identifier: LGPL-2.1-or-later
# dro in crysol is contrast density of the water hydration layer
# crysol sets the parameters as dr1=dr2=1.0 and dr3=0 by default,
# where: dr1/dr2 are convex/concave water beads and dr3 are cavity water beads.
#
# - dro3: Cavity water beads can be denser *or* sparser than surrounding water bulk density,
# depending on if the cavity is hydrophobic or hydrophilic. Chosen a standard normal distribution,
# with a mean of the total electronegativity and standard deviation.
#
# - dro1: shows that for Protein, convex beads are ~15% denser on the surface.
# A log-normal distribution with μ_ln = 0 (median ρ = 1, matching CRYSOL's canonical default exactly) has
# the mean comes out above 1 purely from the right-skew, and tune σ_ln so that skew lands the mean at 1.15.
# CRYSOL's default is the typical convex bead, and the empirical "15% denser" finding is explained as the mean
# being pulled up by the right tail (a few very dense convex patches)
#
# - dro2: can be positive or negative, but mostly positive. A normal distribution centered at 1 is chosen.
#
# - dro4: specific for nucleotides for cation condensation. Requires total counterion valence z, total ionic strength I,
# uncertainty in ionic strength σ_I, and the Manning linear charge density ξ with uncertainty σ_ξ.
using Distributions

# median ρ = 1 (μ_ln = 0), and σ_ln chosen so the mean lands at 1.15:
#   mean = exp(μ_ln + σ_ln²/2) = exp(σ_ln²/2) = 1.15  =>  σ_ln = √(2·ln(1.15))
const _dro1_prior = LogNormal(0.0, sqrt(2 * log(1.15)))

const _dro2_prior = Normal(1, 0.15)

"""
    dro_prior(μ_χ, σ_χ) -> (dro1, dro2, dro3)

Protein variant.

# Arguments
- `μ_χ`: mean of the total electronegativity χ, feeding dro3's cavity-water contrast.
- `σ_χ`: standard deviation of χ, feeding dro3's cavity-water contrast.

# Returns
- `dro1::LogNormal`: convex-bead contrast (fixed prior, `_dro1_prior`).
- `dro2::Normal`: concave-bead contrast (fixed prior, `_dro2_prior`).
- `dro3::Normal`: cavity-water contrast, `Normal(μ_χ, σ_χ)`.
"""
function dro_prior(μ_χ::Real, σ_χ::Real)::Tuple{LogNormal, Normal, Normal}
    return (_dro1_prior, _dro2_prior, Normal(μ_χ, σ_χ))
end

# """
#     dro_prior(μ_χ, σ_χ, z, I, σ_I, ξ, σ_ξ) -> (dro1, dro2, dro3, dro4)

# Nucleotide variant: dro1, dro2, dro3 as in the protein variant, plus dro4 for
# cation condensation around the phosphate backbone (Manning theory).

# # Arguments
# - `μ_χ`: mean of the total electronegativity χ, feeding dro3's cavity-water contrast.
# - `σ_χ`: standard deviation of χ, feeding dro3's cavity-water contrast.
# - `z`:   total counterion valence.
# - `I`:   total ionic strength.
# - `σ_I`: uncertainty in ionic strength.
# - `ξ`:   Manning linear charge density parameter.
# - `σ_ξ`: uncertainty in ξ.

# # Returns
# - `dro1::LogNormal`: convex-bead contrast (fixed prior, `_dro1_prior`).
# - `dro2::Normal`: concave-bead contrast (fixed prior, `_dro2_prior`).
# - `dro3::Normal`: cavity-water contrast, `Normal(μ_χ, σ_χ)`.
# - `dro4::LogNormal`: condensed-cation-layer contrast, derived from `z`, `I`, `σ_I`, `ξ`, `σ_ξ`.
# """
# function dro_prior(
#     μ_χ::Real, 
#     σ_χ::Real, 
#     z::Real, 
#     I::Real, 
#     σ_I::Real, 
#     ξ::Real, 
#     σ_ξ::Real
# )::Tuple{LogNormal, Normal, Normal, LogNormal}
# end