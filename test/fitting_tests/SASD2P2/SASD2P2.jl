# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASD2P2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASD2P2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASD2P2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASD2P2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASD2P2: chondroitin sulfate 8-mer (CS08; 1.8 kDa; SASBDB experimental MW
# 1.8 kDa, "molecular_type other", no sequence), a sulfated glycosaminoglycan octasaccharide
# at 10 mg/ml, in 50 mM sodium phosphate pH 7.0 with 100 mM NaCl (paper; SASBDB lists
# only the phosphate). IMPORTANT: this entry is the glycan
# ALONE (the sample list has one molecule and the atomic model has 197 atoms); it is
# not a CXCL8 complex, although the SASBDB model record links PDB 3IL8 (CXCL8) and the
# project is about glycosaminoglycan-bound CXCL8.
#
# Publication (SASBDB): White MA, Mahler BP, Joseph PRB, Nagarajan B, Wang X, Desai UR,
# Rajarathnam K, "Solution structures of glycosaminoglycan-bound CXCL8 complexes
# determined by small-angle X-ray scattering (SAXS)", Biochem J 2026 Oct 7, DOI
# 10.1042/BCJ20260348, PMID 42619214. Entry: https://www.sasbdb.org/data/SASD2P2/.
# The paper WAS read (round-6 audit, 2026-11-13; PDF in sources/, with its Supplementary
# Table 1 appended) and is the source of truth: Suppl. Table 1 (a), the column "CS dp08"
# (the glycan alone, 10.0 mg/ml): "Buffer (solution in which the samples were dissolved
# and also for buffer subtraction): 50 mM Na2PO4 pH 7.0, 100mM NaCl"; (b) wavelength
# 1.5418 Å, camera length 484.2 mm, sample temperature 5 °C, Rigaku BioSAXS-1000; (f)
# CS dp08 "MD (197)", CRYSOL (ns=151, lm=25) χ² 0.922, Vol 1925 Å^3, Rg 11.25 Å, Dro
# 0.004, "Constant subtraction yes" (s range 0.0151-0.500 Å⁻¹). The Methods sentence
# "50 mM sodium phosphate buffer (pH 7.0) containing 100 mM NaCl and 5 mM MgCl2" is about
# the heparin-CXCL8 and CS-CXCL8 complexes ("SAXS data for heparin-CXCL8 and CS-CXCL8
# complexes"); the free glycan's own column of Suppl. Table 1 has no MgCl2, so none is
# modelled. SASBDB gives only "50 mM phosphate buffer pH 7.0" (no NaCl): the paper's
# NaCl is added. The paper's χ² (0.922) is its own CRYSOL run with a subtracted
# constant; the depositor's .fit (0.899) is the one overlaid and used as refChi2.
#
# Instrument (SASBDB): Rigaku BioSAXS-1000 (in-house source), Pilatus 100K detector,
# Sealy Center for Structural Biology, UTMB, Galveston, TX, USA; wavelength 0.15418 nm
# (SASBDB `xray_energy` is null, so the energy is hc/λ ≈ 8041 eV); sample-detector
# distance 0.4842 m; ten 3600 s frames; cell and storage temperature 5 °C; measured
# 2016-03-21; one concentration, 10 mg/ml. Wavelength, distance and 5 °C agree with the
# paper.
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (angular_unit "1/A"; 475 points from
# 0.0151 to 0.691 Å⁻¹; six "#" comment lines, then q, I, σ, all handled by `_readCurve`).
# The intensities are in arbitrary units (SASBDB intensity_unit); I(0) ≈ 1860. No point has
# I ≤ 0; I/σ is 77 at 0.08 Å⁻¹, 9.5 at 0.49 Å⁻¹ and still about 4 on average beyond
# 0.5 Å⁻¹, so the whole curve is fitted (no q cut). The data go to 0.691 Å⁻¹ but the
# depositor's CRYSOL curve ends at 0.4988 Å⁻¹, so refChi2 is not like for like.
#
# Model and depositor fit: SASBDB type "mix", software "Custom in-house", Charmm, symmetry
# P1, comment "Polysaccharide not in External DBs listed". SASD2P2_fit1_model1.pdb is
# SASBDB's file, kept UNCHANGED: 197 ATOM records (no chain id, residues 144-155), all
# the glycan (56 C, 77 H, 56 O, 4 N, 4 S; hydrogens included), written with CHARMM
# glycan residue names (4ZB, VVB, 6VB, SO3) that are not standard wwPDB names for these
# groups.
# LOADER CHECK (static reading of src/molecular-structure, nothing run, round-6 audit):
# `components.tsv` has the SAME three-letter ids as UNRELATED wwPDB components (4ZB: C20
# H26 N8 O, 6VB: C28 H23 Br O13 S3, VVB: H2 O2 V, SO3: O3 S, all class "other"), but
# the loader never uses them for these atoms. The model is written as ATOM records, and
# `polymerSelector` (Components.jl) keeps every ATOM record whatever its residue name;
# `loadMolecule` (mols.jl) builds the atoms from the element column (all filled) only.
# `dummyLikeResidues` (checks.jl, logged, flow unchanged) does not flag it (each residue
# has far more than `DUMMY_MAX_HEAVY_ATOMS` = 2 heavy atoms; occupancy is 1.00). So the
# file loads and the 120 heavy atoms scatter. What is lost: the canonical copy that
# `resloveStruct` writes always drops hydrogens (`hydrogenselector` in
# `_canonicalSelector`), `ADD_HYDROGENS = false` skips pdb2pqr, and a glycan is not
# something PARSE/PROPKA can hydrogenate (the ids are not peptides or nucleotides, so
# `hydrogenationChoice` would route it to the protein path). The model's 77 hydrogens
# (about 8 % of its 953 electrons) therefore do not scatter; the fitted ρₑ/δρ absorb
# part of it. The script uses `ADD_HYDROGENS = false`; no loader change and no model edit
# were made. The deposited fit header reads "Dro: 0.000
# Rg: 11.31 Vol: 1925. Chi^2: 0.899"; the fit file (340 rows, q = 0.0151 to 0.4988 Å⁻¹)
# recomputed from its columns 2-4 gives χ² = 0.896, so the label is χ² (not χ) and the
# depositor's χ² is 0.899 (SASBDB chi_square_value: the same; CRYSOL 3.2.1). CRYSOL's
# contrast was set to 0.000.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A); no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # paper and SASBDB: pH 7.0

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5418   # ≈ 8041 eV, 1.5418 Å (paper, SASBDB)
const TEMPERATURE_C = 5.0                    # paper (Suppl. Table 1) and SASBDB

# Buffer (paper, Suppl. Table 1, quoted above): 50 mM sodium phosphate pH 7.0 ("Na2PO4"
# is not a defined salt; at pH 7.0 sodium phosphate is the HPO₄²⁻/H₂PO₄⁻ mixture of
# Na⁺ salts, so the species are computed from the pH, the convention of SASDV62) and
# 100 mM NaCl. SASBDB: "50 mM phosphate buffer pH 7.0" (no NaCl, no cation; the paper's
# sodium is taken). The measured glycan is deliberately NOT a solute (see
# BulkElectronDensity.Solute).
#
# pK₂ = 7.198 at 25 °C, ΔH = 3.6 kJ/mol (Goldberg, Kishore & Lennen 2002, J. Phys. Chem.
# Ref. Data 31, 231, DOI 10.1063/1.1416902; the same values as the SASDV62 script, quoted
# from there and not re-checked), moved to the measurement temperature 5 °C by van't
# Hoff (pK₂ = 7.243, ΔCp ignored; the pH is not shifted for temperature), Davies-
# corrected (A = 0.509). With x the HPO₄²⁻ fraction the ionic strength is I = 0.1
# (NaCl) + 0.05 + 0.1 x = 0.15 + 0.1 x, and log(x/(1 − x)) = pH − pK₂ + 3 A f(I) with f
# = √I/(1 + √I) − 0.3 I (the activity ratio γ(HPO₄²⁻)/γ(H₂PO₄⁻) = 10^(−3 A f)); solved
# by iteration: I ≈ 0.208 M, f = 0.2508, log ratio = 0.1396, x = 0.580 (without the
# activity correction 0.364), i.e. HPO₄²⁻ 28.99 mM and H₂PO₄⁻ 21.01 mM. σ combines σ_pH
# = 0.1 (2.81 mM) and 30 % of the Davies shift (3.24 mM): 4.29 mM for both species (they
# are anticorrelated, as the total is fixed, which the independent σ ignores). NaCl ±2 %.
const SOLUTES = Solute[
    NonBiological(0.1, 0.002, "sodium chloride"),                    # 100 mM NaCl, ±2%
    NonBiological(0.02899, 0.00429, "disodium hydrogen phosphate"),  # HPO₄²⁻, 28.99 mM
    NonBiological(0.02101, 0.00429, "sodium dihydrogen phosphate"),  # H₂PO₄⁻, 21.01 mM
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = false: the model is a glycan alone, which the protein/nucleic
# hydrogenation route does not handle; the loader keeps the 120 heavy atoms and drops the
# model's 77 hydrogens (see "LOADER CHECK" above).
const ADD_HYDROGENS = false

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasd2p2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasd2p2` below is the whole story (build the seed, then sample it).
function seedSasd2p2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasd2p2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasd2p2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasd2p2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 0.899",
    runLog = true,
)

# `@__DIR__` (this SASD2P2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
