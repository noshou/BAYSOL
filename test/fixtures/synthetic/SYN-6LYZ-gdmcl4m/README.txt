SYNTHETIC entry SYN-6LYZ-gdmcl4m  (no experimental data, no fit)

Host: 6LYZ (protein), file 6LYZ.pdb: the RCSB download (files.rcsb.org/download/6LYZ.pdb); the repository has only the .cif of this entry, so the .pdb download is used.
Atoms as the loader sees them: 1001 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

6LYZ, hen egg-white lysozyme (Gallus gallus), X-ray, 2.00 Å, 129 residues, 1001 heavy
atoms, 4 disulfides, 101 waters (HOH, not scattered), no other hetero group, no alternate
location. File: the RCSB download of 6LYZ in PDB format (the repository only has the mmCIF
test/fixtures/molecules/6LYZ-TEST.cif, whose atom records were not compared). Loaded as a
protein: PROPKA + PARSE hydrogens at the entry pH.

Buffer (INVENTED, flagged synthetic): 4 M guanidinium chloride, pH 7.0, 25.0 C.
  guanidinium chloride: 4000.0000 mM (±80.0000)  4 M GdmCl, ±2 %

Assumptions (details in test/synthetic_tests/SYN-6LYZ-gdmcl4m/SYN-6LYZ-gdmcl4m.jl):
4 M guanidinium chloride in water, no buffer (a denaturing solution; the folded 6LYZ
structure is used as it is). 4 M is 382 g/L (4 × 95.53). Row "guanidinium chloride" (alias
guanidine hydrochloride; 50 electrons, ϕ° = 67.53 ± 0.13 cm³/mol), which displaces 27 % of
the water. A strong electrolyte stored as the salt, so the chloride needs no extra row.
Linear mixing at 4 M is an approximation (stated, not modelled).

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.363706 e/A^3, sigma = 0.000633 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.09125

Outputs of the script (next to it): SYN-6LYZ-gdmcl4m.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-6LYZ-gdmcl4m.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
