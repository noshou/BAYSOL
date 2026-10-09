# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Partial molar volumes (V0, cm³/mol) and water bulk electron density.
"""
module PartialMolarVolumes

using  ..PhysicalConstants: AVOGADRO, WATER_MOLAR_MASS, WATER_DENSITY_UNCERTAINTY,
        WATER_ELECTRONS, ANGSTROM3_PER_LITER, CM3_PER_LITER,
        KELL_DENSITY_NUM, KELL_DENSITY_DEN, BACKBONE_ELECTRONS
using  ..Cache: KeyedCache
using  JSON3: JSON3
using  FastClosures: @closure
export ϕ°, ρₑ_w, COMMON_TO_IUPAC

using ..PhysicalConstants: STANDARD_TEMPERATURE_C

"""
Temperature, °C, at which the bundled partial-molar-volume tables are tabulated
(see PartialMolarVolumes/README.md: 298.15 K unless a source says otherwise): the
standard reference temperature,
[`STANDARD_TEMPERATURE_C`](@ref BAYSOL.Utils.PhysicalConstants.STANDARD_TEMPERATURE_C).
"""
const PMV_REFERENCE_TEMPERATURE_C = STANDARD_TEMPERATURE_C

"""
Fractional partial-molar-volume expansibility, K⁻¹: an upper bound on
(∂ϕ°/∂T)/ϕ° used to widen a solute's 25 °C ϕ° uncertainty when the sample is at
another temperature

    `σ_T` = `PMV_FRACTIONAL_EXPANSIBILITY` · ϕ° · |t − [`PMV_REFERENCE_TEMPERATURE_C`](@ref)|.

Derived from the multi-temperature series bundled with the tables
(15-35 °C: sugars, ureas and glycolurils in `sources/extracted_pmv_candidates.tsv`;
18-40 °C: Chalikian et al. 2001's nucleobases/nucleosides, 10.1016/S0301-4622(01)00200-9,
the `other-T` rows of nonbiological.tsv): across those 42 solutes the fractional
expansibility spans 0.44-2.96 × 10⁻³ K⁻¹ (median 0.82 × 10⁻³), so 3.0 × 10⁻³
covers every one of them. No electrolyte has multi-temperature data in the
tables, so this bound is unverified for salts.
"""
const PMV_FRACTIONAL_EXPANSIBILITY = 3.0e-3

"""
Peptide-bond backbone unit (-CH2CONH-, "glycyl") partial molar volume at 25 °C,
(value, uncertainty) in cm³·mol⁻¹, added once per residue by the protein PMV
backend. Protein.json's per-residue entries (A, V, L, ... and G's zero) are
side-chain-only increments relative to glycine (Lee et al. 2008's own
convention), not absolute residue volumes. Source: Protein.tsv CH2CONH row,
10.1039/9781782627043-00542.
"""
const BACKBONE_PMV = (37.4, 0.1)

# Water.jl first: _H2O_V0_25C below calls its _kell_density at load time.
include("Water.jl")

"Bulk water molar volume at the PMV reference temperature (25 °C), cm³·mol⁻¹,
from the same Kell equation as `ρₑ_w` (≈ 18.0686)."
const _H2O_V0_25C = WATER_MOLAR_MASS / _kell_density(PMV_REFERENCE_TEMPERATURE_C) * CM3_PER_LITER

""" Returns the partial molar volume at infinite dilution of a solute. """
function ϕ° end

include("Helpers.jl")
include("Protein.jl")
include("NonBio.jl")
include("Nucleotides.jl")

end # module PartialMolarVolumes
