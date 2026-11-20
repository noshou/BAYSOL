# New fitting-test entries, slice F (wired 2026-11-18, NOT RUN)

25 entries wired: 15 nucleic-acid (6 DNA G-quadruplex, 9 RNA) and 10 protein (IDs SASDX.. to
SASDZ..). Nothing was run: each script was only parse-checked (`Meta.parseall`), checked for
the 92-column limit and the SPDX line, and every fixture folder was packed with
`bysl fixtures pack <ID>`. Each script is `test/fitting_tests/<ID>/<ID>.jl` (single run, plain
`res` names). Each header says what comes from the paper, what comes from SASBDB only, which
values are flagged defaults, the atom count, the depositor chi2 as listed and as recomputed
from the `.fit`, and which cleaning was applied to the model (a cleaned copy `_clean.pdb`
sits beside the untouched original in the fixture).

Common conventions in every header: the pH of the buffer is taken as set at 22 +- 3 C (the
repository convention, notes/buffer-templates.md section 2); counter-ions are computed with
the buffer templates (Tris and Bis-Tris with HCl -> chloride, HEPES with NaOH -> Na+,
phosphate as two salts). The papers were read for the G-quadruplex entries only (through the
sibling SASDMJ6); for all others the buffer is the SASBDB one and the header says so.

