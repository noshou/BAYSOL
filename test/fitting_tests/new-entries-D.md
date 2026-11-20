# New entries, slice D (proteins SASDH.. to SASDN..)

30 entries wired (scripts in `test/fitting_tests/<ID>/`, fixtures in
`test/fixtures/experiments/<ID>/`, each packed with `bysl fixtures pack`). No fit, smoke run
or benchmark was run: the scripts were only parse-checked (`Meta.parseall`) and checked for
92 columns. Every buffer is the SASBDB metadata (the papers were mostly not open access),
flagged in each header. Counter-ions of Tris, Bis-Tris, HEPES, MES, acetate and phosphate
buffers follow the SASDF53 convention (Davies activities, sigma from pH/T/pK/Davies/C); the
numbers are in each header. The depositor chi2 (`refChi2`) is the SASBDB `chi_square_value`.

## README-table rows (Entry | System | Notes | refChi2)

| Entry | System | Notes | refChi2 |
|---|---|---|---|
| SASDH64 | Myosin essential light chain (Plasmodium falciparum) | 588 heavy atoms; buffer from SASBDB | CRYSOL 1.371 |
| SASDH94 | Myosin essential light chain 2 (Toxoplasma gondii) | 1264 heavy atoms; buffer from SASBDB | CRYSOL 1.158 |
| SASDHM8 | Aquifex aeolicus McoA metaloxidase ∆328-352 evolved variant  (Aquifex aeolicus) | 5927 heavy atoms; buffer from SASBDB | CRYSOL 1.003 |
| SASDHP7 | Haloalkane dehalogenase variant DhaA115 -monomeric fraction (Rhodococcus rhodochrous) | 2453 heavy atoms; buffer from SASBDB | CRYSOL 1.145 |
| SASDJL6 | Rod domain of α-actinin-2 (Homo sapiens) | 7860 heavy atoms; buffer from SASBDB | CRYSOL 1.021 |
| SASDJQ7 | Cathepsin Z (Homo sapiens) | 3816 heavy atoms; buffer from SASBDB | CRYSOL 1.13 |
| SASDJP5 | Tetanus toxin (Clostridium tetani) | 2447 heavy atoms; buffer from SASBDB | CRYSOL 1.297 |
| SASDKT9 | p450 cytochrome, putative (Moco carrier protein) (Rippkaea orientalis (strain PCC 8801)) | 4835 heavy atoms; buffer from SASBDB | CRYSOL 0.91 |
| SASDKT6 | Replicase polyprotein 1ab (non-structural protein 14) (Severe acute respiratory syndrome coronavirus 2) | 4111 heavy atoms; T 25 C default; buffer from SASBDB | CRYSOL 1.234 |
| SASDKS7 | HpcH/HpaI aldolase (Rhizorhabdus wittichii RW1) | 11304 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 1.127 |
| SASDMA9 | Diacetylchitobiose deacetylase (Thermococcus chitonophagus) | 13322 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 1.198 |
| SASDLQ3 | Interleukin-11 (W168A) (Homo sapiens) | 1423 heavy atoms; buffer from SASBDB | CRYSOL 0.918 |
| SASDM82 | Ubiquitin fold modifer 1 (Homo sapiens) | 658 heavy atoms; buffer from SASBDB | CRYSOL 1.011 |
| SASDMG8 | Non-POU domain-containing octamer-binding protein (Homo sapiens) | 4449 heavy atoms; buffer from SASBDB | CRYSOL 1.651 |
| SASDMK9 | Replicase polyprotein 1a (Severe acute respiratory syndrome-related coronavirus) | 2754 heavy atoms; T 25 C default; buffer from SASBDB | CRYSOL 1.73186 |
| SASDMS4 | Internalin B (Listeria monocytogenes serotype 1/2a (strain EGD / Mackaness)) | 2257 heavy atoms; T 25 C default; buffer from SASBDB | CRYSOL 2.969 |
| SASDLY8 | Recombinant Mycobacterium tuberculosis H37Rv (Mycobacterium tuberculosis H37Rv) | 4564 heavy atoms; buffer from SASBDB | CRYSOL 0.936 |
| SASDMC9 | Glycogen synthase kinase 3 (Plasmodium falciparum (isolate 3D7)) | 3628 heavy atoms; buffer from SASBDB | CRYSOL 1.237 |
| SASDJ92 | Extracellular matrix binding protein F-repeats (Staphylococcus epidermidis) | 4406 heavy atoms; buffer from SASBDB | CRYSOL 2.236 |
| SASDK74 | Transcriptional repressor BusR RCK_C domain (Streptococcus agalactiae serotype III (strain NEM316)) | 1588 heavy atoms; buffer from SASBDB | CRYSOL 3.364 |
| SASDJX7 | Similar to Aedes aegypti 34 kDa salivary secreted protein 34 (Aedes albopictus) | 2424 heavy atoms; buffer from SASBDB | CRYSOL 1.666 |
| SASDLM3 | Interleukin-6 receptor subunit beta (Homo sapiens) | 12014 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 3.065 |
| SASDJC5 | SUN domain-containing protein 1 (Homo sapiens) | 10562 heavy atoms; VERY LARGE; q cut 0.3; buffer from SASBDB | CRYSOL 1.619 |
| SASDLQ2 | L-lactate dehydrogenase (Plasmodium falciparum) | 9848 heavy atoms; VERY LARGE; T 25 C default; buffer from SASBDB | CRYSOL 0.867 |
| SASDJ75 | Piwi protein AF_1318 (Archaeoglobus fulgidus) | 6964 heavy atoms; q cut 0.2; 2 runs (fit1, fit2); buffer from SASBDB | CRYSOL 1.699, CRYSOL 1.252 |
| SASDJW5 | Plasminogen activator inhibitor 1 (Homo sapiens) | 4098 heavy atoms; q cut 0.5; buffer from SASBDB | CRYSOL 1.392 |
| SASDJB6 | gp11 encapsidation protein (Lactococcus phage Phi28) | 31240 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 0.993 |
| SASDKY7 | Alpha-L-fucosidase (Paenibacillus thiaminolyticus (Bacillus thiaminolyticus)) | 22520 heavy atoms; VERY LARGE; q cut 0.2; buffer from SASBDB | CRYSOL 1.032 |
| SASDH23 | Alpha domain of Ag43a (Escherichia coli) | 3477 heavy atoms; buffer from SASBDB | CRYSOL 0.743044 |
| SASDJJ4 | Collagen alpha-3(VI) chain, N2 domain (Homo sapiens) | 1558 heavy atoms; buffer from SASBDB | CRYSOL 1.039 |
## Very large structures (plan the run time)

