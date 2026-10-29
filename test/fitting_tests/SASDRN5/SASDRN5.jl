# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDRN5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRN5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRN5: Structural and functional analysis of a plant nucleolar RNA chaperone-like
# protein.
#
# Paper: Fernandes R, Ostendorp A, Ostendorp S, et al., Sci Rep (2023),
# DOI 10.1038/s41598-023-36426-4. Open access (CC BY, CC BY SA); PDF not
# in the repository, see test/fixtures/experiments/SASDRN5/README.txt
# (PMC PMC10267116). SASBDB entry: https://www.sasbdb.org/data/SASDRN5/
#
# Sample: NURC1 (monomer, 25.262 kDa/chain); measured at up to 18.0 mg/ml (SEC-SAS).
# Instrument: PETRA III (X-ray synchrotron), wavelength 0.124 nm = 1.24 Å => energy = hc/λ ≈
# 9999 eV (hc = 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "50 mM HNa2PO4, 300 mM NaCl, 5% glycerol (v/v), 1 mM
# DTT", pH 7.5. Only the components with a partial-molar-volume entry and a
# stated concentration are modelled below; the measured macromolecule is
# deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# '50 mM HNa2PO4' is disodium hydrogen phosphate (Na2HPO4), which is in the PMV
# table; titrated to pH 7.5 (titrant not stated) it is a Na2HPO4/NaH2PO4 mixture, so
# it is split into its two species with Na⁺ as counter-cation. The HPO4²⁻ fraction is
# 0.835: pK2 from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231,
# DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C (pH set at
# room temperature), Davies-corrected at I ≈ 0.433 M, giving an effective pK2' ≈
# 6.80. This replaces the earlier flat pKa2 = 7.2, which ignored ionic strength. σ
# combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
#
# Curve units: the SASBDB .dat is in nm⁻¹ and is converted to Å⁻¹ (÷10). The
# reference fit files are read from the same folder; each run's comparison
# curve is the depositor's fit for that model.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, from the stated 0.124 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately
# NOT listed: ρₑ is the buffer's electron density).
const SOLUTES = Solute[
    NonBiological(0.3, 0.006, "sodium chloride"),   # 300 mM, ±2%
    NonBiological(0.6846265772, 0.01369253154, "glycerol"),   # 684.6 mM, ±2%
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM, ±2%
    # 50 mM NaPi, H2PO4⁻ part
    NonBiological(0.008258, 0.002534, "sodium dihydrogen phosphate"),
    # 50 mM NaPi, HPO4²⁻ part
    NonBiological(0.041742, 0.002663, "disodium hydrogen phosphate"),
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
        ref_chi2 = "SREFLEX 3.04",
        pdb = "SASDRN5_fit2_model1.pdb",
        fit = "SASDRN5_fit2.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "SREFLEX",
    ),   # D_max ≈ 120 Å; deposited χ² = 3.035
    (
        tag = "fit3_model1",
        ref_chi2 = "CRYSOL 12.0",
        pdb = "SASDRN5_fit3_model1.pdb",
        fit = "SASDRN5_fit3.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "CRYSOL",
    ),   # D_max ≈ 122 Å; deposited χ² = 11.97
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

# Builds the Seed that `run_sasdrn5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdrn5` below is the whole story (build the seed, then sample it).
function seed_sasdrn5(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdrn5(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdrn5(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdrn5(run)

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

    # `@__DIR__` (this SASDRN5/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
