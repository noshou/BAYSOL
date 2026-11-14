# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Protein, DNA, RNA, Polymer, ρₑ
using BAYSOL.Scattering: intensityTerms, modelIntensity, excludedVolumeFactor
include(joinpath(@__DIR__, "..", "..", "fitting_tests", "common.jl"))   # shared constants

const _FIXTURE_DIR = joinpath(
@__DIR__, "..", "..", "fixtures", "synthetic", "SYN-6LYZ-bsa100"
)
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "6LYZ.pdb")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SYN-6LYZ-bsa100: SYNTHETIC buffer (invented, NOT measured) around a real host structure.
# There is no experimental curve and nothing is fitted: the script predicts the host's
# profile in a buffer that does not exist, so that BAYSOL, Pepsi-SAXS, CRYSOL and FoXS
# can be
# benchmarked on one and the same solvent electron density and q grid.
#
# Host (scattered molecule): PDB 6LYZ, hen egg-white lysozyme (129 aa). Chosen as a
# small, clean,
# well-known protein entry. File: 6LYZ.pdb, downloaded from files.rcsb.org (identical atom
# counts to test/fixtures/molecules/6LYZ-TEST.*). What the loader sees:
#   1001 ATOM records and 101 HETATM waters (HOH, dropped by the loader); no altlocs, no
#   hydrogens.
#
# Buffer (BSA crowder, 100 g/L; protein host in a protein crowder), pH 7.4, 25 °C.
# Solutes (molarity in mol/L, as
# the constructors take it; mass concentrations are converted below):
#   - NonBiological sodium chloride: 150 mM (±1.5 mM)
#   - Protein       BSA: 1.5024 mM (±0.0751 mM)
# Pure-water reference and the buffer both go into `<ID>.solvent.txt`.
#
# What the benchmark compares: set the solvent electron density written to
# SYN-6LYZ-bsa100.solvent.txt in Pepsi-SAXS, CRYSOL and FoXS (their solvent-density
# option), run them on
# 6LYZ.pdb (hydrogens as each program adds them) on the grid q = 0.01..0.5 Å⁻¹, step
# 0.005, and compare with SYN-6LYZ-bsa100.profile.tsv (q, I).
#
# Macromolecule solutes are BAYSOL solutes of the buffer (see
# BulkElectronDensity.Solute): the
# blank contains them, so they only shift the solvent density through their electrons and
# partial molar volume (sequence-based, titrated at the pH). Their own scattering and any
# interaction (crowding structure factor) are not modelled, and neither is excess volume.
#
# Mass concentrations (g/L = mg/ml) become molarities with the molar mass, per mole of
# chains: proteins and the tRNA take the formula weight of the RCSB polymer entity
# (data.rcsb.org, rcsb_polymer_entity.formula_weight); the DNA and RNA oligos take the
# sum of
# the RCSB chemical-component weights of their nucleotides (DA 331.222, DT 322.208, DC
# 307.197,
# DG 347.221, A 347.221, U 324.181), minus (n-1) waters (18.015) and the 5' phosphate
# (HPO3, 79.979): 5'-OH, 3'-OH strands. The 12-mer comes to 3646.39, 0.45 % below the RCSB
# entity weight 3.663 kDa of 1BNA (not resolved; below the 5 % σ). BAYSOL's own nucleic-acid
# volume keeps the 5' phosphate (one HPO3 per strand, <1 %).
# Nucleic-acid counter-ions: the polymers are taken as sodium salts, one Na⁺ per
# phosphodiester
# (n-1 per strand; 75 for the 76-nt tRNA), added as `sodium(1+)`. Net protein charge is
# not compensated (the NaCl is taken to cover it).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const WAVELENGTH_A  = 1.5418   # Å, Cu Kα (CRYSOL's default wavelength; one value for all)
const ENERGY_EV     = HC_EV_ANGSTROM / WAVELENGTH_A   # ≈ 8041 eV
const TEMPERATURE_C = 25.0                   # the temperature of the PMV tables
const ADD_HYDROGENS = true                   # as the siblings: pdb2pqr/PROPKA at PH

# The fixed grid of the benchmark, Å⁻¹.
const Q_GRID = collect(0.01:0.005:0.5)

