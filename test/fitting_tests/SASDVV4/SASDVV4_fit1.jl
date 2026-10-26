using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVV4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVV4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVV4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVV4_fit1.fit")

# The .dat has 2 lines of header and 9 lines of processing history at the end, and the
# latter break `readdlm` (SASDVV4's has quote characters), so `_read_curve` (common.jl,
# numeric rows only) reads it: 273 points.
qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
@assert length(qvals) == 273

# qvals are in nm⁻¹ (0.06-31.9); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
# The curve runs to 3.19 Å⁻¹, beyond `Q_SANITY_RANGE`, so only the part up to 0.5 Å⁻¹
# (well past `Q_MAX_FIT`) is checked.
check_q_angstrom(filter(≤(0.5), qvals))

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDVV4 (sasbdb.org/data/SASDVV4/); paper: Gezelle
# et al. 2025, Nucleic Acids Res., "A conserved viral RNA fold enables nuclease resistance
# across kingdoms of life", DOI 10.1093/nar/gkaf840 (PMID 40884403). The paper's methods
# text was not consulted.
#
#     50 mM Tris pH 7.5, 100 mM NaCl, 1 mM DTT, 10 mM MgCl2, 0.0002% w/v NaN3
#
# ST9 RNA, wild type (54 nt, 17.5 kDa), in-line SEC-SAXS (Superdex 200 Increase) of a
# 3 mg/mL injection, 20 °C, NSLS-II 16-ID (LiX), wavelength 0.082 nm => energy =
# hc/λ ≈ 15.1 keV (hc = 12398.42 eV·Å). SASBDB gives no separate pH field; the pH is the
# 7.5 of the buffer name. The model is the deposited RNA chain plus one Mg²⁺ HETATM.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 0.82   # ≈ 15120 eV, from the stated 0.082 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB

# Buffer components. 0.0002 % w/v NaN3 = 0.002 g/L / 65.01 g/mol = 3.08e-5 M. Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# Assumed: 50 mM Tris titrated with HCl -> Cl⁻ = C·0.858 (pK(22 °C) = 8.156). The pH is
# taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion amount
# whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-
# corrected at I ≈ 0.173 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift,
# and ±2 % on C. Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine, Bis-Tris), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.050, 0.001, "tris"),                  # 50 mM Tris, ±2%
    NonBiological(0.100, 0.001, "sodium chloride"),       # 100 mM NaCl, ±1%
    NonBiological(0.001, 0.00002, "dtt"),                 # 1 mM DTT, ±2%
    NonBiological(0.010, 0.0001, "magnesium chloride"),   # 10 mM MgCl2, ±1%
    NonBiological(3.076e-5, 6.2e-7, "sodium azide"),      # 0.0002 % w/v NaN3, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.042877, 0.002138, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .dat runs to 3.19 Å⁻¹ (the .fit file to 1.48 Å⁻¹); the fit is cut at 0.3 Å⁻¹.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE, no PROPKA for a
# nucleic-acid-only file)
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

# Builds the Seed that `run_sasdvv4_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdvv4_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdvv4_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdvv4_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdvv4_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdvv4_fit1()

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

# `@__DIR__` (this SASDVV4/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
