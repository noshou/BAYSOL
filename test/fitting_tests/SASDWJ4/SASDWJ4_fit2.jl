# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWJ4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWJ4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWJ4_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWJ4_fit2.fit")

# The .dat has 3 lines of header and 53 lines of processing history at the end, and the
# latter break `readdlm` (SASDVV4's has quote characters), so `_readCurve` (common.jl,
# numeric rows only) reads it: 2630 points.
qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 2630

# qvals are in nm⁻¹ (0.0224-7.33); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDWJ4 (sasbdb.org/data/SASDWJ4/); paper: Stafflinger
# et al. 2025, Nucleic Acids Res., "Crystal structure of the class V GTP-binding RNA
# aptamer bound to its ligand: GTP recognition by a topologically complex intermolecular
# G-quadruplex", DOI 10.1093/nar/gkaf1315 (PMID 41422825). The paper's own methods text
# was not consulted.
#
#     50 mM Bis-Tris, 50 mM KCl, 2 mM MgCl2, pH 6.5
#
# Class V GTP aptamer (68 nt, 22.1 kDa) with GTP, 6.0 mg/mL, one concentration, 20 °C
# (cell and storage), EMBL P12 (PETRA III), wavelength 0.123985 nm => energy =
# hc/λ ≈ 10 keV (hc = 12398.42 eV·Å). The model (SASDWJ4_fit2_model1.pdb) is the crystal
# structure: one RNA chain with two bound GTP, K⁺ and Mn²⁺ ions as HETATM records.
# The GTP concentration of the sample is not stated in the SASBDB record, and GTP is not in
# the bundled solute tables, so the free ligand is not listed as a solute (it is part of the
# model). The macromolecule is deliberately NOT listed either.

# BUFFER OMISSIONS (not modelled; the recipe given by the depositors is incomplete or a
# component is not in the tables):
#   - free GTP: concentration unknown (GTP is in the tables now, tetrasodium salt, measured
#     290 ± 22 cm³/mol); est. +0.026 % per mM

const PH, σ_PH = 6.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.23985   # ≈ 10000 eV, from the stated 0.123985 nm
const TEMPERATURE_C = 20.0                       # 20 °C, SASBDB

# Buffer components. Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# Assumed: 50 mM Bis-Tris titrated with HCl -> Cl⁻ = C·0.578 (Bis-Tris pK 6.484 at 25 °C,
# ΔH 28.4 kJ/mol, ΔCp taken as 0; pK(22 °C) = 6.535). The pH is taken as set at room
# temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the measurement
# temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem. Ref. Data 31,
# 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected at I ≈ 0.085 M.
# σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C. Only the
# counter-ion is modelled; the volume change of the buffer's own (de)protonation is not.
# Titrant: not stated; HCl for amine bases (Tris, imidazole, histidine, Bis-Tris), NaOH
# for Good's buffers.
# (The Bis-Tris pK and ΔH are the Goldberg 2002 values as quoted by a secondary calculator
# page, not read from the paper itself.)
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.050, 0.001, "bis-tris"),              # 50 mM Bis-Tris, ±2%
    NonBiological(0.050, 0.0005, "potassium chloride"),   # 50 mM KCl, ±1%
    NonBiological(0.002, 0.00002, "magnesium chloride"),  # 2 mM MgCl2, ±1%
    # Cl⁻ counter-ion from HCl titration of Bis-Tris (see note above)
    NonBiological(0.028895, 0.003359, "chloride"),
]

# The omissions listed under "BUFFER OMISSIONS" above, one line each. Every run of
# this script, and every developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "free GTP: concentration unknown; est. +0.026 % per mM (tetrasodium salt)",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDWJ4: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole curve is fitted. The .dat reaches 0.73 Å⁻¹ but the depositor's
# Pepsi-SAXS fit stops at 0.5 Å⁻¹, so the refChi2 is not like for like. The tail is
# signal (median I/σ 13 above 0.3 Å⁻¹; only 2 of the 2630 points have I ≤ 0).

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the deposited model already carries hydrogens (745 H, ANISOU
# records too); pdb2pqr rebuilds them at PH, as for SASDWZ9.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut). (`seedModel`
bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(>(0), σ_exp)
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdwj4Fit2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdwj4Fit2` below is the whole story (build the seed, then sample it).
function seedSasdwj4Fit2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwj4Fit2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdwj4Fit2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwj4Fit2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
pos = iFit .> 0   # the points with a positive intensity, as the plots show
ref = readdlm(_FIT_PATH; skipstart = 1)
qRef, iRef = _rescaleFit(
    (Float64.(ref[:, 1]), Float64.(ref[:, 4])), qFit[pos], iFit[pos],
)
reference = BAYSOL.Reference("Pepsi-SAXS fit2 (rescaled)", qRef, iRef)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit2", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "Pepsi-SAXS 10.774",
    runLog = true,
)

# `@__DIR__` (this SASDWJ4/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
