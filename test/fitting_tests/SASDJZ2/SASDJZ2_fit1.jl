using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJZ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJZ2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDJZ2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJZ2_fit1.fit")

raw = readdlm(_DATA_PATH; skipstart = 3)

# has 3 lines of headers (run description lines), no trailer: all 1727 rows are data.
qvals = Float64.(raw[1:1727, 1])
I_exp = Float64.(raw[1:1727, 2])
σ_exp = Float64.(raw[1:1727, 3])

# qvals are in nm⁻¹ (SASBDB "1/nm", range 0.0758-4.665); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata (sasbdb.org/data/SASDJZ2/); paper: Czapinska H, Kowalska M,
# Zagorskaite E, Manakova E, Slyvka A, Xu SY, Siksnys V, Sasnauskas G, Bochtler M 2018,
# Nucleic Acids Res., "Activity and structure of EcoKMcrA", DOI 10.1093/nar/gky731. Open
# access (PMC6182155), no PDF is bundled; the numbers below are SASBDB's (the same buffer
# as the sister entry SASDJY2).
#
#   Sample:   N-terminal domain of EcoKMcrA (20.633 kDa) with the cognate hemimethylated
#             12-bp oligoduplex (7.435 kDa), 28.1 kDa in total, 1.14 mg/mL
#   Buffer:   "20 mM Tris–HCl pH 7.5, 200 mM KCl, 0.1 mM EDTA, 0.01% (w/v) sodium azide
#             and 1 mM DTT", pH 7.5
#   Temp.:    20 °C (cell; storage 10 °C)
#   Beamline: PETRA III EMBL P12, Pilatus 2M, wavelength 0.124 nm = 1.24 Å => energy =
#             hc/λ = 12398.42 eV·Å / 1.24 Å ≈ 9999 eV
#   Model:    SASDJZ2_fit1_model1.pdb, deposited with the CRYSOL fit1 (χ² 1.654): chains A
#             (protein) and G, H (the DNA duplex), 1876 atoms, no hydrogens, no HETATM.
#             SASBDB notes that the DNA in the model is homologous and does not correspond
#             in sequence to the DNA of the complex that was measured.

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - EDTA 0.1 mM: cations not stated (tetra-anion modelled); est. up to +0.0004 % as Na+

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, from the stated 0.124 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB cell temperature

# Buffer components. All names below are in the bundled NonBiological tables
# (src/BulkElectronDensity/NonBiological/nonbio_lookup.json).
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 20 mM Tris titrated with HCl -> Cl⁻ = C·0.859 (pK(22 °C) = 8.156).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.217 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C. Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris,
# imidazole, histidine), NaOH for Good's buffers.
# Sodium azide: 0.01 % w/v = 0.1 g/L / 65.01 g/mol = 1.538 mM, as in SASDJY2.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.02, 0.0004, "tris"),                              # 20 mM, ±2%
    NonBiological(0.2, 0.002, "potassium chloride"),                  # 200 mM KCl, ±1%
    NonBiological(0.0001, 2e-06, "edta"),                             # 0.1 mM, ±2%
    NonBiological(0.001538224888, 3.076449777e-05, "sodium azide"),   # 1.538 mM, ±2%
    NonBiological(0.001, 2e-05, "dtt"),                               # 1 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017182, 0.000852, "chloride"),
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "EDTA 0.1 mM: cations not stated (tetra-anion modelled); est. up to +0.0004 % as Na+",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDJZ2: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# 0.3: the .dat and the depositor's fit file reach 0.4665 Å⁻¹, but the fit is cut at 0.3 as
# for the sister entry SASDJY2 (54 of the 1727 points are ≤ 0, mostly at high q).
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has no hydrogens. It holds protein and DNA, so
# `seed_model` runs PROPKA for the protein at PH and takes the nucleotides as supplied.
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdjz2_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdjz2_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdjz2_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdjz2_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdjz2_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdjz2_fit1()

fit, divergence_rate, map_result, quantile_result = result

# The figures (terminal plots, pgfplots .tex, TSV) go before the report, so
# that their time is in its timing section.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
)

# `@__DIR__` (this SASDJZ2/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
