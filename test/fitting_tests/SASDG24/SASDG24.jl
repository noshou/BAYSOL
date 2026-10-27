using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDG24")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDG24.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDG24: Long non-coding subgenomic flavivirus RNAs have extended 3D structures
# and are flexible in solution (the entry is the Dengue virus 2 sfRNA, 423 nt, 136.9 kDa).
#
# Paper: Zhang Y, Zhang Y, Liu ZY, et al., EMBO Rep (2019), DOI
# 10.15252/embr.201847016. SASBDB entry: https://www.sasbdb.org/data/SASDG24/ (the buffer,
# pH, temperature and instrument below are the SASBDB entry metadata; the paper was not
# consulted for them).
#
# Sample: 0.75-3.0 mg/ml series, extrapolated to infinite dilution. Instrument: Advanced
# Photon Source 12-ID-B (X-ray synchrotron), Pilatus 2M, wavelength 0.08857 nm = 0.8857 Å
# => energy = hc/λ ≈ 13998 eV (hc = 12398.42 eV·Å). Sample temperature: 25 °C (SASBDB
# cell temperature).
#
# Buffer as deposited: "20mM Tris-HCl, 100mM NaCl, 5mM MgCl2", pH 7.5. The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q 0-0.3 Å⁻¹, no header or trailer
# lines; SASBDB's "1/A" agrees with the range); its first row is q = 0 and two rows have
# σ = 0, which `fit_subset` drops. The deposited model is a single atomistic model (12366
# atoms, 3305 of them hydrogens) with the legacy residue names GUA/ADE/URI/CYT and a
# blank chain id. The depositor's `.fit` is an EOM *ensemble* fit (header "CYCLE: 89
# Chi^2: 0.350 ... ENSEMBLES: 50 CURVES: 3"): the one deposited model is fitted here, so
# the curve overlaid is the ensemble's, not that of this model. Recomputed from the file,
# the ensemble curve has χ² 2.49 against the data, not the 0.35 of its header.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.8857   # ≈ 13998 eV, from the stated 0.08857 nm
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions. Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 20 mM Tris titrated with
# HCl -> Cl⁻ = C·0.855 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.132 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.1, 0.001, "sodium chloride"),   # 100 mM, ±1%
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris-HCl, ±2%
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017105, 0.000856, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.25

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model already carries 3305 hydrogens, but, as for
# SASDWZ9, pdb2pqr drops them and places its own from the heavy atoms (4576 hydrogens in the
# seed build). The legacy residue names GUA/ADE/URI/CYT and the blank chain id are left as
# deposited; the seed build's `classify` note reports them.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    ref_chi2 = "EOM ensemble 0.35 (2.49 recomputed from the file)",
    pdb = "SASDG24_fit2_model1.pdb",
    fit = "SASDG24_fit2.fit",
    fit_scale = 1.0,
    fit_col = 3,
    rescale = false,
    software = "EOM ensemble",
),   # 423-nt sfRNA, single model of an EOM fit; header χ² = 0.350 (2.49 from the file)
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

# Builds the Seed that `run_sasdg24` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdg24` below is the whole story (build the seed, then sample it).
function seed_sasdg24(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdg24(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdg24(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdg24(run)

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

    # `@__DIR__` (this SASDG24/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
