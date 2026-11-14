# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDRX8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRX8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRX8: heterodimeric complex of the Archaeoglobus fulgidus Argonaute AfAgo
# (AF_1318, MID and PIWI domains, 50.856 kDa) and AfAgo-N (N-L1-L2 domains, 30.534 kDa;
# both constructs carry an N-terminal polyhistidine tag) with a 5'-phosphorylated,
# self-complementary 14 bp DNA oligoduplex (MZ1288, ATTGTGGCCACAAT, 8.668 kDa, two
# strands). A protein-DNA complex.
#
# Paper: Manakova E, Golovinas E, Pocevičiūtė R, Sasnauskas G, Silanskas A, Rutkauskas
# D, Jankunec M, Zagorskaitė E, Jurgelaitis E, Grybauskas A, Venclovas Č, Zaremba M,
# "The missing part: the Archaeoglobus fulgidus Argonaute forms a functional heterodimer
# with an N-L1-L2 domain protein", Nucleic Acids Res (2024), DOI 10.1093/nar/gkad1241
# (PMID 38197228). The paper's text was not consulted; every condition below is from the
# SASBDB entry (https://www.sasbdb.org/data/SASDRX8/ and its REST summary).
#
# Instrument: PETRA III, EMBL P12 (X-ray synchrotron), Pilatus 6M, wavelength 0.124 nm =
# 1.24 Å => energy = hc/λ ≈ 10000 eV (hc = 12398.42 eV·Å). SEC-SAS, measured 2019-07-06,
# 33 sample frames (0.995 s each), 0.5 mL/min flow, sample and cell temperature 20.0 °C.
# Peak concentration stated: 14.0 (the unit is not stated in the entry). The curve is the
# deposited SEC-SAS curve (s 0.100-7.318 nm⁻¹; 2605 points, 6 with I ≤ 0).
#
# Buffer as deposited: "20 mM TrisHCl pH 7.5, 200 mM NaCl, 5 mM MgCl2, 1 mM DTT".
#
# The two atomic models (both deposited as "Custom in-house" models cut from the crystal
# structure PDB 8OK9 (CRYST1 P 21 21 21); the entry notes
# that SASBDB could not accept the PDB id), read from the PDB files themselves:
#
#   fit1 (SASDRX8_fit1_model1.pdb; CRYSOL 2.8.4 chi² 4.263, model "apoTK", model mass
#   75.58 kDa; entry text: "Fit to the PDB ID 8OK9 with deleted DNA strands"): protein
#   only, 5340 atoms without hydrogens. Chain A, 425 residues (numbered 1-427, two of
#   them absent; AfAgo, no His tag residues); chain C, 227 residues (numbered 19-245;
#   AfAgo-N). There is NO DNA, no ion and no water in this model, so fit1 tests only the
#   protein part of the complex. The .fit header reads Dro 0.018, Ra 1.400.
#
#   fit2 (SASDRX8_fit2_model1.pdb; CRYSOL 2.8.4 chi² 8.663, model "Af-gs851", model mass
#   83.08 kDa; entry text: "Fit to the PDB ID 8OK9 with deleted target DNA strand (S),
#   that in the crystal structure does not form a duplex with the guide strand"): the
#   same chains A and C plus DNA chain R (10 nucleotides, 1-10: 6 A, 1 T, 2 C, 1 G) and
#   DNA chain S (15 nucleotides, 1-15: 4 A, 2 T, 5 C, 4 G), one Mg²⁺ (chain M) and 75
#   waters (chain D). The two DNA strands are therefore not the 14 bp duplex of the
#   sample: the model holds the 10 + 15 nucleotides of the crystal (the entry's wording
#   about which strand was deleted is not reconciled here with the file, which holds
#   both chains R and S). The DNA is written with legacy names (single-letter residues
#   A T C G, primed atoms O5* C5*, and the extra 5'-phosphate oxygen `O3P` on R1).
#   Waters and the ion are dropped by the pipeline, the DNA is repaired in the copy
#   pdb2pqr sees (see "Hydrogenation routes" in test/fitting_tests/README.md). The .fit
#   header reads Dro 0.072, Ra 1.800.
#
# Neither model carries the His-tag residues, so the modelled mass (75.6 and 83.1 kDa)
# is lower than the 50.9 + 30.5 (+ 8.7 per duplex) kDa of the constructs. The GASBOR
# dummy-atom fit3 (chi² 1.22) has no atomic model and is not run.
#
# Curve units: the SASBDB .dat is in nm⁻¹ and is converted to Å⁻¹ (÷10). The .dat has
# three header lines and a block of beam-processing lines after the data; `_readCurve`
# keeps only the numeric rows. The depositor .fit files are CRYSOL files (q in Å⁻¹; q,
# I_exp, σ, I_fit) on the data's scale, so the fitted intensity is column 4, unscaled.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 10000 eV, from the stated 0.124 nm
const TEMPERATURE_C = 20.0                    # SASBDB cell temperature

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the
# deposited recipe does not list. "TrisHCl" is modelled as Tris plus HCl at the
# molarity derived from the pK, no Tris-HCl salt is added. Assumed: 20 mM Tris titrated
# with HCl -> Cl⁻ = C·0.8594 = 17.19 mM (pK(22 °C) = 8.156). The pH is taken as set at
# room temperature (22 ± 3 °C), which fixes the counter-ion amount whatever the
# measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J. Phys. Chem.
# Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-corrected
# at I ≈ 0.232 M (200 mM NaCl, 5 mM MgCl2 = 15 mM, and the protonated Tris with its
# chloride). σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, and ±2 % on C;
# the same calculation reproduces the Cl⁻ amounts of SASDJ72 and SASDQ69. Only the
# counter-ion is modelled; the volume change of the buffer's own (de)protonation is not.
# Titrant: not stated; HCl for amine bases (Tris), NaOH for Good's buffers. DTT is taken
# as the neutral molecule. Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.020, 0.0004, "tris"),                 # 20 mM Tris, ±2%
    NonBiological(0.200, 0.002, "sodium chloride"),       # 200 mM NaCl, ±1%
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM MgCl2, ±2%
    NonBiological(0.001, 0.00002, "dtt"),                 # 1 mM DTT, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.017187, 0.000844, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The whole .dat is fitted (q 0.0100-0.7318 Å⁻¹); the depositor's fits end at 0.3002 Å⁻¹,
