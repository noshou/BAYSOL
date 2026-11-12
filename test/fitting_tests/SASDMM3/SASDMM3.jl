# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDMM3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMM3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMM3: the immunity repressor of the mycobacteriophage TipsytheTRex (UniProt
# A0A2D1GKF7, 183 residues, 21.438 kDa, monomer) mixed with a 13-bp double-stranded DNA
# (GGTGGCTGTCAAG and its complement, 8.052 kDa); total solute 3.0 mg/ml (one
# concentration; SASBDB gives no molar concentrations of the two components).
# The depositor's description: "The SAXS data is best described as a mixture of 64% free
# DNA and 36% free protein (i.e., the protein and DNA do not form a complex)."
# This test is the one with FREE DNA in the solution next to a protein.
#
# Paper: McGinnis RJ, Brambley CA, Stamey B, Green WC, Gragg KN, Cafferty ER, Terwilliger
# TC, Hammel M, Hollis TJ, Miller JM, Gainey MD, Wallen JR, "A monomeric mycobacteriophage
# immunity repressor utilizes two domains to recognize an asymmetric DNA sequence",
# Nat Commun (2022, published 14 Jul), DOI 10.1038/s41467-022-31678-6 (PMID 35835745). Not
# bundled; the conditions below are SASBDB's entry metadata
# (https://www.sasbdb.org/rest-api/entry/summary/SASDMM3/).
#
# Buffer as deposited: "20 mM Tris pH 7.5, 0.5 M NaCl, 1 mM DTT". Batch SAXS at SIBYLS
# (beamline 12.3.1, ALS), Pilatus3 X 2M, 2.1 m, wavelength 0.1127 nm = 1.127 Å => energy
# = hc/λ ≈ 11001 eV (hc = 12398.42 eV·Å); cell temperature 20 °C (SASBDB; storage 4 °C).
# The measured macromolecules are deliberately NOT solutes (see BulkElectronDensity.Solute).
#
# THE TWO MODELS ARE THE FREE COMPONENTS, NOT A COMPLEX (read from the PDB files):
#   SASDMM3_fit1_model1.pdb  BILBOMD, 13-bp DNA ONLY: chain B (residues 26-38) =
#       GGTGGCTGTCAAG, chain C (residues 64-76) = CTTGACAGCCACC (the reverse complement),
#       824 atoms of which 291 hydrogens, a 5' phosphate on each strand (SASBDB "model
#       MW" 7.715 kDa).
#   SASDMM3_fit1_model2.pdb  BILBOMD, repressor ONLY: chain A, 203 residues (the
#       N-terminal His-tag MGSSHHHHHHSSGLVPRGSH, numbered -19..0, then residues 1-183 of
#       the UniProt sequence), 2863 atoms of which 1198 hydrogens, no ligand or ion
#       (SASBDB 23.58 kDa; the deposited sequence, 21.438 kDa, has no tag).
# Neither file holds both components, so there is no model of the state the depositor
# fitted (64 % free DNA + 36 % free protein); one run per model.
# NOTE: BAYSOL fits ONE structure at a time and the deposited curve is a WEIGHTED
# MIXTURE, so each single-state fit (DNA alone or protein alone) is NOT like-for-like
# with the deposited FoXS χ²; a BAYSOL χ² clearly worse than 1.18 is expected for both
# runs. The depositor's curve is drawn as a reference in both. SASBDB gives one FoXS fit
# (fit1) for the two models, with no per-model curves and no stated weights beyond the
# description above (whether 64/36 is by mass, volume or molecules is not stated).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular unit "1/A", q 0.0103-0.3002, i.e.
# s 0.103-3.002 nm⁻¹; no header, q, I, σ, arbitrary intensity scale). The comparison
# curve is the depositor's FoXS file SASDMM3_fit1.fit (3 comment lines, then q, I_exp, σ,
# I_fit; 520 points, q ≤ 0.2996; I_fit already scaled to the data, c = 3.17e-6, offset 0)
# so the fitted intensity is column 4. (The downloaded file separates its data rows by
# lone CR characters; the fixture copy has LF, see its README.txt.)

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.01-0.30, is checked below).
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.127   # ≈ 11001 eV, from the stated 0.1127 nm
const TEMPERATURE_C = 20.0   # SASBDB cell temperature (20 °C)

# Buffer components (the measured DNA and protein are deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the
# deposited recipe does not list. ASSUMED (not stated): 20 mM Tris titrated with HCl ->
# Cl⁻ = C·0.8604 = 0.017209 M (pK(22 °C) = 8.156; fraction protonated at pH 7.5, Davies
# correction at I ≈ 0.517 M). Same method as SASDMJ9.jl (pH set at 22 ± 3 °C; pK(T) from
# Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902; σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 %
# on C, in quadrature, central differences), which this calculation reproduces for
# SASDMJ9 (0.008587, σ 0.000421 vs the 0.008588, 0.000422 there); here σ = 0.000838.
# Only the counter-ion is modelled. Titrant not stated; HCl for amine bases. The
# 0.5 M NaCl is as deposited (a different titrant, e.g. NaOH-adjusted Tris base, would
# change the chloride by up to the amount above).
const SOLUTES = Solute[
    NonBiological(0.500, 0.005, "sodium chloride"),   # 0.5 M NaCl, ±1%
    NonBiological(0.020, 0.0004, "tris"),             # 20 mM Tris, ±2%
    NonBiological(0.001, 0.00002, "dtt"),             # 1 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017209, 0.000838, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# Both models are rebuilt by pdb2pqr (DNA: AMBER names, no PROPKA; protein: PROPKA at PH).
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model; `fit` is the (common) depositor curve (q scaled to Å⁻¹ by
# `fit_scale`; the fitted intensity is column `fit_col`; `rescale` = the file is
# normalized, scale it to the data). BAYSOL fits ONE structure per run, the deposited
# curve is the FoXS fit of the 64 % DNA + 36 % protein mixture, so neither run is
# like-for-like with it.
const RUNS = [
    (
        tag = "fit1_model1",
        ref_chi2 = "FoXS 1.18 (mixture of both models)",
        pdb = "SASDMM3_fit1_model1.pdb",
        fit = "SASDMM3_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "FoXS mixture",
    ),   # model 1 = the 13-bp DNA alone (64 % of the deposited mixture)
    (
        tag = "fit1_model2",
        ref_chi2 = "FoXS 1.18 (mixture of both models)",
        pdb = "SASDMM3_fit1_model2.pdb",
        fit = "SASDMM3_fit1.fit",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "FoXS mixture",
    ),   # model 2 = the repressor alone (36 % of the deposited mixture)
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

# Builds the Seed that `run_sasdmm3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdmm3` below is the whole story (build the seed, then sample it).
function seed_sasdmm3(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdmm3(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdmm3(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdmm3(run)

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

    # `@__DIR__` (this SASDMM3/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
