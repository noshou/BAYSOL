SYNTHETIC test SYN-1CRN-pva  (invented buffer, no measured curve, no fit)

Host structure: PDB 1CRN, crambin, 46 residues, 327 heavy atoms (1.50 Å X-ray).
File: 1CRN.pdb, downloaded from https://files.rcsb.org/download/1CRN.pdb on 2026-11-13,
unmodified. Atom counts checked against the checked-in test/fixtures/molecules/1CRN-TEST.*
(same ATOM and HETATM counts; for 1CRN, 1BNA and 1EHZ the PDB files are byte-identical).
What the loader sees: no HETATM records (no waters, no ligands), no altlocs.
Fixes of the model: none.

Buffer (invented, flagged synthetic): PVA (poly(vinyl alcohol)), 3 % (w/v), in water, pH 7.0 nominal, 25 C.
Solute: mol/L of monomer units (C2H4O) = 0.68099 M.
Assumptions: see the comment block of test/synthetic_tests/SYN-1CRN-pva/SYN-1CRN-pva.jl (concentration
arithmetic and the table row used).
Table status: nothing missing.

The script test/synthetic_tests/SYN-1CRN-pva/SYN-1CRN-pva.jl writes SYN-1CRN-pva.solvent.txt (rho_e, sigma,
composition) and SYN-1CRN-pva.profile.tsv (q, I on q = 0.01..0.5 A^-1, step 0.005, fixed CRYSOL3-default solvent
parameters, c1 = 1) next to itself. Benchmark: Pepsi-SAXS, CRYSOL and FoXS with the same
solvent electron density and q grid.
