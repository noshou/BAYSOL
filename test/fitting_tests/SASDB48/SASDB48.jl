using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDB48")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDB48.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDB48: HSV-1 ICP4 N-terminal DNA-binding domain (ICP4N, 24.3 kDa) dimer
# on the 19-bp IE3 DNA (two strands of 5.8 kDa), 60.3 kDa in total; a rigid-body model
# (chains G, H protein and C, D DNA; 3735 atoms, no hydrogens; the protein residues are
# written as HETATM records).
#
# Paper: Tunnicliffe RB, Lockhart-Cairns MP, Levy C, et al., Nucleic Acids Res (2017),
# DOI 10.1093/nar/gkx419 (PMID 28505309). Not bundled; the conditions below are SASBDB's
# entry metadata (https://www.sasbdb.org/data/SASDB48/).
#
# Buffer as deposited: "20 mM HEPES, 150 mM NaCl", pH 7.4. HPLC SEC-SAXS at B21 (Diamond),
# Pilatus 2M, wavelength 0.1 nm = 1.0 Å => energy = hc/λ ≈ 12398 eV; 20 °C. The measured
# complex is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (52 REMARK header lines, CRLF line endings; q,
# I, σ). The comparison file `SASDB48_fit1.dat` is a FoXS-style profile whose columns are
# q, I_exp, I_model, σ: the fitted intensity is column 3 (not 4). Its header says Chi =
# 1.545, SASBDB 2.4; column 3 against this .dat gives 2.41.

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.01-0.44, is checked below).
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the stated 0.1 nm = 1.0 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer components (the measured complex is deliberately NOT listed). Counter-ion:
# setting the pH adds a titrant that the deposited recipe does not list. Assumed: 20 mM
# HEPES titrated with NaOH -> Na⁺ = C·0.4538 (pK(22 °C) = 7.6). Same method as
# SASDKQ8.jl (pH set at 22 ± 3 °C; pK(T) from Goldberg, Kishore & Lennen 2002, J. Phys.
# Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; Davies correction at I ≈ 0.159 M; σ
# combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C). Only the
# counter-ion is modelled. Titrant not stated; NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),                # 20 mM HEPES, ±2%
    NonBiological(0.150, 0.0015, "sodium chloride"),     # 150 mM NaCl, ±1%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.009075, 0.001319, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.25

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
    pdb = "SASDB48_fit1_model1.pdb",
    fit = "SASDB48_fit1.dat",
    fit_scale = 1.0,
    fit_col = 3,
    rescale = false,
    software = "FoXS",
),   # deposited χ² = 2.4 (FoXS); I_model is column 3
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

# Builds the Seed that `run_sasdb48` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdb48` below is the whole story (build the seed, then sample it).
function seed_sasdb48(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdb48(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdb48(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdb48(run)

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

    # `@__DIR__` (this SASDB48/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
