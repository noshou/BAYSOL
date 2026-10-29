# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDNP7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNP7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNP7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNP7_fit1.fit")

# no header and no trailer lines; q is already in Å⁻¹ (0.0159-0.4002).
raw = readdlm(_DATA_PATH)

qvals = Float64.(raw[1:581, 1])
I_exp = Float64.(raw[1:581, 2])
σ_exp = Float64.(raw[1:581, 3])

check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDNP7 (sasbdb.org/data/SASDNP7/); paper: Gabel et
# al. 2022, Acta Cryst. D 78, 1120, "Medical contrast agents as promising tools for
# biomacromolecular SAXS experiments", DOI 10.1107/S2059798322007392 (PMID 36048152). The
# paper's methods text was not consulted.
#
#     10 mM MOPS-NaOH pH 6.7, 200 mM NaCl, 5 mM MgCl 2, 1 mM GDPNP
#
# aIF2 (γ and α subunits) bound to tRNA (79.4 kDa), 1.65 mg/mL, 15 °C (cell), SOLEIL
# SWING, wavelength 0.1 nm as recorded => energy = hc/λ ≈ 12.4 keV (hc = 12398.42 eV·Å).
# The curve is the one WITHOUT the Gd-HPDO3A contrast agent. The model has chains A, B, D
# (aIF2-γ, aIF2-α, tRNA) with GNP, Mg²⁺ and modified tRNA nucleotides (4SU, H2U, OMC, 5MU,
# PSU as HETATM), kept as deposited. GDPNP (1 mM, the GNP in the model) is not in the
# bundled solute tables and is left out of the solutes.

# GDPNP (1 mM) is modelled as its tetrasodium salt (3D-RISM estimate anchored on the
# measured GTP tetrasodium, 288.8 ± 22 cm³/mol; not a measurement). The cations of the
# deposited recipe are not stated, so the Na⁺ content is an assumption (+0.027 % of water).

const PH, σ_PH = 6.7, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the recorded 0.1 nm
const TEMPERATURE_C = 15.0                   # 15 °C, SASBDB (cell)

# Buffer components. Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# Assumed: 10 mM MOPS titrated with NaOH -> Na⁺ = C·0.288 (pK(22 °C) = 7.222). The pH is
# taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion amount
# whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-
# corrected at I ≈ 0.218 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift,
# and ±2 % on C. Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine, Bis-Tris), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.010, 0.0002, "mops"),                 # 10 mM MOPS, ±2%
    NonBiological(0.200, 0.002, "sodium chloride"),       # 200 mM NaCl, ±1%
    NonBiological(0.005, 0.00005, "magnesium chloride"),  # 5 mM MgCl2, ±1%
    NonBiological(0.001, 0.00002, "gdpnp"),               # 1 mM GDPNP (Na4 salt), ±2%
    # Na⁺ counter-ion from NaOH titration of MOPS (see note above)
    NonBiological(0.002881, 0.000544, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .dat and the .fit file both end at 0.40 Å⁻¹; the fit is cut at 0.3 Å⁻¹.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr with PROPKA (protein + RNA
# mixed file) at PH; the five modified tRNA bases are hydrogenated through their parent
# base by the pipeline (an approximation; nothing special is done here)
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

# Builds the Seed that `run_sasdnp7_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdnp7_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdnp7_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdnp7_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdnp7_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdnp7_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 3]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "CRYSOL 29.579",
    run_log = true,
)

# `@__DIR__` (this SASDNP7/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
