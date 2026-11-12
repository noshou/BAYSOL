# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDF29")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDF29.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDF29: the fourth double-stranded RNA-binding domain of human Staufen1
# (STAU1-RBD4, UniProt O95793 residues 286-355, 8.4 kDa) in complex with the 34-nt ARF1
# stem-loop RNA (GGCAGAAGCUGCCUCUUCGGAGGCAGUUUCUGCC, 11.0 kDa), 1:1, one solute
# concentration of 6.5 mg/ml.
#
# Paper: Yadav DK, Zigackova D, Zlobina M, Klumpler T, Beaumont C, Kubickova M, Vanacova S,
# Lukavsky PJ, Nucleic Acids Res (2019), "Staufen1 reads out structure and sequence
# features in ARF1 dsRNA for target recognition", DOI 10.1093/nar/gkz1163. Not bundled;
# the conditions below are SASBDB's entry metadata (https://www.sasbdb.org/data/SASDF29/),
# the paper was not consulted for them.
#
# Buffer as deposited: "50 mM potassium phosphate, 100 mM NaCl, 3.5 mM
# 2-mercaptoethanol", pH 6.8. Instrument: Rigaku BioSAXS-1000 (CEITEC, Brno), in-house
# X-ray source, Pilatus 100K, sample-detector distance 0.48 m, wavelength 0.154 nm (Cu
# K-alpha) => energy = hc/λ ≈ 8051 eV (hc = 12398.42 eV·Å); six 600 s frames, scattering
# of the solvent blank subtracted; cell temperature 35 °C (storage 20 °C). The measured
# complex is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Model (fit1_model1, "CYANA 3.97", NMR bundle of 20 MODEL records, the deposited .pdb has
# 25,720 ATOM + 400 HETATM records in total): ONE complex per MODEL record, chain A =
# protein, 74 residues numbered 201-274 (GSHM tag + RBD4), chain B = RNA, 34 nucleotides
# numbered 1-34 with the plain wwPDB names G C A U (2'-OH present, O2' in all 34; no
# 5' phosphate, the first residue starts at O5'), 1306 heavy atoms per model (C 685, O
# 346, N 239, P 33, S 3) and NO hydrogens (serial numbers skip them). No altlocs. Two
# histidines (203 and 247) are written as HETATM records with residue name HIS in
# columns 18-20 and a stray T in column 21 (CYANA's "HIST" tautomer name); the loader
# reads columns 18-20 and keeps modified/HETATM amino acids. `seed_model` fits the FIRST
# MODEL record (`model = 1`, below); the other 19 conformers of the bundle are not fitted.
# The depositor's CRYSOL fit (SASDF29_fit1.fit, header "Dro:0.000 Ra:1.400 RGT:17.94
# Vol: 21817. Chi^2: 1.167", entry χ² 1.167, CRYSOL 2.8.3, from the log file named
# "dsRBD4_hARF-for-deposition-2018-11-19_noH-100.log") is the reference curve; which
# model(s) of the bundle CRYSOL used is not stated in the entry (its log name suggests
# the whole bundle, "-100").
#
# Curve units: the SASBDB .dat is in Å⁻¹ (the entry states angular units 1/A; q
# 0.0483-0.3013 Å⁻¹, 177 rows, no header; `_read_curve` keeps the numeric rows). The
# .fit file is also in Å⁻¹ (q steps of 0.002 up to the data range, columns q, I_exp, σ,
# I_fit; its first 25 rows, q < 0.048, have no data and zero I_exp, and I_fit is used
# from column 4 as is, on the data's scale: I(0) = 0.4507 vs Guinier I0 0.44).

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.8, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, from the stated 0.154 nm
const TEMPERATURE_C = 35.0                    # SASBDB cell temperature (storage 20 °C)

# Buffer components (the measured complex is deliberately NOT listed). "50 mM potassium
# phosphate" is a mix of KH2PO4 and K2HPO4 at pH 6.8: the HPO4²⁻ fraction is 0.484 (pK2
# from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C (pH assumed set at
# room temperature, ASSUMPTION: the entry gives no setting temperature), Davies-corrected
# at I ≈ 0.198 M (0.1 M NaCl + the phosphate and its potassium). σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift and ±2 % on C. Same treatment as SASDPN6 and
# SASDVX2. 3.5 mM 2-mercaptoethanol is a neutral molecule; no titrant counter-ion is
# added.
const SOLUTES = Solute[
    # 50 mM KPi, H2PO4⁻ part
    NonBiological(0.025795, 0.0044, "potassium dihydrogen phosphate"),
    # 50 mM KPi, HPO4²⁻ part
    NonBiological(0.024205, 0.0044, "dipotassium hydrogen phosphate"),
    NonBiological(0.100, 0.001, "sodium chloride"),         # 100 mM NaCl, ±1%
    NonBiological(0.0035, 0.00007, "2-mercaptoethanol"),    # 3.5 mM, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The curve ends at 0.3013 Å⁻¹, so the fit uses all of it.
const Q_MAX_FIT = 0.31

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens; pdb2pqr (PARSE and PROPKA at PH, a protein-RNA
# model) places them from the heavy atoms.
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fit_scale`; the fitted intensity is
# column `fit_col`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    ref_chi2 = "CRYSOL 1.167",
    pdb = "SASDF29_fit1_model1.pdb",
    fit = "SASDF29_fit1.fit",
    fit_scale = 1.0,
    fit_col = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 1.167 (CRYSOL 2.8.3)
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

# Builds the Seed that `run_sasdf29` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdf29` below is the whole story (build the seed, then sample it).
function seed_sasdf29(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
        model = 1,   # the first MODEL record of the NMR bundle (the file has 20)
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdf29(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdf29(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdf29(run)

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

    # `@__DIR__` (this SASDF29/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
