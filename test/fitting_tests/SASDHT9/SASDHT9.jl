# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDHT9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDHT9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDHT9: the dimeric NanR-DNA hetero-complex from Escherichia coli. NanR (HTH-type
# transcriptional repressor NanR, GntR family, UniProt P0A8W0, 263 residues, 29.524 kDa per
# monomer, deposited as a dimer) bound to a 17 bp DNA with two GGTATA repeats (SASDHT9
# sequences TGGTATAACAGGTATAA / TTATACCTGTTATACCA, 10.519 kDa). The entry's SASBDB
# fields read "number_molecules 2" for the DNA as well, but the experiment description
# mixes NanR and DNA 2:1 (340 µM NanR, 170 µM DNA), i.e. one duplex per NanR dimer, and
# the deposited model holds exactly that (see below). This is a PROTEIN-DNA entry.
#
# Paper: Horne C, Venugopal H, Panjikar S, Henrickson A, Brookes E, North R, Murphy J,
# Friemann R, Griffin M, Ramm G, Demeler B, Dobson R, "Mechanism of NanR gene repression
# and allosteric induction of bacterial sialic acid metabolism", bioRxiv (2020), DOI
# 10.1101/2020.04.22.056440 (the DOI SASBDB lists). Not bundled; the conditions below are
# SASBDB's entry metadata (https://www.sasbdb.org/data/SASDHT9/): "NanR-DNA hetero-complex
# was prepared by incubating NanR (340 µM) and DNA with two GGTATA repeats (170 µM) on ice
# for 30 min prior to injection. Samples were prepared in 20 mM Tris-Hcl (pH 8.0), 150 mM
# NaCl, 0.1 % (w/v) sodium azide, pH 8 and were collected using co-flow size exclusion
# chromatography SAXS (SEC-SAXS) on the SAXS/WAXS beam line at the Australian Synchrotron
# (Melbourne, Australia) using a Pilatus 1M detector at a sample-detector distance of
# 1.6 m and at a wavelength of λ = 0.10332 nm ... Co-flow SEC-SAXS was performed at 12 °C"
# (Superdex S200 Increase 5/150 GL, 0.45 mL/min, 70 µL injected, 1 s frames). The measured
# complex is deliberately NOT a solute (see BulkElectronDensity.Solute), so the 340 / 170 µM
# stock concentrations do not enter the buffer: the sample was diluted on the column.
#
# Model (SASDHT9_fit1_model1.pdb, SASBDB "Custom in-house", atomic, 56.7 kDa; the REMARK
# records are those of a PHENIX real-space refinement), as read from the file: chain A =
# DNA strand 1, 13 nt numbered 10-22 (T A T A A C A G G T A T A), chain B = strand 2, 13 nt
# numbered 50-62 (A T A C C T G T T A T A C), the complement, i.e. a 13 bp duplex (the
# central part of the 17 bp sample DNA, 5' phosphate on the first residue of each strand);
# chains C and D = the two NanR monomers, 218 residues each numbered 32-249 (no gaps; they
# are UniProt P0A8W0 residues 31-248 exactly, 0 mismatches, so the file numbering is the
# UniProt numbering plus one). The N-terminal 30 and the C-terminal 15 residues of the 263
# are not in the model. So the file holds NanR x2 + ONE 13 bp duplex = the sample's 2:1
# stoichiometry, minus the disordered termini and 4 bp of DNA. 7680 atoms, 3692 of them
# hydrogens (all four chains carry hydrogens); no waters, ions, ligands, altlocs or
# HETATM records; the DNA residues are named T, A, C, G (no D prefix; the one-letter names
# of the PDB's old DNA naming; the protein is standard). The DNA atoms have occupancy 0.00
# with B 299.76 (protein: occupancy 1.00), which the pipeline ignores: it never reads
# occupancy except in the dummy-atom check (zero B AND zero occupancy together).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (2 header lines, then q, I, σ; q 0.0121-0.300,
# 395 points; the entry's s_min 0.121 / s_max 3.0 are the same numbers in nm⁻¹; Rg 3.3 nm =
# 33 Å). It is a co-flow SEC-SAXS curve on an arbitrary intensity scale and 25 of its 395
# points have I ≤ 0, which `seedModel` bins away. The comparison curve is the depositor's
# CRYSOL file SASDHT9_fit1.fit (header "Dro:0.075 Ra:1.400 RGT:31.02 Vol: 71722. Chi^2:
# 2.295"; rows q, 0, 0, I_fit for q < 0.0121 and then q, I_exp, σ, I_fit), the fitted
# intensity is column 4, already on the data's scale, so no rescaling is needed.

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.012-0.30, is checked below).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0332   # ≈ 12000 eV, from λ = 0.10332 nm = 1.0332 Å
const TEMPERATURE_C = 12.0   # SASBDB cell temperature (co-flow SEC-SAXS at 12 °C)

