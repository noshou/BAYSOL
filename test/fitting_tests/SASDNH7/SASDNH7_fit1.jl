# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDNH7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNH7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNH7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNH7_fit1.fit")

# The .dat has 2 lines of header (the first one empty) and 87 lines of processing history
# at the end (merge scales, parent frames), which break `readdlm`, so `_read_curve`
# (common.jl, numeric rows only) reads it: 1374 points.
qvals, I_exp, σ_exp = _read_curve(_DATA_PATH)
@assert length(qvals) == 1374

# qvals are already in Å⁻¹ (range 0.0059-0.4770, SASBDB "1/A", BioCAT SEC-SAXS); no unit
# conversion is applied, `check_q_angstrom` asserts it.
check_q_angstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDNH7 (sasbdb.org/data/SASDNH7/); paper: Montaño SP
# et al. 2022, Nucleic Acids Res., "Structural basis for topological regulation of Tn3
# resolvase", DOI 10.1093/nar/gkac733 (PMID 36100255). The paper's methods text was not
# consulted (the PDF is not bundled).
#
#     25 mM Tris, 150 mM NaCl, 10 mM MgCl2, 1% glycerol, pH 7.5
#
# Tn3 resolvase dimer (2 x 21.5 kDa) bound to the 52 bp site II DNA (32.1 kDa), 75.2 kDa
# in total; in-line SEC-SAXS (Superdex 200 10/300) of a 3 mg/mL injection, cell at
# 22 °C (storage 4 °C), BioCAT 18ID (APS), Pilatus 100K, wavelength 0.103 nm = 1.03 Å =>
# energy = hc/λ ≈ 12.04 keV (hc = 12398.42 eV·Å). The measured complex is deliberately
# NOT a solute (see BulkElectronDensity.Solute).
#
# Model: SASDNH7_fit1_model1.pdb, chains C and D (resolvase, 1415 and 1433 atoms) and Y
# and Z (the two DNA strands, 1065 and 1067 atoms); 4980 atoms, no hydrogens, no HETATM.
#
# Comparison curve: the entry's API link for the fit file returns 404, so
# `SASDNH7_fit1.fit` was fetched from https://www.sasbdb.org/media/fitting_files/
# SASDNH7_fit1.fit. It is a FoXS profile ("# SAXS profile" header, 3 comment lines;
# columns q, I_exp, error, model_intensity; q 0.0083-0.1997 Å⁻¹, 559 points) whose
# I_exp column equals this .dat to 1e-7 and whose own χ² (16.465, with FoXS offset
# 0.264) is the depositor's value in the entry; the model column is already scaled to
# the data (c = 4.0e-7, offset subtracted), so it is overlaid as it is.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # ≈ 12037 eV, from the stated 0.103 nm
const TEMPERATURE_C = 22.0                    # 22 °C, SASBDB (cell)

# Buffer components (the measured complex is deliberately NOT listed). Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# Assumed: 25 mM Tris titrated with HCl -> Cl⁻ = C·0.8586 (pK(22 °C) = 8.156). The pH is
# taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion amount
# whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-
# corrected at I ≈ 0.201 M (10 mM MgCl2 included). σ combines σ_PH, ±3 °C, ±0.02 pK, 30 %
# of the Davies shift, and ±2 % on C. Only the counter-ion is modelled; the volume change
# of the buffer's own (de)protonation is not. Titrant: not stated; HCl for amine bases
# (Tris, imidazole, histidine, Bis-Tris), NaOH for Good's buffers.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),                 # 25 mM Tris, ±2%
    NonBiological(0.150, 0.0015, "sodium chloride"),      # 150 mM NaCl, ±1%
    NonBiological(0.010, 0.0001, "magnesium chloride"),   # 10 mM MgCl2, ±1%
    # 1 % v/v glycerol -> molarity via pure-glycerol density (1.2613 g/mL) and MW
    # (92.094 g/mol): 1 mL glycerol/100 mL soln * 1.2613 g/mL / 92.094 g/mol * 1000
    # ≈ 0.1370 M. 5 % relative uncertainty as for the v/v glycerol of SASDJ72.jl.
    NonBiological(0.1370, 0.00685, "glycerol"),
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.021466, 0.001067, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The .dat runs to 0.48 Å⁻¹ and the depositor's fit to 0.20 Å⁻¹; the 75 kDa SEC-SAXS
# curve is at the noise floor early (437 of its 1374 points are ≤ 0), so the fit is cut
# at 0.15 Å⁻¹.
const Q_MAX_FIT = 0.15

# The spherical-harmonic band limit lMax is not set here: `seed_model` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(q_max * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE; PROPKA for the protein
# chains, none for the DNA)
const ADD_HYDROGENS = true

"""
    fit_subset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`. (`seed_model`
bins the curve and drops the bins with non-positive intensity.)
"""
function fit_subset()
    keep = findall(≤(Q_MAX_FIT), qvals)
    return qvals[keep], I_exp[keep], σ_exp[keep]
end

# Builds the Seed that `run_sasdnh7_fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `run_sasdnh7_fit1` below is the whole story (build the seed, then sample it).
function seed_sasdnh7_fit1(; seed::Integer = SAMPLER_SEED)
    q_fit, I_fit, σ_fit = fit_subset()

    Random.seed!(seed)
    s = BAYSOL.seed_model(
        LocalPathSource(_PDB_PATH), ENERGY_EV, q_fit, I_fit, σ_fit, PH, σ_PH, SOLUTES;
        add_hydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function run_sasdnh7_fit1(;
    n_samples::Int = N_SAMPLES,
    n_adapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seed_sasdnh7_fit1(; seed)
    res = BAYSOL.run_model(s, n_samples, n_adapt)
    return res, s.fw.form_factor_log, s.fw.n_atoms, data
end

result, form_factor_log, n_atoms, (q_fit, I_fit, σ_fit) = run_sasdnh7_fit1()

fit, divergence_rate, map_result, quantile_result = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `ref_chi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 3)
reference = BAYSOL.Reference(
    "FoXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    q_max = Q_MAX_FIT,
)
BAYSOL.results(
    result, (q_fit, I_fit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    form_factor_log = form_factor_log, n_atoms = n_atoms,
    ref_chi2 = "FoXS 16.465",
    run_log = true,
)

# `@__DIR__` (this SASDNH7/ folder), not the caller's cwd.
BAYSOL.print_summary(result)
