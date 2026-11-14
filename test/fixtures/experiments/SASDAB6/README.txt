SASBDB entry SASDAB6  (https://www.sasbdb.org/data/SASDAB6/)

Xylose (glucose) isomerase, Streptomyces rubiginosus (tetramer, 149 kDa), 5.76 mg/ml in 20 mM HEPES,
200 mM Na2SO4, 50 mM K2SO4, 1 mM MgCl2, 50 % v/v D2O, SASBDB pH 6.6 (pD 7.0), 10 C; EMBL P12.
Paper (round-6 audit): pH 7.0, 20 C, lambda 0.124 nm; the paper wins, the script uses those.
Publication: Franke D, Jeffries CM, Svergun DI, "Correlation Map, a goodness-of-fit test for
one-dimensional X-ray scattering spectra", Nat Methods 2015, DOI 10.1038/nmeth.3358.
Files, all from SASBDB (https://www.sasbdb.org/rest-api/entry/summary/SASDAB6/) except 4E3V.pdb:
  experimental_data/SASDAB6.dat    media/intensities_files/SASDAB6.dat (q in nm^-1)
  SASDAB6_fit2.fit                 media/fitting_files/SASDAB6_fit2.fit (CRYSOL 3.0, q in A^-1)
  SASDAB6_fit2_model1.pdb          media/pdb_file/SASDAB6_fit2_model1.pdb (atomic, "Based on PDB
                                   4E3V"; tetramer A-D, 12 056 records, no hydrogens). Eight
                                   HETATM atoms of one proline in chain B carry the residue name
                                   "d" instead of "PRO"; the file is NOT modified.
  4E3V.pdb                         RCSB asymmetric unit (chain A), kept for comparison.
SASDAB6 has four fits: fit1 DAMMIF (chi2 1.355), fit2 CRYSOL (chi2 1.411; used), fit3 and
fit4 (no model). The .fit header says "Chi:1.188" = sqrt(1.411): the header is a chi, the
REST value the chi2; the script uses 1.411.
The fitting script test/fitting_tests/SASDAB6/ states the conditions; the paper (franke2015.pdf in
sources/, Online Methods) was read 2026-11-13 and overrides SASBDB where they differ (20 C, pH 7.0,
0.124 nm). No file was modified.

q cut (round 9, 2026-11-13): the script fits q <= 0.18 A^-1 and leaves out the noise tail: S/N about 1.4 beyond 0.18; 75 of 1297 points non-positive, the first at 0.183; above the cut 647 points, mean I/sigma 1.3.
Every other entry without such a tail is fitted over its whole curve.
