SYNTHETIC entry SYN-6LYZ-mgcl2kcl  (no experimental data, no fit)

Host: 6LYZ (protein), file 6LYZ.pdb: the RCSB download (files.rcsb.org/download/6LYZ.pdb); the repository has only the .cif of this entry, so the .pdb download is used.
Atoms as the loader sees them: 1001 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

6LYZ, hen egg-white lysozyme (Gallus gallus), X-ray, 2.00 Å, 129 residues, 1001 heavy
atoms, 4 disulfides, 101 waters (HOH, not scattered), no other hetero group, no alternate
location. File: the RCSB download of 6LYZ in PDB format (the repository only has the mmCIF
test/fixtures/molecules/6LYZ-TEST.cif, whose atom records were not compared). Loaded as a
protein: PROPKA + PARSE hydrogens at the entry pH.

Buffer (INVENTED, flagged synthetic): 20 mM MgCl2 + 100 mM KCl, pH 7.0, 25.0 C.
  magnesium chloride: 20.0000 mM (±0.4000)  20 mM MgCl₂, ±2 %
  potassium chloride: 100.0000 mM (±1.0000)  100 mM KCl, ±1 %

Assumptions (details in test/synthetic_tests/SYN-6LYZ-mgcl2kcl/SYN-6LYZ-mgcl2kcl.jl):
20 mM MgCl2 + 100 mM KCl in water, no buffer (pH 7.0 only sets the host's protonation). A
divalent salt next to a monovalent one. Rows "magnesium chloride" (alias of the table's
magnesium dichloride, 46 electrons, ϕ° = 14.49 cm³/mol, no stated uncertainty, so the
fallback 3.04 cm³/mol is used) and "potassium chloride" (36 electrons, ϕ° = 26.81). No ion
pairing is modelled (none stored).

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.335024 e/A^3, sigma = 0.000027 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.00520

Outputs of the script (next to it): SYN-6LYZ-mgcl2kcl.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-6LYZ-mgcl2kcl.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
