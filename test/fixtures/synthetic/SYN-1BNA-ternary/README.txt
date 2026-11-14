SYNTHETIC entry SYN-1BNA-ternary  (no experimental data, no fit)

Host: 1BNA (dna), file 1BNA.pdb: the RCSB download (files.rcsb.org/download/1BNA.pdb); ATOM/HETATM records identical to test/fixtures/molecules/1BNA-TEST.pdb.
Atoms as the loader sees them: 486 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1BNA, the Dickerson-Drew B-DNA dodecamer d(CGCGAATTCGCG)2, X-ray, 1.90 Å, 2 chains of 12
nucleotides, 486 heavy atoms, 80 waters (HOH, not scattered), no other hetero group, no
alternate location. File: the RCSB download of 1BNA; its ATOM/HETATM records are identical
to the checked-in test/fixtures/molecules/1BNA-TEST.pdb (compared line by line, no
difference). Loaded as a nucleic acid alone: AMBER hydrogens through pdb2pqr, no PROPKA,
no pH dependence of the nucleic acid protonation.

Buffer (INVENTED, flagged synthetic): 20 % w/v sucrose + 2 M urea + 150 mM NaCl, pH 7.0, 25.0 C.
  sucrose: 584.2879 mM (±11.6858)  20 % w/v sucrose, ±2 %
  urea: 2000.0000 mM (±40.0000)  2 M urea, ±2 %
  sodium chloride: 150.0000 mM (±1.5000)  150 mM NaCl, ±1 %

Assumptions (details in test/synthetic_tests/SYN-1BNA-ternary/SYN-1BNA-ternary.jl):
Ternary co-solute mixture: 20 % w/v sucrose + 2 M urea + 150 mM NaCl in water, no buffer
(pH 7.0 only sets the host's protonation; the host is used as is). Each component is one
table row, concentrations as in the single-solute entries:

    sucrose: 200 g/L / 342.297 g/mol = 0.58429 M  (row "sucrose": 182 e)
    urea: 2 M = 120 g/L  (row "urea": 32 e)
    NaCl: 150 mM  (row "sodium chloride": 28 e)

ϕ° of the rows: 211.3, 44.23 and 16.61 cm³/mol.

The three together displace 21.4 % of the water; additivity of the partial molar volumes
(no cross terms between the sugar, the urea and the salt) is the model's assumption and
its largest error source here.

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.366941 e/A^3, sigma = 0.000497 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.10096

Outputs of the script (next to it): SYN-1BNA-ternary.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1BNA-ternary.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
