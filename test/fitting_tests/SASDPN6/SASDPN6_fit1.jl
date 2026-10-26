using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDPN6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPN6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDPN6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDPN6_fit1.fit")

# The .dat has 2 lines of header and 7 lines of processing history at the end (frame
# lists), which break `readdlm`, so `_read_curve` (common.jl, numeric rows only) reads it:
# 2650 points.
qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
@assert length(qvals) == 2650

# qvals are in nm⁻¹ (0.024-7.37); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
# The curve runs to 0.74 Å⁻¹, still inside `Q_SANITY_RANGE`.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDPN6 (sasbdb.org/data/SASDPN6/); paper: Korn SM,
# Dhamotharan K, Jeffries CM, Schlundt A 2023, Nat. Commun., "The preference signature of
# the SARS-CoV-2 Nucleocapsid NTD for its 5'-genomic RNA elements", DOI
# 10.1038/s41467-023-38882-y (PMID 37286558). The paper's methods text was not consulted.
#
#     25 mM potassium phosphate, 150 mM KCl, 2 mM TCEP, pH 6.5
#
# Stem loop 4 with AU extension (69 nt, 22.1 kDa) of the SARS-CoV-2 5'-genomic RNA;
# in-line SEC-SAXS (Superdex 75 Increase 10/300) of a 90 µL, 6.2 mg/mL injection, cell
# at 20 °C (storage 5 °C), EMBL P12 (PETRA III), Pilatus 6M, wavelength 0.124 nm = 1.24 Å
# => energy = hc/λ ≈ 10 keV (hc = 12398.42 eV·Å); 9 frames averaged with CHROMIXS. The
# measured RNA is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Model: SASDPN6_fit1_model1.pdb, one RNA chain (A, residues G/U/C/A, 69 nt) built with
# RNAMasonry; 2191 atoms of which 731 are hydrogens (names H01-H12, a numbering of the
# builder, and a 5'-terminal phosphate). The hydrogens are not kept: see ADD_HYDROGENS.
#
# Curve units: the SASBDB .dat is in nm⁻¹ and is converted to Å⁻¹ (÷10). The comparison
# curve is the depositor's Pepsi-SAXS fit (header "Dro: Rg: Vol: Chi^2: 1.143"; entry
# χ² 1.224; columns q, I_exp, σ, I_fit).

const PH, σ_PH = 6.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, from the stated 0.124 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB (cell)

# Buffer components (the measured RNA is deliberately NOT listed). "25 mM potassium
# phosphate" is a mix of KH2PO4 and K2HPO4 at pH 6.5: the HPO4²⁻ fraction is 0.320 (pK2
# from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C (pH set at room
# temperature), Davies-corrected at I ≈ 0.191 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift and ±2 % on C. Same treatment as SASDVX2. TCEP (usually supplied as
# the hydrochloride, which acidifies the stock) is taken as the neutral molecule; no
# titrant counter-ion is added.
const SOLUTES = Solute[
    # 25 mM KPi, H2PO4⁻ part
    NonBiological(0.017010, 0.001734, "potassium dihydrogen phosphate"),
    # 25 mM KPi, HPO4²⁻ part
    NonBiological(0.007990, 0.001734, "dipotassium hydrogen phosphate"),
    NonBiological(0.150, 0.0015, "potassium chloride"),   # 150 mM KCl, ±1%
    NonBiological(0.002, 0.00004, "tcep"),                # 2 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .dat runs to 0.74 Å⁻¹ (the .fit file to 0.50 Å⁻¹); the fit is cut at 0.3 Å⁻¹ (425
# of the .dat's 2650 points are ≤ 0, the first at 0.33 Å⁻¹, i.e. none inside the fit).
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited RNAMasonry model carries 731 hydrogens (builder names H01-H12). Runs
# Pdb2pqr at PH (PARSE, no PROPKA for a nucleic-acid-only file), which rebuilds the
# hydrogens from the heavy atoms, as for the other models that arrive with hydrogens
# (SASDT55, SASDWZ9).
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`. (`seed_model`
bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(≤(Q_MAX_FIT), qvals)
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdpn6_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdpn6_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdpn6_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdpn6_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdpn6_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdpn6_fit1()

fit, divergence_rate, map_result, quantile_result = result

# The figures (terminal plots, pgfplots .tex, TSV) go before the report, so
# that their time is in its timing section.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "Pepsi-SAXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
)

# `@__DIR__` (this SASDPN6/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
