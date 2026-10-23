# SPDX-License-Identifier: LGPL-3.0-or-later

"""
The bulk electron density of the buffer, and nothing else is public: [`ρₑ`](@ref)
takes the buffer's [`Solute`](@ref)s (concentrations with uncertainties), the pH
and the temperature and returns the electron density of the solution and its
propagated standard deviation. Underneath are the partial molar volumes of the
solutes at infinite dilution (V0, cm³/mol; per-class backends for proteins, DNA,
RNA and non-biological solutes) and the density of water, which are internal.
"""
module BulkElectronDensity

using ..PhysicalConstants: STANDARD_TEMPERATURE_C, AVOGADRO, WATER_MOLAR_MASS,
    WATER_DENSITY_UNCERTAINTY,
    WATER_ELECTRONS, ANGSTROM3_PER_LITER, CM3_PER_LITER,
    KELL_DENSITY_NUM, KELL_DENSITY_DEN, BACKBONE_ELECTRONS
using ..Runtime: KeyedCache
using JSON3: JSON3
using FastClosures: @closure

export Solute, Protein, NonBiological, Polymer, DNA, RNA, DEFAULT_TEMPERATURE_C, ρₑ


"""
Temperature, °C, at which the bundled partial-molar-volume tables are tabulated
(see BulkElectronDensity/README.md: 298.15 K unless a source says otherwise): the
standard reference temperature,
[`STANDARD_TEMPERATURE_C`](@ref BAYSOL.Utils.PhysicalConstants.STANDARD_TEMPERATURE_C).
"""
const PMV_REFERENCE_TEMPERATURE_C = STANDARD_TEMPERATURE_C

"""
Fractional partial-molar-volume expansibility, K⁻¹: an upper bound on
(∂ϕ°/∂T)/ϕ° used to widen a solute's 25 °C ϕ° uncertainty when the sample is at
another temperature

    `σ_T`   = `PMV_FRACTIONAL_EXPANSIBILITY` · ϕ°
            · |t − [`PMV_REFERENCE_TEMPERATURE_C`](@ref)|.

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

"""
Default solution temperature, °C, for [`ρₑ`](@ref)'s bulk electron density calculation. Pass
the sample's real temperature instead whenever it is known: water's density is evaluated at
it exactly, and the solutes' 25 °C partial molar volumes get a widened uncertainty (see
[`PMV_FRACTIONAL_EXPANSIBILITY`](@ref)). Defaults to the standard reference temperature,
[`STANDARD_TEMPERATURE_C`](@ref `BAYSOL.Utils.PhysicalConstants.STANDARD_TEMPERATURE_C`),
the same temperature the PMV tables are given at, so the default never widens their
uncertainty.
"""
const DEFAULT_TEMPERATURE_C = STANDARD_TEMPERATURE_C

# ---------------------------------------------------------------------------
#   Solutes of the buffer
# ---------------------------------------------------------------------------

"""
Solutes of the *buffer*: the solution the macromolecule is dissolved in, i.e.
what the buffer blank that was subtracted from the sample contains.

