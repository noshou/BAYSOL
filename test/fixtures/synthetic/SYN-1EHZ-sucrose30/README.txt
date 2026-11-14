SYNTHETIC entry SYN-1EHZ-sucrose30  (no experimental data, no fit)

Host: 1EHZ (rna), file 1EHZ.pdb: the RCSB download (files.rcsb.org/download/1EHZ.pdb); ATOM/HETATM records identical to test/fixtures/molecules/1EHZ-TEST.pdb.
Atoms as the loader sees them: 1661 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1EHZ, yeast tRNA-Phe (Saccharomyces cerevisiae), X-ray, 1.93 Å, 76 nucleotides. The file
has 1329 ATOM records (the standard nucleotides) and, as HETATM, 14 modified residues (11
types: 1MA, 2MG, 5MC, 5MU, 7MG, H2U, M2G, OMC, OMG, PSU, YYG; hydrogenated through their
parent base), 6 Mg2+ and 3 Mn2+ ions and 160 waters; no alternate location. The loader
keeps the modified residues and the 9 ions (ligands, heavy atoms without hydrogens; 1652 +
9 = 1661 heavy atoms, 2481 with hydrogens, as in test_nucleotide_fixtures) and drops the
waters. The ions are scattered although the buffer of the entry has no Mg2+ or Mn2+: that
is part of the structure, not of the buffer. File: the RCSB download of 1EHZ; its
ATOM/HETATM records are identical to the checked-in test/fixtures/molecules/1EHZ-TEST.pdb
(compared line by line, no difference). Loaded as a nucleic acid alone: AMBER hydrogens
through pdb2pqr (83 hydrogens of the modifications are not placed, about 0.7 % of the
electrons; src/hydrogenator/README.md).

Buffer (INVENTED, flagged synthetic): 30 % w/v sucrose, pH 7.0, 25.0 C.
  sucrose: 876.4319 mM (±17.5300)  30 % w/v sucrose, ±2 %

Assumptions (details in test/synthetic_tests/SYN-1EHZ-sucrose30/SYN-1EHZ-sucrose30.jl):
30 % w/v sucrose in water (a cryo-protectant / density-matching level), no buffer; pH 7.0
only sets the host's protonation. w/v means grams of sucrose per 100 mL of the final
solution, which is the molarity basis of the model (mol per litre of solution):

    300 g/L / 342.297 g/mol = 0.87642 M    (C₁₂H₂₂O₁₁: 12·12.011 + 22·1.008 + 11·15.999)

Row "sucrose" (182 electrons, ϕ° = 211.3 ± 0.3 cm³/mol). The solute displaces 18.5 % of
the water at 0.876 M, so linear mixing carries the largest uncertainty of the sugar
entries; ±2 % on the weighed mass.

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.367629 e/A^3, sigma = 0.000692 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.10302

Outputs of the script (next to it): SYN-1EHZ-sucrose30.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1EHZ-sucrose30.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
