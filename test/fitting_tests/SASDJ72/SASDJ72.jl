using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDJ72")
const _PDB_PATHS   = (
model1 = joinpath(_FIXTURE_DIR, "SASDJ72_fit1_model1.pdb"),
model2 = joinpath(_FIXTURE_DIR, "SASDJ72_fit1_model2.pdb")
)
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDJ72_fit1.fit")

# SASDJ72 ships no experimental_data/ or pddf/ fixture (both directories are
# present but empty); SASDJ72_fit1.fit
#   # SAXS profile: number of points = 517, q_min = ..., q_max = 0.3256..., delta_q = ...
#   # offset = ..., scaling c = ..., Chi^2 = ...
#   #  q       exp_intensity   error model_intensity
# followed by 517 data rows, columns (q, I_exp, σ_exp, I_crysol_fit). q is
# already in Å⁻¹ (q_max ≈ 0.326 Å⁻¹, typical SIBYLS-beamline protein SAXS
# range) -- no nm→Å conversion needed here, unlike SASDMJ9's .dat file.
raw = readdlm(_FIT_PATH; skipstart = 3)

qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
# Hammel M, Rashid I, Sverzhinsky A, et al., "An atypical BRCT-BRCT interaction 
# with the XRCC1 scaffold protein compacts human DNA Ligase IIIα within a flexible DNA
# repair complex", Nucleic Acids Res, 2020.
#
# Sample: human DNA Ligase IIIα (LigIIIα), monomer/dimer;
# SASBDB reports a Porod/sequence-derived monomer MW of
# 102.69 kDa but an experimental (I(0)-derived) MW of ~150 kDa, suggestive of
# partial dimerization in solution. Both candidate PDB models here
# (SASDJ72_fit1_model1.pdb, SASDJ72_fit1_model2.pdb) are single-chain,
# single-copy structures (922 residues each, see below), so no multimer
# scaffolding is attempted.
#
# Buffer (SASBDB "Sample buffer"): 25 mM Tris-HCl, 150 mM NaCl, 10%
# glycerol, 2 mM DTT, pH 7.5.
#
# Instrument: SIBYLS beamline 12.3.1 (Advanced Light Source, Berkeley),
# MAR 165 CCD, stated wavelength λ = 0.11 nm = 1.1 Å
# => energy = hc/λ ≈ HC_EV_ANGSTROM / 1.1 ≈ 11271.29 eV (hc = 12398.42 eV·Å).
#
# Temperature: SASBDB states 20°C measurement (10°C storage); 20°C is used.
#
# Sample concentration: SASBDB states a 1-5 mg/ml range, with "low-angle
# data collected at lower concentration merged with the highest
# concentration high-angle data" i.e. SASDJ72_fit1.fit is a
# concentration-merged curve, not a single-concentration measurement. No
# single mg/ml figure is exactly correct; 3.0 mg/ml (midpoint of the stated
# range) is used with a wide (40%) relative uncertainty on molarity to
# reflect that ambiguity, rather than fabricating a precise number.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV        = HC_EV_ANGSTROM / 1.1   # ≈ 11271.29 eV, from stated λ = 0.11 nm
const TEMPERATURE_C    = 20.0            # 20°C measurement, SASBDB
const IONIC_STRENGTH_M = 0.150           # 150 mM NaCl

# LigIIIα sequence, read off SASDJ72_fit1_model1.pdb (MODEL 1;
# the file contains two MODEL records; load_molecule only reads struc[1],
# i.e. MODEL 1, so that's what's transcribed here). No chain ID is present
# in either PDB file (column is blank); single continuous chain, 922
# residues, CA-verified against SASDJ72_fit1_model2.pdb (identical
# sequence, confirming both candidate models represent the same construct).
const LIGIII_SEQ =
    "MAEQRFCVDYAKRGTAGCKKCKEKIVKGVCRIGKVVPNPFSESGGDMKEWYHIKCMFEKL" *
    "ERARATTKKIEDLTELEGWEELEDNEKEQITQHIADLSSKAAGTPKKKAVVQAKLTTTGQ" *
    "VTSPVKGASFVTSTNPRKFSGFSAKPNNSGEAPSSPTPKRSLSSSKCDPRHKDCLLREFR" *
    "KLCAMVADNPSYNTKTQIIQDFLRKGSAGDGFHGDVYLTVKLLLPGVIKTVYNLNDKQIV" *
    "KLFSRIFNCNPDDMARDLEQGDVSETIRVFFEQSKSFPPAAKSLLTIQEVDEFLLRLSKL" *
    "TKEDEQQQALQDIASRCTANDLKCIIRLIKHDLKMNSGAKHVLDALDPNAYEAFKASRNL" *
    "QDVVERVLHNAQEVEKEPGQRRALSVQASLMTPVQPMLAEACKSVEYAMKKCPNGMFSEI" *
    "KYDGERVQVHKNGDHFSYFSRSLKPVLPHKVAHFKDYIPQAFPGGHSMILDSEVLLIDNK" *
    "TGKPLPFGTLGVHKKAAFQDANVCLFVFDCIYFNDVSLMDRPLCERRKFLHDNMVEIPNR" *
    "IMFSEMKRVTKALDLADMITRVIQEGLEGLVLKDVKGTYEPGKRHWLKVKKDYLNEGAMA" *
    "DTADLVVLGAFYGQGSKGGMMSIFLMGCYDPGSQKWCTVTKCAGGHDDATLARLQNELDM" *
    "VKISKDPSKIPSWLKVNKIYYPDFIVPDPKKAAVWEITGAEFSKSEAHTADGISIRFPRC" *
    "TRIRDDKDWKSATNLPQLKELYQLSKEKADFTVVAGDEGSSTTGGSSEENKGPSGSAVSR" *
    "KAPSKPSASTKKAEGKLSNSNSKDGNMQTAKPSAMKVGEKLATKSSPVKVGEKRKAADET" *
    "LCQTKVLLDIFTGVRLYLPPSTPDFSRLRRYFVAFDGDLVQEFDMTSATHVLGSRDKNPA" *
    "AQQVSPEWIWACIRKRRLVAPC"