# Sequences (canonical one-letter codes of the RCSB polymer entities named above).
# DNA 5'->3'; RNA with U.
# BSA: bovine serum albumin, RCSB 4F5S entity 1 (583 aa, formula weight 66.562 kDa)
const BSA_SEQ =
    "DTHKSEIAHRFKDLGEEHFKGLVLIAFSQYLQQCPFDEHVKLVNELTEFAKTCVADESHAGCEKSLHTLF" *
    "GDELCKVASLRETYGDMADCCEKQEPERNECFLSHKDDSPDLPKLKPDPNTLCDEFKADEKKFWGKYLYE" *
    "IARRHPYFYAPELLYYANKYNGVFQECCQAEDKGACLLPKIETMREKVLTSSARQRLRCASIQKFGERAL" *
    "KAWSVARLSQKFPKAEFVEVTKLVTDLTKVHKECCHGDLLECADDRADLAKYICDNQDTISSKLKECCDK" *
    "PLLEKSHCIAEVEKDAIPENLPPLTADFAEDKDVCKNYQEAKDAFLGSFLYEYSRRHPEYAVSVLLRLAK" *
    "EYEATLEECCAKDDPHACYSTVFDKLKHLVDEPQNLIKQNCDQFEKLGEYGFQNALIVRYTRKVPQVSTP" *
    "TLVEVSRSLGKVGTRCCTKPESERMPCTEDYLSLILNRLCVLHEKTPVSEKVTKCCTESLVNRRPCFSAL" *
    "TPDETYVPKAFDEKLFTFHADICTLPDTEKQIKKQTALVELLKHKPKATEEQLKTVMENFVAFVDKCCAA" *
    "DDKEACFAVEGPKLVVSTQTALA"

# Molar masses used below (g/mol): BSA 66562.00.
const SOLUTES = Solute[
    # 150 mM NaCl, 1 % pipetting error
    NonBiological(0.15, 0.0015, "sodium chloride"),
    # 100 g/L / 66562 g/mol = 1.5024 mM
    Protein(0.00150236, 7.512e-05, BSA_SEQ),
]

# ---------------------------------------------------------------------------
#                    Placeholder curve and the seed
# ---------------------------------------------------------------------------

# `seedModel` is the cheapest public call that builds the host's forward cache (Gram matrix
# of the five species at the grid) and the priors: it needs a curve, so a PLACEHOLDER of
# unit intensity and unit σ on the grid is passed (nothing is fitted; `rebin = nothing`
# keeps
# the 99 grid points unbinned).
const _Q   = Q_GRID
const _IPH = ones(length(_Q))
const _SPH = ones(length(_Q))

function seedSynthetic(; seed::Integer = SAMPLER_SEED)
    Random.seed!(seed)
    return BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, _Q, _IPH, _SPH, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C, rebin = nothing,
    )
end

s = seedSynthetic()
@assert s.fw.qvals ≈ _Q "the forward cache is not on the benchmark grid"

# The buffer's bulk electron density and its σ (e⁻/Å³), and pure water at the same T.
ρBuffer, σBuffer = ρₑ(PH, σ_PH, SOLUTES; t = TEMPERATURE_C)
ρWater, σWater = ρₑ(PH, σ_PH, Solute[]; t = TEMPERATURE_C)

# The predicted profile at fixed shell contrasts, the CRYSOL3 defaults (1, 1, 0 x 0.03
# e/Å³; the point the other programs run, not the mean of BAYSOL's priors), ρₑ the
# buffer's value, excluded-volume correction c₁ = 1, scale 1, background 0.
δρ = (1.0, 1.0, 0.0)
A, B, C = intensityTerms(s.fw, ρBuffer, δρ)
g = excludedVolumeFactor(s.fw.qvals, s.fw.rM, 1.0)
profile = modelIntensity(A, B, C, g)

open(joinpath(@__DIR__, "SYN-6LYZ-bsa100.profile.tsv"), "w") do io
    println(io, "# q (1/Angstrom)\tI (e^2, scale 1, no background)")
    writedlm(io, [s.fw.qvals profile], '\t')
end

open(joinpath(@__DIR__, "SYN-6LYZ-bsa100.solvent.txt"), "w") do io
    println(io, "SYN-6LYZ-bsa100: SYNTHETIC buffer, host 6LYZ")
    println(io, "rho_e (e/A^3)\t", ρBuffer)
    println(io, "sigma_rho_e (e/A^3)\t", σBuffer)
    println(io, "rho_e water (e/A^3)\t", ρWater)
    println(io, "T (C), pH, sigma_pH\t", TEMPERATURE_C, "\t", PH, "\t", σ_PH)
    println(io, "contrasts (delta rho 1..3, CRYSOL3 defaults)\t", join(δρ, "\t"))
    println(io, "composition (type, name or sequence, mol/L, sigma)")
    for x in SOLUTES
        arg = x.arg
        name = length(arg) > 30 ? arg[1:12] * "..." * "($(length(arg)) letters)" : arg
        println(io, nameof(typeof(x)), "\t", name, "\t", x.molarity, "\t",
            x.molarityUncertainty)
    end
end

println("rho_e buffer = ", ρBuffer, " ± ", σBuffer, " e/A^3 (water ", ρWater, ")")
