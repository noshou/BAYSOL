SYNTHETIC test SYN-1EHZ-peg20000  (invented buffer, no measured curve, no fit)

Host structure: PDB 1EHZ, yeast tRNA-Phe, 76 nt, 1329 ATOM records (1.93 Å X-ray).
File: 1EHZ.pdb, downloaded from https://files.rcsb.org/download/1EHZ.pdb on 2026-11-13,
unmodified. Atom counts checked against the checked-in test/fixtures/molecules/1EHZ-TEST.*
(same ATOM and HETATM counts; for 1CRN, 1BNA and 1EHZ the PDB files are byte-identical).
What the loader sees: modified nucleotides as HETATM (1MA, 2MG, 5MC, 5MU, 7MG, H2U, M2G, OMC, OMG, PSU, YYG: 11 kinds), 6 MG and 3 MN ions (kept as ligands, no hydrogens), 160 HOH (dropped); no altlocs.
Fixes of the model: none.

Buffer (invented, flagged synthetic): PEG 20000, 3 % (w/v), in water, pH 7.0 nominal, 25 C.
Solute: mol/L of chains (Mn 20000) = 0.0015 M.
Assumptions: see the comment block of test/synthetic_tests/SYN-1EHZ-peg20000/SYN-1EHZ-peg20000.jl (concentration
arithmetic and the table row used).
Table status: no fixed PEG 20000 grade (family extrapolation beyond the PEG 10000 row).

The script test/synthetic_tests/SYN-1EHZ-peg20000/SYN-1EHZ-peg20000.jl writes SYN-1EHZ-peg20000.solvent.txt (rho_e, sigma,
composition) and SYN-1EHZ-peg20000.profile.tsv (q, I on q = 0.01..0.5 A^-1, step 0.005, fixed CRYSOL3-default solvent
parameters, c1 = 1) next to itself. Benchmark: Pepsi-SAXS, CRYSOL and FoXS with the same
solvent electron density and q grid.
