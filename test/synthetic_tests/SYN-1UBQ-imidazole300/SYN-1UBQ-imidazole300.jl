# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Printf
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, ρₑ
using BAYSOL.PhysicalConstants: HC_EV_ANGSTROM
using BAYSOL.Scattering: intensityTerms, modelIntensity, excludedVolumeFactor

const _ID          = "SYN-1UBQ-imidazole300"
const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "synthetic", _ID)
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "1UBQ.pdb")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SYNTHETIC test: the buffer is INVENTED, nothing here was measured and there is no
# experimental curve and no fit. One real small structure from the PDB (the host) is
# combined with a buffer chosen to exercise the solute tables; the script computes the
# buffer's bulk electron density and the host's predicted profile, and the benchmark sets
# the same solvent electron density in other programs and compares profiles.
#
# Entry SYN-1UBQ-imidazole300: host 1UBQ in 300 mM imidazole + 500 mM NaCl pH 8.0.
#
# Host (the molecule that is scattered):
#
# 1UBQ, human ubiquitin, X-ray, 1.80 Å, 76 residues, 602 heavy atoms, 58 waters (HOH, not
# scattered: the loader drops waters), no other hetero group, no alternate location. File:
# the RCSB download of 1UBQ in PDB format (the repository only has the mmCIF
# test/fixtures/molecules/1UBQ-TEST.cif, whose atom records were not compared). Loaded as
# a protein: PROPKA + PARSE hydrogens at the entry pH.
#
# Buffer: 300 mM imidazole + 500 mM NaCl pH 8.0.
# Solutes in mol/L (as `NonBiological` takes it), 25.0 °C (the tables' own temperature,
# so no ϕ° temperature widening), pH 8.0:
#
#   imidazole                  300.0000 mM  ±6.0000 mM
#   sodium chloride            500.0000 mM  ±5.0000 mM
#   chloride                    35.3930 mM  ±7.2299 mM
#
# 300 mM imidazole + 500 mM NaCl, pH 8.0 (the elution buffer of a Ni-NTA purification).
# The pH is not part of the brief's recipe and is invented: imidazole alone is a weak base
# of pH about 10 at this concentration, so it is taken as titrated with HCl to pH 8.0 (HCl
# for amine buffers, as in the sibling scripts), and the counter-ion is modelled: Cl⁻ =
# C·f, f the protonated (imidazolium) fraction f = 1/(1 + 10^(pH − pK)·γ₁), pK = 6.993 at
# 25 °C (Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902, as quoted in SASDA58 and not re-checked here; its 22 °C value 7.058
# with ΔH 36.64 kJ/mol moves to 6.993 at 25 °C), γ₁ the Davies activity coefficient (A =
# 0.509) at the self-consistent ionic strength I = 0.5·(c_Na⁺ + c_Cl⁻ + 2·C·f) = 0.500 +
# 0.300·f = 0.5354 M, γ₁ = 0.7357:
#
#     f = 0.1180  ->  Cl⁻ = 35.39 mM    (26.88 mM without the Davies correction)
#
# I = 0.54 M is above the range of the Davies equation (about 0.5 M), so f is indicative.
# σ, summed in quadrature: σ_pH = 0.1 (6.57 mM), pK ± 0.02 (1.46 mM), 30 % of the Davies
# shift (2.56 mM), ±2 % on C (0.71 mM) = 7.23 mM. Rows "imidazole" (36 electrons, ϕ° =
# 59.95 ± 0.5 cm³/mol, the neutral base), "sodium chloride" and "chloride" (ϕ° = 17.8).
# The imidazolium/imidazole volume difference itself is not modelled.
#
# What the benchmark compares: the file SYN-1UBQ-imidazole300.profile.tsv (q in Å⁻¹ on
# 0.01..0.5 step 0.005, 99 points, and I(q) in e² (electron units, scale 1, no
# background)) against the profile that Pepsi-SAXS, CRYSOL and FoXS give for the same host
# file with the same solvent electron density (SYN-1UBQ-imidazole300.solvent.txt: ρₑ and σ
# in e/Å³, composition) and the same q grid. Feed the other programs the raw host PDB of
# the fixture folder (they place their own hydrogens or use implicit ones; BAYSOL adds
# explicit hydrogens with pdb2pqr at the entry pH, the loader drops waters). Differences
# that are expected and not errors: hydrogens (explicit here), the anomalous terms f' +
# f'' at the photon energy below (BAYSOL only), the shell model (BAYSOL's three bead
# contrasts at the CRYSOL3 defaults, see below) and the excluded-volume model (c₁ = 1).
#
# Hand check (a Python replica of `BulkElectronDensity.ρₑ` with the table values, NOT the
# output of BAYSOL; the smoke run must reproduce it): ρₑ = 0.339638 e/Å³,
# σ = 0.000092 e/Å³ (water alone at 25 °C: 0.333292 e/Å³).
#
# How the profile is computed (no curve, no fit): the cheapest public path found is
# `BAYSOL.seedModel` with a PLACEHOLDER curve (unit intensity, unit σ on the q grid, `rebin
# = nothing` so that the forward model sits on exactly this grid), which builds the
# hydrogenated structure, the hydration shell and the forward cache (`seed.fw`); nothing is
# sampled, no MAP search, no scale or background is fitted (all of that would act on the
# placeholder). The profile is then evaluated directly from the forward cache with the
# internal helpers `BAYSOL.Scattering.intensityTerms`, `excludedVolumeFactor` and
# `modelIntensity` (not exported) at fixed parameters: ρₑ from the buffer
# (`BulkElectronDensity.ρₑ`, the mean of the prior that `seedModel` builds), the shell
# contrasts at the CRYSOL3 defaults (relative units of 0.03 e/Å³: 1, 1, 0, written as the
# manual puts it in inference/priors.jl; the mean of BAYSOL's δρ₁₂ prior would be about
# 0.38 and is NOT used, since the other programs run their defaults), the excluded-volume
# factor c₁ = 1 (no correction) and scale 1.
#
# The script was written without being run (smoke run pending approval).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, 0.1   # synthetic pH; σ_pH = 0.1, a benchtop meter's precision

