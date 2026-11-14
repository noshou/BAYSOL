SYNTHETIC test SYN-1BNA-ficoll70  (invented buffer, no measured curve, no fit)

Host structure: PDB 1BNA, Dickerson-Drew dodecamer CGCGAATTCGCG, two chains (A, B), 486 ATOM records (1.90 Å X-ray).
File: 1BNA.pdb, downloaded from https://files.rcsb.org/download/1BNA.pdb on 2026-11-13,
unmodified. Atom counts checked against the checked-in test/fixtures/molecules/1BNA-TEST.*
(same ATOM and HETATM counts; for 1CRN, 1BNA and 1EHZ the PDB files are byte-identical).
What the loader sees: 80 HOH (dropped by the loader), no ions, no altlocs.
Fixes of the model: none.

Buffer (invented, flagged synthetic): Ficoll 70, 10 % (w/v), in water, pH 7.0 nominal, 25 C.
Solute: mol per 1000 Da of polymer per litre = 0.1 (per kDa).
Assumptions: see the comment block of test/synthetic_tests/SYN-1BNA-ficoll70/SYN-1BNA-ficoll70.jl (concentration
arithmetic and the table row used).
Table status: nothing missing from the table, but the Ficoll 70 row is cited-unverified.

The script test/synthetic_tests/SYN-1BNA-ficoll70/SYN-1BNA-ficoll70.jl writes SYN-1BNA-ficoll70.solvent.txt (rho_e, sigma,
composition) and SYN-1BNA-ficoll70.profile.tsv (q, I on q = 0.01..0.5 A^-1, step 0.005, fixed CRYSOL3-default solvent
parameters, c1 = 1) next to itself. Benchmark: Pepsi-SAXS, CRYSOL and FoXS with the same
solvent electron density and q grid.
