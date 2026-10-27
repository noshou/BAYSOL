using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDCM5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCM5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDCM5: The vaccinia virus DNA polymerase structure provides insights into the
# mode of processivity factor binding (binary complex of the E9 exo- polymerase and a
# template-primer DNA hairpin, 126.2 kDa).
#
# Paper: Tarbouriech N, Ducournau C, Hutin S, et al., Nat Commun (2017), DOI
# 10.1038/s41467-017-01542-z. SASBDB entry: https://www.sasbdb.org/data/SASDCM5/ (the
# buffer, pH, temperature and instrument below are the SASBDB entry metadata; the paper
# was not consulted for them).
#
# Sample: the E9 exo- mutant (117.14 kDa, 1010 residues) with a 29-nt DNA template-primer
# hairpin (9.01 kDa), measured by SEC-SAXS. Instrument: ESRF BM29 (X-ray synchrotron),
# Pilatus 1M, wavelength 0.0992 nm = 0.992 Å => energy = hc/λ ≈ 12498 eV (hc = 12398.42
# eV·Å). Sample temperature: 20 °C (SASBDB cell temperature).
#
# Buffer as deposited: "20 mM Tris HCl, 100 mM NaCl, 4 mM DTT", pH 7.0. The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (q 0.043-4.98 nm⁻¹, 2 header lines, 19 trailer
# lines; `_read_curve` keeps the numeric rows only) and is converted to Å⁻¹ (÷10). The
# model (8838 atoms, no hydrogens) has the protein in chain A and the DNA in chains P and
# T, including the chain-terminating dideoxy-C `DOC` and a dCTP `DCP` as HETATM, plus 89
# HOH waters and one Ca²⁺; it is kept as deposited.
# The depositor's CRYSOL fit (3 columns: q in Å⁻¹, the resampled data, the CRYSOL curve)
# only runs to q = 0.2504 Å⁻¹, hence the q cut below.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.992   # ≈ 12498 eV, from the stated 0.0992 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions. Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 20 mM Tris titrated with
# HCl -> Cl⁻ = C·0.949 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.119 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.1, 0.001, "sodium chloride"),   # 100 mM, ±1%
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris-HCl, ±2%
    NonBiological(0.004, 8e-05, "dtt"),   # 4 mM, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.018977, 0.000488, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.25

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model has no hydrogens. It holds protein and DNA, so
# `seed_model` takes the mixed route (AMBER force field, PROPKA for the protein only).
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    ref_chi2 = "CRYSOL 1.08",
    pdb = "SASDCM5_fit1_model1.pdb",
    fit = "SASDCM5_fit1.fit",
    fit_scale = 1.0,
    fit_col = 3,
    rescale = false,
    software = "CRYSOL",
),   # 1010-residue E9 + 29-nt DNA, DOC/DCP/HOH/CA HETATM; deposited χ² = 1.083
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

# Builds the Seed that `run_sasdcm5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdcm5` below is the whole story (build the seed, then sample it).
function seed_sasdcm5(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdcm5(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdcm5(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdcm5(run)

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

    # `@__DIR__` (this SASDCM5/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
