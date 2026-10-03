# SPDX-License-Identifier: LGPL-2.1-or-later

#--------------------
# Physical Constants 
#--------------------

"Avogadro constant, mol⁻¹ (CODATA, exact since the 2019 SI redefinition)."
const AVOGADRO = 6.02214076e23

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

Derived from the multi-temperature series already bundled with the tables
(15-35 °C: sugars, ureas and glycolurils in sources/extracted_pmv_candidates.tsv;
18-40 °C: Chalikian et al. 2001's nucleobases/nucleosides, 10.1016/S0301-4622(01)00200-9,
the `other-T` rows of nonbiological.tsv): across those 42 solutes the fractional
expansibility spans 0.44-2.96 × 10⁻³ K⁻¹ (median 0.82 × 10⁻³), so 3.0 × 10⁻³
covers every one of them. No electrolyte has multi-temperature data in the
tables, so this bound is unverified for salts.
"""
const PMV_FRACTIONAL_EXPANSIBILITY = 3.0e-3
