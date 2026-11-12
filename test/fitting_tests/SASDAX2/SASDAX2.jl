# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity:
    Solute, NonBiological, Polymer, DEFAULT_TEMPERATURE_C
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDAX2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAX2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDAX2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDAX2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDAX2: pyruvate decarboxylase (ZmPDC) from Zymomonas mobilis, a tetramer of
# 60.93 kDa chains (SASBDB total 244.0 kDa; experimental MW 247 kDa).
#
# Publication (SASBDB): Svergun DI, Petoukhov MV, Koch MHJ, Koenig S, "Crystal versus
# solution structures of thiamine diphosphate-dependent enzymes", J Biol Chem, 2000 Jan 7,
# PMID 10617618 (SASBDB gives no DOI). Entry: https://www.sasbdb.org/data/SASDAX2/. The
# buffer, pH and instrument below are the SASBDB entry metadata; the paper was NOT
# consulted for them.
#
# Instrument (SASBDB): EMBL X33, DORIS III, DESY Hamburg (X-ray synchrotron, 1D gas
# detector); measured 1998-11-03; merged curve, q 0.293-4.69 nm⁻¹ (376 points).
#
# *** ASSUMPTIONS: SASBDB records neither a wavelength / X-ray energy nor a
# *** temperature for this entry (xray_energy, wavelength, cell_temperature and
# *** storage_temperature are all null). Neither is silently invented:
# ***   - energy: X33 at the 1.5 Å wavelength that SASDA52 (also X33) uses after
# ***     its "0.15" slip was read as nm/Å (see that script); 1.5 Å => hc/λ ≈ 8266 eV.
# ***     SASDMJ9 gives 1.54 Å for the same beamline in 2012; the 2.7 % difference
# ***     changes the anomalous terms of the light atoms negligibly.
# ***   - temperature: the package default `DEFAULT_TEMPERATURE_C` (25 °C), as in
# ***     SASDAC9 (no temperature recorded in SASBDB either).
#
# Curve units: the SASBDB .dat is in nm⁻¹ (header "Angular axis m02000.sax ..."; one
# text line, then q, I, σ) and is converted to Å⁻¹ (÷10). The last 25 points have
# I ≤ 0 (the curve is noise beyond q ≈ 0.35 Å⁻¹); the fit is cut at `Q_MAX_FIT`
# anyway and `seed_model` drops non-positive bins. The smallest q is 0.0293 Å⁻¹, about
# 1.1/Rg (Rg ≈ 38.9 Å by Guinier, CRYSOL log): there is no Guinier region.
#
# Model and depositor fit: SASDAX2_fit1_model1.pdb is the crystal structure of the
# tetramer (CRYSOL log: "This is Xtal model"; space group label P222), chains A, B, E, F
# (4290 protein atoms each), 4 thiamine diphosphate (TDP, residue 600) and 4 Mg²⁺ (atom
# MG written as residue "IUM", residue 601, which the table knows as uranyl), 492 waters
# (HOH, chains U-X); all as ATOM records, no hydrogens. `seed_model` keeps only the
# amino-acid heavy atoms and the ligands of a known composition (waters are not part of the
# model; `KEEP_LIGANDS`, 2026-11-11), and TDP and the Mg²⁺ (`IUM`) are ATOM records, so they
# are scattered, without hydrogens (a residue pdb2pqr leaves out is put back). Expected
# log notes (not errors): the four "IUM" are flagged `few_atoms` by the dummy-like check
# ("undefined behaviour" in the log; the flow is unchanged) and one duplicate atom (ARG A
# 405 CA appears twice) is dropped.
# The deposited fit is CRYSOL 2.8.2 (14/09/12): Dro 0.003, Ra 1.400, Vol 308046 Å³, and
# the .fit header prints "Chi:0.816", which is χ and not χ²: SASBDB's chi_square_value
# is 0.667884 (= 0.816²), and recomputing from the file (376 points, columns 2-4)
# gives χ² = 0.666, χ = 0.816. So the depositor's χ² is 0.668. Column 4 of the .fit
# is on the data's scale (no rescale). CRYSOL's own solvent density was 0.334 e/Å³,
# the pure-water value: the depositors used no buffer correction. With 0.8 the fit is
# already below 1 (errors a little large), so BAYSOL's χ² is not expected to beat it.
# ---------------------------------------------------------------------------

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 6.0, PH_METER_SIGMA   # SASBDB: pH 6.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV; ASSUMED 1.5 Å, none in SASBDB
const TEMPERATURE_C = DEFAULT_TEMPERATURE_C   # ASSUMED 25 °C, none recorded in SASBDB