## README rows

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDM36 | c-Myc12 promoter G-quadruplex (DNA) | BPEK K-phosphate pH 7.2/185 mM KCl/1 mM EDTA, SASBDB cell 25 °C (flagged); cleaned model (DG5/DG3 -> DG, K+ style); recomputed 3.494 | CRYSOL 3.407 |
| SASDMD6 | 2LBY G-quadruplex, 19 nt (DNA) | as M36, 22 °C; recomputed 1.930 | CRYSOL 2.049 |
| SASDMF6 | 1XAV G-quadruplex, 22 nt (DNA) | as MD6; recomputed 1.521 | CRYSOL 1.503 |
| SASDMH6 | 2M27 G-quadruplex, 22 nt (DNA) | as MD6; recomputed 1.609 | CRYSOL 1.662 |
| SASDML6 | kRas-8 promoter G-quadruplex (DNA) | as M36 (22 °C); recomputed 9.005 | CRYSOL 8.758 |
| SASDMN6 | cKit-12 promoter G-quadruplex (DNA) | as M36 (22 °C); recomputed 4.126 | CRYSOL 4.065 |
| SASDUS8 | DIS-C RNA | 50 mM K-phosphate pH 7.5/Mg²⁺/NaCl, 20 °C (SASBDB only); FoXS column 3; model is RNAMasonry/AlphaFold3 and SAXS-restrained, so the fit is not independent; heavy-atom model | FoXS 1.225 |
| SASDUT8 | DIS-Gk RNA | as US8 | FoXS 1.134 |
| SASDUU8 | DIS-C/DIS-Gk RNA:RNA complex | as US8 | FoXS 1.106 |
| SASDXD9 | mascRNA (RNA) | HEPES-NaOH/NaCl/10 mM MgCl₂, "150 NaCl" unit assumed mM, 25 °C (SASBDB only); q = 0 nan row dropped by `fitSubset` | CRYSOL 1.252 |
| SASDPG2 | NOX-E36 Spiegelmer (L-RNA, modelled as D-RNA) | 20 mM HEPES pH 7.52, SASBDB cell 5.8 °C (flagged), no salt listed; q in nm⁻¹; depositor χ² matches the .fit's own error column (1.20 against the .dat errors) | CRYSOL 1.007 |
| SASDPJ2 | NOX-A12 Spiegelmer variant 1 (L-RNA as D-RNA) | as PG2 (0.984 against the .dat errors) | CRYSOL 0.968 |
| SASDPK2 | NOX-A12 Spiegelmer variant 2 (L-RNA as D-RNA) | as PG2; depositor χ² NOT reproducible from the .dat (32.1 against the .dat errors) | CRYSOL 1.278 |
| SASDPD3 | ESS2p HIV-1 splice-site regulatory RNA | 20 mM Bis-Tris pH 6.2/20 mM NaCl; T and wavelength unstated (25 °C, 1.033 Å flagged); cleaned model (G5/C3 -> G/C); depositor fit covers 693 of 1257 points (from q = 0.0146 Å⁻¹) | SASBDB fit 1.458 |
| SASDSP8 | apo-D43 RNA device (PD-1) | 10 mM Bis-Tris pH 6.8/100 mM KCl/1 mM MgCl₂, 20 °C, 0.8202 Å (SASBDB only); cryo-EM model with missing residues, hence the large depositor χ² | CRYSOL 69.336 |
| SASDSQ8 | holo-D43 RNA device (PD-1) with the ligand TAC (tetracycline) | as SP8 (owner's SI: 10 mM Bis-Tris pH 6.8/100 mM KCl/1 mM MgCl₂, 20 °C, 0.8202 Å); TAC (53 HETATM atoms) in the model only, not in the buffer; cryo-EM model with missing residues, large depositor χ² | CRYSOL 63.691 |
| SASDXF3 | h-OGA dimer, AlphaFold model (protein) | Tris/NaCl/TCEP, SASBDB only, wavelength "1.34" read as Å (flagged); the .fit does not reproduce its header (5.3 against 0.828), so no reference curve | none (header 0.8276) |
| SASDXH4 | IgE + profilin (protein complex), SREFLEX | 20 mM Tris pH 8.4/50 mM NaCl, 20 °C; q in nm⁻¹; 12882 heavy atoms | SREFLEX 1.073 |
| SASDXK4 | IgE (protein), Chimera model | as XH4; the DAMMIF fit 1 unused; 10971 heavy atoms | CRYSOL 1.673 |
| SASDXA7 | hCS-MDH2 metabolon, 6 chains | Tris/NaCl/EDTA pH 7.5; T and wavelength unstated (25 °C, 1.127 Å flagged); 16107 heavy atoms (+16439 H in the file) | FoXS 0.847 |
| SASDXF8 | LILRB3 + beta antigen C protein, FoXSDock | 20 mM HEPES pH 7.4/140 mM NaCl; T and wavelength unstated (flagged as XA7); 11257 heavy atoms | FoXS 1.268 |
| SASDXC7 | E. histolytica ASF1 complex, AlphaFold, 3 chains | 20 mM Tris pH 7.5/150 mM NaCl/2 mM BME, 20 °C; q in nm⁻¹; wavelength "0.9794" read as Å (flagged) | FoXS 0.976 |
| SASDYV6 | pyruvate kinase monomer, AlphaFold | 20 mM Tris-HCl pH 8.0/300 mM NaCl, 15 °C; monomer model of a protein whose oligomeric state is the paper subject | CRYSOL 2.101 |
| SASDZ78 | vaccinia K4 endonuclease octamer | 20 mM Tris pH 7.5/150 mM NaCl/0.5 mM TCEP, 20 °C; 27005 heavy atoms; the depositor χ² is tiny because the deposited errors exceed the intensities | CRYSOL 0.026 |
| SASDZD6 | transducin-bound PDE6 (7JSN), six chains plus GTP/35G/VDN/Zn/Mg | 25 mM Tris pH 8.0/100 mM NaCl/2 mM MgCl₂/2 % glycerol (v/v assumed), 4 °C; 19438 heavy atoms; FoXS column 3; no publication listed | FoXS 5.271 |
| SASDX89 | Arabidopsis AMY3 catalytic domain, AlphaFold | 100 mM K-phosphate pH 7.4, 10 °C; the model is mmCIF (fixture is `.cif`) | FoXS 0.616 |

## Very large structures (run-time planning)

All atom counts are heavy atoms of the model as wired (the deposited hydrogens are replaced).

- SASDZ78: 27005 (octamer, 321 points)
- SASDZD6: 19438 (six chains, ligands; the largest for the ligand protonation check)
- SASDXA7: 16107 (+16439 H in the file; pdb2pqr still rebuilds all hydrogens)
- SASDXH4: 12882
- SASDXF3: 11950
- SASDXF8: 11257
- SASDXK4: 10971

None passes 40000. The nucleic-acid entries are all below 2700 heavy atoms (SASDSP8 the
largest, 2652).

## Open points

- Everything is unrun: the first run of each entry needs a look at R̂, ESS and the divergent
  share (the gates of the strict-gate ladder).
- SASDZD6: the ligands GTP, 35G and VDN and the ions are in the component table, but their
  protonation by pdb2pqr/the hydrogenator is unchecked; if the hydrogenator refuses one, drop
  the ligand records in a cleaned copy.
- SASDM36: the SASBDB cell temperature is 25 °C, the sibling G4 entries use 22 °C
  (kept as SASBDB gives it).
- SASDPG2, SASDPJ2, SASDPK2: no publication, no salt listed, T 5.8 °C; SASDPK2's depositor
  χ² is not reproducible against the `.dat` errors.
- SASDUS8, SASDUT8, SASDUU8: the models were built with SAXS restraints, so the depositor
  FoXS χ² flatters them. The Structure 2025 paper (DOI 10.1016/j.str.2025.01.017) was not
  read; the buffer is the SASBDB one.
- SASDXF3's `.fit` header (0.828) does not match its own columns; no reference curve was used.
- Wavelengths of SASDXF3 ("1.34") and SASDXC7 ("0.9794") are numbers without unit in SASBDB,
  read as Å; ALS entries SASDXA7 and SASDXF8 carry no temperature or wavelength (25 °C and
  1.127 Å, flagged in the header).
- The G4 entries use the SASDMJ6 buffer reading (phosphate 8 mM from SASBDB, species computed
  at pH 7.2 with K⁺ as the cation).

## AMBIGUOUS (needs owner)

Each item: the question, and the default I would take if you say "go".

1. SASDSQ8 (holo-D43 RNA with the TAC ligand, same paper as SASDSP8): the ligand
   concentration in the SAXS sample is not stated by SASBDB. Question: what TAC
   concentration (and is the ligand to be modelled in the structure and in the buffer)?
   Default: wire it like SASDSP8 with TAC in the model and not in the buffer solutes (the
   component table lists TAC as "other"); a hydrogenator check of TAC is still needed.
2. SASDAH5: the paper says bicine, SASBDB says Tris (sources conflict). Question: which?
   Default: the paper (bicine; check that a bicine template exists, otherwise Tris).
3. SASDAP8: SASBDB says "Tris" only, no concentration, and the model residue names are
   GUA/CYT. Question: what Tris concentration? Default: 20 mM and rename GUA -> DG, CYT -> DC
   in a cleaned copy.
   (SASDRY7 was dropped by the owner, 2026-11-18: not wired.)
5. SASDXH2 (and SASDXJ2, same buffer): SASBDB's buffer text ends in a trailing comma after
   "0.01 mM GDP," (25 mM Tris-HCl, 150 mM NaCl, 6 mM beta-ME, 20 % glycerol, 0.01 mM GDP),
   so a component may be missing, and the glycerol is not marked v/v or w/v. Question: the
   full buffer and the glycerol unit? Default: v/v (2.74 M), no extra component.
6. SASDX48 / SASDZW5: SASDX48's model file is a 50-model ensemble of 6VU9 (excluded as
   ensemble); SASDZW5's `.dat` runs to q = 2.099 Å⁻¹, above the 2.0 limit of
   `checkQAngstrom`. Question for ZW5: cut the curve at 2.0 Å⁻¹ before the check, or raise
   the limit? Default: neither, skip.
