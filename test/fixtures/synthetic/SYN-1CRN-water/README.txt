SYNTHETIC entry SYN-1CRN-water  (no experimental data, no fit)

Host: 1CRN (protein), file 1CRN.pdb: the RCSB download (files.rcsb.org/download/1CRN.pdb); ATOM/HETATM records identical to test/fixtures/molecules/1CRN-TEST.pdb.
Atoms as the loader sees them: 327 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1CRN, crambin (Crambe hispanica subsp. abyssinica seed protein), X-ray, 1.50 Å, 46
residues, 3 disulfides, 327 heavy atoms, no hetero group, no water, no alternate location
in the file. It is the smallest protein of the set (about 4.7 kDa), so the solvent term is
a large share of its contrast. File: the RCSB download of 1CRN; its ATOM/HETATM records
are identical to the checked-in test/fixtures/molecules/1CRN-TEST.pdb (compared line by
line, no difference). Loaded as a protein: PROPKA + PARSE hydrogens at the entry pH.

Buffer (INVENTED, flagged synthetic): pure water (control), pH 7.0, 25.0 C.
  (none)

Assumptions (details in test/synthetic_tests/SYN-1CRN-water/SYN-1CRN-water.jl):
Pure water, pH 7.0, no solute: the control of the series. The solvent electron density is
the one of water at 25 °C (Kell 1975, 0.333292 e/Å³, σ 20 ppm of the mass density), so
every other entry reads as a change against this one. The solute list is empty on purpose
(`Solute[]`), which also checks that the machinery accepts a buffer without components.

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.333292 e/A^3, sigma = 0.000007 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.00000

Outputs of the script (next to it): SYN-1CRN-water.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1CRN-water.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
