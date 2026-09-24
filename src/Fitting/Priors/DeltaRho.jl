# SPDX-License-Identifier: LGPL-2.1-or-later

# Delta rho (dro) in CRYSOL is change in electron density at the surface hydration layer.
# CRYSOL sets the parameters as δρ1=δρ2=1.0 and δρ3=0 by default,
# where: δρ1/δρ2 are convex/concave water beads and δρ1 are cavity water beads.
#
# - δρ1: shows that for Protein, convex beads are ~15% denser on the surface.
# Source: Merzel & Smith, "Is the first hydration shell of lysozyme of higher
# density than bulk water?", PNAS 99(8):5378-5383 (2002), doi:10.1073/pnas.082335099.
# MD simulation explaining the SAS/SANS measurement of Svergun et al., PNAS
# 95:2267-2272 (1998): the 3-A-thick first hydration layer averages ~15%
# denser than bulk, integrated over 0-3 A from the protein surface.
# A log-normal distribution with μ_ln = 0 (median ρ = 1, matching CRYSOL's canonical default exactly) has
# the mean comes out above 1 purely from the right-skew, and tune σ_ln so that skew lands the mean at 1.15.
# CRYSOL's default is the typical convex bead, and the empirical "15% denser" finding is explained as the mean
# being pulled up by the right tail (a few very dense convex patches)
#
# - δρ2: can be positive or negative, but mostly positive. A normal distribution centred at 1 is chosen.
#
# - δρ3: Cavity water beads can be denser *or* sparser than surrounding water bulk density, depending
#        on the net charge of the cavity.
# 
# !!NOT IMPLEMENTED YET!!
# - δρ4: specific for nucleotides for cation condensation. Requires total counterion valence z, 
# total ionic strength I, # uncertainty in ionic strength σ_I, and the Manning linear charge density ξ with 
# uncertainty σ_ξ.

using Distributions

# median ρ = 1 (μ_ln = 0), and σ_ln chosen so the mean lands at 1.15:
#mean      = exp(μ_ln + σ_ln²/2) = exp(σ_ln²/2) = 1.15  =>  σ_ln = √(2·ln(1.15))
const _δρ1_prior = LogNormal(0.0, sqrt(2 * log(1.15)))

const _δρ2_prior = Normal(1, 0.15)

"""
    δρ_prior(; μ_χ, σ_χ) -> (δρ1, δρ2, δρ3)

Protein variant.

# Keywords
- `μ_χ`=0.0: mean, over cavity beads, of the screened-electrostatic potential χ
    (Debye-Hückel, aggregated from nearby phosphate / ionizable-side-chain charge
    sites — see [`BayeSol.Solvation.Electrostatics.nucleic_acid_cavity_electrostatics`](@ref) /
    [`BayeSol.Solvation.Electrostatics.protein_cavity_electrostatics`](@ref)), feeding δρ3's
    cavity-water contrast.
- `σ_χ`=0.0: standard deviation, over cavity beads, of χ, feeding δρ3's
    cavity-water contrast.

# Returns
- `δρ1::LogNormal`: convex-bead contrast (fixed prior, `_δρ1_prior`).
- `δρ2::Normal`:    concave-bead contrast (fixed prior, `_δρ2_prior`).
- `δρ3::Normal`:    cavity-water contrast, `Normal(μ_χ, σ_χ)`.
                    The default `μ_χ = 0, σ_χ = 0` is a point mass at 0,
                    matching standard CRYSOL's own `dr3 = 0` default.
"""
function δρ_prior(
    ; μ_χ::Real=0,
    σ_χ::Real=0.0
)::Tuple{LogNormal{Float64}, Normal{Float64}, Normal{Float64}}
    return (_δρ1_prior, _δρ2_prior, Normal(μ_χ, σ_χ))
end

# TODO: after validating w/ CRYSOL on proteins, move on to fitting w/ nucleotides.

# """
#     δρ_prior(μ_χ, σ_χ, z, I, σ_I, ξ, σ_ξ) -> (δρ1, δρ2, δρ3, δρ4)

# Nucleotide variant: δρ1, δρ2, δρ3 as in the protein variant, plus δρ4 for
# cation condensation around the phosphate backbone (Manning theory).

# # Arguments
# - `μ_χ`: mean of the total electronegativity χ, feeding δρ3's cavity-water contrast.
# - `σ_χ`: standard deviation of χ, feeding δρ3's cavity-water contrast.
# - `z`:   total counterion valence.
# - `I`:   total ionic strength.
# - `σ_I`: uncertainty in ionic strength.
# - `ξ`:   Manning linear charge density parameter.
# - `σ_ξ`: uncertainty in ξ.

# # Returns
# - `δρ1::LogNormal`: convex-bead contrast (fixed prior, `_δρ1_prior`).
# - `δρ2::Normal`: concave-bead contrast (fixed prior, `_δρ2_prior`).
# - `δρ3::Normal`: cavity-water contrast, `Normal(μ_χ, σ_χ)`.
# - `δρ4::LogNormal`: condensed-cation-layer contrast, derived from `z`, `I`, `σ_I`, `ξ`, `σ_ξ`.
# """
# function δρ_prior(
#     μ_χ::Real, 
#     σ_χ::Real, 
#     z::Real, 
#     I::Real, 
#     σ_I::Real, 
#     ξ::Real, 
#     σ_ξ::Real
# )::Tuple{LogNormal, Normal, Normal, LogNormal}
# end