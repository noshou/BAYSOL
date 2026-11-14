# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Printf
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, ρₑ
using BAYSOL.PhysicalConstants: HC_EV_ANGSTROM
using BAYSOL.Scattering: intensityTerms, modelIntensity, excludedVolumeFactor

const _ID          = "SYN-1EHZ-argtris"
const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "synthetic", _ID)
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "1EHZ.pdb")

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
# Entry SYN-1EHZ-argtris: host 1EHZ in 500 mM L-arginine HCl + 50 mM Tris pH 7.5.
#
# Host (the molecule that is scattered):
#
# 1EHZ, yeast tRNA-Phe (Saccharomyces cerevisiae), X-ray, 1.93 Å, 76 nucleotides. The file
# has 1329 ATOM records (the standard nucleotides) and, as HETATM, 14 modified residues
# (11 types: 1MA, 2MG, 5MC, 5MU, 7MG, H2U, M2G, OMC, OMG, PSU, YYG; hydrogenated through
# their parent base), 6 Mg2+ and 3 Mn2+ ions and 160 waters; no alternate location. The
# loader keeps the modified residues and the 9 ions (ligands, heavy atoms without
# hydrogens; 1652 + 9 = 1661 heavy atoms, 2481 with hydrogens, as in
# test_nucleotide_fixtures) and drops the waters. The ions are scattered although the
# buffer of the entry has no Mg2+ or Mn2+: that is part of the structure, not of the
# buffer. File: the RCSB download of 1EHZ; its ATOM/HETATM records are identical to the
# checked-in test/fixtures/molecules/1EHZ-TEST.pdb (compared line by line, no difference).
# Loaded as a nucleic acid alone: AMBER hydrogens through pdb2pqr (83 hydrogens of the
# modifications are not placed, about 0.7 % of the electrons; src/hydrogenator/README.md).
#
# Buffer: 500 mM L-arginine HCl + 50 mM Tris pH 7.5.
# Solutes in mol/L (as `NonBiological` takes it), 25.0 °C (the tables' own temperature,
# so no ϕ° temperature widening), pH 7.5:
#
#   tris                        50.0000 mM  ±1.0000 mM
#   arginine                   500.0000 mM  ±10.0000 mM
#   chloride                   541.7560 mM  ±10.2080 mM
#
# 500 mM L-arginine hydrochloride in 50 mM Tris-HCl pH 7.5 (an aggregation-suppressing
# co-solute). Convention of the sibling scripts, not a speciation: Arg-HCl is the arginium
# cation (net +1 at this pH: guanidinium +1, the α-NH₃⁺/α-COO⁻ pair neutral) with one
# chloride, so it is the table's neutral amino acid row "arginine" (94 electrons, ϕ° =
# 127.42 ± 0.01 cm³/mol, as in SASDRJ8) plus 500 mM "chloride"; the pH is taken as the
# Tris-HCl's 7.5 and the (small) pH shift Arg-HCl would cause is ignored.
#
# Tris-HCl counter-ion: Tris base titrated with HCl to pH 7.5 (the convention of the
# siblings for amine buffers), Cl⁻ = C_Tris · f with f the protonated fraction f = 1/(1 +
# 10^(pH − pK)·γ₁), pK = 8.072 at 25 °C (the 22 °C value 8.156 and ΔH 47.45 kJ/mol of
# Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902, as quoted in SASDA58 and not re-checked here, moved to 25 °C by van't
# Hoff), γ₁ the Davies activity coefficient (A = 0.509) at the self-consistent ionic
# strength I = 0.5·(c_Arg⁺ + c_Cl⁻ + 2·C·f) = 0.500 + 0.050·f = 0.5418 M, γ₁ = 0.7361:
#
#     f = 0.8351  ->  Cl⁻(Tris) = 41.76 mM    (39.43 mM without the Davies correction)
#     Cl⁻ in all = 500 + 41.76 = 541.76 mM
#
# I = 0.54 M is above the range of the Davies equation (about 0.5 M), so f is indicative.
# σ(Cl⁻, Tris part), summed in quadrature: σ_pH = 0.1 (1.71 mM), pK ± 0.02 (0.31 mM), 30 %
# of the Davies shift (0.70 mM), ±2 % on C (0.84 mM) = 2.05 mM; with ±2 % on the 500 mM of
# Arg-HCl chloride (10 mM) the row's σ is 10.21 mM. At 0.5 M the arginine displaces 6.4 %
# of the water; its ϕ° is the value of the neutral amino acid at low concentration, so the
# linear-mixing error is the largest term here.
#
# What the benchmark compares: the file SYN-1EHZ-argtris.profile.tsv (q in Å⁻¹ on
# 0.01..0.5 step 0.005, 99 points, and I(q) in e² (electron units, scale 1, no
# background)) against the profile that Pepsi-SAXS, CRYSOL and FoXS give for the same host
# file with the same solvent electron density (SYN-1EHZ-argtris.solvent.txt: ρₑ and σ in
# e/Å³, composition) and the same q grid. Feed the other programs the raw host PDB of the
# fixture folder (they place their own hydrogens or use implicit ones; BAYSOL adds
# explicit hydrogens with pdb2pqr at the entry pH, the loader drops waters). Differences
# that are expected and not errors: hydrogens (explicit here), the anomalous terms f' +
# f'' at the photon energy below (BAYSOL only), the shell model (BAYSOL's three bead
# contrasts at the CRYSOL3 defaults, see below) and the excluded-volume model (c₁ = 1).
#
# Hand check (a Python replica of `BulkElectronDensity.ρₑ` with the table values, NOT the
# output of BAYSOL; the smoke run must reproduce it): ρₑ = 0.343497 e/Å³,
# σ = 0.000570 e/Å³ (water alone at 25 °C: 0.333292 e/Å³).
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

const PH, σ_PH = 7.5, 0.1   # synthetic pH; σ_pH = 0.1, a benchtop meter's precision

const WAVELENGTH_A  = 1.5418                      # Å, Cu Kα (CRYSOL's default wavelength)
const ENERGY_EV     = HC_EV_ANGSTROM / WAVELENGTH_A   # ≈ 8041 eV
const TEMPERATURE_C = 25.0                      # the tables' reference temperature

# Buffer components (the host is deliberately NOT a solute: ρₑ is the buffer's electron
# density). Every solute is a row of the bundled tables (looked up, not remembered).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2 %
    NonBiological(0.5, 0.01, "arginine"),   # 500 mM L-arginine, ±2 %
    NonBiological(0.541756, 0.010208, "chloride"),   # Cl⁻: 500 Arg-HCl + 41.76 Tris-HCl
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
    println(io, "host\t1EHZ (rna), ", fw.nAtoms, " atoms, lMax ", fw.lMax,
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
