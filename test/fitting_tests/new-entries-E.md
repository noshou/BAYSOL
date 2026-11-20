# New entries, slice E (protein SASDP.. to SASDW..)

35 entries wired, none run (inputs only; each script parses with `Meta.parseall`, lines <= 92 columns,
fixtures packed with `bysl fixtures pack`). Buffers follow `notes/buffer-templates.md` (Davies, pK shifted
to the cell temperature). Every header states its buffer source: for all 35 it is the SASBDB buffer fields
(the papers were NOT read), 25 C and an unstated wavelength are flagged where used. Model: one structure
per entry; AlphaFold and preliminary models are flagged in the Notes column. Heavy-atom count in each header.

## README-table rows

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDQ28 — | USP14, Homo sapiens, 46.243 kDa monomer; 3235 heavy atoms; "20 mM HEPES, 150 mM NaCl, 2 mM TCEP", pH 7.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.056 |
| SASDQ98 — | DPCD, Homo sapiens, 23.239 kDa monomer; 1634 heavy atoms; "25 mM Tris-HCl, 200 mM NaCl", pH 7.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 0.932 |
| SASDRZ6 — | THSD7A, Homo sapiens, 16.656 kDa monomer; 1164 heavy atoms; "25mM Tris, 150 mM NaCl, 5 mM NaNO3", pH 7.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.088 |
| SASDRH8 — | AstaPo1, Coelastrella astaxanthina, 21.606 kDa monomer; 1566 heavy atoms; "20 mM Tris- HCl, 150 mM NaCl", pH 7.6. | Buffer from SASBDB only (paper not read). | CRYSOL 1.181 |
| SASDRQ8 — | BSA, Bos taurus, 66.432 kDa monomer; 4672 heavy atoms; "10 mM HEPES, 5 mM NaCl, 0.1 mM EDTA", pH 7.4. | Alternate locations in the model; buffer from SASBDB only (paper not read). | CRYSOL 1.095 |
| SASDSF7 — | Codanin1, Homo sapiens, 24.961 kDa monomer; 1743 heavy atoms; "20 mM Tris HCl, 150 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.229 |
| SASDTR2 — | TuAsV 2A3, Turkey avisivirus, 13.349 kDa monomer; 936 heavy atoms; "20 mM citrate pH 5.4, 150 mM NaCl, 2 mM TCEP, 1% glycerol", pH 5.4. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature; glycerol percentage unit not stated, v/v assumed; citrate titrant not stated, Na-only charge balance assumed. | CRYSOL 2.133 |
| SASDTT2 — | TuAsV 2A3, Turkey avisivirus, 13.349 kDa monomer; 936 heavy atoms; "20 mM HEPES, 150 mM NaCl, 2 mM TECP, 1% Glycerol", pH 7.4. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature; glycerol percentage unit not stated, v/v assumed. | CRYSOL 1.207 |
| SASDTT4 — | SLDCP, Sphaerobacter thermophilus (strain DSM 20745 / S 6022), 12.105 kDa monomer; 840 heavy atoms; "20 mM Tris, 150 mM NaCl, 3% glycerol", pH 7.6. | Ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); glycerol percentage unit not stated, v/v assumed. | CRYSOL 1.409 |
| SASDU78 — | VFT2, Trypanosoma brucei, 42.755 kDa monomer; 2927 heavy atoms; "50 mM Tris-HCl, 500 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.351 |
| SASDU89 — | ApoA-I, Homo sapiens, 21.567 kDa monomer; 1471 heavy atoms; "20 mM Tris, 150 mM NaCl, 0.1% sodium azide", pH 7.4. | Buffer from SASBDB only (paper not read). | CRYSOL 1.157 |
| SASDUV3 — | LrpA, Ligilactobacillus ruminis ATCC 25644, 48.969 kDa monomer; 3317 heavy atoms; "20 mM Tris, 150 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.435 |
| SASDUW6 — | HpARI2, Heligmosomoides polygyrus, 25.998 kDa monomer; 1792 heavy atoms; "137 mM NaCl, 2.7 mM KCl, 10 mM phosphate buffer, 5% glycerol", pH 7.2. | Buffer from SASBDB only (paper not read); glycerol percentage unit not stated, v/v assumed. | CRYSOL 1.065 |
| SASDV46 — | tau4RD domain, Homo sapiens, 13.7 kDa monomer; 1971 heavy atoms; "100 mM NaCl", pH 6.8. | Buffer from SASBDB only (paper not read); no buffering species: 100 mM NaCl only, the pH is the stated value. | CRYSOL 1.742 |
| SASDVL8 — | McGlcH, Mucor circinelloides, 44.696 kDa monomer; 3019 heavy atoms; "50 mM Tris, 150 mM NaCl", pH 7.1. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.523 |
| SASDVQ8 — | PcGlc, Penicillium rubens (strain ATCC 28089 / DSM 1075 / NRRL 1951 / Wisconsin 54-1255), 42.461 kDa monomer; 2820 heavy atoms; "50 mM sodium citrate, 150 mM NaCl", pH 4.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); citrate titrant not stated, Na-only charge balance assumed. | CRYSOL 1.094 |
| SASDVQ9 — | Full-length mature human mitochondrial ATP synthase subunit O, Homo sapiens, 20.875 kDa dimer; 2928 heavy atoms; "50 mM Na2HPO4, 300 mM NaCl", pH 7.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); phosphate titrant not stated, HCl assumed. | CRYSOL 1.232 |
| SASDVT5 — | MpARF3, Marchantia polymorpha, 45.502 kDa monomer; 3133 heavy atoms; "20 mM Tris-HCl, 150 mM NaCl, 1 mM DTT", pH 8.0. | Buffer from SASBDB only (paper not read). | CRYSOL 0.747 |
| SASDWM2 — | PRT1, Arabidopsis thaliana, 45.936 kDa monomer; 3206 heavy atoms; "50 mM Tris-HCl, 150 mM NaCl, 1 mM TCEP, 2% w/v glycerol", pH 7.5. | AlphaFold prediction (no experimental structure); ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature. | CRYSOL 1.734 |
| SASDWP9 — | MDtxRGA G149, synthetic construct, 84.189 kDa monomer; 5926 heavy atoms; "20 mM MOPS, 250 mM KCl,", pH 7.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.084 |
| SASDPW7 — | FAD-dependent monooxygenase from Stenotrophomonas maltophilia, Stenotrophomonas maltophilia, 38.941 kDa monomer; 2665 heavy atoms; "25 mM Bis-Tris, 150 mM NaCl, 30 mM DTT", pH 6.5. | Ligand HETATM groups scattered with the protein; the model is a preliminary model of PDB 8AQ8 chain C with FAD; sibling of the wired SASDPV7; buffer from SASBDB only (paper not read); Bis-Tris constants are `verified: false` in buffer_templates.json. | CRYSOL 0.894 |
| SASDSQ9 — | NanoLuc, Oplophorus gracilirostris, 20.365 kDa monomer; 1484 heavy atoms; "10 mM Tris-HCl, 50 mM NaCl", pH 7.5. | Alternate locations in the model; ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read). | CRYSOL 1.216 |
| SASDQ59 — | DpdA(D95A), Salmonella enterica subsp. enterica serovar Montevideo, 50.396 kDa monomer; 3540 heavy atoms; "100 mM KCl, 50 mM Tris pH 7.0, 1 mM DTT", pH 7.0. | Buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDWN5 — | DS6A, Mycobacterium phage DS6A, 43.458 kDa monomer; 3046 heavy atoms; "20 mM Tris, 150 mM NaCl and 1 mM DTT", pH 8.0. | Buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDSE7 — | CDIN1, Homo sapiens, 33.381 kDa dimer; 4548 heavy atoms; "20 mM Tris HCl, 150 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 2.045 |
| SASDSN8 — | Pro-Nivolumab, Lu02, None, 54.366 kDa monomer; 3822 heavy atoms; "20 mM Tris, 100 mM NaCl", pH 8.0. | Buffer from SASBDB only (paper not read). | CRYSOL 1.876 |
| SASDWW6 — | Apoferritin dimer, Equus caballus, 19.846 kDa other; 66288 heavy atoms; "137 mM NaCl, 2.7 mM KCl, 10 mM phosphate buffer, 0.9 mM CaCl2, 0.5 mM MgCl2", pH 7.4. | VERY LARGE structure (66288 heavy atoms): expect a long run time; alternate locations in the model; buffer from SASBDB only (paper not read). | CRYSOL 1.22 |
| SASDTV4 — | Fe8×FerSUMO, Helicobacter pylori (strain J99 / ATCC 700824), 31.469 kDa octamer; 17736 heavy atoms; "25 mM Tris, 150 mM NaCl", pH 7.4. | Large structure (17736 heavy atoms); AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.066 |
| SASDSU8 — | Tha1, Mus musculus, 41.366 kDa tetramer; 11130 heavy atoms; "20 mM Tris, 150 mM NaCl, 1 mM EDTA, 1 mM DTT", pH 7.8. | Large structure (11130 heavy atoms); ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read). | CRYSOL 1.145 |
| SASDVQ6 — | VPS35L, Homo sapiens, 109.618 kDa monomer; 11455 heavy atoms; "50 mM Tris, 200 mM NaCl, 1 mM TCEP", pH 7.5. | Large structure (11455 heavy atoms); AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.502 |
| SASDVG6 — | NnhA, Mycobacterium sp. (strain JS330), 43.08 kDa hexamer; 19390 heavy atoms; "25 mM Tris-HCl, 150 mM NaCl, 5% (v/v) glycerol", pH 7.6. | Large structure (19390 heavy atoms); alternate locations in the model; ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature; glycerol percentage unit not stated, v/v assumed. | CRYSOL 2.404 |
| SASDTC5 — | Full-length E3 ubiquitin-protein ligase HACE1, Homo sapiens, 102.399 kDa dimer; 14374 heavy atoms; "50 mM HEPES, 50 mM NaCl, 5 mM DTT", pH 8.0. | Large structure (14374 heavy atoms); buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDVE7 — | SaIlvA, Staphylococcus aureus (strain USA300), 48.002 kDa hexamer; 19818 heavy atoms; "20 mM KPO4, 200 mM NaCl, 0.1 mM TCEP,", pH 7.5. | Large structure (19818 heavy atoms); buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDUU3 — | AOC3, Homo sapiens, 81.784 kDa dimer; 11885 heavy atoms; "137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8 mM KH2PO4", pH 7.4. | Large structure (11885 heavy atoms); ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature. | CRYSOL 1.112 |
| SASDU98 — | MBP, Escherichia coli (strain K12), 40.248 kDa dimer; 11730 heavy atoms; "50 mM Tris pH 7.5, 150 mM NaCl", pH 7.5. | Large structure (11730 heavy atoms); the SASBDB pH field is empty; the pH is the one in the buffer name; AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.399 |

