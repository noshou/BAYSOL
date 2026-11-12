# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDBA8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDBA8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDBA8: "Probable ATP-dependent RNA helicase DDX58 (Full-length RIG-I) plus
# 10mer hairpin dsRNA /AMP-PNP" (human RIG-I, 107.4 kDa, with a 5'-triphosphate 10 bp
# hairpin dsRNA, 24 nt GGACGUACGUUUCGACGUACGUCC, 7.7 kDa, in the presence of the ATP
# analogue AMP-PNP). Paper: Shah N, Beckham SA, Wilce JA, Wilce MCJ, "Combined roles of
# ATP and small hairpin RNA in the activation of RIG-I revealed by solution-based
# analysis", Nucleic Acids Res (2018), DOI 10.1093/nar/gkx1307. The paper was not
# consulted; everything below is from the SASBDB entry record
# (https://www.sasbdb.org/data/SASDBA8/, rest-api/entry/summary/SASDBA8/).
#
# Instrument: SAXS/WAXS beamline, Australian Synchrotron (Melbourne), Pilatus 1M, point
# geometry, sample-detector distance 1.6 m, wavelength 0.10332 nm = 1.0332 Å
# => energy = hc/λ ≈ 12000.0 eV (hc = 12398.42 eV·Å). SEC-SAXS (Superdex 200 10/300),
# 15 x 2 s frames through the peak at 31.8 min, merged curve. Cell temperature 15 °C
# (storage 4 °C). The curve is already in Å⁻¹ (0.0127-0.2504 Å⁻¹, 563 rows).
#
# Buffer as deposited: "25 mM HEPES, 150 mM NaCl, 2.5 mM MgCl2, 10% glycerol and 1mM
# DTT, 0.5 mM AMP-PNP", pH 7.4. The measured macromolecules (RIG-I and the RNA) are
# deliberately NOT solutes (see BulkElectronDensity.Solute); the AMP-PNP is a free
# nucleotide ligand in the buffer and is listed as the solute `amp-pnp`.
#
# The deposited models are the four members of an EOM/RANCH (v2.1) ensemble
# (`SASDBA8_fit1_model1.pdb` ... `model4.pdb`, `.fit` header "CYCLE: 55 Chi^2: 0.594
# GENER.: 1000 ENSEMBLES: 50 CURVES: 11"; the entry states chi² 0.72). The deposited
# curve is the weighted ENSEMBLE AVERAGE of those conformers, so an ensemble average is
# NOT fitted here: each member is fitted as a separate single structure (one run each),
# and a single conformer is not expected to reach the deposited chi². The depositor's
# ensemble curve is drawn as the reference of every run. All four PDBs hold the same
# content, read from the files: one model each, ATOM records only (7577 atoms), chain A
# only, no hydrogens, no HETATM (no AMP-PNP, no Mg²⁺, no triphosphate): 922 protein
# residues (1-922, M1 ... E922; no His-tag, no residues beyond the 922nd) followed by the
# 24 RNA nucleotides G1 ... C24 (GGACGUACGUUUCGACGUACGUCC) in the SAME chain A with their
# residue numbers restarting at 1 (a residue-number overlap between protein 1-24 and RNA
# 1-24 inside one chain). The RNA has no 5'-triphosphate atoms in the file (the 5'-end
# residue starts at the C5'/O5' atoms), so the deposited 5'ppp group is absent from the
# model. The members differ only in coordinates (conformers of the helicase relative to
# the RNA, produced by RANCH).

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0332   # ≈ 12000.0 eV, from the stated 0.10332 nm
const TEMPERATURE_C = 15.0                      # SASBDB cell temperature

# Buffer components (the measured macromolecules are deliberately NOT listed: ρₑ is the
# buffer's electron density). Every solute was checked in the bundled tables
# (src/BulkElectronDensity/NonBiological): `hepes`, `sodium chloride`,
# `magnesium chloride`, `glycerol`, `dtt` and `amp-pnp` (alias of the 3D-RISM estimate
# for AMP-PNP(4-), not a measurement) are present.
#
# Counter-ions. Setting the pH adds titrant counter-ions that the deposited recipe does
# not list. Assumed: 25 mM HEPES titrated with NaOH -> Na⁺ = C·0.456 (pK(22 °C) = 7.6,
# as in SASDBS6; pH set at room temperature, 22 ± 3 °C; fraction Davies-corrected at
# I ≈ 0.174 M, iterated with the Na⁺ it adds). σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change
# of the buffer's own (de)protonation is not. The supplier's counter-ion of the AMP-PNP
# is NOT stated; the solute `amp-pnp` is the 4- anion, so 4 x 0.5 mM = 2 mM Na⁺ is
# assumed to balance it (±50 %); the binding of Mg²⁺ to AMP-PNP and the protonation of
# the anion at pH 7.4 are ignored. Both Na⁺ amounts are one entry: 0.011402 + 0.002 =
# 0.013402 M, σ = √(0.001681² + 0.001²) = 0.001956 M.
#
# Glycerol: 10 % taken as v/v (the entry does not say v/v or w/v) -> molarity via the
# pure-glycerol density (1.2613 g/mL) and MW (92.094 g/mol): 0.1 · 1.2613 / 92.094 ·
# 1000 ≈ 1.369 M, ±5 % because of that approximation (as in SASDJ72).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),                # 25 mM, ±2%
    NonBiological(0.150, 0.0015, "sodium chloride"),      # 150 mM, ±1%
    NonBiological(0.0025, 0.000025, "magnesium chloride"),   # 2.5 mM, ±1%
    NonBiological(1.369, 0.06845, "glycerol"),            # 10 % v/v, ±5%
    NonBiological(0.001, 0.00002, "dtt"),                 # 1 mM, ±2%
    NonBiological(0.0005, 0.00001, "amp-pnp"),            # 0.5 mM, ±2%
    # Na⁺ from NaOH titration of HEPES plus the assumed AMP-PNP counter-ion (see above)
    NonBiological(0.013402, 0.001956, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The curve ends at 0.2504 Å⁻¹, so the cut keeps all of it.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr (protein + RNA in one file) at PH

# One run per ensemble member; `fit` is the depositor's EOM ensemble curve (the same
# file for every member: column 3 is the ensemble fit, column 2 the data it fitted;
# the q axis is already Å⁻¹). `ref_chi2` is the ensemble's, not the member's.
const RUNS = [
    (
        tag = "fit1_model1",
        ref_chi2 = "EOM ensemble 0.72 (file header 0.594)",
        pdb = "SASDBA8_fit1_model1.pdb",
        fit = "SASDBA8_fit1.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),
    (
        tag = "fit1_model2",
        ref_chi2 = "EOM ensemble 0.72 (file header 0.594)",
        pdb = "SASDBA8_fit1_model2.pdb",
        fit = "SASDBA8_fit1.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),
    (
        tag = "fit1_model3",
        ref_chi2 = "EOM ensemble 0.72 (file header 0.594)",
        pdb = "SASDBA8_fit1_model3.pdb",
        fit = "SASDBA8_fit1.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),
    (
        tag = "fit1_model4",
        ref_chi2 = "EOM ensemble 0.72 (file header 0.594)",
        pdb = "SASDBA8_fit1_model4.pdb",
        fit = "SASDBA8_fit1.fit",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "EOM ensemble",
    ),
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

# Builds the Seed that `run_sasdba8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdba8` below is the whole story (build the seed, then sample it).
function seed_sasdba8(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdba8(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdba8(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdba8(run)

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

    # `@__DIR__` (this SASDBA8/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
