# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDUP5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUP5.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDUP5_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDUP5_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUP5: inosine-5'-monophosphate dehydrogenase (IMPDH) of Mycobacterium
# smegmatis, the octamer (8 x 513 residues), "ATP-bound form" per SASBDB.
#
# Publication (SASBDB): Bulvas O et al., Nat Commun 2024, DOI
# 10.1038/s41467-024-50933-6. Entry: https://www.sasbdb.org/data/SASDUP5/. The paper
# WAS consulted (the PDF in sources/, 41467_2024_Article_50933; its Suppl. Table 10 is
# not available) and is the source of the buffer (owner rule 2026-11-13: the paper wins
# over SASBDB). Methods, "Small angle X-ray scattering" (PDF p. 11): "Samples of 3 mg ml-1
# MsmIMPDH in buffer containing 50 mM HEPES, pH 7.4, 200 mM KCl, and 0.5 mM TCEP were
# measured in the presence of ATP, GTP, and IMP (0-10 mM) and a 2 mM molar excess of
# MgCl2 over the nucleotide concentration. Buffer-solution datasets were collected
# under the same conditions, including the respective nucleotides." Fig. 4f legend
# (PDF p. 6): SAXS profiles of 56 uM MsmIMPDH, "(orange) compressed octamers in the apo
# state, (red) with 10 mM GTP, and (blue) with 10 mM ATP; ... (purple) extended
# octamers induced by 10 mM ATP and IMP". The ATP-bound octamer of this entry is the
# 10 mM ATP condition (SASBDB has one entry per condition: apo SASDUM5, IMP SASDUN5,
# ATP SASDUP5, ATP+IMP SASDUQ5, GTP SASDUR5, all with the identical buffer field "50 mM
# HEPES, 200 mM KCl, 2 mM MgCl2, 0.5 mM TCEP", pH 7.5, i.e. SASBDB lists neither the
# nucleotide nor the paper's pH 7.4). Resolved with the paper: pH 7.4, ATP 10 mM,
# MgCl2 = 2 mM excess + 10 mM = 12 mM (SASBDB's 2 mM is the excess alone).
#
# Instrument (SASBDB): Anton Paar SAXSpoint 2.0 at IBT Vestec (Czech Republic);
# wavelength 0.134 nm = 1.34 Å (SASBDB `xray_energy` is null, so the energy is hc/λ ≈
# 9253 eV); sample temperature 20 °C.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; text lines, then
# q, I, σ, all skipped by `_readCurve`) and is converted to Å⁻¹ (÷10). The intensities
# are on an arbitrary scale. The fit is cut at `Q_MAX_FIT` = 0.2 Å⁻¹ because the
# curve is a flat noise floor above it (see the q cut in the wiring section; the
# depositor's CRYSOL curve ends there too, 0.2002 Å⁻¹); `seedModel` drops non-positive bins.
#
# Model and depositor fit: fit1 is CRYSOL 2.8.3 against SASBDB's atomic model of the
# octamer (8 chains of 513 residues, 34186 hydrogens, protein only, no ligands, PDB-v3
# N-terminal names H2/H3). The fit header reads "Chi^2: 2.433", which equals SASBDB's
# chi_square_value, so the label is χ² and header and REST agree. The .fit file has
# columns q (Å⁻¹), I_exp, σ, I_fit (CRYSOL).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # paper (Methods, SAXS): pH 7.4 (SASBDB: 7.5)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 0.134 nm
const TEMPERATURE_C = 20.0                    # SASBDB sample temperature (paper: none)

# Buffer (paper, Methods "Small angle X-ray scattering" and Fig. 4f): 50 mM HEPES,
# pH 7.4, 200 mM KCl, 0.5 mM TCEP, 10 mM ATP and 12 mM MgCl2 (2 mM excess over the
# 10 mM nucleotide). The measured macromolecule is deliberately NOT a solute (see
# BulkElectronDensity.Solute).
#
# Counter-ion. HEPES is neutral in BAYSOL's table; setting the pH with NaOH is the
# convention (the titrant is not stated), leaving Na⁺ = c·f with f the deprotonated
# fraction: pK(22 °C) = 7.601 (the value the sibling scripts use), pH = pK + log(f/(1-f))
# - A·g(I) with the Davies term g(I) = √I/(1+√I) - 0.3 I, A = 0.509, solved at the
# self-consistent I = 0.5·(KCl 0.2 + MgCl2 0.012·4 + 0.024 + 2·f·0.05) with the
# nucleotide left out: I = 0.259 M, f = 0.4604, i.e. Na⁺ = 23.02 mM (the ionic strength
# of the ATP and its Mg complex, I up to about 0.45 M, moves f by < 0.003, i.e. < 0.2
# mM). σ = 3.3 mM combines σ_pH = 0.1 (2.9 mM; df/dpH = f(1-f)·ln 10 = 0.57), ±3 °C on
# the pK (ΔH about 21 kJ/mol; 1.1 mM), ±0.02 pK (0.6 mM), 30 % of the Davies shift
# (1.1 mM) and ±2 % on C (0.5 mM).
#
# ATP 10 mM is the solute `atp` as the neutral acid (as in SASDTX4); the counter-ions of
# ATP⁴⁻ (Na⁺ or H⁺ titrant from the salt used, about 20-35 mM) and the Mg²⁺-ATP complex
# are not stated and not modelled: 30 mM Na⁺ is 1.8e-4 e⁻/Å³, 0.05 % of the electrons of
# water (listed under BUFFER_OMISSIONS). TCEP (0.5 mM; counter-ion unknown, negligible).
const SOLUTES = Solute[
    NonBiological(0.050, 0.001, "hepes"),                # 50 mM HEPES, ±2%
    NonBiological(0.023022, 0.0033, "sodium(1+)"),       # Na⁺ from NaOH titration
    NonBiological(0.200, 0.002, "potassium chloride"),   # 200 mM KCl, ±1%
    NonBiological(0.012, 0.00024, "magnesium chloride"), # 12 mM MgCl₂ (2 mM + 10 mM), ±2%
    NonBiological(0.0005, 1e-05, "tcep"),                # 0.5 mM TCEP, ±2%
    NonBiological(0.010, 0.0002, "atp"),                 # 10 mM ATP, ±2%
]
# The omissions listed above, one line each. Every run of this script, and every
# developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "counter-ions of ATP (10 mM, salt not stated) and Mg²⁺-ATP pairing not modelled",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDUP5: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.2 Å⁻¹. The data run to 0.400 Å⁻¹,
# but the 342 points above 0.2 Å⁻¹ (σ > 0) have a median I/σ of -0.06 and 53 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.25 Å⁻¹) has a median I/σ of 0.32.
const Q_MAX_FIT = 0.2

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model carries its own hydrogens (v3 names): pdb2pqr/PROPKA place them
# at PH. UNTESTED for this file; if pdb2pqr rejects it (compare SASDP48), set this to
# false and the model's own hydrogens are used.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdup5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdup5` below is the whole story (build the seed, then sample it).
function seedSasdup5(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdup5(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdup5(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdup5()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
shown = crysol[:, 1] .> 0
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[shown, 1]),
    Float64.(crysol[shown, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 2.433",
    runLog = true,
)

# `@__DIR__` (this SASDUP5/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