**Do not list the measured macromolecule itself.** Buffer-subtracted SAXS
measures contrast against the buffer, so the solvent electron density ρₑ is the
buffer's. Other copies of the measured species are separate scatterers (their
correlations show up as a structure factor, not as a uniform background
density), and the volume they displace in the sample cell only changes the
buffer-subtraction baseline, which the flat background correction absorbs. A
`Protein`/`DNA`/`RNA` solute is only correct for a genuine buffer component
that the blank also contained (e.g. a carrier protein).
"""
abstract type Solute end

"A protein buffer component (not the measured species; see [`Solute`](@ref))."
struct Protein <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"A non-biological buffer component (salt, buffering agent, cosolute, ...)."
struct NonBiological <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"""
A polymer, polydisperse surfactant or short oligomer buffer component: PEG,
Pluronics, dextran, detergents such as Tween, Triton and Brij, peptides,
cyclodextrins ... `arg` is a grade name (`"PEG-3350"`, `"tween 80"`), a chain
description (`"Pluronic nEO=150 nPO=30"`, `"C12E23"`) or a peptide (`"peptide GAG"`,
`"tetraalanine"`). Molarity is per mole of chains (per average monomer unit for
dextran, amphipol, PVP and PVA; per 1000 Da for Ficoll). See the README, `Polymers/`.
"""
struct Polymer <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"A DNA buffer component (not the measured species; see [`Solute`](@ref))."
struct DNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"An RNA buffer component (not the measured species; see [`Solute`](@ref))."
struct RNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

# ---------------------------------------------------------------------------
#   Constants and caches shared by the backends
#   (each class keeps its tables beside its code: Protein/, NonBiological/, Nucleotide/,
#   Polymers/)
# ---------------------------------------------------------------------------

"Memoized water electron bulk density"
const _ρₑ_w_cache = KeyedCache{Int64,Tuple{Float64,Float64}}()

# The polymer JSON tables are read into `const`s at precompile time; declare them as
# dependencies so editing them invalidates the precompile cache (otherwise stale values/keys
# keep being served after a table edit). Same for NonBiological/NonBiological.jl.
include_dependency(joinpath(@__DIR__, "Polymers", "polymers.json"))
include_dependency(joinpath(@__DIR__, "Polymers", "polymers_lookup.json"))

include("CalcDensity.jl")   # water first: `_H2O_V0_25C` below needs its density

# Defined after CalcDensity.jl because its initializer calls `_kell_density`.
"Bulk water molar volume at the PMV reference temperature (25 °C), cm³·mol⁻¹,
from the same Kell equation as `_ρₑ_w` (≈ 18.0686)."
const _H2O_V0_25C =
    WATER_MOLAR_MASS / _kell_density(PMV_REFERENCE_TEMPERATURE_C) * CM3_PER_LITER

# Group-additive polymer volumes (Polymers/Polymers.jl); sources and fits in the README.
"Molar mass of one oxyethylene unit, –OCH₂CH₂–, g/mol."
const EO_MOLAR_MASS = 44.0526

"Intercept, cm³/mol, of the PEG ϕ° line `PEG_V0_INTERCEPT + PEG_V0_PER_UNIT·m` (`m` =
oxyethylene
units, H(OCH₂CH₂)ₘOH): weighted fit to the ten PEGs 200–10 000 of Ayranci & Sahin 2008 and
to the
measured di- to pentaethylene glycols at 25 °C (worst residual 1.0 %, diethylene glycol)."
const PEG_V0_INTERCEPT = 19.24

"Slope, cm³/mol per oxyethylene unit, of the PEG ϕ° line (see [`PEG_V0_INTERCEPT`](@ref))."
const PEG_V0_PER_UNIT = 36.73

"Fractional uncertainty of the PEG line (largest residual of the ten fitted grades, 0.9 %)."
const PEG_V0_REL_UNC = 0.01

"""
ϕ° contribution, cm³/mol, of one ethylene oxide
unit of a Pluronic at 25 °C (Senkow et al. 2002).
"""
const PLURONIC_EO_V0 = 36.92

"""
ϕ° contribution, cm³/mol, of one propylene oxide
unit of a Pluronic at 25 °C (Senkow et al. 2002).
"""
const PLURONIC_PO_V0 = 53.13

"""
End-group term, cm³/mol, of the Pluronic additivity scheme (L35, L64, F68, 10R5 give 8–13).
"""
const PLURONIC_END_V0 = 9.0

"Uncertainty, cm³/mol, of [`PLURONIC_END_V0`](@ref)."
const PLURONIC_END_UNC = 8.0

"Fractional uncertainty of the Pluronic scheme: 0.2 % on L35/L64/F68/10R5, but micellar
grades
(P123 at 25 °C) deviate by 2 %, so 1 % is a compromise."
const PLURONIC_REL_UNC = 0.01

"Molar mass of one oxypropylene unit, –OCH(CH₃)CH₂–, g/mol."
const PO_MOLAR_MASS = 58.0791

"Molar mass of 1-butanol, g/mol, the starter of the UCON 50-HB random EO/PO copolymers."
const UCON_STARTER_MOLAR_MASS = 74.1216

"Electrons of the UCON starter, 1-butanol (C₄H₁₀O)."
const UCON_STARTER_Z = 42

"ϕ°, cm³/mol, of the UCON starter, 1-butanol, measured (the tables): the chain is the butyl
ether
C₄H₉(OR)ₙOH, and the same step on 2-butoxyethanol (123.0 = 86.6 + 36.4) reproduces the EO
increment."
const UCON_STARTER_V0 = 86.6

"Uncertainty, cm³/mol, of the UCON starter term: the 1-butanol value is measured, the
end-group
change of a copolymer is not."
const UCON_STARTER_UNC = 3.0

"Mass fraction of oxyethylene units in UCON 50-HB copolymers (equal weights of EO and PO)."
const UCON_EO_MASS_FRACTION = 0.5

"Intercept, cm³/mol, of the poly(propylene glycol) line
`PPG_V0_INTERCEPT + PPG_V0_PER_UNIT·m`,
H(OC₃H₆)ₘOH: weighted fit to the measured propylene to pentapropylene glycols of the tables
(m = 1–5, residuals ≤ 0.2 %); its slope agrees with the Pluronic PO increment."
const PPG_V0_INTERCEPT = 18.10

"Slope, cm³/mol per oxypropylene unit, of the PPG line (see [`PPG_V0_INTERCEPT`](@ref))."
const PPG_V0_PER_UNIT = 53.20

"Fractional uncertainty of the PPG line; only m ≤ 5 is anchored, longer chains extrapolate."
const PPG_V0_REL_UNC = 0.01

"Molar mass of one anhydroglucose unit, C₆H₁₀O₅, g/mol (dextran, pullulan, maltodextrin)."
const GLUCOSE_UNIT_MOLAR_MASS = 162.1406

"Intercept, cm³/mol, of the α-glucan line `GLUCAN_V0_INTERCEPT + GLUCAN_V0_PER_UNIT·m` (`m`
=
anhydroglucose units): weighted fit to glucose and maltose to maltoheptaose of the tables."
const GLUCAN_V0_INTERCEPT = 16.6

"Slope, cm³/mol per anhydroglucose unit (0.60 mL/g) of the α-glucan line; the dextran
measured in
10× PBS at 2.5–25 % (Migliorini 2026) is 5 % higher (102.2), inside
[`GLUCAN_V0_REL_UNC`](@ref)."
const GLUCAN_V0_PER_UNIT = 96.7

"Fractional uncertainty of the α-glucan line."
const GLUCAN_V0_REL_UNC = 0.04

"Slope, cm³/mol per anhydroglucose unit, of the dextran line
`GLUCAN_V0_INTERCEPT + DEXTRAN_V0_PER_UNIT·m`:
the measured partial specific volume of dextran 10, 40 and 450 kDa, 0.630 mL/g (Migliorini
2026)
× 162.14. Measured dextran takes priority over the α-glucan line, which is fitted to
maltooligosaccharides."
const DEXTRAN_V0_PER_UNIT = 102.2

"""
Fractional uncertainty of the dextran line: the
three measured molar masses agree within 2 %.
"""
const DEXTRAN_V0_REL_UNC = 0.02

"Octylphenol ethoxylate (Triton X) ϕ°, cm³/mol, at zero ethylene oxide units, micellar
state:
`V(Triton X-114, 7.5 EO) − 7.5·`[`PLURONIC_EO_V0`](@ref) (Szymczyk & Taraba 2016)."
const TRITON_V0_BASE = 239.7

"Fractional uncertainty of the Triton scheme: one measured grade, micellar state."
const TRITON_V0_REL_UNC = 0.02

"Intercept, cm³/mol, of the alkyl ethoxylate scheme CₙEₘ = H(CH₂)ₙ(OCH₂CH₂)ₘOH,
`ϕ° = ALKYL_ETHOXYLATE_V0_BASE +
ALKYL_ETHOXYLATE_V0_PER_CH2·n + `[`PLURONIC_EO_V0`](@ref)`·m`:
fit to the measured 2-methoxy-, 2-ethoxy- and 2-butoxyethanol of the tables (C₁E₁, C₂E₁,
C₄E₁, residuals ≤ 0.05); the EO increment agrees with diglyme − 1,2-dimethoxyethane (36.8)
and the PEG slope."
const ALKYL_ETHOXYLATE_V0_BASE = 22.38

"""
Slope, cm³/mol per CH₂, of the alkyl ethoxylate
scheme (see [`ALKYL_ETHOXYLATE_V0_BASE`](@ref)).
"""
const ALKYL_ETHOXYLATE_V0_PER_CH2 = 15.93

"Fractional uncertainty of the alkyl ethoxylate scheme: calibrated on C₁–C₄ monoethers,
applied to
C₈–C₁₈ chains that are micellar above the CMC, so 2 %."
const ALKYL_ETHOXYLATE_V0_REL_UNC = 0.02

"Intercept, cm³/mol, of the alkyl maltoside scheme (n-alkyl β-D-maltoside with an `n`-carbon
chain),
`ϕ° = MALTOSIDE_V0_BASE + `[`ALKYL_ETHOXYLATE_V0_PER_CH2`](@ref)`·n`, monomer (infinite
dilution): the
3D-RISM estimate for decyl maltoside, 373.3 (3D-RISM 367.7 plus a group correction fitted to
72
measured solutes of the tables), minus 10 CH₂ of 15.93 each."
const MALTOSIDE_V0_BASE = 214.0

"Chain length at which the maltoside and LMNG schemes were calculated (decyl maltoside, and
each of
the two chains of LMNG as drawn in its structure)."
const MALTOSIDE_REFERENCE_CARBONS = 10

"Uncertainty, cm³/mol, of the alkyl maltoside scheme at
[`MALTOSIDE_REFERENCE_CARBONS`](@ref): the
estimate of decyl maltoside (conformer spread, anchor class and fitted corrections in
quadrature)."
const MALTOSIDE_V0_UNC = 3.9

"Uncertainty, cm³/mol, added per CH₂ away from [`MALTOSIDE_REFERENCE_CARBONS`](@ref) (in
quadrature
with [`MALTOSIDE_V0_UNC`](@ref)): the scatter of the measured per-CH₂ increments, 15.6 to
16.2."
const MALTOSIDE_V0_PER_CH2_UNC = 0.4

"Intercept, cm³/mol, of the LMNG scheme (lauryl maltose neopentyl glycol: two maltosides on
a
neopentyl glycol core with two `n`-carbon chains),
`ϕ° = LMNG_V0_BASE + 2·`[`ALKYL_ETHOXYLATE_V0_PER_CH2`](@ref)`·n`,
monomer: the 3D-RISM estimate for LMNG, 782.9 (n = 10), minus 20 CH₂."
const LMNG_V0_BASE = 464.3

"""
Uncertainty, cm³/mol, of the LMNG scheme at
[`MALTOSIDE_REFERENCE_CARBONS`](@ref) carbons per chain.
"""
const LMNG_V0_UNC = 5.6

"ϕ° per anhydroglucose unit, cm³/mol, of a cyclodextrin (`n` units, no end groups): mean of
α, β
and γ (6, 7, 8 units: 601.5, 710.0, 803.0)."
const CYCLODEXTRIN_V0_PER_UNIT = 100.7

"""
Fractional uncertainty of the cyclodextrin scheme (residuals ≤ 0.8 % on the three measured).
"""
const CYCLODEXTRIN_V0_REL_UNC = 0.01

"""
pKa of the peptide carboxyl terminus, Lee et al. 2008
(10.1016/j.bpc.2008.02.009, `Protein/ionization.tsv`, 25 °C).
"""
const PEPTIDE_COOH_PKA = 3.3

"""
Volume gain, cm³/mol, of protonating the carboxyl
terminus (zwitterion → cation), and its uncertainty.
"""
const PEPTIDE_COOH_DV = 10.5
const PEPTIDE_COOH_DV_UNC = 0.4

"pKa of the peptide amino terminus (same source)."
const PEPTIDE_NH2_PKA = 8.0

"""
Volume change, cm³/mol, of protonating the amino terminus
(−4.8: deprotonating it gains 4.8), and its uncertainty.
"""
const PEPTIDE_NH2_DV = -4.8
const PEPTIDE_NH2_DV_UNC = 0.5

"Extra uncertainty, cm³/mol, of the residue-additive scheme on short peptides: the protein
residue values
reproduce Gly₃–Gly₅ to 0.1 but Ala/Ser peptides 1–4 low (mean −1.7, worst −3.8; measured di-
to pentapeptides)."
const PEPTIDE_SHORT_UNC = 2.0

"Peptides of at most this many residues get [`PEPTIDE_SHORT_UNC`](@ref)."
const PEPTIDE_SHORT_MAX_RESIDUES = 8

include("Polymers/Polymers.jl")
""" Returns the partial molar volume at infinite dilution of a solute. """
function ϕ° end

# helpers shared by the sequence backends
include("Titration.jl")
include("Protein/Protein.jl")               # ϕ°(pH, seq)
include("NonBiological/NonBiological.jl")   # ϕ°(name)
include("Nucleotide/Nucleotide.jl")         # ϕ°(isDNA, seq, pH)

end # module BulkElectronDensity