# Average mass from LIGIII_SEQ (ExPASy average residue masses + one water
# for the terminal H/OH) = 102690.9 Da, matching SASBDB's reported
# 102.69 kDa monomer MW almost exactly.
const LIGIII_MW = 102690.9   # g/mol
# midpoint of SASBDB's stated 1-5 mg/ml range; see note above
const LIGIII_CONC_MG_ML = 3.0
const LIGIII_MOLARITY   = LIGIII_CONC_MG_ML / LIGIII_MW # ≈ 2.92e-5 M (≈ 0.0292 mM)
const LIGIII_MOLARITY_σ = 0.40 * LIGIII_MOLARITY        # 40% merged-curve estimate

# Buffer components. Counter-ions (added 2026-10-01). Setting the pH adds titrant
# counter-ions that the deposited recipe does not list. Assumed: 25 mM Tris titrated with
# HCl -> Cl⁻ = C·0.857 (pK(22 °C) = 8.156). The pH is taken as set at room temperature (22
# ± 3 °C), which fixes the counter-ion amount whatever the measurement temperature. pK(T)
# from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.171 M. σ combines
# σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the counter-ion is
# modelled; the volume change of the buffer's own (de)protonation is not. Titrant: not
# stated; HCl for amine bases (Tris, imidazole, histidine), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.150, 0.0015, "sodium chloride"), # 150 mM NaCl, ±1%
    NonBiological(0.025, 0.0005, "tris"),            # 25 mM Tris-HCl, ±2%
    NonBiological(0.002, 0.00004, "dtt"),             # 2 mM DTT, ±2%
    # 10% v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL)
    # and MW (92.094 g/mol): 10 mL glycerol/100 mL soln * 1.2613 g/mL /
    # 92.094 g/mol * 1000 ≈ 1.369 M. Wider (5%) relative uncertainty than
    # the other components since this is a v/v -> molarity approximation
    # (ignores mixing non-ideality), not a directly-stated molar concentration.
    NonBiological(1.369, 0.0685, "glycerol"),
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.021436, 0.001060, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# Restricting the fit to q ≤ Q_MAX_FIT = 0.30 Å⁻¹ drops the noisiest tail points
# above that, where relative errors balloon to 20-40%. The spherical-harmonic
# band limit lMax is not set here: `seed_model` takes it from the diameter of
# the scatterer cloud and the largest fitted q (ceil(q_max * D)), and bins the
# curve to the Shannon channels that diameter allows (see `rebin` there).

const Q_MAX_FIT = 0.30

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seed_model` bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdj72` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `run_sasdj72` below is the whole story (build the seed, then sample it).
function seed_sasdj72(model::Symbol; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATHS[model]), ENERGY_EV,
        q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdj72(
    model::Symbol;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdj72(model; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

for model in (:model1, :model2)
    result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdj72(model)

    fit, divergence_rate, map_result, quantile_result = result

    # The figures (terminal plots, pgfplots .tex, TSV) go before the report, so
    # that their time is in its timing section.
    crysol = readdlm(_FIT_PATH; skipstart = 3)
    reference = BAYSOL.Reference(
        "MultiFoXS 2-state",
        Float64.(crysol[:, 1]),
        Float64.(crysol[:, 4]);
        q_max = Q_MAX_FIT,
    )
    BAYSOL.results(
        result, (q_fit, I_fit, σ_fit);
        dir = @__DIR__, name = "res_$(model)", references = reference,
        form_factor_log = form_factor_log, n_atoms = n_atoms,
    )

    # `@__DIR__` (this SASDJ72/ folder), not the caller's cwd.
    BAYSOL.print_summary(result)
end
