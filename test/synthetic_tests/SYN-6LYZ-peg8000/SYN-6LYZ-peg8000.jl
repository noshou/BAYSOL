# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Polymer, CustomPolymer, ρₑ
using BAYSOL.PhysicalConstants: HC_EV_ANGSTROM

const _FIXTURE_DIR = joinpath(
@__DIR__, "..", "..", "fixtures", "synthetic", "SYN-6LYZ-peg8000"
)
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "6LYZ.pdb")

# ---------------------------------------------------------------------------
#                                Synthetic test
# ---------------------------------------------------------------------------
#
# SYNTHETIC buffer (invented for the benchmark, NOT measured): there is no experimental
# curve and no fit. One real PDB structure is scattered in one invented solution.
#
# Host structure: PDB 6LYZ, hen egg-white lysozyme, 129 residues, 1001 ATOM records (2.00
# Å X-ray): a protein host. Why this one: small, well refined and in the checked-in set of
# test molecules; 101 HOH (dropped by the loader), no ligands, no altlocs. The model is
# the unmodified RCSB file (files.rcsb.org/download/6LYZ.pdb), see
# fixtures/synthetic/SYN-6LYZ-peg8000/README.txt.
#
# Buffer: PEG 8000 at 8 % (w/v) in water, pH 7.0 nominal (no buffer salt, no ions), 25 C.
#   solute PEG 8000: mol/L of chains (Mn 8000) = 0.01 M
# The concentration arithmetic is beside the solute below. Everything is invented for
# the benchmark (a concentration the polymer dissolves at; no measured sample).
#
# What the benchmark compares: the solvent electron density of this buffer (written to
# SYN-6LYZ-peg8000.solvent.txt) is set as the solvent density in Pepsi-SAXS, CRYSOL and
# FoXS and their profiles of the same structure are compared with BAYSOL's prediction
# (SYN-6LYZ-peg8000.profile.tsv) on q = 0.01..0.5 A^-1 in steps of 0.005 (99 points).
#
# What this script computes (no fit, no sampling):
#   1. the buffer's bulk electron density rho_e and its sigma (BulkElectronDensity.ρₑ);
#   2. a Seed (seedModel) of the host on the fixed q grid, with a PLACEHOLDER curve of
#      unit intensity and unit sigma (the Seed needs a curve to be built; the
#      forward model, the Gram matrix of the five species, depends on q only; no
#      Shannon binning: rebin = nothing keeps the 99 grid points);
#   3. the profile I(q) at FIXED solvent parameters: rho_e = the buffer value,
#      delta-rho_1..3 = the CRYSOL3 defaults (1, 1, 0 x 0.03 e/A^3), excluded-volume factor
#      c1 = 1 (CRYSOL's uncorrected radii), scale 1, background 0: A + g (B + g C) of
#      Scattering.intensityTerms / excludedVolumeFactor / modelIntensity.
#   The script has NOT been run (no Julia was available when it was written); the
#   owner approves a smoke run.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, 0.1    # nominal, unbuffered; sigma = a benchtop pH meter
const TEMPERATURE_C = 25.0     # the standard temperature of the pipeline
const WAVELENGTH_A  = 1.5418   # Å, Cu Kα (CRYSOL's default wavelength; one value for all)
const ENERGY_EV     = HC_EV_ANGSTROM / WAVELENGTH_A   # ≈ 8041 eV

# The buffer: one polymer in water. The measured macromolecule (the host) is deliberately
# NOT a solute (see BulkElectronDensity.Solute).
#
# 8 % (w/v) = 80 g/L; Mn 8000 g/mol -> 80 / 8000 = 0.0100 M of chains, sigma 5 %.
#
# Table: Polymer family PEG.
const SOLUTES = Solute[
    Polymer(0.01, 0.0005, "PEG 8000"),
]

# ---------------------------------------------------------------------------
#                                 The q grid
# ---------------------------------------------------------------------------

# The fixed grid of the benchmark, q = 0.01..0.5 A^-1 in steps of 0.005 (99 points).
const Q_GRID = collect(0.01:0.005:0.5)

# ---------------------------------------------------------------------------
#                           Buffer electron density
# ---------------------------------------------------------------------------

