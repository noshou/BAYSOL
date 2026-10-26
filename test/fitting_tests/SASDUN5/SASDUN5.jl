using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDUN5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUN5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUN5: Deciphering the allosteric regulation of mycobacterial
# inosine-5′-monophosphate dehydrogenase
#
# Paper: Bulvas O, Knejzlík Z, Sýs J, et al., Nature Communications (2024), DOI
# 10.1038/s41467-024-50933-6.
# Open access (CC BY); PMC PMC11303537.
# SASBDB entry: https://www.sasbdb.org/data/SASDUN5/
#
# Sample: IMPDH (tetramer, 53.257 kDa/chain); measured at up to 3.0 mg/ml (Single
# concentration).
# Instrument: Institute of Biotechnology, Czech Academy of Sciences/Centre of Molecular
# Structure (X-ray in house), wavelength 0.134 nm = 1.34 Å => energy = hc/λ ≈ 9253 eV (hc =
# 12398.42 eV·Å). Sample temperature: 20.0 °C (SASBDB record).
#
# Buffer as deposited: "50 mM HEPES, 200 mM KCl, 2 mM MgCl2, 0.5 mM TCEP", pH 7.5.
#
# The deposited string omits the ligand. This is the IMP-bound dataset: the .dat
# header's buffer blank is "10_buffer_onlyIMP10mM.dat", and the paper
# (doi:10.1038/s41467-024-50933-6, Methods, "Small angle X-ray scattering") states
# the samples were measured with nucleotide (0-10 mM) "and a 2 mM molar excess of
# MgCl2 over the nucleotide concentration. Buffer-solution datasets were collected
# under the same conditions, including the respective nucleotides." So the blank
# holds 10 mM IMP and 2 + 10 = 12 mM MgCl2 (the deposited "2 mM MgCl2" is the
# excess only). IMP is taken as the disodium salt (PMV: 'inosine 5'-monophosphate
# disodium salt', a predicted value, see BulkElectronDensity/README.md).
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
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, from the stated 0.134 nm
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 50 mM HEPES titrated with
# NaOH -> Na⁺ = C·0.519 (pK(22 °C) = 7.6). The pH is taken as set at room temperature (22 ±
# 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.292 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM, ±2%
    NonBiological(0.2, 0.004, "potassium chloride"),   # 200 mM, ±2%
    # 2 mM excess + 10 mM (= [IMP]), ±2%
    NonBiological(0.012, 0.00024, "magnesium chloride"),
    NonBiological(0.010, 0.0002, "imp disodium salt"),   # 10 mM IMP (buffer blank), ±2%
    NonBiological(0.0005, 1e-05, "tcep"),   # 0.5 mM, ±2%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.025963, 0.003365, "sodium(1+)"),
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
        tag = "fit1_model1",
        pdb = "SASDUN5_fit1_model1.pdb",
        fit = "SASDUN5_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "OLIGOMER 2-state",
    ),   # D_max ≈ 160 Å; deposited χ² = 2.21
    (
        tag = "fit1_model2",
        pdb = "SASDUN5_fit1_model2.pdb",
        fit = "SASDUN5_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "OLIGOMER 2-state",
    ),   # D_max ≈ 167 Å; deposited χ² = 2.21
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

# Builds the Seed that `run_sasdun5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdun5` below is the whole story (build the seed, then sample it).
function seed_sasdun5(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdun5(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdun5(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdun5(run)

    # The figures (terminal plots, pgfplots .tex, TSV) go before the report, so
    # that their time is in its timing section.
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
    )

    # `@__DIR__` (this SASDUN5/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