7. SASDXX4 / SASDXY4: "phosphate-buffered saline" with no composition (AlphaFold models,
   depositor χ² 4.9 and 4.3). Question: PBS composition? Default: 137 mM NaCl, 2.7 mM KCl,
   10 mM Na₂HPO₄, 1.8 mM KH₂PO₄.
8. SASDT65: complex buffer (NH₄OAc, arginine, 4 °C). Question: which values? Default: skip.
9. SASDXC4: SASREF rigid-body model of Pex8 + Pex5, SASBDB `.fit` does not reproduce its
   header (8.8 recomputed against 1.093). Question: wire with the SASBDB χ² and a flag, or
   without a reference curve? Default: no reference curve.

## Skipped (otherwise)

- SASDNJ7: the model file is a 20-model ensemble. SASDRF9: model 1 is a DENSS map, model 2
  the 8FCS complex file with 23 models.
- SASDM56, SASDM66: the models contain inosine (DI), whose component-table base is "-".
- SASDFW6: two models. SASDFP6: residue names all "TD". SASDMH9: SANS (ILL).
- SASDX94, SASDX84: MultiFoXS/OLIGOMER ensemble fits. SASDXZ2, SASDYE2, SASDYC2, SASDXX2,
  SASDXY2, SASDYD2: XPLOR-NIH models of one project (HEPES/NaCl/EDTA/glycerol/more), left for a
  later round.