# Buffer as deposited (SASBDB, buffer name and additive fields): "100 mM Sodium Citrate,
# 17% Glycerol, 22.5% PEG 1500", pH 6.0. The measured macromolecule is deliberately NOT
# a solute (see BulkElectronDensity.Solute).
#
# PEG 1500 and glycerol: the percentages carry no unit in SASBDB. Convention taken here,
# explicitly: % = g per 100 mL of solution (w/v), the unit that crystallization-style
# PEG/glycerol/citrate recipes use (this is the recipe of the crystallization-type TPP
# enzyme buffer, SASBDB comment "buffer for thiamin diphosphat dependent enzyme"; this
# is a reading of the recipe, not a statement of the depositors).
#   - PEG 1500, 22.5 % w/v = 225 g/L; the grade is the mean molar mass Mn = 1500 g/mol,
#     so 225 / 1500 = 0.150 M of chains (the loader reads "PEG 1500" as the family form
#     "PEG {Mn}", n = (1500 − 18.015)/44.053 ≈ 33.6 units, Z = 817 e⁻,
#     ϕ° ≈ 1254.9 ± 12.5 cm³/mol). If the 22.5 % were w/w the same chains would be
#     ≈ 0.168 M (solution density ≈ 1.12 g/mL, estimated, not measured), 12 % higher; the
#     real Mn of a "1500" lot spreads about ±5 %. σ is therefore 10 % (0.015 M),
#     not the usual 2 %.
#   - Glycerol, 17 % w/v = 170 g/L / 92.094 g/mol = 1.846 M. If it were v/v (as for
#     SASDJ72 and SASDK94, where the papers say v/v) it would be 170 mL/L · 1.2613 g/mL
#     / 92.094 = 2.328 M, 26 % higher; w/w would lie between (≈ 1.9-2.0 M at an
#     estimated 1.13 g/mL). The same unit is assumed for both so the recipe reads as one
#     w/v list; σ is 0.20 M (≈ 11 %), so the v/v reading sits about 2.4σ away, not
#     excluded. Both are guesses the entry does not settle; an undefined "%" is the
#     largest uncertainty of this buffer.
# Mixing volumes are not additive at these loadings (≈ 0.395 kg of solutes per litre);
# BAYSOL treats each solute as molarity per litre of solution, as for every script here.
#
# Citrate at pH 6.0 and its counter-ions: 100 mM total citrate (the entry says "sodium
# citrate" without stoichiometry). Setting a citrate buffer to pH 6.0 means a mixture
# of the species H₂Cit⁻, HCit²⁻ and Cit³⁻ with Na⁺ as the counter-ion; the recipe is
# assumed made with citric acid and NaOH (or trisodium citrate and citric acid), so
# that no other anion (Cl⁻) is present: charge balance gives Na⁺ = 0.264 M. If
# trisodium citrate were titrated down with HCl instead the buffer would carry
# ≈ 0.036 M extra Cl⁻ (NaCl) and ≈ 0.036 M more Na⁺, not modelled. The
# species fractions use pK₁ 3.128, pK₂ 4.761, pK₃ 6.396 (thermodynamic, 25 °C;
# Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902; the values are quoted from memory of that table and were NOT
# re-checked here), Davies-corrected for activity at the self-consistent ionic strength
# (I ≈ 0.49 M, PEG and glycerol activity effects not modelled; Davies is at the edge of
# its range there). The result, with each species as its sodium salt (sodium is part of
# the salt, so no separate "sodium" entry): H₂Cit⁻ 0.78 mM (0.0078), HCit²⁻ 34.28 mM
# (0.3428), Cit³⁻ 64.94 mM (0.6494), the sum being 100 mM. σ combines σ_PH = 0.1
# (±0.005 on the Cit³⁻ and HCit²⁻ amounts), 30 % of the Davies shift (±0.011), ±0.02 pK and
# ±3 °C (smaller): taken as 0.012 M for the two main species and 0.0006 M for H₂Cit⁻.
# Without the Davies correction (I = 0) the split would be 4.0 / 68.5 / 27.5 mM, so the
# activity treatment matters for the species amounts (the ρₑ effect is small because
# the three salts differ by one sodium each). The pH is taken as set at room temperature.
# The table has all three salts (`trisodium citrate` ϕ° 69.32, `disodium hydrogen
# citrate` 86.157 and `sodium dihydrogen citrate` 102.6137 cm³/mol, 3.04 cm³/mol
# fallback σ; `glycerol` 70.95). No TCEP, DTT or other reductant is listed in the entry.
const SOLUTES = Solute[
    # 100 mM citrate at pH 6.0: Cit³⁻ as trisodium citrate (see the note above)
    NonBiological(0.06494, 0.012, "trisodium citrate"),
    # HCit²⁻ as disodium hydrogen citrate
    NonBiological(0.03428, 0.012, "disodium hydrogen citrate"),
    # H₂Cit⁻ as sodium dihydrogen citrate
    NonBiological(0.00078, 0.0006, "sodium dihydrogen citrate"),
    # 17 % glycerol, read as w/v: 170 g/L / 92.094 g/mol = 1.846 M, ±0.20 M (see above)
    NonBiological(1.846, 0.20, "glycerol"),
    # 22.5 % PEG 1500, read as w/v: 225 g/L / 1500 g/mol = 0.150 M of chains, ±10 %
    Polymer(0.150, 0.015, "PEG 1500"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdax2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdax2` below is the whole story (build the seed, then sample it).
function seed_sasdax2(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdax2(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdax2(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdax2()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "CRYSOL 0.668 (header Chi 0.816)",
    run_log = true,
)

# `@__DIR__` (this SASDAX2/ folder), not the caller's cwd.

BAYSOL.print_summary(result)
