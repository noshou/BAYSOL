SYNTHETIC test SYN-6LYZ-peg8000  (invented buffer, no measured curve, no fit)

Host structure: PDB 6LYZ, hen egg-white lysozyme, 129 residues, 1001 ATOM records (2.00 Å X-ray).
File: 6LYZ.pdb, downloaded from https://files.rcsb.org/download/6LYZ.pdb on 2026-11-13,
unmodified. Atom counts checked against the checked-in test/fixtures/molecules/6LYZ-TEST.*
(same ATOM and HETATM counts; for 1CRN, 1BNA and 1EHZ the PDB files are byte-identical).
What the loader sees: 101 HOH (dropped by the loader), no ligands, no altlocs.
Fixes of the model: none.

Buffer (invented, flagged synthetic): PEG 8000, 8 % (w/v), in water, pH 7.0 nominal, 25 C.
Solute: mol/L of chains (Mn 8000) = 0.01 M.
Assumptions: see the comment block of test/synthetic_tests/SYN-6LYZ-peg8000/SYN-6LYZ-peg8000.jl (concentration
arithmetic and the table row used).
Table status: nothing missing.

The script test/synthetic_tests/SYN-6LYZ-peg8000/SYN-6LYZ-peg8000.jl writes SYN-6LYZ-peg8000.solvent.txt (rho_e, sigma,
composition) and SYN-6LYZ-peg8000.profile.tsv (q, I on q = 0.01..0.5 A^-1, step 0.005, fixed CRYSOL3-default solvent
parameters, c1 = 1) next to itself. Benchmark: Pepsi-SAXS, CRYSOL and FoXS with the same
solvent electron density and q grid.