## Open points

- Glycerol given as a bare percent (SASDTR2, SASDTT2, SASDTT4, SASDUW6): taken as v/v. SASDWM2 is
  stated 2 % w/v, SASDVG6 5 % v/v.
- Citrate (SASDTR2, SASDVQ8): titrant not stated, Na-only charge balance. SASDVQ9: phosphate titrated with HCl
  assumed. SASDVE7: K phosphate with both cations K.
- SASDPW7: Bis-Tris constants are `verified: false` in the buffer templates. SASDRQ8: EDTA taken as H2EDTA.
  SASDTT2: pH taken as measured before the glycerol was added.
- SASDU98: the SASBDB pH field is empty; 7.5 comes from the buffer name.
- SASDRQ8, SASDVQ9, SASDWP9, SASDSU8 appear in the skipped list of `new-entries-B.md` (paper not open
  access, buffer not found, not a protein structure) but are wired here under the lowered bar from the SASBDB
  fields. Check that agent B did not also wire them (no folder existed when this slice started).
- Q cut only where the README noise rule held (numbers in each header); several entries have the depositor
  fit covering a smaller q range than the data (stated in the header).
- SASDQ59, SASDWN5, SASDTC5, SASDVE7 are reference-less (FoXS fit layout, or no usable fit).
- SASDPP2 (Pyrococcus Argonaute 1Z26, 6 M urea) was wired earlier in this round, but its folder and git entry
  are gone and `notes/dropped-entries` has no record: reason undocumented.