# so refChi2 is not like for like.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited models; runs Pdb2pqr with PROPKA at PH (fit1 is protein
# only; fit2 is a protein + DNA file, which keeps PARSE and PROPKA)
const ADD_HYDROGENS = true

# One run per atomic model with a deposited CRYSOL fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
        tag = "fit1",
        refChi2 = "CRYSOL 4.263",
        pdb = "SASDRX8_fit1_model1.pdb",
        fit = "SASDRX8_fit1.fit",
        fitScale = 1.0,
        fitCol = 4,
        rescale = false,
        software = "CRYSOL fit1",
    ),   # protein only (chains A, C); deposited χ² = 4.263
    (
        tag = "fit2",
        refChi2 = "CRYSOL 8.663",
        pdb = "SASDRX8_fit2_model1.pdb",
        fit = "SASDRX8_fit2.fit",
        fitScale = 1.0,
        fitCol = 4,
        rescale = false,
        software = "CRYSOL fit2",
    ),   # protein + DNA chains R and S; deposited χ² = 8.663
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdrx8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdrx8` below is the whole story (build the seed, then sample it).
function seedSasdrx8(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdrx8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdrx8(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdrx8(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

    # run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
    fitCurve = try
        fc = _readFit(joinpath(_FIXTURE_DIR, run.fit), run.fitScale, run.fitCol)
        fc !== nothing && run.rescale ? _rescaleFit(fc, qFit, iFit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    references = BAYSOL.Reference[]
    if fitCurve !== nothing
        # the CRYSOL files start at q = 0, which a log q axis cannot show
        pos = findall(>(0), fitCurve[1])
        push!(
            references,
            BAYSOL.Reference(
                run.software * (run.rescale ? " (rescaled)" : ""),
                fitCurve[1][pos], fitCurve[2][pos],
            ),
        )
    end
    BAYSOL.results(
        result, (qFit, iFit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        formFactorLog = formFactorLog, nAtoms = nAtoms,
        refChi2 = run.refChi2,
        runLog = true,
    )

    # `@__DIR__` (this SASDRX8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
