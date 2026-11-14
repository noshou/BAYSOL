SASBDB entry SASDEL7  (https://www.sasbdb.org/data/SASDEL7/)

Human glycine decarboxylase dimer, ESRF BM29, 10 mM Tris pH 7.5, 100 mM NaCl, 1 mM DTT
(no glycine in the buffer). SASBDB lists no publication.
Files:
  experimental_data/SASDEL7.dat    SASBDB intensities file (q in nm^-1)
  SASDEL7_fit1.fit                 SASBDB fitting file (CRYSOL, THREE columns: q in A^-1,
                                   I_exp, I_fit; chi2 3.155)
  6I33.pdb                         SASBDB model (identical to PDB 6I33)
  6I33_rcsb.pdb                    files.rcsb.org/download/6I33.pdb (same atoms; record order
                                   and HETATM numbering differ; nothing modified)
The fitting script states the conditions it takes from the entry; no paper was consulted.

q cut (round 9, 2026-11-13): the script fits q <= 0.425 A^-1 and leaves out the noise tail: S/N 2-5 up to 0.4 then noise; above the cut 29 of 146 points non-positive (first at 0.381), mean I/sigma 0.8 (raised from 0.25 in round 9).
Every other entry without such a tail is fitted over its whole curve.
