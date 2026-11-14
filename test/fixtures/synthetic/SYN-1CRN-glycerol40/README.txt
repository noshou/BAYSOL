SYNTHETIC entry SYN-1CRN-glycerol40  (no experimental data, no fit)

Host: 1CRN (protein), file 1CRN.pdb: the RCSB download (files.rcsb.org/download/1CRN.pdb); ATOM/HETATM records identical to test/fixtures/molecules/1CRN-TEST.pdb.
Atoms as the loader sees them: 327 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1CRN, crambin (Crambe hispanica subsp. abyssinica seed protein), X-ray, 1.50 Å, 46
residues, 3 disulfides, 327 heavy atoms, no hetero group, no water, no alternate location
in the file. It is the smallest protein of the set (about 4.7 kDa), so the solvent term is
a large share of its contrast. File: the RCSB download of 1CRN; its ATOM/HETATM records
are identical to the checked-in test/fixtures/molecules/1CRN-TEST.pdb (compared line by
line, no difference). Loaded as a protein: PROPKA + PARSE hydrogens at the entry pH.

Buffer (INVENTED, flagged synthetic): 40 % v/v glycerol, pH 7.0, 25.0 C.
  glycerol: 5478.3156 mM (±273.9158)  40 % v/v glycerol, ±5 %

Assumptions (details in test/synthetic_tests/SYN-1CRN-glycerol40/SYN-1CRN-glycerol40.jl):
40 % v/v glycerol in water, no buffer; pH 7.0 only sets the host's protonation. The volume
fraction is turned into a molarity as the SASBDB scripts do (SASDA58, SASDRJ8): 400 mL of
pure glycerol per litre, density 1.2613 g/mL (as in those scripts, the 20 °C value; not
re-derived for 25 °C) and M = 92.094 g/mol:

    0.40 L/L × 1261.3 g/L / 92.094 g/mol = 5.4784 M

±5 % because v/v against ideal volume mixing is an approximation (the mixing contraction
is not modelled). Row "glycerol" (50 electrons, ϕ° = 70.95 cm³/mol, no stated uncertainty:
the fallback 3.04 cm³/mol enters, and at 5.5 M it dominates σρₑ). Linear mixing at 5.5 M
is the weakest assumption of the whole series (README of BulkElectronDensity: 'users must
supply their own values' at such concentrations).

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.368702 e/A^3, sigma = 0.005834 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.10624

Outputs of the script (next to it): SYN-1CRN-glycerol40.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1CRN-glycerol40.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
