using DelimitedFiles
using Statistics
using Random
using GLMakie
using BayeSol
using BayeSol.MolecularStructure: LocalPathSource, resolve_structure, load_molecule,
    propka_pKas, resolve_hydrogens, Ionization
using BayeSol.Solvation: protein_cavity_electrostatics
using BayeSol.Scattering: forward_cache
using BayeSol.Fitting: Solute, Protein, NonBiological, PROFILE, seed_fitting

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "fixtures", "SASDMJ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMJ9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDMJ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDMJ9_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 5)

# has 5 lines of headers, and some beam info at the end; need to skip.
# `raw` itself comes back `Matrix{Any}` (readdlm parses the whole file,
# trailing text metadata included, so it can't infer a concrete element
# type) even though the retained rows are all numeric -- convert to Float64
# explicitly, since leaving these `Vector{Any}` propagates into `Seed`'s own
# type parameter and breaks `ForwardDiff`/`wls_fit`'s type inference deep
# inside the NUTS gradient (`zero(::Type{Any})` MethodError).
qvals   = Float64.(raw[1:2048, 1])
I_exp   = Float64.(raw[1:2048, 2])
σ_exp   = Float64.(raw[1:2048, 3])

# qvals are in nm⁻¹; must convert to Å⁻¹. Cross-check: X33's stated maximum
# recordable momentum transfer (see ENERGY_EV below) was 0.6 Å⁻¹, and this
# file's own max q/10 = 0.567 Å⁻¹ -- comfortably inside that bound, which
# confirms the nm⁻¹ read rather than some other unit.
qvals = qvals ./ 10

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: Xiao et al. 2012, J. Virol. 86(6):3144-3157 ("FCoV Nsp7 and Nsp8
# Form a 2:1 Heterotrimer..."), test/fixtures/SASDMJ9/xiao-et-al-2012-*.pdf.
#
# SASDMJ9 is SASBDB's entry for FCoV Nsp7 *alone* (confirmed independently:
# SASDMJ9_fit1_model1.pdb's two chains, B and C, carry the identical
# 82-residue sequence in NSP7_SEQ below -- a homodimer, matching the paper's
# own description, in the SAXS section, of comparing the data to a curve
# "calculated by CRYSOL from a dimeric model").
#
# The buffer that matters here is the one used for the SEC step immediately
# preceding SAXS ("SEC" paragraph, Materials and Methods) -- *not* buffer
# A/B (50 mM Tris-HCl [pH 7.5], 300 mM NaCl [+imidazole], used only during
# Ni-affinity purification, several steps upstream):
#
#     10 mM Tris-HCl (pH 7.5), 200 mM NaCl, 5 mM DTT
#
# The SAXS concentration series for Nsp7 alone was 1.2, 2.4, 4.7, 9.4 mg/ml
# ("SAXS" paragraph); no concentration dependence was observed, and "the
# SAXS data from the most concentrated sample were used for further
# analysis" -- i.e. this file should be the 9.4 mg/ml curve.
#
# X33 (EMBL BioSAXS, DORIS storage ring, DESY Hamburg) recorded at a stated
# wavelength of 1.54 Å ("SAXS" paragraph) => energy = hc/λ ≈ 8051 eV
# (hc = 12398.42 eV·Å). Sample temperature was stated explicitly as 20°C.

const PH, σ_PH = 7.5, 0.1   # pH not given a stated uncertainty in the paper; ±0.1 is a typical benchtop pH-meter precision

const ENERGY_EV      = 12398.42 / 1.54   # ≈ 8051 eV, from X33's stated 1.54 Å wavelength
const TEMPERATURE_C   = 25.0             
const IONIC_STRENGTH_M = 0.200           # 200 mM NaCl, matches the SEC/SAXS buffer above

# Nsp7 sequence, read directly off SASDMJ9_fit1_model1.pdb chain B (residues
# 2-83, 82 residues). Chain C models the identical sequence plus a 2-residue
# Gly-Ser cloning-tag remnant at residues 0-1 that's disordered (not modeled)
# in chain B; the tag-free chain B sequence is used here as the dominant,
# biologically relevant species (the paper itself describes the mature
# protein, not the tag, as "Nsp7").
const NSP7_SEQ = "KLTEMKCTNVVLLGLLSKMHVESNSKEWNYCVGLHNEINLCDDPDAVLEKLLALIAFFLSKHNTCDLSDLIESYFENTTILQ"

# Average mass from NSP7_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH).
const NSP7_MW = 9331.77   # g/mol

# Most concentrated sample (9.4 mg/ml == 9.4 g/L, per the paper) / MW ->
# per-chain (monomer) molarity.
const NSP7_CONC_MG_ML = 9.4
const NSP7_MOLARITY   = NSP7_CONC_MG_ML / NSP7_MW           # ≈ 1.007 mM
const NSP7_MOLARITY_σ = 0.05 * NSP7_MOLARITY                # 5% relative: typical A280/mg-ml concentration-determination precision

# Buffer components
const SOLUTES = Solute[
    Protein(NSP7_MOLARITY, NSP7_MOLARITY_σ, NSP7_SEQ),
    NonBiological(0.200, 0.002,   "sodium chloride"),   # 200 mM NaCl, ±1%
    NonBiological(0.010, 0.0002,  "tris"),              # 10 mM Tris-HCl, ±2%
    NonBiological(0.005, 0.0001,  "dtt"),               # 5 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# Restrict fitting to q ≤ 0.3 Å⁻¹: comfortably clear of the noise floor
# above ~0.37 Å⁻¹ where 3 points in the raw curve go negative (visible in
# `sasdmj9_figure` below), and still well past the Guinier region given the
# reference GNOM fit's Rg = 19.11 Å (SASDMJ9_fit1.fit header, q·Rg ≲ 1.3
# breaks down around q ≈ 0.068 Å⁻¹). Decimated down from ~1000 raw points in
# that range to keep one real NUTS run (gradient of the forward model on
# every leapfrog step) tractable.
const Q_MAX_FIT    = 0.3
const N_FIT_POINTS = 150

# lMax = 15 follows the usual q·D_max multipole-resolution rule of thumb:
# D_max for a roughly globular dimer with Rg = 19.11 Å is ~45-65 Å, and
# Q_MAX_FIT * D_max ≈ 0.3 * 50 ≈ 15.
const LMAX = 15

const ADD_HYDROGENS = true   # runs PDB2PQR at PH; needs CondaPkg-provisioned pdb2pqr/propka3, same assumption test_pdb2pqr.jl/test_integration.jl make

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and decimated to about
`N_FIT_POINTS` points, evenly spaced in index (not q) across the retained
range.
"""
function fit_subset()
    keep = findall(q -> q <= Q_MAX_FIT, qvals)
    idx = unique(round.(Int, range(first(keep), last(keep); length = N_FIT_POINTS)))
    return qvals[idx], I_exp[idx], σ_exp[idx]
end

function run_sasdmj9(; n_samples::Int = 500, n_adapt::Int = 250, seed::Integer = 0)
    q_fit, I_fit, σ_fit = fit_subset()

    path  = resolve_structure(LocalPathSource(_PDB_PATH))
    pKa_records = propka_pKas(path)
    hpath = resolve_hydrogens(path, pKa_records, PH; add = ADD_HYDROGENS)
    mol, residues = load_molecule(hpath)

    fw = forward_cache(mol, q_fit, LMAX, ENERGY_EV)

    ionization = Ionization(residues, pKa_records, PH, σ_PH)
    μ_χ, σ_χ = protein_cavity_electrostatics(
        mol, residues, ionization;
        ionic_strength_M = IONIC_STRENGTH_M, T = TEMPERATURE_C + 273.15,
    )

    Random.seed!(seed)
    s = seed_fitting(fw, I_fit, σ_fit, PH, σ_PH, SOLUTES; μ_χ = μ_χ, σ_χ = σ_χ, t = TEMPERATURE_C)
    samples, stats = BayeSol.run_model(s, n_samples, n_adapt; l = PROFILE())
    return samples, stats, (q_fit, I_fit, σ_fit)
end

samples, stats = run_sasdmj9()
print("\n")
print(samples)
print("\n")
print(stats)

# function sasdmj9_figure()
#     fig = Figure(size = (600, 450))

#     ax = Axis(
#         fig[1, 1],
#         xlabel = "q (Å⁻¹)",
#         ylabel = "I(q)",
#         # 3 points have I <= 0 (noise floor at high q), so a log y-axis would
#         # drop/error on them -- leave linear unless those are filtered out first.
#     )

#     errorbars!(ax, qvals, I_exp, σ_exp; whiskerwidth = 4, color = (:gray40, 0.6))
#     scatter!(ax, qvals, I_exp; markersize = 4, color = :dodgerblue)

#     return fig
# end

# "Display the SASDMJ9 experimental curve. Blocks until the window is closed."
# vis_sasdmj9() = wait(display(sasdmj9_figure()))
