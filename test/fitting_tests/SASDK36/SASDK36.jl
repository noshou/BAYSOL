# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDK36")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDK36.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDK36: LC-18t, a 35-nucleotide single-stranded DNA aptamer against lung
# adenocarcinoma cells (10.8 kDa), modelled by a GROMACS MD frame (chain X, 1109 atoms,
# 395 hydrogens).
#
# Paper: Morozov D, Mironov V, Moryachkov R, et al., Mol Ther Nucleic Acids (2021),
# DOI 10.1016/j.omtn.2021.07.015 (open access, PMC8379633). SASBDB entry:
# https://www.sasbdb.org/data/SASDK36/
#
# Buffer: SASBDB gives only "Phosphate-buffered saline", pH 7.4, and no recipe. The paper
# (sections 2.4 and 4.5, simulations "carried out under the conditions of the SAXS
# experiments") states the ions as "Na+ 146 mM and Mg2+ 0.5 mM", at 5 and 20 °C; those two
# numbers are what the buffer below is built from (see SOLUTES for the assumption). SAXS
# at P12 (EMBL, PETRA III), Pilatus 6M, wavelength 0.12 nm = 1.2 Å => energy = hc/λ
# ≈ 10332 eV; batch mode, 1-8 mg/ml dilution series, cell 20 °C (SASBDB). The measured
# aptamer is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Curve units: the SASBDB .dat ("Merged" curve) is in nm⁻¹ with a 3-line header and 50
# trailing lines of beam information, and is converted to Å⁻¹ (÷10). The comparison curve
# is the depositor's CRYSOL fit2 (columns q, I_exp, σ, I_fit; the rows at q = 0 have
# σ = 0 and fall outside the plotted range).

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - PBS phosphate and K+: concentration unknown; est. +0.114 % (standard PBS recipe)
#   - Na+ 146 mM taken wholly as NaCl; part may be phosphate sodium (approximation)

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # ≈ 10332 eV, from the stated 0.12 nm = 1.2 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer components (the measured aptamer is deliberately NOT listed). ASSUMED from the
# paper's ion statement, not from a recipe: Na⁺ 146 mM is taken as NaCl and Mg²⁺ 0.5 mM
# as MgCl₂. The phosphate of the "phosphate-buffered saline" (and any K⁺) has no stated
# concentration and is left out; no counter-ion is added for the same reason.
const SOLUTES = Solute[
    NonBiological(0.146, 0.00146, "sodium chloride"),     # Na⁺ 146 mM as NaCl, ±1%
    NonBiological(0.0005, 0.00001, "magnesium chloride"),   # Mg²⁺ 0.5 mM as MgCl₂, ±2%
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "PBS phosphate and K+: concentration unknown; est. +0.114 % (standard PBS recipe)",
    "Na+ 146 mM taken wholly as NaCl; part may be phosphate sodium (approximation)",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDK36: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model's 395 GROMACS hydrogens are rebuilt by pdb2pqr.
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit2_model1",
    ref_chi2 = "CRYSOL 2.615",
    pdb = "SASDK36_fit2_model1.pdb",
    fit = "SASDK36_fit2.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 2.615 (CRYSOL)
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

# Builds the Seed that `run_sasdk36` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdk36` below is the whole story (build the seed, then sample it).
function seed_sasdk36(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdk36(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdk36(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdk36(run)

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

    # `@__DIR__` (this SASDK36/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
