SYNTHETIC entry SYN-1UBQ-nacl150  (no experimental data, no fit)

Host: 1UBQ (protein), file 1UBQ.pdb: the RCSB download (files.rcsb.org/download/1UBQ.pdb); the repository has only the .cif of this entry, so the .pdb download is used.
Atoms as the loader sees them: 602 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1UBQ, human ubiquitin, X-ray, 1.80 Å, 76 residues, 602 heavy atoms, 58 waters (HOH, not
scattered: the loader drops waters), no other hetero group, no alternate location. File:
the RCSB download of 1UBQ in PDB format (the repository only has the mmCIF
test/fixtures/molecules/1UBQ-TEST.cif, whose atom records were not compared). Loaded as a
protein: PROPKA + PARSE hydrogens at the entry pH.

Buffer (INVENTED, flagged synthetic): 150 mM NaCl, pH 7.0, 25.0 C.
  sodium chloride: 150.0000 mM (±1.5000)  150 mM NaCl, ±1 %

Assumptions (details in test/synthetic_tests/SYN-1UBQ-nacl150/SYN-1UBQ-nacl150.jl):
150 mM NaCl in water, no buffer (pH 7.0 only sets the protonation of the host). NaCl is
the table's salt row "sodium chloride" (28 electrons, ϕ° = 16.61 cm³/mol), molarity in
mol/L, ±1 % (weighing and volume).

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.334991 e/A^3, sigma = 0.000018 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.00510

Outputs of the script (next to it): SYN-1UBQ-nacl150.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1UBQ-nacl150.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
