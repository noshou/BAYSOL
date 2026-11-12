# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDQ79")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQ79.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQ79: the catalytically dead D95A mutant of DpdA (DNA-guanine
# transglycosylase, Salmonella enterica serovar Montevideo, UniProt P0DW33, N-terminal
# His-tag construct of 437 residues, 50.4 kDa) bound to a 28 bp double-stranded DNA
# (GGGGTTTTCGCCAGCTGGCGTTTTGGGG and its complement, 17.3 kDa); the complex is 66.7 kDa.
# This is a PROTEIN-DNA entry: the same DNA substrate as SASDQ69 (DNA alone).
#
# Paper: Gedara SH, Wood E, Gustafson A, et al., Nucleic Acids Res (2023), DOI
# 10.1093/nar/gkad141 (PMID 36928176). Not bundled; the conditions below are SASBDB's
# entry metadata (https://www.sasbdb.org/data/SASDQ79/), which does not state the
# concentrations of the macromolecules for this entry.
#
# Buffer as deposited: "100 mM KCl, 50 mM Tris pH 7.0, 1 mM DTT". In-line SEC-SAXS at
# SIBYLS (beamline 12.3.1, ALS), Pilatus3 X 2M, wavelength 0.1 nm = 1.0 Å => energy =
# hc/λ ≈ 12398 eV (hc = 12398.42 eV·Å); cell temperature 24.9 °C (SASBDB). The measured
# complex is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Model (SASDQ79_fit1_model1.pdb, GROMACS; SASBDB comment: "Homology modeling combined
# with molecular dynamics built DpdA-DNA complex model", 66.68 kDa), as read from the
# file: chain A = DNA strand 1 (28 nt, DG DG DG DG DT DT DT DT DC DG DC DC DA DG DC DT DG
# DG DC DG DT DT DT DT DG DG DG DG), chain B = strand 2 (28 nt, the complement), chain C =
# the protein, 435 residues numbered 1-435 (the construct's N-terminal His-tag
# HHHHHHSSGLVPRGSHMHMA... then the DpdA sequence; the last two residues of the 437 of the
# deposited sequence, K S, are absent: it ends ...RSED), plus one zinc (ATOM record "ZN",
# blank chain, residue 436, the first atom of the file; ions are not read by the loader, so
# it does not enter the form factor; the Zn is not part of the deposited sequence).
# The D95A mutation IS in the model: residue 116 of chain C (UniProt P0DW33 residue 95 is
# D; the model numbers the tag residues too) is ALA, matching the deposited sequence.
# 8769 atoms, 4087 of them hydrogens (all three chains carry hydrogens).
#
# THE REFERENCE IS A MultiFoXS ENSEMBLE, NOT A SINGLE-CONFORMER FIT. SASBDB's fit1
# description: "MultiFoXs 2-State Fit of DpdAD95A-28bp DNA complex plus free DNA.
# Weights are 0.48 for the complex and 0.52 for free DNA." (chi² 1.883782), and the
# sample name says "2-state model: complex plus free DNA". The deposited atomic model
# is the complex alone, so this script fits the complex only (a single state); the
# reference curve is the weighted two-state mixture, so a BAYSOL χ² worse than the
# deposited one is expected and is not a like-for-like comparison.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular unit "1/A", q 0.0104-0.44, equal to
# s_max 4.4 nm⁻¹; 46 REMARK header lines, then q, I, σ, 850 points; SEC-SAXS, so the
# intensity is on an arbitrary scale). The comparison curve is the depositor's
# MultiFoXS file SASDQ79_fit1.dat (3 comment lines, then q, I_exp, I_fit, σ; 849
# points; I_fit is already scaled to the data, scaling c = 2.92e-7, offset 0), so the
# fitted intensity is column 3 and no rescaling is needed.

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.01-0.44, is checked below).
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12398 eV, from the stated 0.1 nm = 1.0 Å
const TEMPERATURE_C = 24.9   # SASBDB cell temperature (24.9 °C)

# Buffer components (the measured complex is deliberately NOT listed: ρₑ is the buffer's
# electron density). Counter-ion: setting the pH adds a titrant that the deposited recipe
# does not list. Assumed: 50 mM Tris titrated with HCl -> Cl⁻ = C·0.9496 (pK(22 °C) =
# 8.156). Same method as SASDMJ9.jl (pH set at 22 ± 3 °C; pK(T) from Goldberg, Kishore &
# Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; Davies correction
# at I ≈ 0.148 M; σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on
# C), which this calculation reproduces for SASDMJ9 (0.008588). Only the counter-ion is
# modelled. Titrant not stated; HCl for amine bases.
const SOLUTES = Solute[
    NonBiological(0.100, 0.001, "potassium chloride"),   # 100 mM KCl, ±1%
    NonBiological(0.050, 0.001, "tris"),                 # 50 mM Tris, ±2%
    NonBiological(0.001, 0.00002, "dtt"),                # 1 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.047481, 0.001219, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model's 4087 GROMACS hydrogens (protein and DNA) are rebuilt by pdb2pqr with PROPKA
# at PH (protein + DNA mixed file, so the protein is protonated at pH 7.0).
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    ref_chi2 = "MultiFoXS 2-state 1.884",
    pdb = "SASDQ79_fit1_model1.pdb",
    fit = "SASDQ79_fit1.dat",
    fit_scale = 1.0,
    fit_col = 3,
    rescale = false,
    software = "MultiFoXS 2-state",
),   # deposited χ² = 1.883782 (MultiFoXS, complex 0.48 + free DNA 0.52)
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

# Builds the Seed that `run_sasdq79` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdq79` below is the whole story (build the seed, then sample it).
function seed_sasdq79(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdq79(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdq79(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdq79(run)

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

    # `@__DIR__` (this SASDQ79/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
