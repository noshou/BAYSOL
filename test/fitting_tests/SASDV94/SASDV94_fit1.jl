using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDV94")
const _FIT_PATH = joinpath(_FIXTURE_DIR, "SASDV94_fit1.fit")

# `SASDV94_fit1_model1.pdb`'s own ATOM records mix two kinds of chain: real
# atomistic chains (B = PLC H, D = PLC R2, both with full backbone + side
# chains) and two CA-only, single-residue-type ("GLY") dummy chains (A:
# residues 1-40; C: residues 745-772) that are  rigid-body-modelling
# filler beads for disordered termini.
# Passing those beads through to the forward model/Pdb2pqr would (a)
# corrupt the scattering calculation with un-hydrogenated placeholder mass
# that was never observed, and (b) likely crash pdb2pqr, which
# expects real per-residue backbone chemistry it cannot reconstruct from CA
# alone. `awk` was used to write # `SASDV94_fit1_model1_PLCH_R2.pdb`, containing 
# only chains B and D's ATOM records.
const _PDB_PATH = joinpath(_FIXTURE_DIR, "SASDV94_fit1_model1_PLCH_R2.pdb")

# ---------------------------------------------------------------------------
#                            Experimental data
# ---------------------------------------------------------------------------
#
# `experimental_data/` and `pddf/` are both empty for this fixture. 
#
#   CrPL4.pd  Dro:0.015  Ra:1.800  RGT:31.46  Vol:136085.  Chi^2: 1.284
#
# is a CRYSOL rigid-body-fit header (Dro/Ra/RGT/Vol are CRYSOL's own
# hydration-shell-contrast/atomic-radius/Rg/volume outputs), followed by 4
# data columns: q, I_exp, σ_exp, I_fit(CRYSOL model against
# SASDV94_fit1_model1.pdb). q is already in Å⁻¹ (max ≈0.434); no unit conversion needed.
raw = readdlm(_FIT_PATH; skipstart = 1)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: doi:10.1093/procel/pwag062 ("Molecular virulence mechanism of phospholipase C from
# Pseudomonas aeruginosa", Sabharwal et al., Protein & Cell).
#
# SASBDB metadata (WebFetch of sasbdb.org/data/SASDV94/):
#   Sample: Phospholipase C (PLC H) bound to chaperone PLC R2 complex
#   Buffer: 25 mM Tris pH 7.5, 100 mM NaCl, 3 mM β-mercaptoethanol
#   Temperature: 20°C
#   Concentrations: three sequential SEC-SAXS injections (3.5, 7, 14 mg/mL),
#     merged to mitigate radiation damage at the higher concentrations
#   Beamline: EMBL P12, PETRA III (DESY, Hamburg); λ = 0.12398 nm
#   Column: Cytiva Superdex 200 Increase 10/300, 0.7 mL/min
#
# NOTE: fit1 and fit2 (SASDV94_fit2.fir) are, the SAME
# experimental curve. Directly comparing
# I_exp at matching q between SASDV94_fit1.fit and SASDV94_fit2.fir (e.g.
# q≈0.05: 0.037785 both files; q≈0.10: 0.0043852 both; q≈0.20: 0.00020545
# both) shows bit-for-bit identical experimental intensities wherever the
# two files' q-grids coincide. fit1 (.fit, CRYSOL format) is this one
# merged SEC-SAXS curve fit against a rigid-body/atomistic model (this
# script); fit2 (.fir, GNOM format, narrower q-range 0.015-0.300 Å⁻¹) is the
# same curve fit against two ab initio DAMMIF/DAMAVER dummy-atom bead
# reconstructions.

const PH, σ_PH = 7.5, PH_METER_SIGMA   # buffer pH stated directly by SASBDB metadata

# = 10000.0 eV, from λ=0.12398 nm (P12's standard 10 keV setting)
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2398
const TEMPERATURE_C = 20.0               # 20°C, SASBDB
# 100 mM NaCl; Tris (near-neutral free base at pH 7.5) and
const IONIC_STRENGTH_M = 0.100
# 2-mercaptoethanol (neutral thiol-alcohol)
# are treated as ionic-strength-inert, same
# convention as SASDMJ9/SASDZC6's own
# Tris/DTT/BME-type buffer components.

# ---------------------------------------------------------------------------
#                    Sequences and complex stoichiometry
# ---------------------------------------------------------------------------
#
# Sequences read off of SASDV94_fit1_model1_PLCH_R2.pdb's ATOM records:
#
#   chain B: PLC H,  residues 27-730 (704 resolved residues)
#   chain D: PLC R2, residues 65-207 (143 resolved residues, the 19 kDa
#            cognate chaperone's disordered N-terminus is not resolved here)
#
# Paper text: "1:1 stoichiometry of PLC H/R2 complex" (Results, 2nd
# paragraph), so both proteins therefore share the same molarity.
const PLC_H_SEQ =
    "GLFPETLRRALAIEPDIRTGTIQDVQHVVILMQENRSFDHYFGHLNGVRGFNDPRALKRQ" *
    "DGKPVWYQNYKYEFSPYHWDTKVTSAQWVSSQNHEWSAFHAIWNQGRNDKWMAVQYPEAM" *
    "GYFKRGDIPYYYALADAFTLCEAYHQSMMGPTNPNRLYHMSGRAAPSGDGKDVHIGNDMG" *
    "DGTIGASGTVDWTTYPERLSAAGVDWRVYQEGGYRSSSLWYLYVDAYWKYRLQEQNNYDC" *
    "NALAWFRNFKNAPRDSDLWQRAMLARGVDQLRKDVQENTLPQVSWIVAPYCYCEHPWWGP" *
    "SFGEYYVTRVLDALTSNPEVWARTVFILNYDEGDGFYDHASAPVPPWKDGVGLSTVSTAG" *
    "EIEASSGLPIGLGHRVPLIAISPWSKGGKVSAEVFDHTSVLRFLERRFGVVEENISPWRR" *
    "AVCGDLTSLFDFQDAGDTQVAPDLTNVPQSDARKEDAYWQQFYRPSPKYWSYEPKSLPGQ" *
    "EKGQRPTLAVPYQLHATLALDIAAGKLRLTLGNDGMSLPGNPQGHSAAVFQVQPREVGNP" *
    "RFYTVTSYPVVQESGEELGRTLNDELDDLLDANGRYAFEVHGPNGFFREFHGNLHLAAQM" *
    "ARPEVSVTYQRNGNLQLNIRNLGRLPCSVTVTPNPAYTQEGSRRYELEPNQAISEVWLLR" *
    "SSQGWYDLSVTASNTEANYLRRLAGHVETGKPSRSDPLLDIAAT"

const PLC_R2_SEQ =
    "NLEQQLGEFGRNAGQMSEIERKQAAEGLIEQLKREVAVGADPRQTFEEIQRLTPYVEADA" *
    "RRREALDFEIWMALKDNASVQQQAPTPGEEEQLREYAQESDKVIAEVLASVDGEEQRHAA" *
    "IDERLKALRKQIFGEENPRLLQR"

# Average masses from each *_SEQ (ExPASy average
# residue masses + one water for the terminal H/OH).
const PLC_H_MW = 79_695.78   # g/mol
const PLC_R2_MW = 16_387.22   # g/mol
const COMPLEX_MW = PLC_H_MW + PLC_R2_MW   # ≈ 96_083 g/mol

# SASBDB's merged injections (3.5, 7, 14 mg/mL) were pooled into one
# curve  to remove concentration-dependent (interparticle)
# effects, so no single concentration applies to the deposited/merged
# profile. The series mean is used as the representative concentration, with
# a widened relative uncertainty. Assumed each measurement as a ≈5% error, 
# typical for A280 measurements 
const COMPLEX_CONC_MG_ML = (3.5 + 7.0 + 14.0) / 3   # ≈ 8.17 mg/mL
const COMPLEX_MOLARITY   = COMPLEX_CONC_MG_ML / COMPLEX_MW   # ≈ 8.50e-5 M
const COMPLEX_MOLARITY_σ = 0.20 * COMPLEX_MOLARITY           # 20% relative

# Buffer components. "sodium chloride", "tris", and "2-mercaptoethanol" Counter-ions
# (added 2026-10-01). Setting the pH adds titrant counter-ions that the deposited
# recipe does not list. Assumed: 25 mM Tris titrated with HCl -> Cl⁻ = C·0.855 (pK(22
# °C) = 8.156). The pH is taken as set at room temperature (22 ± 3 °C), which fixes
# the counter-ion amount whatever the measurement temperature. pK(T) from Goldberg,
# Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902)
# pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.121 M. σ combines σ_PH, ±3 °C,
# ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is modelled;
# the volume change of the buffer's own (de)protonation is not. Titrant: not stated;
# HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.100, 0.001, "sodium chloride"),      # 100 mM NaCl, ±1%
    NonBiological(0.025, 0.0005, "tris"),                 # 25 mM Tris pH 7.5, ±2%
    NonBiological(0.003, 0.00006, "2-mercaptoethanol"),    # 3 mM β-mercaptoethanol, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.021365, 0.001069, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# SASDV94_fit1.fit's own q_max (≈0.434015 Å⁻¹); no truncation needed
const Q_MAX_FIT = 0.434

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# real atomistic structure (chains B/D only); runs Pdb2pqr at PH
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

# Builds the Seed that `run_sasdv94_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdv94_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdv94_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdv94_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdv94_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdv94_fit1()

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
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "CRYSOL 1.28",
    run_log = true,
)

# `@__DIR__` (this SASDV94/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