## Very large entries (run-time planning)

| Entry | heavy atoms |
|---|---|
| SASDWW6 (apoferritin dimer of 24-mers, model in the alternate-location form) | 66288 (VERY LARGE) |
| SASDVE7 | 19818 |
| SASDVG6 | 19390 |
| SASDTV4 | 17736 |
| SASDTC5 | 14374 |
| SASDUU3 | 11885 |
| SASDU98 | 11730 |
| SASDVQ6 | 11455 |
| SASDSU8 | 11130 |

Ligand/glycan content is listed in the headers of SASDUU3 (TPQ, CA, CU, NAG, MAN, FUC), SASDSU8 and SASDVG6.

## AMBIGUOUS (needs owner)

Not wired because a needed value is stated neither in SASBDB nor (as far as checked) in the paper.

| Entry | Question | Proposed default |
|---|---|---|
| SASDQS6 | PBS composition not stated | 137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8 mM KH2PO4, pH from SASBDB |
| SASDW94 | PBS composition not stated (476 kDa entry) | same PBS |
| SASDWB4, SASDWA4 | PBS + 1 % glycerol, composition and glycerol unit not stated | same PBS, glycerol v/v |
| SASDVW3 | Na/K phosphate ratio not stated | all Na |
| SASDVS8, SASDVT8 | McIlvaine buffer, citrate/phosphate composition not stated | derive from pH with the standard McIlvaine table |

