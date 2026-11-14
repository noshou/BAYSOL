# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Printf
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, ρₑ
using BAYSOL.PhysicalConstants: HC_EV_ANGSTROM
using BAYSOL.Scattering: intensityTerms, modelIntensity, excludedVolumeFactor

const _ID          = "SYN-1BNA-tmao1m"
const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "synthetic", _ID)
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "1BNA.pdb")

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
# Entry SYN-1BNA-tmao1m: host 1BNA in 1 M trimethylamine N-oxide.
#
# Host (the molecule that is scattered):
#
# 1BNA, the Dickerson-Drew B-DNA dodecamer d(CGCGAATTCGCG)2, X-ray, 1.90 Å, 2 chains of 12
# nucleotides, 486 heavy atoms, 80 waters (HOH, not scattered), no other hetero group, no
# alternate location. File: the RCSB download of 1BNA; its ATOM/HETATM records are
# identical to the checked-in test/fixtures/molecules/1BNA-TEST.pdb (compared line by
# line, no difference). Loaded as a nucleic acid alone: AMBER hydrogens through pdb2pqr,
# no PROPKA, no pH dependence of the nucleic acid protonation.
#
# Buffer: 1 M trimethylamine N-oxide.
# Solutes in mol/L (as `NonBiological` takes it), 25.0 °C (the tables' own temperature,
# so no ϕ° temperature widening), pH 7.0:
#
#   trimethylamine n-oxide    1000.0000 mM  ±20.0000 mM
#
# 1 M trimethylamine N-oxide (TMAO, an osmolyte; 75 g/L) in water, no buffer. TMAO is
# taken as neutral at pH 7.0 (an assumption, not looked up), so no counter-ion is needed.
# Row "trimethylamine n-oxide" (alias of N,N-dimethylmethanamine N-oxide; 42 electrons, ϕ°
# = 73.32 ± 0.02 cm³/mol). Its Z/ϕ° = 0.57 is close to the water value 0.553, so TMAO
# barely changes ρₑ (+0.25 %): a case where the buffer is nearly electron-density matched.
#
# What the benchmark compares: the file SYN-1BNA-tmao1m.profile.tsv (q in Å⁻¹ on 0.01..0.5
# step 0.005, 99 points, and I(q) in e² (electron units, scale 1, no background)) against
# the profile that Pepsi-SAXS, CRYSOL and FoXS give for the same host file with the same
# solvent electron density (SYN-1BNA-tmao1m.solvent.txt: ρₑ and σ in e/Å³, composition)
# and the same q grid. Feed the other programs the raw host PDB of the fixture folder
# (they place their own hydrogens or use implicit ones; BAYSOL adds explicit hydrogens
# with pdb2pqr at the entry pH, the loader drops waters). Differences that are expected
# and not errors: hydrogens (explicit here), the anomalous terms f' + f'' at the photon
# energy below (BAYSOL only), the shell model (BAYSOL's three bead contrasts at the
# CRYSOL3 defaults, see below) and the excluded-volume model (c₁ = 1).
#
# Hand check (a Python replica of `BulkElectronDensity.ρₑ` with the table values, NOT the
# output of BAYSOL; the smoke run must reproduce it): ρₑ = 0.334148 e/Å³,
# σ = 0.000019 e/Å³ (water alone at 25 °C: 0.333292 e/Å³).
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

const PH, σ_PH = 7.0, 0.1   # synthetic pH; σ_pH = 0.1, a benchtop meter's precision

const WAVELENGTH_A  = 1.5418                      # Å, Cu Kα (CRYSOL's default wavelength)
const ENERGY_EV     = HC_EV_ANGSTROM / WAVELENGTH_A   # ≈ 8041 eV
const TEMPERATURE_C = 25.0                      # the tables' reference temperature

# Buffer components (the host is deliberately NOT a solute: ρₑ is the buffer's electron
# density). Every solute is a row of the bundled tables (looked up, not remembered).
const SOLUTES = Solute[
    NonBiological(1, 0.02, "trimethylamine n-oxide"),   # 1 M TMAO, ±2 %
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
    println(io, "host\t1BNA (dna), ", fw.nAtoms, " atoms, lMax ", fw.lMax,
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
