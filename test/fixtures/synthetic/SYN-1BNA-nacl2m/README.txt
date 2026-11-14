SYNTHETIC entry SYN-1BNA-nacl2m  (no experimental data, no fit)

Host: 1BNA (dna), file 1BNA.pdb: the RCSB download (files.rcsb.org/download/1BNA.pdb); ATOM/HETATM records identical to test/fixtures/molecules/1BNA-TEST.pdb.
Atoms as the loader sees them: 486 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1BNA, the Dickerson-Drew B-DNA dodecamer d(CGCGAATTCGCG)2, X-ray, 1.90 Å, 2 chains of 12
nucleotides, 486 heavy atoms, 80 waters (HOH, not scattered), no other hetero group, no
alternate location. File: the RCSB download of 1BNA; its ATOM/HETATM records are identical
to the checked-in test/fixtures/molecules/1BNA-TEST.pdb (compared line by line, no
difference). Loaded as a nucleic acid alone: AMBER hydrogens through pdb2pqr, no PROPKA,
no pH dependence of the nucleic acid protonation.

Buffer (INVENTED, flagged synthetic): 2 M NaCl, pH 7.0, 25.0 C.
  sodium chloride: 2000.0000 mM (±20.0000)  2 M NaCl, ±1 %

Assumptions (details in test/synthetic_tests/SYN-1BNA-nacl2m/SYN-1BNA-nacl2m.jl):
2 M NaCl in water, no buffer (a high-salt condition). Row "sodium chloride" (ϕ° = 16.61
cm³/mol at 25 °C). 2 M is 117 g/L of NaCl (2 × 58.44). 2 M is outside the range where the
module README accepts ideal volume mixing (the apparent molar volume of a salt changes
with concentration): the excess volume is stated here and not modelled.

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.355944 e/A^3, sigma = 0.000227 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.06796

Outputs of the script (next to it): SYN-1BNA-nacl2m.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1BNA-nacl2m.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
