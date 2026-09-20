# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Leaf module of constant primitives.
"""
module Constants

export DEFAULT_ATOL, SHELL_THICKNESS, PROBE_RADIUS, BOND_CUTOFF, SHELL_N_TARGET,
DRO_UNIT, B_LM_CHUNK, AVOGADRO, PHOSPHATE_NET_CHARGE, ELEMENTARY_CHARGE,
VACUUM_PERMITTIVITY, BOLTZMANN, ANGSTROM, MV_PER_CM, IONIC_STRENGTH_M, WATER_EPS_R,
DEBYE_TEMPERATURE_K, CUTOFF_DEBYE_LENGTHS, DEFAULT_TEMPERATURE_C, C1_PRIOR_MASS_PERCENT

#-------------------------
# Floating-point accuracy 
#-------------------------

"""
Default absolute tolerance for floating-point equality checks (`abs(a - b) < DEFAULT_ATOL`,
or `isapprox(a, b; atol = DEFAULT_ATOL)`): a few orders of magnitude above `Float64` roundoff.
"""
const DEFAULT_ATOL = 1.0e-9

#-------------------------
# Forward model constants
#-------------------------

"""
Hydration-shell thickness in Å: how far the perturbed-density water layer
extends beyond the solvent-accessible surface. `3.0` is CRYSOL's border-layer
default.
"""
const SHELL_THICKNESS = 3.0

"Solvent probe radius in Å (water), forwarded to `SASA.shell_points`."
const PROBE_RADIUS = 1.4

"""
Default shell-dummy budget (`hydration`'s `n_target`). `nothing` lets
`SASA.shell_points` size the cloud from the accessible area
(`≈ area / SASA.SHELL_AREA_PER_POINT`, floored at `SASA.SHELL_MIN_POINTS`);
an `Int` pins it.
"""
const SHELL_N_TARGET::Union{Nothing,Int} = nothing

"Shell-contrast unit in e·Å⁻³ (CRYSOL's `--dro`); `dro_k = DRO_UNIT * δρ_k`."
const DRO_UNIT = 0.03

"Atoms/dummies per pass in `compute_B_lm`."
const B_LM_CHUNK = UInt64(2048)

#--------------------
# Physical Constants 
#--------------------

"Avogadro constant, mol⁻¹ (CODATA, exact since the 2019 SI redefinition)."
const AVOGADRO = 6.02214076e23

"Elementary charge, C (CODATA, exact since the 2019 SI redefinition)."
const ELEMENTARY_CHARGE = 1.602176634e-19

"Vacuum permittivity, F/m."
const VACUUM_PERMITTIVITY = 8.8541878128e-12

"Boltzmann constant, J/K (CODATA, exact since the 2019 SI redefinition)."
const BOLTZMANN = 1.380649e-23

"Metres per angstrom."
const ANGSTROM = 1.0e-10

"V/m per MV/cm."
const MV_PER_CM = 1.0e8

"""
Net Manning-condensed charge of a single B-DNA phosphate group, in units of
the elementary charge. Laage/Elsaesser/Hynes 2017 section 5.1: the bare
`-1 e` phosphate charge is reduced by counterion condensation to `-0.24 e`
for B-DNA geometry (`d_charge = 0.17 nm`) with monovalent counterions at
`T = 300 K`, `ε = 80` (`Γ = λ_B/d_charge = 4.22`, `η = 1 - 1/Γ = 0.76` bound
fraction, net charge `1/(Γ) ... = -0.24`).
"""
const PHOSPHATE_NET_CHARGE = -0.24

"""
Covalent-bond distance cutoff, Å: generous enough for P-O (~1.5-1.6 Å) and
C-O/C-C/C-N (~1.4-1.6 Å) single bonds, tight enough to exclude non-bonded
contacts. `Molecule` carries no bonding table (see `MolecularStructure.create`'s
`(name, elms, coords)` signature), so interatomic distance is the only
connectivity proxy available.
"""
const BOND_CUTOFF = 1.75

#----------------------------
# Electrostatics/solution
#----------------------------

"Physiological monovalent salt concentration, mol/L (`debye_length`'s default ionic strength)."
const IONIC_STRENGTH_M = 0.15

"Water's static relative permittivity (`debye_length`'s default `eps_r`)."
const WATER_EPS_R = 80.0

"""
Solution temperature, K, for the Debye screening-length calculation
(`debye_length`'s default `T`). Distinct from [`DEFAULT_TEMPERATURE_C`](@ref)
(25°C ≈ 298.15 K), which is `_ρₑ`/`ρₑ_prior`'s own default temperature for
the bulk-electron-density calculation — the two aren't currently reconciled
to the same value; each keeps its own pre-existing default here rather than
silently changing either one.
"""
const DEBYE_TEMPERATURE_K = 300.0

"""
Charge sites beyond this many Debye lengths from a bead are dropped in the
screened-electrostatic aggregation (`exp(-5) ≈ 0.007`, already negligible
next to the screened `1/r` prefactor).
"""
const CUTOFF_DEBYE_LENGTHS = 5.0

#----------------------------
# Sampler defaults
#----------------------------

"""
Default solution temperature, °C, for `_ρₑ`/`ρₑ_prior`'s bulk-electron
-density calculation. **Do not change** without also checking `_ρₑ`'s own
note: only water's density is temperature-dependent in that model as of this
version.
"""
const DEFAULT_TEMPERATURE_C = 25.0

"""
Default percentage ((0, 100]) of `c1_prior`'s prior mass required to fall
within CRYSOL's bound `[0.96, 1.04]` around its default `c_1 = 1`.
"""
const C1_PRIOR_MASS_PERCENT = 95

end # module