SASDJB6 (31240 heavy atoms), SASDKY7 (22520, q cut 0.2), SASDMA9 (13322), SASDLM3 (12014),
SASDKS7 (11304), SASDJC5 (10562, q cut 0.3), SASDLQ2 (9848). Everything else is below 8000.

## Open points (flagged in the headers, none blocks a run)

- Buffer values are SASBDB's, not the papers'. Where the paper was read (SASDHM8, JC5, JL6,
  JP5, KT6, KT9) it was not used to override SASBDB.
- Temperature defaults to 25 C (SASBDB gives none): SASDKT6, SASDMK9, SASDMS4, SASDLQ2.
  Wavelength was taken from the SASBDB field or experiment description.
- SASDMK9: the .fit header chi2 is 1.316, SASBDB's value is 1.73186 (used as refChi2); the fit
  file is normalised, so `rescale = true` (also SASDLM3). SASDH23: header 0.862, SASBDB
  0.743044 (used).
- Depositor fits that end below the data q (SASDJ75, JW5, KY7, JC5): q cuts were set from
  the noise statistics (numbers in each header), not from the fit range.
- SASDJQ7: EDTA assumed as Na2EDTA (H2EDTA(2-) plus 2 Na+). SASDLQ3 and SASDLM3: "0.2 %
  sodium azide" taken as w/v (30.8 mM). SASDKT9/JJ4/JW5/KT9: glycerol taken as v/v.
- Bis-Tris pK constants (SASDJW5) are the unverified ones of the buffer templates.
- SASDJ75 has two runs (fit1 from PDB 1W9H, fit2 from PDB 1YTU): two single-structure fits
  of one sample, not a multi-structure fit; it has no publication DOI in SASBDB.
- Alternate-location atoms are left to the loader's own handling (SASDKT9 and others).

## AMBIGUOUS (needs owner)

- SASDHP7: SASBDB states "50 mM potassium phosphate (41 mM K2HPO4, 9 mM KH2PO4)" and pH
  7.5, which are inconsistent (41/9 gives pH about 7.8). Question: which wins? Proposed
  default (used): the stated 41/9 salts, pH 7.5 kept in the header as is; the alternative is
  the 38 mM/12 mM mix that gives pH 7.5.

## Skipped

- SASDME2, SASDMD2: not wired (reference fit scale not resolved; no further check made).
- Dropped earlier by the owner: SASDF39, SASDMU7, SASDPT4, SASDRW2.
- Ensembles, multi-state and multi-structure entries, entries with unresolvable residue
  names, and entries already in `test/fitting_tests/` or wired by other agents: not listed
  one by one.

## Resolved ambiguous cases (2026-11-18)

- SASDHP7: the paper was read: "41 mM K2HPO4, 9 mM KH2PO4, pH 7.5" for the blank, measurements at 293 K (= 20 °C), Cu Kα
  1.54 Å, 0.48 m; all agree with SASBDB and with the script, only its header now cites the paper first.
