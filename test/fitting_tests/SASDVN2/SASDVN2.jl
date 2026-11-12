# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVN2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVN2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVN2: Eap34, the domains 3 and 4 of the Staphylococcus aureus extracellular
# adherence protein (strain Mu50, UniProt Q99QS1 266-476, 211 residues, 24.124 kDa,
# monomer), SEC-SAXS. In the paper's Table 4 this entry is "Eap34" (Guinier Rg 24.7 Å, I(0)
# 18.7, Dmax 85 Å); SASDVH2 is Eap/4NE and SASDVP2 the Eap34/2CG/2NE complex.
#
# Paper: Mishra N, Gido CD, Herdendorf TJ, Hammel M, Hura GL, Fu ZQ, Geisbrecht BV, "S.
# aureus Eap is a polyvalent inhibitor of neutrophil serine proteases", J Biol Chem (2024),
# DOI 10.1016/j.jbc.2024.107627 (open access, PMC11420654; the PDF is not in the
# repository, see test/fixtures/experiments/SASDVN2/README.txt).
#
# Instrument (SASBDB record, https://www.sasbdb.org/rest-api/entry/summary/SASDVN2/):
# Advanced Light Source beamline 12.3.1 (SIBYLS), Pilatus3 X 2M, wavelength 0.1127 nm =
# 1.127 Å => energy = hc/λ ≈ 11001 eV (hc = 12398.42 eV·Å; the paper's methods say 1.127 Å
# too), sample-detector distance 2.1 m, cell temperature 20 °C (storage 4 °C), 660 frames of
# 2 s, 0.65 ml/min on a Shodex 803 column, up to 5 mg/ml. The measured protein is
# deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# THE ENSEMBLE IS NOT FITTED. The three SASBDB fits are MultiFoXS multi-state fits of one
# curve: fit1 one conformer (FoXS chi² 0.814083), fit2 two (0.816708), fit3 three
# (0.813946); the curve a depositor's fit file holds is the weighted AVERAGE of the
# conformers' curves. BAYSOL has no mixture likelihood: every run below fits ONE conformer
# alone against the whole curve, and the FoXS ensemble curve of its fit is drawn as the
# reference (it is not a single-structure fit, so its chi² is not comparable with a
# member's). All six files SASBDB serves are run; fit2_model2 and fit3_model2 are
# byte-identical files (same md5), so those two runs fit the same structure and differ
# only in the reference curve.
#
# What the model files contain (read from the .pdb): each has one MODEL record, chain B,
# residues 1-211 numbered from 1 (the deposited sequence in full, no gaps, checked
# residue by residue against the entry's sequence), 1706 atoms: 1097 C, 294 N, 315 O, no
# hydrogens, no waters, ions or ligands (no HETATM), the last residue has its OXT. The
# occupancy column is 0.00 for 1605 atoms and 1.00 for 101 (a MultiFoXS output
# convention; BAYSOL does not use it) and the B-factor column is not zero. The six
# conformers differ in the domain arrangement: Rg of the heavy atoms 25.3 Å (fit1),
# 23.7 and 27.5 (fit2), 24.8, 27.5 and 22.9 (fit3), against 24.7 Å from the data's Guinier
# fit. FoXS chi² values above are over all 912 points; the fit here stops at 0.25 Å⁻¹.
#
# BUFFER: THE TWO SOURCES DISAGREE. (a) SASBDB's sample buffer field: "20 mM HEPES, 140 mM
# NaCl", pH 7.4 (as for the sibling entries SASDVK2, SASDVL2, SASDVM2 and SASDVG2).
# (b) The paper's "SAXS experiments" paragraph (Experimental procedures): "For EapH2, CG,
# Eap, CG/EapH2/NE, NE/Eap4/NE, and Eap/4CG, a buffer of 20 mM Hepes (pH: 7.4), 140 mM
# NaCl was used as the mobile phase; for Eap/4NE, Eap34, and 2CG/Eap34/2NE, a buffer of 20
# mM acetate (pH: 4.0), 100 mM L-arginine, 100 mM L-glutamic acid, 300 mM NaCl, 1% (v/v)
# glycerol was used as the mobile phase." So the arginine and glutamic acid of the
# owner's note ARE stated by a source, but together with acetate pH 4.0, 300 mM NaCl and
# glycerol, and WITHOUT HEPES; the entry's HEPES/pH 7.4 is not what the paper says Eap34
# ran in (the entry's own metadata, Table 4 and wavelength/flow rate agree with the paper
# otherwise). No hybrid (HEPES + arginine + glutamate) is stated anywhere and none is
# modelled. The paper itself is not self-consistent for 2CG/Eap34/2NE (SEC list above,
# HT-SAXS in HEPES pH 7.4 in the next paragraph), so a depositor's record error cannot be
# excluded either way. `BUFFER` below picks the recipe: `:paper` (default, the
# publication's mobile phase) or `:sasbdb` (the deposited record).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (angular unit "1/A"; 912 points, 0.0104-
# 0.472 Å⁻¹; the trailer after the data is the depositor's frame list, skipped by
# `_read_curve`). The reference fit files are FoXS output in Å⁻¹: columns q, I_exp,
# I_model, error; the model column is already on the data's scale.

qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

# :paper (acetate pH 4.0, arginine, glutamic acid) or :sasbdb (HEPES pH 7.4)
const BUFFER = :paper

const PH, σ_PH      = BUFFER === :paper ? 4.0 : 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.127   # ≈ 11001 eV, from the stated 0.1127 nm
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer components (the measured protein is deliberately NOT listed: ρₑ is the buffer's
# electron density). Every solute is a row of the bundled tables: "acetic acid",
# "arginine" and "glutamic acid" (the neutral forms), "glycerol", "sodium chloride" and
# "chloride" (ion), "hepes" and "sodium(1+)".
#
# :paper recipe, 20 mM acetate pH 4.0, 100 mM L-arginine, 100 mM L-glutamic acid, 300 mM
# NaCl, 1 % (v/v) glycerol. BUFFER OMISSION (assumed, not stated): the acid or base that
# sets pH 4.0 and the form the acetate and the amino acids were added in. Assumed: the
# neutral compounds (acetic acid, L-arginine, L-glutamic acid) titrated to pH 4.0 with
# HCl. The chloride that comes with the HCl is the counter-ion, found by charge balance
# at pH 4.0 (the neutral rows stand for the protonated and deprotonated forms, as for
# the Arg-HCl of SASDRJ8; the volume change of the (de)protonation itself is not
# modelled): Cl⁻ = c_Arg·z_Arg + c_Glu·z_Glu − c_Ac·f_Ac with the mean charges
#
#     arginine: α-NH3⁺ and guanidinium +2, α-COO⁻ f(pK 2.17) = 0.989   -> z = +1.011
#     glutamic acid: α-NH3⁺ +1, α-COO⁻ f(pK 2.19) = 0.989, side chain f(pK 4.25) = 0.435
#                                                                     -> z = -0.424
#     acetate: f(pK 4.757) = 0.193  (20 mM, 3.9 mM as the anion)
#
# the deprotonated fractions being f = r/(1 + r), r = 10^(pH - pK)/γ₁ (HA neutral -> A⁻),
# pK at 25 °C from the CRC Handbook "Dissociation constants of organic acids and bases"
# (acetic acid also Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231,
# DOI 10.1063/1.1416902), pH taken as set at room temperature, γ₁ the Davies activity
# coefficient of a monovalent ion (A = 0.509) at the self-consistent ionic strength
# I = 0.401 M (γ₁ = 0.731), as in SASDRJ8. Result: Cl⁻ = 54.84 mM in addition to the 300
# mM of NaCl (64.0 mM without the Davies correction). σ = 12.9 mM combines, in
# quadrature, σ_PH = 0.1 (6.9 mM), the glutamic acid side-chain pK ±0.05 (2.8 mM), 30 %
# of the Davies shift (2.8 mM), ±2 % on the arginine and glutamic acid (2.0 and 0.9 mM),
# the other pKs (0.3 mM) and 10 mM for the titrant assumption (acetate added as sodium
# acetate instead would raise Cl⁻ by 20 mM). Glycerol 1 % v/v: 10 mL/L · 1.2613 g/mL /
# 92.094 g/mol = 0.137 M, ±3 %. The calculation was done outside the repository; the same
# code reproduces SASDVG2's HEPES counter-ion (below) to 0.06 %.
#
# :sasbdb recipe, 20 mM HEPES, 140 mM NaCl, pH 7.4, as deposited. Assumed: 20 mM HEPES
# titrated with NaOH (Good's buffer; not stated) -> Na⁺ = C·0.4535 at pK(22 °C) = 7.6
# (Goldberg et al. 2002, as above), Davies-corrected at I = 0.149 M; the recipe is that
# of SASDVG2, whose counter-ion (0.009065 ± 0.001316 M) is used unchanged.
const SOLUTES = if BUFFER === :paper
    Solute[
        NonBiological(0.020, 0.0004, "acetic acid"),       # 20 mM acetate, ±2%
        NonBiological(0.100, 0.002, "arginine"),           # 100 mM L-arginine, ±2%
        NonBiological(0.100, 0.002, "glutamic acid"),      # 100 mM L-glutamic acid, ±2%
        NonBiological(0.300, 0.003, "sodium chloride"),    # 300 mM NaCl, ±1%
        NonBiological(0.137, 0.0041, "glycerol"),          # 1 % v/v, ±3%
        # Cl⁻ counter-ion from HCl titration to pH 4.0 (see note above)
        NonBiological(0.05484, 0.01294, "chloride"),
    ]
else
    Solute[
        NonBiological(0.02, 0.0004, "hepes"),             # 20 mM, ±2%
        NonBiological(0.14, 0.0028, "sodium chloride"),   # 140 mM, ±2%
        # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
        NonBiological(0.009065, 0.001316, "sodium(1+)"),
    ]
end

const BUFFER_OMISSIONS = String[
    "SASBDB (HEPES, pH 7.4) and the paper (acetate pH 4.0, arginine ...) disagree",
    "acid or base setting the pH not stated: HCl assumed for the neutral acids (modelled)",
]
@warn "SASDVN2: buffer recipe is uncertain (see the header)" omissions = BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The curve reaches 0.472 Å⁻¹ but is at the noise floor beyond ~0.25 Å⁻¹ (mean I/σ
# 2.2 in 0.20-0.25, 1.3 in 0.25-0.30, 1.1-1.7 above, 8 % of the points negative
# in 0.40-0.45); the fit uses q ≤ 0.25 Å⁻¹.
const Q_MAX_FIT = 0.25

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # the models have heavy atoms only; Pdb2pqr at PH

# One run per atomic model of every fit; `fit` is the FoXS curve of that model's fit (q in
# Å⁻¹ already, `fit_scale` = 1; the fitted intensity is column `fit_col` = 3; the curve is
# on the data's scale, so `rescale = false`). The deposited chi² of fit f is the same
# for each of its members: 0.814083, 0.816708 and 0.813946.
const MEMBERS = [(1, 1), (2, 1), (2, 2), (3, 1), (3, 2), (3, 3)]   # (fit, model)
const DEPOSITED_CHI2 = ["0.81", "0.82", "0.81"]
const RUNS = [
    (
        tag = "fit$(f)_model$m",
        ref_chi2 = "MultiFoXS $(f)-state $(DEPOSITED_CHI2[f])",
        pdb = "SASDVN2_fit$(f)_model$m.pdb",
        fit = "SASDVN2_fit$f.dat",
        fit_scale = 1.0,
        fit_col = 3,
        rescale = false,
        software = "MultiFoXS $(f)-state",
    ) for (f, m) in MEMBERS
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

# Builds the Seed that `run_sasdvn2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdvn2` below is the whole story (build the seed, then sample it).
function seed_sasdvn2(run; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, q_fit, I_fit,
        σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdvn2(
    run;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdvn2(run; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for run in RUNS
    # one set of outputs per run (`res_fit1_model1.xlsx`, ...)
    suffix = "_" * run.tag

    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdvn2(run)

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

    # `@__DIR__` (this SASDVN2/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
