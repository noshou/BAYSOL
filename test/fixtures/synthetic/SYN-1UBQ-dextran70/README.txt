SYNTHETIC test SYN-1UBQ-dextran70  (invented buffer, no measured curve, no fit)

Host structure: PDB 1UBQ, human ubiquitin, 76 residues, 602 ATOM records (1.80 Å X-ray).
File: 1UBQ.pdb, downloaded from https://files.rcsb.org/download/1UBQ.pdb on 2026-11-13,
unmodified. Atom counts checked against the checked-in test/fixtures/molecules/1UBQ-TEST.*
(same ATOM and HETATM counts; for 1CRN, 1BNA and 1EHZ the PDB files are byte-identical).
What the loader sees: 58 HOH (dropped by the loader), no ligands, no altlocs.
Fixes of the model: none.

Buffer (invented, flagged synthetic): dextran 70 kDa, 10 % (w/v), in water, pH 7.0 nominal, 25 C.
Solute: mol/L of chains (Mn 70 kDa) = 0.00142857 M.
Assumptions: see the comment block of test/synthetic_tests/SYN-1UBQ-dextran70/SYN-1UBQ-dextran70.jl (concentration
arithmetic and the table row used).
Table status: nothing missing.

The script test/synthetic_tests/SYN-1UBQ-dextran70/SYN-1UBQ-dextran70.jl writes SYN-1UBQ-dextran70.solvent.txt (rho_e, sigma,
composition) and SYN-1UBQ-dextran70.profile.tsv (q, I on q = 0.01..0.5 A^-1, step 0.005, fixed CRYSOL3-default solvent
parameters, c1 = 1) next to itself. Benchmark: Pepsi-SAXS, CRYSOL and FoXS with the same
solvent electron density and q grid.
