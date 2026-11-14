SASBDB entry SASDNS2  (https://www.sasbdb.org/data/SASDNS2/)

Native human haemoglobin (alpha2-beta2, 53 kDa), 5 mg/ml in Ringer's lactate solution, pH 6.5, no
temperature given; EMBL X33, DORIS III, measured 2006.
Publication: Svergun D, Ekstrom F, Vandegriff K, Malavalli A, Baker D, Nilsson C, Winslow R,
"Solution Structure of Poly(ethylene) Glycol-Conjugated Hemoglobin Revealed by Small-Angle X-Ray
Scattering: Implications for a New Oxygen Therapeutic", Biophys J 2008,
DOI 10.1529/biophysj.107.114314 (not reached, not consulted).
Files:
  experimental_data/SASDNS2.dat    SASBDB media/intensities_files/SASDNS2.dat (q in nm^-1)
  SASDNS2_fit2.fit                 SASBDB media/fitting_files/SASDNS2_fit2.fit (CRYSOL, THREE
                                   columns q, I_exp, I_fit, q in A^-1)
  2DN1.pdb                         RCSB human haemoglobin, the asymmetric unit (chains A and B), as
                                   downloaded (SASBDB lists its model as identical to 2DN1, 32.19 kDa,
                                   but the model file SASDNS2_fit2_model1.PDB was not available: 404).
  SASDNS2_fit2_2DN1_tetramer.pdb   BUILT here from 2DN1.pdb: HOH and ANISOU records removed, chains A
                                   and B kept, chains C and D generated with the file's BIOMT
                                   operator 2 (y, x, -z), atoms renumbered; 4552 records, closest
                                   distance between a generated and an original atom 2.49 A. The
                                   depositor's CRYSOL fit is the tetramer (header Vol 85764, RGT
                                   24.31), inferred from those numbers; not stated.
SASDNS2 has three fits: fit1 GASBOR (chi2 8.35), fit2 CRYSOL against 2DN1 (REST 7.634; used) and
fit3 CRYSOL against 2DN2 (chi2 12.24). The .fit header says "Chi:2.763"; 2.763^2 = 7.634, and the
chi2 recomputed from the .fit and the .dat sigma is about 2.70, so the header number is the chi2
and the script uses 2.763.

Round 6 (owner, 2026-11-13): temperature taken as 25 C (stated by neither paper nor SASBDB); Ringer lactate = USP recipe. KEEP.