const WAVELENGTH_A  = 1.5418                      # Å, Cu Kα (CRYSOL's default wavelength)
const ENERGY_EV     = HC_EV_ANGSTROM / WAVELENGTH_A   # ≈ 8041 eV
const TEMPERATURE_C = 25.0                      # the tables' reference temperature

# Buffer components (the host is deliberately NOT a solute: ρₑ is the buffer's electron
# density). Every solute is a row of the bundled tables (looked up, not remembered).
const SOLUTES = Solute[
    NonBiological(0.3, 0.006, "imidazole"),   # 300 mM imidazole, ±2 %
    NonBiological(0.5, 0.005, "sodium chloride"),   # 500 mM NaCl, ±1 %
    NonBiological(0.035393, 0.0072299, "chloride"),   # Cl⁻ of the HCl titration
]

# Fixed parameters of the predicted profile.
const Q_GRID = collect(range(0.01, 0.5; length = 99))   # 0.01, 0.015, ..., 0.5 Å⁻¹
const REL_δρ = (1.0, 1.0, 0.0)   # δρ₁, δρ₂, δρ₃: CRYSOL3 defaults (1, 1, 0 x 0.03 e/Å³)
const C1     = 1.0               # excluded-volume factor, no correction

# ---------------------------------------------------------------------------
#                                Forward model
# ---------------------------------------------------------------------------

# PLACEHOLDER curve: unit intensity and unit σ on the grid. It only carries the q grid
# into `seedModel`; no number of it enters the profile.
const PLACEHOLDER = ones(length(Q_GRID))

seed = BAYSOL.seedModel(
    LocalPathSource(_PDB_PATH), ENERGY_EV, Q_GRID, PLACEHOLDER, PLACEHOLDER, PH, σ_PH,
    SOLUTES;
    addHydrogens = true, t = TEMPERATURE_C, rebin = nothing,
)
fw = seed.fw
@assert fw.qvals == Q_GRID "the forward model is not on the fixed q grid"

ρ, σρ = ρₑ(PH, σ_PH, SOLUTES; t = TEMPERATURE_C)
ρWater, σWater = ρₑ(PH, σ_PH, Solute[]; t = TEMPERATURE_C)

A, B, C = intensityTerms(fw, ρ, REL_δρ)
g = excludedVolumeFactor(fw.qvals, fw.rM, C1)
I = modelIntensity(A, B, C, g)

# ---------------------------------------------------------------------------
#                                  Outputs
# ---------------------------------------------------------------------------

profilePath = joinpath(@__DIR__, _ID * ".profile.tsv")
writedlm(profilePath, vcat(permutedims(["q", "I"]), hcat(fw.qvals, I)), '\t')

solventPath = joinpath(@__DIR__, _ID * ".solvent.txt")
open(solventPath, "w") do io
    println(io, "SYNTHETIC buffer (invented, not measured): ", _ID)
    println(io, "host\t1UBQ (protein), ", fw.nAtoms, " atoms, lMax ", fw.lMax,
        ", rM ", @sprintf("%.4f", fw.rM), " Å")
    println(io, "temperature_C\t", TEMPERATURE_C)
    println(io, "pH\t", PH, "\tσ_pH\t", σ_PH)
    println(io, "energy_eV\t", @sprintf("%.2f", ENERGY_EV),
        "\twavelength_A\t", WAVELENGTH_A)
    println(io, "rho_e_e_per_A3\t", @sprintf("%.6f", ρ))
    println(io, "sigma_rho_e_e_per_A3\t", @sprintf("%.6f", σρ))
    println(io, "rho_e_water_e_per_A3\t", @sprintf("%.6f", ρWater),
        "\tsigma\t", @sprintf("%.6f", σWater))
    println(io, "rho_e_relative_to_water\t", @sprintf("%.5f", ρ / ρWater))
    println(io, "shell_contrasts_relative\t", REL_δρ, "\tc1\t", C1,
        "\tscale 1, background 0")
    println(io, "composition (mol/L, ±σ):")
    for s in SOLUTES
        println(io, "  ", s.arg, "\t", s.molarity, "\t", s.molarityUncertainty)
    end
end

@printf("%s: ρₑ = %.6f ± %.6f e/Å³ (water %.6f); I(q=%.2f) = %.4g\n",
    _ID, ρ, σρ, ρWater, fw.qvals[1], I[1])
println("wrote ", profilePath, " and ", solventPath)
