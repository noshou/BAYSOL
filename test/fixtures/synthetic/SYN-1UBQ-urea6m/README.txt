SYNTHETIC entry SYN-1UBQ-urea6m  (no experimental data, no fit)

Host: 1UBQ (protein), file 1UBQ.pdb: the RCSB download (files.rcsb.org/download/1UBQ.pdb); the repository has only the .cif of this entry, so the .pdb download is used.
Atoms as the loader sees them: 602 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1UBQ, human ubiquitin, X-ray, 1.80 Å, 76 residues, 602 heavy atoms, 58 waters (HOH, not
scattered: the loader drops waters), no other hetero group, no alternate location. File:
the RCSB download of 1UBQ in PDB format (the repository only has the mmCIF
test/fixtures/molecules/1UBQ-TEST.cif, whose atom records were not compared). Loaded as a
protein: PROPKA + PARSE hydrogens at the entry pH.

Buffer (INVENTED, flagged synthetic): 6 M urea, pH 7.0, 25.0 C.
  urea: 6000.0000 mM (±120.0000)  6 M urea, ±2 %

Assumptions (details in test/synthetic_tests/SYN-1UBQ-urea6m/SYN-1UBQ-urea6m.jl):
6 M urea in water, no buffer (a denaturing solution; the folded 1UBQ structure is used as
it is, the real protein would unfold, which is irrelevant for a solvent-term benchmark). 6
M is 360 g/L (6 × 60.06). Row "urea" (32 electrons, ϕ° = 44.23 ± 0.05 cm³/mol), which
displaces 26.5 % of the water. The module README gives +8.15 % in ρₑ for 6 M urea and
states a 2 cm³/mol error in ϕ° moves it by 1.1 %.

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.360468 e/A^3, sigma = 0.000553 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.08154

Outputs of the script (next to it): SYN-1UBQ-urea6m.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1UBQ-urea6m.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