## Skipped (other reasons)

- Model mass far from sample mass: SASDPX3, SASDPY3, SASDW94, SASDWV6.
- Several models per entry or ensembles: SASDQE8, SASDPP3 series. SREFLEX or other non-CRYSOL/FoXS fits.
- NMR multi-model: SASDRG9. Depositor chi2 above about 20.
- No buffer name: several. SASDRY9, SASDRZ9 (12-chain peptide-like model, MW None); SASDV74 (peptide with SEP).
- Exotic ligands: SASDVY7, SASDVZ7 (SF4, B12).

## Resolved ambiguous cases (2026-11-18)

Scripts and fixtures (.7z) written, parse-checked only, not run. Sources: paper first, SASBDB second (said in each header).
- SASDQS6: paper (Nat Commun 2024): PBS + 1.5 % glycerol, pH 7.2; the PBS recipe and the glycerol unit (v/v assumed) are not stated.
- SASDW94, SASDWA4, SASDWB4: the papers say only "PBS" (WA4/WB4 with 1 % glycerol): standard PBS, glycerol v/v assumed.
  SASDWB4 keeps its DTT and DOM ligand groups; SASDW94 stays the 33552-heavy-atom model (mass far from the sample).
- SASDVW3: "0.2 M Na/K phosphate pH 7.0, 2 mM 2-mercaptoethanol" in both paper and SASBDB; the ratio is not stated, all Na.
- SASDVS8, SASDVT8 (AnRut, no publication): McIlvaine pH 3.5 computed with the repo buffer model (Davies, I = 0.123 M):
  29.2 % of 0.2 M Na2HPO4 and 70.8 % of 0.1 M citric acid (58.4 mM phosphate, 70.8 mM citrate, 116.8 mM Na+), species by
  pH. This matches the standard McIlvaine table (about 5.9 mL of Na2HPO4 per 20 mL at pH 3.5), so NO conflict with the
  assumption; the stock concentrations themselves are assumed (each species ±10 %).
- SASDVL8: checked, the owner's glycosidase/rutinosidase SI is the one of the already wired SASDVL8; no conflict.
- SASDPP2: wired again from scratch (SASBDB model 1z26-based, 12645 atoms with hydrogens). Source: the owner's SI (apo-Pf argonaute,
  20 mM Tris-HCl, 250 mM NaCl, 2 mM DTT, 6 M urea, pH 8, 37 °C, 0.103 nm). Urea needed NOTHING new: "urea" is a neutral
  solute with a measured partial molar volume (44.2 cm3/mol) in the table; the effect of 6 M urea on the Tris pK and the
  pH reading is ignored (flagged).
