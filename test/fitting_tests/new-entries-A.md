# New entries A (SASDA.. to SASDM..)

Seven protein entries wired 2026-11-18 by agent A, none run yet. Each has a CRYSOL .fit with exactly one structure, a buffer read in the paper (DOI in each script header), no q cut and at most 4734 heavy atoms. Rows follow the Replacement-entries table format.

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDF53 | Btk kinase domain (1K2P; 2087 heavy atoms) in 25 mM Tris, 300 mM NaCl, 1 mM TCEP, 5 % glycerol, pH 7.5, 20 C | Nat. Commun. 2020, DOI 10.1038/s41467-020-16128-5 (buffer read in the paper; it differs from SASBDB: 25 mM Tris/300 mM NaCl vs 20 mM/150 mM; temperature from SASBDB); CRYSOL fit2; the TCEP + glycerol Tris entry, BM29 0.992 A; Tris-HCl counter-ion | CRYSOL 1.275 (header Chi^2 1.275) |
| SASDGD2 | human IBA57 (6QE3; 2348 heavy atoms) in 50 mM Na phosphate, 150 mM NaCl, 5 mM DTT, 3 % glycerol, pH 7.0, 20 C | Sci. Rep. 2019, DOI 10.1038/s41598-019-55313-5 (buffer read in the paper, which adds 3 % v/v glycerol to the SASBDB buffer; temperature from SASBDB); CRYSOL fit1; the phosphate + DTT entry, P12 SEC-SAXS; the model carries hydrogens (re-placed by pdb2pqr) and 245 waters (dropped) | CRYSOL 1.075 (header Chi^2 1.075) |
| SASDJB2 | AgeI restriction endonuclease monomer (2089 heavy atoms) in 10 mM Tris-HCl, 150 mM NaCl, 5 mM CaCl2, pH 7.5, 20 C | NAR 2017, DOI 10.1093/nar/gkw1310 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit2, reference rescaled (the .fit is off the data scale); the Ca2+ Tris entry, P12 0.124 nm; Tris-HCl counter-ion | CRYSOL 0.867 (header Chi^2 0.867) |
| SASDC57 | human dUTPase homotrimer (2826 heavy atoms) in 50 mM HEPES, 300 mM NaCl, 5 mM MgCl2, pH 7.5, 20 C | Sci. Rep. 2018, DOI 10.1038/s41598-018-22145-8 (buffer and the 20 C batch temperature read in the paper; SASBDB gives 10 C); CRYSOL fit2, reference rescaled (the .fit is off the data scale); the Mg2+ HEPES entry, P12; 36 altloc atoms; HEPES-Na counter-ion | CRYSOL 1.059 (header Chi^2 1.059) |
| SASDJG5 | SARS-CoV-2 main protease dimer (6M03; 4734 heavy atoms) in 50 mM Tris-HCl, 1 mM DTT, 1 mM EDTA, pH 7.4, 6 C | Nat. Commun. 2020, DOI 10.1038/s41467-020-19662-4 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit1; the in-house Cu K-alpha source (8051 eV), curve in 1/A; q to 0.60 of a deposited fit to 0.50; Tris-HCl counter-ion | CRYSOL 2.158 (header Chi^2 2.158) |
| SASDGA7 | tbMORNdelta6 dimer (3174 heavy atoms) in 20 mM Tris-HCl, 200 mM NaCl, 2 % (w/v) glycerol, 0.5 mM DTT, pH 8.5, 20 C | PLoS ONE 2020, DOI 10.1371/journal.pone.0242677 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit1; the high-pH (8.5) Tris entry with w/v glycerol, P12; Tris-HCl counter-ion at a low acid fraction | CRYSOL 1.160 (header Chi^2 1.160) |
| SASDKJ4 | SARS-CoV-2 nsp7+nsp8 heterotetramer (4097 heavy atoms) in 50 mM Tris, 100 mM NaCl, 4 mM MgCl2, 4 mM DTT, pH 8.0, 20 C | Sci. Adv. 2021, DOI 10.1126/sciadv.abf1004 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit1; four-chain complex, P12; q to 0.73 of a deposited fit to 0.50; Tris-HCl counter-ion | CRYSOL 1.306 (header Chi^2 1.306) |

## Open points

- Counter-ions (HCl for Tris, NaOH for HEPES), sodium as the phosphate cation, v/v glycerol (F53, GD2) and disodium EDTA (JG5) are assumptions the papers do not settle. The pH is taken as set at 22 °C.
- Paper versus SASBDB buffer conflicts: SASDF53 (paper 25 mM Tris/300 mM NaCl, SASBDB 20 mM/150 mM; paper used), SASDGD2 (paper adds 3 % v/v glycerol, SASBDB omits it; paper used), SASDC57 (paper 20 °C, SASBDB 10 °C; paper used).
- Temperatures not given in the paper text read (SASBDB value used, flagged in the headers): SASDF53, SASDGD2, SASDJB2, SASDJG5 (6 °C, pH carries only ±3 °C), SASDGA7, SASDKJ4.
- Depositor fit q range shorter than the data (refChi2 not like for like): SASDJG5 and SASDKJ4 (fit to 0.50 Å⁻¹, data to 0.60 and 0.73).
- SASDJB2 and SASDC57 .fit files are off the data scale: `rescale = true`.
- SASDC57 has 36 altloc atoms counted twice (0.6 %). SASDC57 and SASDKJ4 have noisy tails (rule (a) of the q cut met only above 0.47 and 0.68 Å⁻¹): uncut, check sampler health and try a cut if they diverge.
- SASDKJ4 chain identity (nsp7 vs nsp8) inferred from chain size.
- SASDGD2 model carries 2214 hydrogens (re-placed by pdb2pqr) and 245 waters (dropped).
- Shared files (README tables, common.jl, dev/) were not edited; the rows above are for the owner to merge.

## Skipped (with reason)

- Most SASDA.. to SASDM.. candidates: no depositor .fit with exactly one structure (fit files `.fir`, FoXS/other formats without model, ensembles or several models), or the model exceeds 40,000 heavy atoms.
- Entries whose paper is not open access (no full text to read the buffer from): skipped rather than guessing the buffer from SASBDB.
- SASDC67: the SASBDB chi2 (1.756) disagrees with the .fit header (0.622).
- Entries already in test/fitting_tests/, notes/dropped-entries/ or the earlier skipped list were excluded up front.
- Fit1 of SASDF53, SASDJB2 and SASDC57 are `.fir` files (not used; fit2 is).
- SASDMORN siblings SASDG97 and SASDGB7: SASBDB buffer (100 mM NaCl, no glycerol) contradicts the paper's.