- SASDX24: depositor χ² 47.8 on a Phenix model (not examined further).
- SASDY97: the model is an mmCIF of the crystal structure 1ED9 with Zn/Mg ions (HETATM
  records, not checked), so it was left out of this batch (buffer and depositor chi2 2.098
  would be wirable). SASDXQ9 (DAMMIF-labelled), SASDXA9 and SASDY36 (BILBOMD): not
  examined. SASDXB2 (500 mM imidazole) and SASDX72/X62 (4 °C, BME): not worked out.
- Candidates whose residue names need renames (SASDH44, SASDH54, SASDP24, SASDPZ3, SASDXV3,
  SASDLS7: CYF/ZN2/UNK/HIE/CY1/HSD/CYT/GUA), the HU-DNA series (SASDF26, SASDFP5, SASDFQ5,
  SASDFS5, SASDFU5, SASDFV5, SASDFW5; 10 °C, Bis-Tris, FoXS chi2 3-15), SASDAB7/SASDAC7
  (MES, 500 mM NaCl, glycerol, BME), SASDFX6/FY6/FZ6: not wired for time; they are
  wirable with the renames the generator already knows.
- SASDJC2, SASDMY4, SASDA88, SASDAV7: chi2 disagreement or odd residues (SASDMY4 has 8 models).

## Counts

- Wired: 25 (15 nucleic-acid, 10 protein).
- AMBIGUOUS (needs owner): 9 items, covering 12 SASBDB entries.
- Otherwise skipped: about 35 entries (list above).

## Resolved ambiguous cases (2026-11-18)

Owner decisions applied; scripts and fixtures (.7z) exist for all of them except RY7 and DJ6 (see below).
Papers: only the open-access ones could be read (EuropePMC); "not retrievable" means the paper is not
open access and was not read, so SASBDB alone is the source.

