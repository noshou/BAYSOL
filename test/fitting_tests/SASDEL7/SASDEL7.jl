# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDEL7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDEL7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "6I33.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDEL7_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# Audit 2026-11-13 (owner rule: papers first; a value is open only if neither the paper nor
# the SASBDB record states it): SASBDB lists no publication, and its record states the
# complete buffer, pH, temperature and wavelength used below, so nothing is assumed beyond
# the titrant/counter-ion convention.
#
# SASBDB SASDEL7: human glycine decarboxylase (GLDC, P-protein of the glycine cleavage
# system; UniProt P23378), a dimer of two 109.367 kDa chains (SASBDB experimental MW
# 190 kDa) at 5 mg/ml, in 10 mM Tris pH 7.5, 100 mM NaCl, 1 mM DTT.
#
# Publication: SASBDB lists none (the project is titled "Glycine decarboxylase (P-protein
# of glycine cleavage system)"; contributor Bart Van Laer, ESRF). The crystal structure
# PDB 6I33 has its own paper that was NOT consulted. The conditions below are the SASBDB
# entry metadata (buffer field and experiment description agree). The buffer contains NO
# glycine, so this entry does not cover an amino-acid buffer. Entry:
# https://www.sasbdb.org/data/SASDEL7/.
#
# Instrument (SASBDB): ESRF BM29 (synchrotron), Pilatus 1M; wavelength 0.099 nm
# (SASBDB `xray_energy` is null, so the energy is hc/λ ≈ 12523 eV); sample-detector
# distance 2.864 m; 10 successive 0.5 s frames; cell and storage temperature 20 °C;
# measured 2017-11-12; one concentration, 5 mg/ml.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; 1035 points from 0.0761
# to 4.934 nm⁻¹; two text lines, then q, I, σ, then trailing text, all skipped by
# `_readCurve`) and is converted to Å⁻¹ (÷10). The intensities are in arbitrary units
# (SASBDB intensity_unit). The curve is very precise at low q (I/σ about 200) and
# I/σ is only about 2-5 beyond 0.2 Å⁻¹; the 33 points with I ≤ 0 all lie above 0.35 Å⁻¹.
# The whole curve is fitted (no q cut, see `Q_MAX_FIT`); the depositor's CRYSOL curve
# ends at 0.40 Å⁻¹.
#
# Model and depositor fit: SASBDB states the atomic model is identical to PDB 6I33
# (human glycine decarboxylase, crystal structure at 2.30 Å); SASDEL7's 6I33.pdb is
# SASBDB's copy. Its 14617 ATOM records (chains A and B) have the same coordinates as
# the ones of files.rcsb.org/download/6I33.pdb (kept beside it as 6I33_rcsb.pdb; the
# order of the ATOM records and the numbering/chain labels of the HETATM records
# differ, the atoms do not). HETATM: two PLP (pyridoxal phosphate, 30 atoms in all,
# bound to Lys754 of each chain), 36 EDO atoms (ethylene glycol of the crystallisation
# liquor, not in the sample buffer but in the file CRYSOL read: kept as ligands), 4 BCT
# atoms (bicarbonate) and 165 waters (dropped by the loader). The deposited fit header
# reads "6I33.pdb  Dro:0.055  Ra:1.400  RGE:38.92  RGT:37.45  Vol:258145.  Chi^2: 3.155".
# The fit file has no σ column; recomputed with the σ of the .dat at the same q (837
# matched rows with an experimental value) the χ² is 3.144, so the label is χ² (not χ)
# and the depositor's χ² is 3.155 (SASBDB chi_square_value: the same). The file starts
# with rows at q = 0 to 0.0188 Å⁻¹ that carry a constant, meaningless "experimental"
# column; they are dropped below (the overlay needs q > 0 only).
#
# Ligands: PLP (C8 H10 N O6 P), EDO and BCT are components of a known composition in
# `components.tsv`, so the loader keeps them (`ligandSelector`, `KEEP_LIGANDS`, owner
# decision 2026-11-11); they carry no hydrogens (pdb2pqr places none on ligands).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB buffer pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12523 eV, SASBDB wavelength 0.099 nm
const TEMPERATURE_C = 20.0                    # SASBDB cell temperature (storage 20 °C)

# Buffer as deposited (SASBDB buffer name and experiment description): "10 mM TRIS pH 7.5,
# 100 mM NaCl, 1 mM DTT"; the measured macromolecule is deliberately NOT a solute (see
# BulkElectronDensity.Solute).
#
# Counter-ion: setting the pH adds a titrant that the deposited recipe does not list.
# Assumed: 10 mM Tris titrated with HCl -> Cl⁻ = C·0.8537 (pK(22 °C) = 8.157; Tris pK
# 8.072 at 25 °C, ΔH 47.45 kJ/mol, Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref.
# Data 31, 231, DOI 10.1063/1.1416902, quoted from the SASDAN8 script and not re-checked).
# The pH is taken as set at room temperature (22 ± 3 °C), Davies-corrected at I ≈ 0.109 M.
# σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C, as in SASDAN8.
# Only the counter-ion is modelled; the volume change of the buffer's own (de)protonation
# is not. Titrant: not stated; HCl for amine bases.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "tris"),                # 10 mM Tris, ±2%
    NonBiological(0.1, 0.001, "sodium chloride"),       # 100 mM NaCl, ±1%
    NonBiological(0.001, 0.00002, "dtt"),               # 1 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.008537, 0.000429, "chloride"),
]
# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "acid setting pH 7.5 not stated: HCl assumed for Tris (modelled)",
    "no publication: the buffer is the SASBDB field, no paper consulted",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDEL7: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS


# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0076-0.4934 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.425 Å⁻¹ was used before, but the 146 points above
# 0.425 Å⁻¹ (σ > 0) have a median I/σ of 0.80 and 20 % of them have I ≤ 0, so the data
# above it are not demonstrably unusable (median I/σ 0.80 ≥ 0.5; I ≤ 0 share 20 % < 25 %;
# median I/σ 1.10 ≥ 1 in the lowest-q quarter (up to 0.44 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens (heavy atoms of a crystal structure): pdb2pqr/PROPKA
# place them at PH on the protein; the PLP, EDO and BCT ligands stay heavy-atom only.
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

# Builds the Seed that `runSasdel7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdel7` below is the whole story (build the seed, then sample it).
function seedSasdel7(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdel7(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdel7(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdel7()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1) and has THREE columns: q (Å⁻¹), I_exp, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 3]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 3.155",
    runLog = true,
)

# `@__DIR__` (this SASDEL7/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
