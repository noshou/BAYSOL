# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDQE9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQE9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQE9: the YdaT tetramer (4 × 18.47 kDa, N-terminal His-tag and TEV site kept)
# bound to a 30-bp double-stranded DNA ("Om", 18.55 kDa per duplex), SEC-SAXS at ESRF BM29.
#
# Paper: Prolić-Kalinšek M, Volkov A, Hadži S, Van Dyck J, Bervoets I, Charlier D, Loris
# R, "Structural basis of DNA binding by YdaT, a functional equivalent of the CII
# repressor in the cryptic prophage CP-933P from Escherichia coli O157:H7", Acta Cryst. D
# (2023), DOI 10.1107/S2059798323001249. Not bundled and its methods text was not
# consulted: every condition below is SASBDB's entry metadata
# (https://www.sasbdb.org/data/SASDQE9/, REST summary).
#
# Buffer as deposited: "20 mM Tris-HCl, 200 mM NaCl", pH 8.0. Pilatus3 2M, wavelength
# 0.099 nm = 0.99 Å => energy = hc/λ ≈ 12523 eV (hc = 12398.42 eV·Å); sample-detector
# distance 2.87 m; a 45 µl sample at 8 mg/ml was injected at 0.16 ml/min on an Agilent
# AdvanceBio SEC 300 Å column at 15 °C, 13 frames of 2 s (SASBDB "cell temperature" 15 °C,
# "storage temperature" 20 °C). The measured protein-DNA complex is deliberately NOT a
# solute (see BulkElectronDensity.Solute).
#
# THE ENSEMBLE IS NOT FITTED. SASBDB "fit1" is an AXES fit (calcSAXS, chi² = 1.4177, the
# value reproduced from the .saxs file as Σ((Iexp-Icalc)/Ierr)² / (n-1) over its 406
# points) of the ten atomic models below, Xplor-NIH v 2.49 structures of the complex. Each
# of the ten .pdb files carries TWO MODEL records (a two-member ensemble, "Ensemble Weight:
# 0.500000" for every energy term in its REMARKs), so the depositor's curve is that of an
# ensemble of structures, not of one. BAYSOL has no mixture likelihood: each run below
# fits ONE structure alone, the FIRST MODEL record of one file (`seed_model`'s
# default `model = 1`), against the whole curve; the second MODEL record of every file is
# not fitted. The AXES ensemble curve is drawn as the reference of every run but is not a
# single-structure fit, so its chi² (1.418) is not comparable with a member's.
#
# What the files contain (read from the .pdb, identical in all ten except coordinates and
# the REMARK energies): HEADER and TITLE "YDAT-DNA COMPLEX"; 14112 atoms per model, 6468 of
# them hydrogens, in chains A-D (the 162-residue protein, residues -20 to 141 =
# MGSSHHHHHHSSGENLYFQGASKIKHEHIRMAMNVWAHPDGEKVPAAKITKAYFELGMTFPELYDDSHPEALARNTQKI
# FRWLDKDTPDAVEKMQALLPAIEKAMPPLLVARMRSHSSEYYREIVERRDRLVKDVDDFVASAVVLYDQMNRGGPAGNAVVMH,
# the deposited sequence in full) and chains E-H (30 nucleotides each: E and G
# TCATGCTTGATTTTCATGAATCAACTCCAT, F and H its complement ATGGAGTTGATTCATGAAAATCAAGCATGA,
# i.e. TWO 30-bp duplexes bound to the tetramer, not the single duplex the entry's
# sample table lists; the entry's model mass, 109.6 kDa, is 73.9 kDa protein + 37.1 kDa DNA
# = two duplexes). No waters, ions or ligands. Hydrogens carry CHARMM/Xplor names (HT1-HT3
# on the N-terminus, HN, H2'' ...). Per file, the REMARKs give the Xplor "summary total"
# energy and the "SolnScat xray-prot" chi² of that file's two-member average against the
# data (a different calculation from the AXES fit):
#
#     file  total energy  SolnScat χ²      file  total energy  SolnScat χ²
#     1     16523.90      0.878            6     16436.43      0.861
#     2     16550.71      0.953            7     16507.18      0.855
#     3     16580.10      0.915            8     16493.61      0.877
#     4     16593.31      0.908            9     16385.84      0.841
#     5     16757.93      0.875            10    16350.10      0.900

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# The SASBDB .dat is in nm⁻¹ (angular unit "1/nm", 2 header lines, 1000 points, then
# beam-information lines that `_read_curve` skips): 0.044-5.205 nm⁻¹; converted here.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV

check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12523 eV, from the stated 0.099 nm
const TEMPERATURE_C = 15.0                    # SASBDB cell temperature

# Buffer components (the measured complex is deliberately NOT listed: ρₑ is the buffer's
# electron density). Every solute is a row of the bundled tables: "tris" and
# "sodium chloride" as in SASDMJ9, "chloride" the ion (nonbiological.tsv).
# Counter-ion: "Tris-HCl" at pH 8.0 means Tris titrated with HCl, so Cl⁻ comes along with
# the protonated Tris and is not listed in the recipe. Assumed: 20 mM Tris titrated with
# HCl -> Cl⁻ = C·0.658 (pK(22 °C) = 8.156), the protonated fraction at pH 8.0. Same
# method as SASDMJ9.jl (pH set at 22 ± 3 °C; pK(T) from Goldberg, Kishore & Lennen 2002,
# J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; Davies correction at the
# self-consistent I ≈ 0.213 M; σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift
# and ±2 % on C). That calculation was redone here for this recipe and reproduces
# SASDMJ9's 0.008588 (0.008587) and SASDQ69's 0.047481 (0.047478); the σ agrees with theirs
# to 0.5 % (0.000424 vs 0.000422 and 0.001217 vs 0.001219). Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases.
const SOLUTES = Solute[
    NonBiological(0.200, 0.002, "sodium chloride"),   # 200 mM NaCl, ±1%
    NonBiological(0.020, 0.0004, "tris"),              # 20 mM Tris-HCl, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.013160, 0.001463, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The depositor's AXES curve spans q = 0.0111-0.2204 Å⁻¹ (406 of the .dat's 1000 points,
# identical to the data there); the fit uses the same range. Beyond 0.22 Å⁻¹ the curve is at
# the noise floor (I ≲ 0.5 against I(0) ≈ 50) and below 0.011 Å⁻¹ the points are
# SEC-baseline-dominated (σ up to 6).
const Q_MIN_FIT = 0.0111
const Q_MAX_FIT = 0.2204

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The 6468 deposited hydrogens per model have CHARMM/Xplor names and, for 1104 of them, a
# malformed element column (HG, HD, HE, H2, H5 instead of H); `ADD_HYDROGENS = true` has
# pdb2pqr rebuild the hydrogens at PH for the protein-DNA mixture, as for SASDQ69.
const ADD_HYDROGENS = true

# One run per ensemble file; every run fits the first MODEL record of that file against
# the same curve. `fit` is the AXES ensemble curve, the same for all (q already in
# Å⁻¹, `fit_scale` = 1; the fitted intensity is column `fit_col` = 4; the curve is on the
# data's scale, so `rescale = false`).
const RUNS = [
    (
        tag = "model$i",
        ref_chi2 = "AXES ensemble 1.418",
        pdb = "SASDQE9_fit1_model$i.pdb",
        fit = "SASDQE9_fit1.saxs",
        fit_scale = 1.0,
        fit_col = 4,
        rescale = false,
        software = "AXES ensemble",
    ) for i in 1:10
]

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `Q_MIN_FIT ≤ q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(
        i -> Q_MIN_FIT ≤ qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals),
    )
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdqe9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdqe9` below is the whole story (build the seed, then sample it).
function seed_sasdqe9(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        model = 1,   # the first MODEL record of the file (the file has two)
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdqe9(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdqe9(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run (`res_model1.xlsx`, ...)
    suffix = "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdqe9(run)

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

    # `@__DIR__` (this SASDQE9/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
