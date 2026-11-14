SASBDB entry SASDUX3  (https://www.sasbdb.org/data/SASDUX3/)

Actin filament fragment (17 subunits), 50 mM Tris-HCl, KCl, MgCl2, ATP, 2-ME
Publication DOI: 10.1016/j.ijbiomac.2024.134556
The publisher's PDF is not kept in this folder. The paper was consulted only for SASDRR8
(Europe PMC); the others were unreachable, so their buffer, temperature and wavelength are
the SASBDB entry's (see the header of test/fitting_tests/SASDUX3/SASDUX3_fit1.jl).

Files: SASDUX3_fit1_model1.pdb (SASBDB's model with three fixes, below), SASDUX3_fit1.fit (depositor fit),
experimental_data/SASDUX3.dat. Reference: CRYSOL 2.314 (header Chi^2 2.314 = chi2; SASBDB fits: 2.314, 3.108, 7.705; fit1 used).
Conditions: 10 °C, 0.155 nm (SASBDB).
Model: 50337 heavy atoms (17 chains). FIXES applied to the deposited model (only record/name changes, no coordinates):
  1. ADP (459 atoms, 27 per chain): ATOM -> HETATM, so the loader treats it as a ligand.
  2. Residue 73 (187 atoms, 11 per chain): HMS -> HIC, atom CM -> CZ. HMS in the wwPDB table is a saccharide
     phosphate; this residue is actin's methylhistidine (methyl on NE2), HIC in the table (parent HIS).
  3. MTL, element "M" (17 atoms, one per chain beside the ADP): the Mg2+ of Mg-ADP -> residue MG, atom MG,
     element MG, HETATM.
  Not yet run through the loader (owner's run confirms).

Fit range (2026-11-13): the script cuts at q = 0.3 1/A (flat noise floor: above it 546 points, median I/sigma 0.20, 41 % I <= 0).
