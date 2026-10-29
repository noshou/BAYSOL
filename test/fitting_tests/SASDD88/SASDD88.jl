# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDD88")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDD88.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDD88: M. tuberculosis class II apurinic/ apyrimidinic-endonuclease/3'-5'
# exonuclease (XthA) engages with NAD+-dependent DNA ligase A (LigA) to counter
# futile cleavage and ligation cycles in base excision repair.
#
# Paper: Khanam T, Afsar M, Shukla A, et al., Nucleic Acids Res
# (2020), DOI 10.1093/nar/gkaa188. Open access (CC BY NC); PDF not in
# the repository, see test/fixtures/experiments/SASDD88/README.txt
# (PMC PMC7530888). SASBDB entry: https://www.sasbdb.org/data/SASDD88/
#
# Sample: BRCT (monomer, 9.449 kDa/chain); measured at up to 10.0 mg/ml
# (Single concentration). Instrument: CSIR-Central Drug Research Institute
# (X-ray in house), wavelength 0.154 nm = 1.54 Å => energy = hc/λ ≈ 8051
# eV (hc = 12398.42 eV·Å). Sample temperature: 10.0 °C (SASBDB record).
#
# Buffer as deposited: "50 mM Tris-HCl 500 mM NaCl 5mM β-mercaptoethanol", pH 8.0.
# Conflict: the paper's SAXS Methods (Khanam et al. 2020) say "All proteins were in
# buffer containing 50 mM Tris pH 8.0, 200 mM NaCl and 2 mM βME" for its ESRF BM29
# measurements, while this entry is in-house (Anton Paar SAXSpace, CSIR-CDRI) and
# both its structured buffer field and free-text description give 500 mM NaCl / 5 mM
# βME. The dataset-specific SASBDB record is used. Curve units: the SASBDB .dat is
# in nm⁻¹ and is converted to Å⁻¹ (÷10). The reference fit files are read from the
# same folder; each run's comparison curve is the depositor's fit for that model.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, from the stated 0.154 nm
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 50 mM Tris titrated with
# HCl -> Cl⁻ = C·0.661 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.533 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM, ±2%
    NonBiological(0.5, 0.01, "sodium chloride"),   # 500 mM, ±2%
    NonBiological(0.005, 0.0001, "2-mercaptoethanol"),   # 5 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.033042, 0.003639, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
        tag = "fit2_model1",
        ref_chi2 = "FoXS 4.50",
        pdb = "SASDD88_fit2_model1.pdb",
        fit = "SASDD88_fit2.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "FoXS",
    ),   # D_max ≈ 43 Å; deposited χ² = 4.498
    (
        tag = "fit3_model1",
        ref_chi2 = "FoXS 2.79",
        pdb = "SASDD88_fit3_model1.pdb",
        fit = "SASDD88_fit3.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "FoXS",
    ),   # D_max ≈ 57 Å; deposited χ² = 2.79
]

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdd88` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdd88` below is the whole story (build the seed, then sample it).
function seed_sasdd88(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdd88(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdd88(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdd88(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

    # run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
    fit_curve = try
        fc = _read_fit(joinpath(_FIXTURE_DIR, run.fit), run.fit_scale, run.fit_col)
        fc !== nothing && run.rescale ? _rescale_fit(fc, q_fit, I_fit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    references = BAYSOL.Reference[]
    if fit_curve !== nothing
        push!(
            references,
            BAYSOL.Reference(
                run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""),
                fit_curve...; q_max = Q_MAX_FIT,
            ),
        )
    end
    BAYSOL.results(
        result, (q_fit, I_fit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        form_factor_log = form_factor_log, n_atoms = n_atoms,
        ref_chi2 = run.ref_chi2,
        run_log = true,
    )

    # `@__DIR__` (this SASDD88/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
