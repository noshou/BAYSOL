using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDT55")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDT55.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDT55: influenza B NS1 C-terminal domain (NS1B-CTD*, 15.9 kDa) with the
# 5'-triphosphorylated 24-nucleotide hairpin RNA (7.7 kDa), 1:1, 23.6 kDa in total; a
# HADDOCK model (chain A protein, chain B RNA with legacy residue names GUA ADE URI CYT
# and GTP for the triphosphate-bearing terminal residue; 2173 atoms, 532 hydrogens).
#
# Paper: Woltz R, Schweibenz B, Tsutakawa S, et al., bioRxiv (2024), DOI
# 10.1101/2023.09.25.559316. Not bundled; the conditions below are SASBDB's entry metadata
# (https://www.sasbdb.org/data/SASDT55/), whose experiment text gives the "1K buffer":
#
#     40 mM ammonium acetate, pH 5.5, 225 mM NaCl, 5 mM CaCl2, 0.02% NaN3, 50 mM arginine
#
# SAXS at BioCAT 18ID (APS), Pilatus3 X 1M, "12 keV incident X-rays" (stated directly; the
# entry's 0.103 nm is the same energy), 250 µM (4 mg/ml) complex, capillary at 20 °C. The
# measured complex is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (4-line header: "### DATA:", a blank line, a
# column line and a point count). The comparison curve is the depositor's Pepsi-SAXS fit
# (tab-separated columns q, I_exp, σ, I_fit, CRLF line endings, two blank header lines).

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.01-0.44, is checked below).
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - arginine 50 mM: anion unknown; est. +0.074 % if Cl-, +0.060 to +0.087 % if acetate
#   - acid or base setting pH 5.5 not stated: no titrant ion modelled; est. < 0.006 %

const PH, σ_PH      = 5.5, PH_METER_SIGMA
const ENERGY_EV     = 12_000.0   # 12 keV, stated directly (BioCAT 18ID)
const TEMPERATURE_C = 20.0   # capillary at 20 °C, stated

# Buffer components (the measured complex is deliberately NOT listed). No titrant
# counter-ion is added: ammonium acetate is itself the buffer (acetate pK 4.76, ammonium
# pK 9.25) and the acid or base that sets pH 5.5 is not stated. Arginine (50 mM, net +1 at
# pH 5.5) is modelled as the neutral amino acid of the table; its counter-anion is not
# stated and is left out. 0.02 % w/v NaN3 = 0.2 g/L / 65.01 g/mol = 3.076 mM, as in
# SASDWZ9.jl.
const SOLUTES = Solute[
    NonBiological(0.040, 0.0008, "ammonium acetate"),    # 40 mM, ±2%
    NonBiological(0.225, 0.00225, "sodium chloride"),    # 225 mM NaCl, ±1%
    NonBiological(0.005, 0.00005, "calcium chloride"),   # 5 mM CaCl₂, ±1%
    NonBiological(0.003076, 0.0000615, "sodium azide"),  # 0.02 % w/v NaN₃, ±2%
    NonBiological(0.050, 0.001, "arginine"),             # 50 mM L-arginine, ±2%
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "arginine 50 mM: anion unknown; est. +0.074 % if Cl-, +0.060 to +0.087 % if acetate",
    "acid or base setting pH 5.5 not stated: no titrant ion modelled; est. < 0.006 %",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDT55: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.25

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model's 532 HADDOCK hydrogens are rebuilt by pdb2pqr (PROPKA at PH).
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    pdb = "SASDT55_fit1_model1.pdb",
    fit = "SASDT55_fit1.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "Pepsi-SAXS",
),   # deposited χ² = 1.026 (Pepsi-SAXS)
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

# Builds the Seed that `run_sasdt55` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdt55` below is the whole story (build the seed, then sample it).
function seed_sasdt55(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdt55(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdt55(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdt55(run)

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

    # `@__DIR__` (this SASDT55/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
