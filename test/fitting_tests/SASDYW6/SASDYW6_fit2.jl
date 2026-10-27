using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, Protein, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDYW6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "SASDYW6_fit2.fit")
const _CIF_PATH    = joinpath(_FIXTURE_DIR, "SASDYW6_fit2_model1.cif")
# CRYSOL .fit carries the reference fit curve itself (col 4)
const _FIT_PATH = _DATA_PATH

# ---------------------------------------------------------------------------
#                       SASDYW6_fit2_model1.cif structure
# ---------------------------------------------------------------------------
#
# Unlike SASDYW6_fit1_model1.cif (a GASBOR dummy-bead ab initio envelope --
# see SASDYW6_fit1.jl's header comment), this file is a real atomistic
# model: an AlphaFold3 prediction (`_software.name AlphaFold`,
# `_software.version "AlphaFold-beta-20231127 ..."`, `_audit_author.name
# "Google DeepMind"/"Isomorphic Labs"`) with full backbone + side-chain
# atoms (5528 ATOM records, no dummy beads). `_entity_poly`/
# `_entity_poly_seq` records list two polypeptide entities, strand IDs A
# and B, 360 residues each, and their `mon_id` sequences are byte-identical.

# 1 header line: " Dro: 0.083 Rg: 28.56 Vol: 97845. Chi^2: 3.737"
raw = readdlm(_DATA_PATH; skipstart = 1)

# CRYSOL .fit column layout (own inspection, same convention as
# SASDMJ9.jl's _FIT_PATH): q, Iexp, err, Ifit. SASBDB stores this already
# in Å⁻¹ (range ≈0.0079-0.250 Å⁻¹, consistent with B21/Diamond's usable
# q-range) -- no unit conversion applied.
qvals = Float64.(raw[:, 1])
I_exp = Float64.(raw[:, 2])
σ_exp = Float64.(raw[:, 3])

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# No paper PDF is bundled in the fixture directory for SASDYW6. Metadata
# fetched via WebFetch from https://www.sasbdb.org/data/SASDYW6/ (2026-09-25):
#
#   Sample:      Candida glabrata (Nakaseomyces glabratus) fructose-1,6-
#                bisphosphate aldolase (Fba1), dimer, monomer MW ~37 kDa
#   Buffer (structured field, REST API 2026-10-01): "20 mM Tris-HCl pH, 300 mM
#                NaCl", pH 8.0,
#                λ = 0.09464 nm -- identical to the sibling Pyruvate Kinase entry SASDYV6,
#                so most likely copied from it.
#   Buffer (this entry's own free-text description): 50 mM sodium phosphate,
#                500 mM NaCl, 500 mM imidazole, 1 mM PMSF, pH 8.5, λ = 0.094 nm
#   (These are one entry's conflicting fields, not two datasets. The free text is
#   used: it is specific to Fba1 and to this SEC-SAXS run.)
#   Beamline:    B21, Diamond Light Source (Didcot, UK)
#   Temperature: 15°C (both datasets)
#   Concentration: 1 mg/ml
#   Publication: Cuéllar-Cruz M, Siliqi D, Moreno A (2026), ACS Omega,
#                "Insights into the Solution Structure and Oligomeric State
#                of Fructose-1,6-bisphosphate Aldolase and Pyruvate Kinase
#                from Nakaseomyces glabratus by SAXS and AlphaFold
#                Prediction", DOI 10.1021/acsomega.6c06099
const PH, σ_PH = 8.5, PH_METER_SIGMA   # paper/SASBDB: "pH 8.5"

const ENERGY_EV = HC_EV_ANGSTROM / 0.94    # ≈ 13191 eV, from λ = 0.094 nm = 0.94 Å
const TEMPERATURE_C = 15.0    # 15°C, SASBDB (both datasets)
# I = ½Σcᵢzᵢ² over Na⁺ (NaCl + both NaPi fractions), Cl⁻, H2PO4⁻ (z=1), and
# HPO4²⁻ (z=2, enters with weight 4) -- same careful multi-species treatment
# SASDWZ9.jl uses for its own NaPi buffer, now that phosphate has real PMV
# data (previously missing at wiring time, see SOLUTES above).
# Na⁺ total = 0.500 + 0.002386 + 2·0.047610 ≈ 0.59761 M
# I = ½·[0.59761·1 + 0.500·1 + 0.002386·1 + 0.047610·4] ≈ 0.6452 M
# Imidazole (pKa≈7, mostly neutral free base at pH 8.5) and PMSF (a neutral
# organosulfonyl compound) contribute ~0 and are not separately counted.
const IONIC_STRENGTH_M = 0.6452   # unused by the fit; from the old pKa2 = 7.2 split