# Buffer components as deposited: "20 mM Tris, 150 mM NaCl, 0.1 % (w/v) sodium azide", pH 8
# (the experiment description writes "Tris-Hcl"). The measured NanR-DNA complex is
# deliberately NOT listed: ρₑ is the buffer's electron density. Every solute is a row of
# the bundled tables (nonbio_lookup.json / nonbiological.tsv): "sodium chloride", "tris",
# "sodium azide" (NaN3, 65.0066 g/mol) and the ion "chloride".
#
# Sodium azide: 0.1 % w/v = 1 g/L / 65.0066 g/mol = 0.015382 M (same conversion as
# SASDCQ2.jl's 0.01538224888 M); ±2 % as for the other additives.
#
# Counter-ion: "Tris-HCl" at pH 8.0 means Tris titrated with HCl, so Cl⁻ comes along with
# the protonated Tris and is not in the recipe. Assumed: 20 mM Tris titrated with HCl,
# Cl⁻ = C·0.655 (pK(22 °C) = 8.156, the protonated fraction at pH 8.0). Same method as
# SASDMJ9.jl (pH set at 22 ± 3 °C; pK(T) from Goldberg, Kishore & Lennen 2002, J. Phys.
# Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902; Davies correction at the ionic
# strength; σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C).
# ASSUMPTION: that calculation was NOT redone for this recipe (I ≈ 0.178 M with the
# azide's Na⁺). The value 0.013115 is interpolated linearly in I between the two
# 20 mM Tris results of SASDVU5.jl (0.013096 at I ≈ 0.163 M) and SASDQE9.jl (0.013160 at
# I ≈ 0.213 M), which differ by 0.5 %, well inside the σ of 0.00146 (taken from them).
# Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not. Titrant not stated; HCl for amine bases.
const SOLUTES = Solute[
    NonBiological(0.150, 0.0015, "sodium chloride"),   # 150 mM NaCl, ±1%
    NonBiological(0.020, 0.0004, "tris"),              # 20 mM Tris-HCl, ±2%
    NonBiological(0.01538224888, 0.0003076449777, "sodium azide"),   # 0.1 % w/v = 15.38 mM
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.013115, 0.001460, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model's 3692 hydrogens (protein and DNA, from the PHENIX refinement) are rebuilt by
# pdb2pqr with PROPKA at PH (protein + DNA mixed file, so the protein is protonated at
# pH 8.0).
const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 2.295",
    pdb = "SASDHT9_fit1_model1.pdb",
    fit = "SASDHT9_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 2.295 (CRYSOL, Dro 0.075, Ra 1.400)
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

# Builds the Seed that `runSasdht9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdht9` below is the whole story (build the seed, then sample it).
function seedSasdht9(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdht9(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdht9(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdht9(run)

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
        push!(
            references,
            BAYSOL.Reference(
                run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""),
                fitCurve...,
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

    # `@__DIR__` (this SASDHT9/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