"""
    solvent() -> (rho, sigma, water)

The buffer's bulk electron density and sigma (e/A^3, `ρₑ`), and the density of pure water
at the same temperature, for the `.solvent.txt` file.
"""
function solvent()
    ρ, σ = ρₑ(PH, σ_PH, SOLUTES; t = TEMPERATURE_C)
    ρw, _ = ρₑ(PH, σ_PH, Solute[]; t = TEMPERATURE_C)
    return ρ, σ, ρw
end

# ---------------------------------------------------------------------------
#                       Seed (placeholder curve) and profile
# ---------------------------------------------------------------------------

# Builds the Seed on the fixed grid. The curve is a PLACEHOLDER: unit intensity and unit
# sigma at every grid point, which only lets `seedModel` build the forward model; no
# number of it enters the profile below. rebin = nothing: no Shannon binning, the Seed
# keeps the 99 grid points (checked below).
function seedSynthetic(; seed::Integer = 0)
    Random.seed!(seed)
    ones_ = ones(length(Q_GRID))
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, Q_GRID, ones_, ones_, PH, σ_PH, SOLUTES;
        addHydrogens = true, t = TEMPERATURE_C, rebin = nothing,
    )
    length(s.fw.qvals) == length(Q_GRID) && s.fw.qvals ≈ Q_GRID ||
        error("the Seed changed the q grid")
    return s
end

# Fixed shell contrasts: the CRYSOL3 defaults (1, 1, 0 x 0.03 e/A^3), the point the
# other programs run; the mean of BAYSOL's priors is NOT used.
const REL_δρ = (1.0, 1.0, 0.0)

"""
    profile(s, ρ) -> I

I(q) of the Seed's structure at fixed solvent parameters: bulk density `ρ`,
δρ₁..δρ₃ = the CRYSOL3 defaults (1, 1, 0), c1 = 1, scale 1, no background.
"""
function profile(s, ρ)
    δρ = REL_δρ
    A, B, C = BAYSOL.Scattering.intensityTerms(s.fw, ρ, δρ)
    g = BAYSOL.Scattering.excludedVolumeFactor(s.fw.qvals, s.fw.rM, 1.0)
    return BAYSOL.Scattering.modelIntensity(A, B, C, g), δρ
end

ρ, σρ, ρWater = solvent()
s = seedSynthetic()
I, δρ = profile(s, ρ)

# ---------------------------------------------------------------------------
#                                   Output
# ---------------------------------------------------------------------------

# `@__DIR__` (this synthetic-test folder), not the caller's cwd.
writedlm(
    joinpath(@__DIR__, "SYN-6LYZ-peg8000.profile.tsv"),
    vcat(["q" "I"], hcat(s.fw.qvals, I)),
    '\t',
)

open(joinpath(@__DIR__, "SYN-6LYZ-peg8000.solvent.txt"), "w") do io
    println(io, "entry\tSYN-6LYZ-peg8000")
    println(io, "synthetic\tyes (invented buffer, no measured curve)")
    println(io, "host\t6LYZ")
    println(io, "rho_e\t", ρ, "\te/A^3")
    println(io, "sigma_rho_e\t", σρ, "\te/A^3")
    println(io, "rho_e_water\t", ρWater, "\te/A^3 (pure water, same temperature)")
    println(io, "contrast_over_water\t", ρ - ρWater, "\te/A^3")
    println(io, "temperature\t", TEMPERATURE_C, "\tC")
    println(io, "pH\t", PH, "\tsigma ", σ_PH)
    println(io, "energy\t", ENERGY_EV, "\teV")
    println(io, "delta_rho_relative\t", join(δρ, " "), "\tdimensionless (x 0.03 e/A^3)")
    println(io, "c1\t1.0\tuncorrected, scale 1, background 0")
    println(io, "q_grid\t0.01:0.005:0.5\tA^-1, 99 points")
    println(io, "composition")
    for sol in SOLUTES
        println(io, "  ", typeof(sol), "\t", sol.arg, "\t", sol.molarity, "\tmol/L")
    end
end

println("rho_e = ", ρ, " +- ", σρ, " e/A^3 (water ", ρWater, ")")
println("wrote SYN-6LYZ-peg8000.profile.tsv and SYN-6LYZ-peg8000.solvent.txt")