# Fba1 monomer sequence, read directly off SASDYW6_fit2_model1.cif's
# `_entity_poly_seq` records (entity 1, chain A, 360 residues; entity 2/
# chain B is byte-identical, confirming the homodimer). Converted from the
# file's 3-letter `mon_id` codes to 1-letter via the standard 20-residue table.
const FBA1_SEQ =
    "MGVQEVLKRKTGVIVGDDVRALFDYAKEHKFAIPAINVTSSSTVVAALEAARDAKSPIIL" *
    "QTSNGGAAYFAGKGVSNDGQNASIRGSIAAAHYIRSIAPAYGIPVVLHSDHCAKKLLPWY" *
    "DGMLEADEAYFKEHGEPLFSSHMLDLSEETDDENIATCVKYFKRMAAMNQWLEMEIGITG" *
    "GEEDGVNNEHVDKESLYTKPETVFAVHEALAPISPNFSIAAAFGNVHGVYQAGNVVLSPE" *
    "ILADHQKYAAEKTGAPAGSKPLYLVFHGGSGSTQEEFNTGINNGVVKVNLDTDCQYAYLT" *
    "GIRDYVLNKKDYIMSMVGNPEGADKPNKKFFDPRVWVREGEKTMSKRISEALDVFHTKNT"

# Average mass from FBA1_SEQ (ExPASy average residue masses + one water for
# the terminal H/OH): 39243.23 g/mol. SASBDB states "~37 kDa" for the
# monomer -- close but not identical, presumably a rounded/construct-
# specific figure; the sequence-derived value is used here for consistency
# with how molarity is computed everywhere else in this file family.
const FBA1_MW = 39243.23   # g/mol (monomer)
const FBA1_CONC_MG_ML = 1.0   # SASBDB: "Sample Concentration: 1 mg/ml"
# Monomer molarity used for the solution's bulk-electron-density term
# (matches SASDMJ9.jl's convention of using the monomer sequence/molarity
# even for an oligomeric species -- the dimer's electron-density
# contribution is the same either way since it's linear in C_j·Z_j; the
# structure file itself, unlike the Solute's molarity, carries the full
# dimer, both chains A and B).
const FBA1_MOLARITY   = FBA1_CONC_MG_ML / FBA1_MW    # ≈ 2.548e-5 M ≈ 25.5 µM
const FBA1_MOLARITY_σ = MOLARITY_REL_SIGMA * FBA1_MOLARITY

# Buffer components. Cross-checked against
# src/BulkElectronDensity/NonBiological/nonbio_lookup.json (case-insensitive
# grep) and the sibling nonbiological.tsv.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.500, 0.005, "sodium chloride"),   # 500 mM NaCl, ±1%
    NonBiological(0.500, 0.010, "imidazole"),          # 500 mM imidazole, ±2%
    # Cl⁻ counter-ion (added 2026-10-01): imidazole taken as titrated with
    # HCl at 22 °C; protonated fraction 0.046 with pK from Goldberg,
    # Kishore & Lennen 2002 (DOI 10.1063/1.1416902; 6.993, ΔH 36.64
    # kJ/mol), Davies-corrected at I ≈ 0.671 M. The titrant is not stated.
    NonBiological(0.023086, 0.006466, "chloride"),   # Cl⁻ from HCl titration of imidazole
    # 50 mM sodium phosphate at pH 8.5 is split into NaH2PO4/Na2HPO4 (no single
    # "sodium phosphate" PMV key). The HPO4²⁻ fraction is 0.979: pK2 from Goldberg,
    # Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31, 231, DOI
    # 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C (pH set at
    # room temperature), Davies-corrected at I ≈ 0.671 M, giving an effective pK2' ≈
    # 6.82. This replaces the earlier flat pKa2 = 7.2, which ignored ionic strength.
    # σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
    # 50 mM NaPi, H2PO4⁻ part
    NonBiological(0.001032, 0.000357, "sodium dihydrogen phosphate"),
    # 50 mM NaPi, HPO4²⁻ part
    NonBiological(0.048968, 0.001042, "disodium hydrogen phosphate"),
    # PMSF / phenylmethylsulfonyl fluoride (1 mM): no measured aqueous V0
    # exists (it hydrolyzes in water); the table entry
    # ("phenylmethanesulfonyl fluoride", resolves from "pmsf") is our own
    # estimate, 127.2 ± 5.0 cm³/mol (basis=predicted; see
    # BulkElectronDensity/README.md, "Adding a missing solute"). It is the
    # smallest-concentration component by far, so its ρₑ impact is minimal.
    NonBiological(0.001, 0.00005, "pmsf"),  # 1 mM PMSF, ±5% (unstable stock)
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

const Q_MAX_FIT = 0.25   # the .fit file's own max q (0.249981 Å⁻¹); no further cut needed

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

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

# Builds the Seed that `run_sasdyw6_fit2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdyw6_fit2` below is the whole story (build the seed, then sample it).
function seed_sasdyw6_fit2(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_CIF_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdyw6_fit2(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdyw6_fit2(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdyw6_fit2()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit2", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "CRYSOL 3.74",
    run_log = true,
)

# `@__DIR__` (this SASDYW6/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
