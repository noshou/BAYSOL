# SPDX-License-Identifier: LGPL-2.1-or-later

#--------------------
# Physical Constants 
#--------------------

"Avogadro constant, mol⁻¹ (CODATA, exact since the 2019 SI redefinition)."
const AVOGADRO = 6.02214076e23

"Molar mass of H₂O, g·mol⁻¹ (IAPWS-95 value)."
const WATER_MOLAR_MASS = 18.015268

"Electrons per H₂O molecule (2 from H, 8 from O)."
const WATER_ELECTRONS = 10

"Å³ per litre: 1 L = 10⁻³ m³ = 10²⁷ Å³."
const ANGSTROM3_PER_LITER = 1e27

"cm³ per litre."
const CM3_PER_LITER = 1e3

"""
Default solution temperature, °C, for _ρₑ/[`Fitting.ρₑ_prior`](@ref BAYSOL.Fitting.ρₑ_prior)'s bulk-electron
-density calculation. Pass the sample's real temperature instead whenever it is
known: water's density is evaluated at it exactly, and the solutes' 25 °C
partial molar volumes get a widened uncertainty (see [`PMV_FRACTIONAL_EXPANSIBILITY`](@ref)).
"""
const DEFAULT_TEMPERATURE_C = 25.0

"""
Temperature, °C, at which the bundled partial-molar-volume tables are tabulated
(see PartialMolarVolumes/README.md: 298.15 K unless a source says otherwise).
"""
const PMV_REFERENCE_TEMPERATURE_C = 25.0

"""
Fractional partial-molar-volume expansibility, K⁻¹: an upper bound on
(∂ϕ°/∂T)/ϕ° used to widen a solute's 25 °C ϕ° uncertainty when the sample is at
another temperature, σ_T = PMV_FRACTIONAL_EXPANSIBILITY · ϕ° · |t - 25|.

Derived from the multi-temperature series bundled with the tables
(15-35 °C: sugars, ureas and glycolurils in sources/extracted_pmv_candidates.tsv;
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

"""
Peptide backbone unit (-CH2CONH-, neutral, C2H3NO) electron count:
2×C(6) + 3×H(1) + N(7) + O(8) = 30 e. Added once per residue on the same basis
as [`BACKBONE_PMV`](@ref); Protein.json's electron_count field is a
side-chain-only increment relative to glycine.
"""
const BACKBONE_ELECTRONS = 30