- SASDXX4, SASDXY4: no publication in SASBDB; standard PBS (137 / 2.7 / 10 / 1.8 mM), pH 7.4, 20 °C.
- SASDXH2, SASDXJ2: the paper's SAXS section has no buffer; SASBDB buffer used; glycerol 20 % read as v/v (owner, 2026-11-18)
  (inferred from the paper's MD box: 525 glycerol molecules in 12 nm = 0.50 M, 4.6 % w/v, not 3.7 % v/v);
  0.01 mM GDP added as "gdp(2-)". Question left: is the SAXS glycerol w/v? (the paper does not say).
- SASDAP8: paper has no SAXS buffer; its annealing buffer (11.1 mM Tris pH 7.6, 55.5 mM NaCl, 5.5 mM MgCl2) is
  used; T = 20 °C (293 K) and 0.9 Å from the paper's Table 3 (SASBDB: no T, 0.93 Å). Cleaned model
  `SASDAP8_fit1_model1_clean.pdb`: GUA/CYT/THY/ADE renamed DG/DC/DT/DA (also THY/ADE; the original is kept).
- SASDSQ8: NOT WIRED. TAC is a HETATM group of 53 atoms in the model, its concentration is in the paper
  (gkaf156), which is not open access and could not be retrieved. Question: the TAC concentration (and what TAC
  is: ligand name, charge) in the SAXS buffer? Also no TAC row exists in the solute table.
- SASDAH5: paper and SASBDB DISAGREE. Paper: 50 mM bicine pH 8.8, 100 mM NaCl, 250 mM KCl, 35 °C. Followed.
  The bicine template and the "bicine" solute exist, nothing is missing. SASBDB says Tris pH 7.5 + DTT.
  The .fit (software not stated; header "ChiExp = 1.50" = sqrt of 2.25) is used as the reference ("depositor").
- SASDRY7: DROPPED (not wired, files untouched; its rows removed from this file and from NA.md).
- SASDT65: buffer from SASBDB (preprint not retrievable): 40 mM NH4OAc, 450 NaCl, 5 CaCl2, 0.02 % NaN3 (w/v,
  3.08 mM), 50 mM arginine (neutral row), pH 5.5, 4 °C; FoXS fit, so no reference and no refChi2.
- SASDXC4: wired without reference curve and refChi2; fit1 model 1 is empty, model 2 is used; preprint not
  retrievable; q cut 0.679 Å⁻¹ by the README rule.
- SASDZW5: q is in Å⁻¹ (the label is right; Guinier Rg 32.6 Å against 30.9 Å of the model; read as nm⁻¹ it
  would be 326 Å), so NO conversion. The form-factor table limit is q = 4π·6 = 75.40 Å⁻¹ (753.98 nm⁻¹), far above
  the data. BUT the curve runs to 2.099 Å⁻¹ and `checkQAngstrom` (shared common.jl, `Q_SANITY_RANGE` 0.05 to 2.0)
  rejects it, so the script cuts at 2.0 Å⁻¹ (33 points). Question: allow a larger sanity range in common.jl?
- Parse-checked only (Meta.parseall), nothing was run.

## Round 3 (owner decisions, 2026-11-18)

- SASDZW5: the cut is gone. `Q_SANITY_RANGE` of `common.jl` (the only place of the 2.0
  limit; nothing in `src/` and no unit test pinned it) is now `(0.05, 4π·WK_S_MAX)` =
  75.40 Å⁻¹, the Waasmaier-Kirfel table limit (`BAYSOL.Scattering.WK_S_MAX` = 6.0, s = q/4π),
  imported, not retyped; `checkQAngstrom` got `# Returns`/`# Exceptions`. SASDZW5.jl fits the
  whole curve (no `Q_MAX_FIT`, header updated). Side effect: the guard no longer
  catches a curve left in nm⁻¹ unless its maximum exceeds 75 (a typical 5 nm⁻¹ curve
  passes), so the nm⁻¹ conversion of each script is now unchecked there.
- SASDSQ8: WIRED (`SASDSQ8/SASDSQ8.jl`, a copy of SASDSP8's script, fixture
  `SASDSQ8.7z` built from the SASBDB files with `bysl fixtures pack`; the plain folder
  `test/fixtures/experiments/SASDSQ8/` was left, delete it if unwanted). Buffer and
  conditions are the owner's SI; TAC is not a solute. `bis-tris` exists as template and
  solute (SP8 uses it). TAC is in `components.tsv` (C22 H24 N2 O8, type "other",
  non-polymer), so the hydrogenator treats it as a ligand: pdb2pqr's output keeps it or
  `_restoreLigandResidues!` puts its heavy atoms back; the deposited 21 H of the 53 atoms
  (the formula has 24) are not restored (about 21 electrons of roughly 2 x 10^4,
  negligible). Not verified by a run: whether pdb2pqr keeps or drops TAC. Depositor χ²
  63.691 (header). Parse-checked only; not run.
- SASDP29: DROPPED. `SASDP29/SASDP29.jl` renamed to `SASDP29.jl.dropped`, the `.7z` kept,
  its rows removed from this file and from `new-entries-NA.md`.
- SASDXH2/SASDXJ2: glycerol switched to v/v on 2026-11-18 (owner: glycerol is a liquid): 20 % = 2.739 M.
- No other entry dropped (G44, T65, XC4, DDJ6 stay, see the reply for what each adds).
