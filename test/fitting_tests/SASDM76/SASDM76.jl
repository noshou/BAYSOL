using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDM76")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDM76.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDM76: Long promoter sequences form higher-order G-quadruplexes: an integrative
# structural biology study of c-Myc, k-Ras and c-Kit promoter sequences (the entry is the
# 28-nt G-quadruplex 201D, d(G4T4G4T4G4T4G4), 8.9 kDa).
#
# Paper: Monsen RC, DeLeeuw LW, Dean WL, et al., Nucleic Acids Res (2022),
# DOI 10.1093/nar/gkac182. SASBDB entry: https://www.sasbdb.org/data/SASDM76/ (the buffer,
# pH, temperature and instrument below are the SASBDB entry metadata; the paper was not
# consulted for them).
#
# Sample: 201D at up to 13.1 mg/ml, co-flow SEC-SAXS. Instrument: Advanced Photon Source
# BioCAT 18ID (X-ray synchrotron), Pilatus3 X 1M, wavelength 0.1033 nm = 1.033 Å =>
# energy = hc/λ ≈ 12002 eV (hc = 12398.42 eV·Å). Sample temperature: 22 °C (SASBDB cell
# temperature).
#
# Buffer as deposited (SASBDB comment: "BPEK buffer"): "6 mM Na2HPO4, 2 mM NaH2PO4, 1 mM
# Na2EDTA, 185 mM KCl", pH 7.2. The measured macromolecule is deliberately NOT a solute
# (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q 0.0044-0.3497 Å⁻¹, 4 header lines, 80
# trailer lines; `_read_curve` keeps the numeric rows only); 29 of its 1209 points have a
# non-positive intensity, dropped by `seed_model` after binning. The model (written by
# Maestro; 914 atoms) carries 322 hydrogens and three K⁺ ions as residues `K`.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 22.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). The phosphates are stated as the two species already
# (6 mM Na2HPO4 + 2 mM NaH2PO4), so they are used as deposited: no titrant counter-ion
# is added (nothing in the recipe is titrated with a strong acid or base), although the
# stated 3:1 split would give a pH above the recorded 7.2. "1 mM Na2EDTA" is the
# disodium salt, i.e. H2EDTA²⁻ with two Na⁺ (the table has the H2EDTA ion and the
# sodium ion, not the salt); at pH 7.2 EDTA is mostly HEDTA³⁻, a difference far below the
# uncertainty of such a small contribution.
const SOLUTES = Solute[
    NonBiological(0.185, 0.00185, "potassium chloride"),   # 185 mM, ±1%
    NonBiological(0.006, 0.00012, "disodium hydrogen phosphate"),   # 6 mM Na2HPO4, ±2%
    NonBiological(0.002, 4e-05, "sodium dihydrogen phosphate"),   # 2 mM NaH2PO4, ±2%
    NonBiological(0.001, 2e-05, "H2EDTA"),   # 1 mM Na2EDTA: H2EDTA²⁻ part, ±2%
    NonBiological(0.002, 4e-05, "sodium"),   # 1 mM Na2EDTA: the two Na⁺, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model already carries 322 hydrogens (Maestro names),
# but, as for SASDWZ9, pdb2pqr drops them and places its own from the heavy atoms (324
# hydrogens in the seed build), so the hydrogen set is consistent with the other entries.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    ref_chi2 = "CRYSOL 1.779",
    pdb = "SASDM76_fit1_model1.pdb",
    fit = "SASDM76_fit1.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "CRYSOL",
),   # 201D G-quadruplex with 322 H and 3 K; deposited χ² = 1.779
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

# Builds the Seed that `run_sasdm76` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdm76` below is the whole story (build the seed, then sample it).
function seed_sasdm76(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdm76(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdm76(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdm76(run)

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

    # `@__DIR__` (this SASDM76/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
